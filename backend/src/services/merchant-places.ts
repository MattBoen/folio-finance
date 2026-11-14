import { and, eq, isNull, sql, desc } from "drizzle-orm";
import { db } from "../db/client.js";
import { transactions, merchantPlaces, categories } from "../db/schema.js";

// Where purchases happened, for the map on a transaction. The bank's own street address wins; then the
// street address many cards print at the end of the statement line; then Apple Maps search on the phone.

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

/**
 * Merchant addresses now come only from the bank, the statement line, and Apple Maps search on the phone.
 * There is no Claude or web-search lookup here, so a bank sync never spends API credits.
 */
export async function researchMerchantPlaces(_userId: string): Promise<number> {
  return 0;
}
