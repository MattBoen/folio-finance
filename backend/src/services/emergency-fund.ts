import { and, eq, gte, isNull, lt } from "drizzle-orm";
import { db } from "../db/client.js";
import { accounts, budgets, plaidItems, transactions, userSettings } from "../db/schema.js";
import { askModel, costOf, type Usage } from "./ask-cost.js";
import { computeOutflow, isoDay } from "./insights.js";
import { getIncome } from "./income-sources.js";
import { loadInsightInputs, todayIso } from "./insight-data.js";

/**
 * Emergency fund: which cash accounts count, and how many months of spending they cover.
 *
 * Folio makes the first call for every account: simple rules here, and Claude when the customer has turned Ask Folio on.
 * The Claude call lives in routes/ask.ts so it goes through Ask Folio's switch and credit limits (API credits are for
 * Ask only). The customer's own choices always win and are never undone. Folio's picks are saved with a signature of
 * the accounts, so the AI only runs again when the accounts change.
 */

export type Basis = "essentials" | "usual" | "budget";
export const BASES: Basis[] = ["essentials", "usual", "budget"];

/** Spending you'd still have in an emergency. Everything else (dining, shopping, travel...) you'd cut. */
export const ESSENTIALS = new Set(["Groceries", "Bills & Utilities", "Transport", "Health"]);

export interface Pick { emergency: boolean; confident: boolean; reason: string }
export interface Picks { signature: string; at: string; by: "ai" | "rules"; picks: Record<string, Pick> }

export interface CashAccount {
  id: string;
  name: string;
  institution: string | null;
  subtype: string | null;
  balance: number;
  /** Names of money that came in over the last 4 months, e.g. "Auto-transfer to Emergency Fund". */
  deposits: string[];
}

const GOAL_WORDS = /emergenc|rainy|reserve|safety|cushion|buffer/i;
const OTHER_GOAL = /house|home|down ?payment|car|vacation|travel|trip|wedding|tax|christmas|holiday|tuition|college|baby/i;

export function signatureOf(list: CashAccount[]): string {
  return list.map((a) => `${a.id}:${a.name}`).sort().join("|");
}

/** The no-AI guess: savings counts, everyday checking doesn't, and names make it certain. */
export function rulePick(a: CashAccount): Pick {
  const text = `${a.name} ${a.deposits.join(" ")}`;
  if (GOAL_WORDS.test(a.name)) return { emergency: true, confident: true, reason: "Named as your emergency fund" };
  if (GOAL_WORDS.test(text)) return { emergency: true, confident: true, reason: "You move money here for emergencies" };
  if (OTHER_GOAL.test(a.name) || /\bfund\b/i.test(a.name)) return { emergency: false, confident: false, reason: "Looks like savings for something else" };
  if (/sav|money market|cd/i.test(a.subtype ?? "") || /saving|money market/i.test(a.name)) return { emergency: true, confident: true, reason: "General savings" };
  return { emergency: false, confident: true, reason: "Everyday spending account" };
}

export interface ModelClient { messages: { create(params: any): Promise<{ content: { type: string; text?: string }[]; usage?: Usage }> } }

/** Claude reads each account's name, bank, type and recent deposits and decides which are the emergency fund. */
export async function aiPick(list: CashAccount[], client: ModelClient, onCost: (usd: number) => void = () => {}): Promise<Record<string, Pick> | null> {
  const payload = list.map((a) => ({
    id: a.id, name: a.name, bank: a.institution, type: a.subtype ?? "checking", balance: Math.round(a.balance), recent_deposits: a.deposits,
  }));
  const res = await client.messages.create({
    model: askModel(),
    max_tokens: 700,
    system: [
      "You sort a person's bank accounts for a personal finance app.",
      "Decide which accounts are their emergency fund: cash set aside for emergencies or job loss.",
      "Not an emergency fund: everyday checking used for bills and spending, or savings clearly set aside for a specific goal (a house, car, trip, wedding, taxes).",
      "A general savings account with no other stated purpose usually counts. Deposits like 'transfer to Emergency Fund' are strong evidence.",
      "Set confident to false only when it really could go either way, so the app can ask the person.",
      'Reply with JSON only, reasons of 2 to 5 plain words: {"accounts":[{"id":"...","emergency":true,"confident":true,"reason":"..."}]}',
    ].join(" "),
    messages: [{ role: "user", content: JSON.stringify({ accounts: payload }) }],
  });
  onCost(costOf(res.usage));
  const text = res.content.filter((b) => b.type === "text").map((b) => b.text ?? "").join("");
  // Each finished {"id": ...} is read on its own, so a reply that got cut off still counts for the accounts it covered;
  // the rest fall back to the rules.
  const out: Record<string, Pick> = {};
  for (const m of text.match(/\{[^{}]*"id"[^{}]*\}/g) ?? []) {
    try {
      const r = JSON.parse(m) as { id: string; emergency: boolean; confident?: boolean; reason?: string };
      if (!list.some((a) => a.id === r.id)) continue;
      out[r.id] = { emergency: Boolean(r.emergency), confident: r.confident !== false, reason: String(r.reason ?? "").slice(0, 60) || (r.emergency ? "Looks like your emergency fund" : "Not set aside for emergencies") };
    } catch { /* half-written entry */ }
  }
  if (Object.keys(out).length === 0) return null;
  for (const a of list) out[a.id] ??= rulePick(a);
  return out;
}

