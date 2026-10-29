import { and, eq, isNull, sql, desc } from "drizzle-orm";
import { db } from "../db/client.js";
import { transactions, merchantPlaces, categories } from "../db/schema.js";
import { getAnthropic } from "./anthropic.js";

// Where purchases happened, for the map on a transaction. The bank's own street address wins; then the
// street address many cards print at the end of the statement line; then a one-time web lookup per merchant.

const MODEL = process.env.MERCHANT_MODEL ?? "claude-opus-5-5";
const BATCH = 8;
const PER_RUN = 48;
const NO_PLACE_CATEGORIES = ["Income", "Transfer", "Subscriptions", "Bills & Utilities", "Fees"];

const STATE = /^(AL|AK|AZ|AR|CA|CO|CT|DE|DC|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY)$/;
const STREET_WORD = /^(ST|AVE|AV|RD|DR|BLVD|HWY|EXPY|LN|WAY|PKWY|CT|PL|CIR|TRL|PIKE|SQ|TER|LOOP)$/;

const titleCase = (w: string) =>
  /^(N|S|E|W|NE|NW|SE|SW|US)$/.test(w) ? w : /^\d/.test(w) ? w.toLowerCase() : w.charAt(0) + w.slice(1).toLowerCase();

/**
 * Many cards end the statement line with where the purchase happened, e.g.
 * "MCDONALD'S F1234 1912 VALLEY BLUFFS DR SE MINOT 58701 ND USA". Returns the street address when the line
 * has one (a house number followed later by a street word), so the map can go straight to it.
 */
export function addressFromStatement(desc: string | null | undefined, city?: string | null): string | null {
  if (!desc) return null;
  const toks = desc.toUpperCase().replace(/[,]/g, " ").trim().split(/\s+/);
  while (toks.length && (toks[toks.length - 1] === "USA" || toks[toks.length - 1] === "US")) toks.pop();
  let state: string | null = null, zip: string | null = null;
  for (let k = 0; k < 2 && toks.length; k++) {
    const last = toks[toks.length - 1];
    if (!zip && /^\d{5}(-?\d{4})?$/.test(last)) { zip = last.slice(0, 5); toks.pop(); continue; }
    if (!state && STATE.test(last)) { state = last; toks.pop(); continue; }
  }
  if (!state) return null;
  // house number: a token after the first that starts with digits and is followed by a street word somewhere
  const start = toks.findIndex((t, k) => k > 0 && /^\d{1,6}[A-Z]?$/.test(t) && toks.slice(k + 1).some((w) => STREET_WORD.test(w)));
  if (start < 0) return null;
  let rest = toks.slice(start);
  const cityWords = city ? city.toUpperCase().split(/\s+/) : [];
  let townWords: string[] = [];
  if (cityWords.length && rest.slice(-cityWords.length).join(" ") === cityWords.join(" ")) {
    townWords = rest.slice(-cityWords.length);
    rest = rest.slice(0, -cityWords.length);
  } else {
    // the town is whatever follows the last street word or direction
    const lastStreet = rest.reduce((at, w, k) => (STREET_WORD.test(w) || /^(N|S|E|W|NE|NW|SE|SW)$/.test(w) ? k : at), -1);
    if (lastStreet >= 0 && lastStreet < rest.length - 1) { townWords = rest.slice(lastStreet + 1); rest = rest.slice(0, lastStreet + 1); }
  }
  if (rest.length < 2) return null;
  const street = rest.map(titleCase).join(" ");
  const town = (townWords.length ? townWords : cityWords).map(titleCase).join(" ");
  return [street, [town, [state, zip].filter(Boolean).join(" ")].filter(Boolean).join(", ")].filter(Boolean).join(", ");
}

