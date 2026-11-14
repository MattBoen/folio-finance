import { eq } from "drizzle-orm";
import { db } from "../db/client.js";
import { userSettings } from "../db/schema.js";
import { isCardPayment } from "./categories.js";
import { addDays as addDaysIso, merchantKey } from "./insights.js";
import { loadInsightInputs, todayIso } from "./insight-data.js";

/**
 * Income, the way it shows up at tax time: every kind of money coming in, sorted the way your tax forms sort it
 * (W-2 wages, 1099-INT interest, 1099-DIV dividends, 1099-NEC side work, 1099-G benefits, 1099-R retirement...),
 * plus the things that look like income but aren't (tax refunds, reimbursements, cash back, money from friends).
 * Folio decides what counts toward your usual monthly income; you flip any of it with a switch, and your choice wins.
 */

export type IncomeKind =
  | "wages" | "interest" | "dividends" | "self_employment" | "benefits" | "retirement" | "rental" | "other_income"
  | "tax_refund" | "reimbursement" | "rewards" | "from_people" | "other";

export const KINDS: Record<IncomeKind, { label: string; form: string | null; counts: boolean }> = {
  wages: { label: "Paychecks", form: "W-2", counts: true },
  interest: { label: "Interest", form: "1099-INT", counts: true },
  dividends: { label: "Dividends", form: "1099-DIV", counts: true },
  self_employment: { label: "Side work and payouts", form: "1099-NEC / 1099-K", counts: true },
  benefits: { label: "Benefits", form: "1099-G / SSA-1099", counts: true },
  retirement: { label: "Pension and retirement", form: "1099-R", counts: true },
  rental: { label: "Rent you collect", form: "Schedule E", counts: true },
  other_income: { label: "Other income", form: null, counts: true },
  tax_refund: { label: "Tax refunds", form: null, counts: false },
  reimbursement: { label: "Reimbursements and refunds", form: null, counts: false },
  rewards: { label: "Cash back and rewards", form: null, counts: false },
  from_people: { label: "Money from people", form: null, counts: false },
  other: { label: "Other deposits", form: null, counts: false },
};

const RULES: [RegExp, IncomeKind][] = [
  [/tax ?ref|taxrfd|irs treas|treas 310|state tax|tax commissioner/i, "tax_refund"],
  [/payroll|salary|direct dep|dir dep|\bwages?\b|\badp\b|gusto|paychex|paycom|workday|\bnet pay\b/i, "wages"],
  [/dividend|\bdiv\b|cap(ital)? gain/i, "dividends"],
  [/interest(?! charge| adjust)|\biod\b|\bapy\b/i, "interest"],
  [/\bssa\b|social sec|treas 449|unemploy|\bui benefit|\bva benefit|\bssi\b|child support/i, "benefits"],
  [/pension|annuity|\bira dist|401k dist|retirement dist/i, "retirement"],
  [/\brent\b|tenant|airbnb|vrbo/i, "rental"],
  [/stripe|square|upwork|fiverr|etsy|doordash|uber|lyft|instacart|shopify|payout|commission|freelanc/i, "self_employment"],
  [/cash ?back|reward|upside|ibotta|rakuten|points credit|statement credit|bonus offer/i, "rewards"],
  [/reimburs|payables|expense|refund|return|adjustment|reversal/i, "reimbursement"],
  [/zelle|venmo|cash app|apple cash|paypal/i, "from_people"],
];

export function classify(name: string, category: string): IncomeKind {
  for (const [re, kind] of RULES) if (re.test(name)) return kind;
  return category === "Income" ? "other_income" : "other";
}

export interface CreditIn { date: string; amount: number; name: string; category: string; account: string; accountType: string }

/** One stream per payer and kind. Interest is kept per account ("Interest · Emergency Fund"). */
export function streamKey(c: CreditIn, kind: IncomeKind): string {
  return kind === "interest" || kind === "dividends" ? `${kind}:${c.account.toLowerCase()}` : `${kind}:${merchantKey(c.name)}`;
}

const r2 = (n: number) => Math.round(n * 100) / 100;