export interface EmergencyFundInput {
  cash: CashAccount[];
  included: Record<string, boolean>;
  basis: Basis;
  picks: Picks;
  monthly: { essentials: number; usual: number; budget: number | null };
  essentials: { category: string; monthly: number }[];
}

/** The pure part: given accounts, choices and spending, what's in the fund and how long it lasts. */
export function summarize(input: EmergencyFundInput) {
  const { cash, included, picks, monthly, essentials } = input;
  let basis = input.basis;
  if (basis === "budget" && !monthly.budget) basis = "essentials";
  if (basis === "essentials" && monthly.essentials <= 0) basis = "usual";

  const rows = cash.map((a) => {
    const pick = picks.picks[a.id] ?? rulePick(a);
    const yours = included[a.id];
    return {
      id: a.id,
      name: a.name,
      institution: a.institution,
      kind: /sav|money market|cd/i.test(a.subtype ?? "") ? "savings" : "checking",
      balance: Math.round(a.balance * 100) / 100,
      included: yours ?? pick.emergency,
      source: yours !== undefined ? "you" : picks.by,
      reason: yours !== undefined ? (yours ? "You chose to count this" : "You chose to leave this out") : pick.reason,
    };
  });
  const total = rows.filter((r) => r.included).reduce((s, r) => s + r.balance, 0);
  const per = basis === "budget" ? monthly.budget ?? 0 : basis === "usual" ? monthly.usual : monthly.essentials;
  const unsure = rows.find((r) => r.source !== "you" && picks.picks[r.id] && !picks.picks[r.id].confident);
  return {
    accounts: rows,
    basis,
    monthly: { essentials: r2(monthly.essentials), usual: r2(monthly.usual), budget: monthly.budget == null ? null : r2(monthly.budget) },
    essentials: essentials.map((e) => ({ category: e.category, monthly: r2(e.monthly) })),
    total: r2(total),
    months: per > 0 ? Math.round((total / per) * 10) / 10 : null,
    question: unsure ? { accountId: unsure.id, text: `Is ${unsure.name} part of your emergency fund?` } : null,
    sortedBy: picks.by,
    canSort: false,
  };
}

const r2 = (n: number) => Math.round(n * 100) / 100;

export async function loadCash(userId: string, now: string): Promise<CashAccount[]> {
  const rows = await db
    .select({ id: accounts.id, name: accounts.name, subtype: accounts.subtype, balance: accounts.balanceCurrent, institution: plaidItems.institutionName })
    .from(accounts)
    .leftJoin(plaidItems, eq(accounts.plaidItemId, plaidItems.id))
    .where(and(eq(accounts.userId, userId), eq(accounts.type, "depository"), eq(accounts.isHidden, false), isNull(accounts.deletedAt)));
  if (rows.length === 0) return [];
  const since = isoDay(Date.parse(now) - 120 * 86_400_000);
  const ins = await db
    .select({ accountId: transactions.accountId, name: transactions.name, userName: transactions.userName })
    .from(transactions)
    .where(and(eq(transactions.userId, userId), isNull(transactions.deletedAt), gte(transactions.date, since), lt(transactions.amount, "0")));
  return rows.map((a) => {
    const names = [...new Set(ins.filter((t) => t.accountId === a.id).map((t) => (t.userName ?? t.name).slice(0, 60)))].slice(0, 8);
    return { id: a.id, name: a.name, institution: a.institution, subtype: a.subtype, balance: parseFloat(a.balance ?? "0"), deposits: names };
  });
}

/** Everything both screens need: accounts and Folio's picks, your settings, spending per month and income. */
async function loadContext(userId: string) {
  const now = todayIso();
  const [settings] = await db.select().from(userSettings).where(eq(userSettings.userId, userId));
  const cash = await loadCash(userId, now);
  const sig = signatureOf(cash);
  const saved = settings?.emergencyPicks?.signature === sig ? settings.emergencyPicks : null;
  const picks: Picks = saved ?? { signature: sig, at: new Date().toISOString(), by: "rules", picks: Object.fromEntries(cash.map((a) => [a.id, rulePick(a)])) };

  const { txns, incomeOverride } = await loadInsightInputs(userId, now);
  const outflow = computeOutflow(txns, now);
  const essentials = outflow.byCategory.filter((c) => ESSENTIALS.has(c.category)).map((c) => ({ category: c.category, monthly: c.monthlyAverage }));
  const lines = await db.select({ amount: budgets.monthlyAmount }).from(budgets).where(and(eq(budgets.userId, userId), eq(budgets.isActive, true)));
  const budgetTotal = lines.reduce((s, l) => s + parseFloat(l.amount), 0);
  const monthly = { essentials: essentials.reduce((s, e) => s + e.monthly, 0), usual: outflow.monthlyAverage, budget: budgetTotal > 0 ? budgetTotal : null };
  return { now, settings, cash, saved, picks, txns, incomeOverride, essentials, monthly };
}