/** "MCDONALD'S F12345" and "McDonald's #12345" look up as the same merchant. */
export function merchantKey(name: string, storeNumber: string | null, city: string | null): string {
  const base = name
    .toLowerCase()
    .replace(/^(sq|tst|fsp|pp|sp|py|dd|4up)\s*\*\s*/, "")
    .replace(/#\s*\d+/g, " ")
    .replace(/\b[a-z]?\d{3,}\b/g, " ")
    .replace(/[^a-z0-9& ]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return [base, storeNumber ?? "", (city ?? "").toLowerCase()].join("|");
}

export function formatPlace(p: { address: string | null; city: string | null; region: string | null; postal: string | null }): string | null {
  if (!p.address || !/^\d/.test(p.address.trim())) return null;
  return [p.address.trim(), [p.city, [p.region, p.postal].filter(Boolean).join(" ")].filter(Boolean).join(", ")].filter(Boolean).join(", ");
}

interface Candidate {
  key: string;
  name: string;
  storeNumber: string | null;
  city: string | null;
  region: string | null;
  statement: string | null;
  count: number;
}

/** Purchases still missing a street address, grouped by merchant. */
async function unplacedPurchases(userId: string) {
  return db
    .select({
      id: transactions.id,
      name: transactions.name,
      merchantName: transactions.merchantName,
      storeNumber: transactions.storeNumber,
      city: transactions.city,
      region: transactions.region,
      statement: transactions.originalDescription,
    })
    .from(transactions)
    .leftJoin(categories, eq(categories.id, sql`coalesce(${transactions.userCategoryId}, ${transactions.categoryId})`))
    .where(
      and(
        eq(transactions.userId, userId),
        isNull(transactions.deletedAt),
        isNull(transactions.place),
        isNull(transactions.lat),
        sql`coalesce(${transactions.paymentChannel}, '') <> 'online'`,
        sql`${transactions.amount} > 0`,
        sql`coalesce(${categories.name}, '') not in (${sql.join(NO_PLACE_CATEGORIES.map((c) => sql`${c}`), sql`, `)})`
      )
    );
}

/** Copies already-found addresses onto purchases at the same merchant. Cheap; runs after every sync. */
export async function applyKnownPlaces(userId: string): Promise<number> {
  const known = await db.select().from(merchantPlaces).where(eq(merchantPlaces.userId, userId));
  const usable = new Map(
    known.filter((k) => k.confidence !== "low").map((k) => [k.key, formatPlace(k)] as const).filter(([, p]) => p)
  );
  if (usable.size === 0) return 0;
  let n = 0;
  for (const t of await unplacedPurchases(userId)) {
    const place = usable.get(merchantKey(t.merchantName ?? t.name, t.storeNumber, t.city));
    if (!place) continue;
    await db.update(transactions).set({ place }).where(eq(transactions.id, t.id));
    n++;
  }
  return n;
}

function homeArea(rows: { city: string | null; region: string | null }[]): string {
  const counts = new Map<string, number>();
  for (const r of rows) if (r.city && r.region) counts.set(`${r.city}, ${r.region}`, (counts.get(`${r.city}, ${r.region}`) ?? 0) + 1);
  return [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 4).map(([c, n]) => `${c} (${n} purchases)`).join("; ");
}

interface Found { id: number; address: string | null; city: string | null; region: string | null; postal: string | null; confidence: string | null }

async function lookUp(batch: Candidate[], area: string): Promise<Found[] | null> {
  const client = getAnthropic();
  if (!client) return null;
  const prompt = `Find where each of these card purchases happened, so the app can put a pin on a map. Use web search.

${area ? `Most of this person's in-store purchases are in: ${area}. When a chain has several locations, prefer the one in or nearest those towns.` : "The person lives in the United States."}

For each purchase, return:
- "id": the number given below
- "address": the street address of the specific location, house number first (e.g. "1912 Valley Bluffs Dr SE"). A store number identifies the exact store: look it up in the chain's store locator. If you can only narrow it to a town, use null.
- "city", "region" (2-letter state), "postal": strings or null
- "confidence": "high" when the store number, statement text or a single location in that town makes it certain; "medium" when you picked the most likely of a few nearby locations; "low" when you are guessing or it is an online-only business

Purchases (merchant · store number · town the bank reported · statement text · times bought):
${batch.map((c, i) => `${i + 1}. ${c.name} · ${c.storeNumber ?? "-"} · ${[c.city, c.region].filter(Boolean).join(", ") || "-"} · ${c.statement ?? "-"} · ${c.count}x`).join("\n")}

Finish with only a JSON array in a \`\`\`json block, one object per purchase.`;

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const messages: any[] = [{ role: "user", content: prompt }];
  for (let turn = 0; turn < 5; turn++) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const params: any = {
      model: MODEL,
      max_tokens: 16000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: { effort: "medium" },
      tools: [{ type: "web_search_20260209", name: "web_search", max_uses: 12 }],
      messages,
    };
    let res;
    try {
      res = await client.beta.messages.create(params, { timeout: 300_000 });
    } catch (err) {
      // If the account can't use the fallback option, ask again without it rather than giving up.
      if ((err as { status?: number }).status !== 400) throw err;
      delete params.betas;
      delete params.fallbacks;
      res = await client.beta.messages.create(params, { timeout: 300_000 });
    }
    if (res.stop_reason === "pause_turn") {
      messages.push({ role: "assistant", content: res.content });
      continue;
    }
    if (res.stop_reason === "refusal") return null;
    const text = res.content.map((b) => (b.type === "text" ? b.text : "")).join("\n");
    const m = text.match(/```json\s*([\s\S]*?)```/) ?? text.match(/(\[[\s\S]*\])\s*$/);
    if (!m) return null;
    try {
      const arr = JSON.parse(m[1]);
      return Array.isArray(arr) ? arr : null;
    } catch {
      return null;
    }
  }
  return null;
}

const running = new Set<string>();

/** Looks up merchants that still have no address. One web lookup per merchant, ever; runs in the background. */
export async function researchMerchantPlaces(userId: string): Promise<number> {
  if (process.env.MERCHANT_LOOKUP === "off" || !getAnthropic() || running.has(userId)) return 0;
  running.add(userId);
  try {
    await applyKnownPlaces(userId);
    const rows = await unplacedPurchases(userId);
    if (rows.length === 0) return 0;
    const done = new Set((await db.select({ key: merchantPlaces.key }).from(merchantPlaces).where(eq(merchantPlaces.userId, userId))).map((r) => r.key));

    const groups = new Map<string, Candidate>();
    for (const t of rows) {
      const name = t.merchantName ?? t.name;
      const key = merchantKey(name, t.storeNumber, t.city);
      if (done.has(key)) continue;
      const g = groups.get(key);
      if (g) g.count++;
      else groups.set(key, { key, name, storeNumber: t.storeNumber, city: t.city, region: t.region, statement: t.statement, count: 1 });
    }
    const todo = [...groups.values()].sort((a, b) => b.count - a.count).slice(0, PER_RUN);
    if (todo.length === 0) return 0;

    const areaRows = await db
      .select({ city: transactions.city, region: transactions.region })
      .from(transactions)
      .where(and(eq(transactions.userId, userId), isNull(transactions.deletedAt)))
      .orderBy(desc(transactions.date))
      .limit(500);
    const area = homeArea(areaRows);

    let saved = 0;
    for (let i = 0; i < todo.length; i += BATCH) {
      const batch = todo.slice(i, i + BATCH);
      let found: Found[] | null = null;
      try {
        found = await lookUp(batch, area);
      } catch (err) {
        console.warn("[places] lookup failed:", (err as Error).message);
      }
      if (!found) continue;
      for (const f of found) {
        const c = batch[Number(f.id) - 1];
        if (!c) continue;
        await db
          .insert(merchantPlaces)
          .values({
            userId,
            key: c.key,
            address: f.address ?? null,
            city: f.city ?? c.city,
            region: f.region ?? c.region,
            postal: f.postal ?? null,
            confidence: f.confidence ?? "low",
          })
          .onConflictDoNothing();
        saved++;
      }
    }
    const placed = await applyKnownPlaces(userId);
    console.log(`[places] looked up ${saved} of ${todo.length} merchants; ${placed} purchases got an address`);
    return saved;
  } finally {
    running.delete(userId);
  }
}