export function summarizeIncome(credits: CreditIn[], now: string, yours: Record<string, boolean>, manual: number | null, historyStart: string | null) {
  const since = addDaysIso(now, -365);
  const year = now.slice(0, 4);
  const recent = credits.filter((c) => c.date >= since && c.date <= now);
  // Months the averages cover: up to 12, fewer if the history is shorter.
  const start = historyStart && historyStart > since ? historyStart : since;
  const months = Math.max(1, Math.min(12, (Date.parse(now) - Date.parse(start)) / (30.44 * 86_400_000)));

  const map = new Map<string, { kind: IncomeKind; rows: CreditIn[] }>();
  for (const c of recent) {
    const kind = classify(c.name, c.category);
    const key = streamKey(c, kind);
    const s = map.get(key) ?? { kind, rows: [] };
    s.rows.push(c);
    map.set(key, s);
  }
  const streams = [...map.entries()].map(([key, s]) => {
    const latest = [...s.rows].sort((a, b) => b.date.localeCompare(a.date))[0];
    const total = s.rows.reduce((t, r) => t + r.amount, 0);
    const k = KINDS[s.kind];
    const name = s.kind === "interest" || s.kind === "dividends" ? `${k.label} · ${latest.account}` : tidy(latest.name);
    const yoursHere = yours[key];
    return {
      key, name, kind: s.kind, kindLabel: k.label, taxForm: k.form, account: latest.account,
      count: s.rows.length, lastDate: latest.date,
      last12: r2(total), ytd: r2(s.rows.filter((r) => r.date.startsWith(year)).reduce((t, r) => t + r.amount, 0)),
      monthly: r2(total / months),
      included: yoursHere ?? k.counts,
      source: yoursHere === undefined ? "rules" : "you",
    };
  }).filter((s) => s.last12 >= 1)
    .sort((a, b) => Number(b.included) - Number(a.included) || b.last12 - a.last12);

  const counted = streams.filter((s) => s.included);
  const detected = r2(counted.reduce((t, s) => t + s.monthly, 0));
  return {
    monthly: manual ?? detected,
    detected,
    source: manual != null ? "manual" : detected > 0 ? "detected" : "none",
    ytd: r2(counted.reduce((t, s) => t + s.ytd, 0)),
    months: Math.round(months * 10) / 10,
    streams,
  };
}

function tidy(name: string): string {
  const t = name.replace(/\b(ppd|ccd|ach|web|pos|dir dep|direct dep)\b/gi, " ").replace(/\s+/g, " ").trim();
  return (t || name).replace(/\w\S*/g, (w) => (w.length > 3 ? w[0].toUpperCase() + w.slice(1).toLowerCase() : w));
}

export async function getIncome(userId: string) {
  const now = todayIso();
  const { txns } = await loadInsightInputs(userId, now, 400);
  const credits: CreditIn[] = txns
    .filter((t) => t.amount < 0 && !t.isPending && !t.isExcluded && (t.accountType === "depository" || t.accountType === "investment"))
    .map((t) => ({ date: t.date, amount: -t.amount, name: t.name, category: t.category, account: t.accountName ?? "Account", accountType: t.accountType }))
    // Moving your own money between accounts isn't income; neither is paying a card.
    .filter((c) => (c.category !== "Transfer" || classify(c.name, c.category) === "wages") && !isCardPayment(c.name));
  const earliest = txns.reduce<string | null>((m, t) => (m == null || t.date < m ? t.date : m), null);
  const [settings] = await db.select({ incomeIncluded: userSettings.incomeIncluded, incomeOverride: userSettings.incomeOverride }).from(userSettings).where(eq(userSettings.userId, userId));
  return summarizeIncome(credits, now, settings?.incomeIncluded ?? {}, settings?.incomeOverride != null ? parseFloat(settings.incomeOverride) : null, earliest);
}

export async function saveIncomeIncluded(userId: string, included: Record<string, boolean | null>) {
  const [settings] = await db.select({ incomeIncluded: userSettings.incomeIncluded }).from(userSettings).where(eq(userSettings.userId, userId));
  const next = { ...(settings?.incomeIncluded ?? {}) };
  for (const [k, v] of Object.entries(included)) { if (v == null) delete next[k]; else next[k] = v; }
  const set = { incomeIncluded: next, updatedAt: new Date() };
  await db.insert(userSettings).values({ userId, ...set }).onConflictDoUpdate({ target: userSettings.userId, set });
  return getIncome(userId);
}