type Ctx = Awaited<ReturnType<typeof loadContext>>;

function fundFrom(c: Ctx) {
  const out = summarize({
    cash: c.cash,
    included: c.settings?.emergencyIncluded ?? {},
    basis: BASES.includes(c.settings?.emergencyBasis as Basis) ? (c.settings!.emergencyBasis as Basis) : "essentials",
    picks: c.picks,
    monthly: c.monthly,
    essentials: c.essentials,
  });
  out.canSort = Boolean(c.settings?.askEnabled) && c.cash.length > 0 && !c.saved;
  return out;
}

/**
 * Everything the Emergency fund screen shows. Never calls the AI itself: `canSort` tells the app to ask
 * Ask Folio to sort the accounts (POST /ask/emergency-fund), which only happens when Ask Folio is on.
 */
export async function getEmergencyFund(userId: string) {
  return fundFrom(await loadContext(userId));
}

/** Savings rate: income minus spending, as a share of income. Spending is measured the same way as the
 *  emergency fund unless you pick something else for it. */
export function savingsSummary(income: { monthly: number; source: string }, monthly: { essentials: number; usual: number; budget: number | null },
  fundBasis: Basis, own: Basis | null) {
  let basis = own ?? fundBasis;
  if (basis === "budget" && !monthly.budget) basis = "essentials";
  if (basis === "essentials" && monthly.essentials <= 0) basis = "usual";
  const spend = basis === "budget" ? monthly.budget ?? 0 : basis === "usual" ? monthly.usual : monthly.essentials;
  const rate = income.monthly > 0 && spend > 0 ? Math.max(-1, Math.min(1, (income.monthly - spend) / income.monthly)) : null;
  return {
    income: r2(income.monthly),
    incomeSource: income.source,
    basis,
    followsFund: own == null,
    fundBasis,
    monthly: { essentials: r2(monthly.essentials), usual: r2(monthly.usual), budget: monthly.budget == null ? null : r2(monthly.budget) },
    spending: r2(spend),
    leftOver: r2(income.monthly - spend),
    rate: rate == null ? null : r2(rate),
  };
}

export async function getSavingsRate(userId: string) {
  const c = await loadContext(userId);
  const fund = fundFrom(c);
  const inc = await getIncome(userId);
  const income = { monthly: inc.monthly, source: inc.source };
  const own = BASES.includes(c.settings?.savingsBasis as Basis) ? (c.settings!.savingsBasis as Basis) : null;
  return savingsSummary(income, c.monthly, fund.basis, own);
}

/** `basis: "match"` goes back to following the emergency fund. */
export async function saveSavingsRate(userId: string, basis: Basis | "match") {
  const set = { savingsBasis: basis === "match" ? null : basis, updatedAt: new Date() };
  await db.insert(userSettings).values({ userId, ...set }).onConflictDoUpdate({ target: userSettings.userId, set });
  return getSavingsRate(userId);
}

/** Saves Folio's AI picks for this exact set of accounts. */
export async function savePicks(userId: string, cash: CashAccount[], found: Record<string, Pick>) {
  const picks: Picks = { signature: signatureOf(cash), at: new Date().toISOString(), by: "ai", picks: found };
  await db.insert(userSettings).values({ userId, emergencyPicks: picks })
    .onConflictDoUpdate({ target: userSettings.userId, set: { emergencyPicks: picks, updatedAt: new Date() } });
}

/** Saves your choices. `reset` forgets them and has Folio sort your accounts again from scratch. */
export async function saveEmergencyFund(userId: string, body: { included?: Record<string, boolean>; basis?: Basis; reset?: boolean }) {
  const [settings] = await db.select().from(userSettings).where(eq(userSettings.userId, userId));
  const set: Partial<typeof userSettings.$inferInsert> = { updatedAt: new Date() };
  if (body.reset) {
    set.emergencyIncluded = null;
    set.emergencyPicks = null;
  } else if (body.included) {
    set.emergencyIncluded = { ...(settings?.emergencyIncluded ?? {}), ...body.included };
  }
  if (body.basis) set.emergencyBasis = body.basis;
  await db.insert(userSettings).values({ userId, ...set }).onConflictDoUpdate({ target: userSettings.userId, set });
  return getEmergencyFund(userId);
}
