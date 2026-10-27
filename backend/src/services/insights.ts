// Pure functions: turn accounts + a few months of transactions into the Plan screen's numbers.
// No database access here so every rule can be unit-tested.
import { NON_SPENDING, isCardPayment } from "./categories.js";

export interface InTxn {
  date: string;            // YYYY-MM-DD
  amount: number;          // Plaid sign: positive = money out, negative = money in
  name: string;
  category: string;        // already normalized (see categories.ts)
  isExcluded: boolean;
  isPending: boolean;
  accountType: string;     // depository | credit | loan | investment | other
}

export interface InAcct {
  type: string;
  subtype: string | null;
  balance: number;
  limit: number | null;
  hidden: boolean;
}

export interface IncomeSource { name: string; monthly: number; frequency: string }
export interface IncomeResult { monthly: number; source: "detected" | "manual" | "none"; confidence: "high" | "medium" | "low" | "none"; sources: IncomeSource[] }
export interface CategoryOutflow { category: string; monthlyAverage: number; isFixed: boolean }
export interface OutflowResult { monthlyAverage: number; fixed: number; variable: number; byCategory: CategoryOutflow[]; fixedByCategory: Record<string, number> }
export interface BudgetItem { category: string; amount: number }

const DAY = 86_400_000;
const r2 = (n: number) => Math.round(n * 100) / 100;

export function toTime(d: string): number {
  const [y, m, dd] = d.split("-").map(Number);
  return Date.UTC(y, m - 1, dd);
}
export function daysBetween(a: string, b: string): number {
  return Math.round((toTime(b) - toTime(a)) / DAY);
}
export function isoDay(t: number): string {
  return new Date(t).toISOString().slice(0, 10);
}
function addDays(d: string, n: number): string { return isoDay(toTime(d) + n * DAY); }
function monthKey(d: string): string { return d.slice(0, 7); }

export function median(xs: number[]): number {
  if (xs.length === 0) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

export function merchantKey(name: string): string {
  return name
    .toLowerCase()
    .replace(/\b(ach|ppd|ccd|web|pos|debit|credit|purchase|deposit|direct|dep|payment|pmt|inc|llc|co|corp|id)\b/g, " ")
    .replace(/[^a-z ]/g, " ")
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 3)
    .join(" ") || name.toLowerCase();
}

function titleCase(s: string): string {
  return s.replace(/\w\S*/g, (w) => w[0].toUpperCase() + w.slice(1).toLowerCase());
}

// ── Recurrence ────────────────────────────────────────────────────────────────

type Freq = "weekly" | "biweekly" | "semimonthly" | "monthly";
const PERIOD: Record<Freq, number> = { weekly: 7, biweekly: 14, semimonthly: 15, monthly: 30 };
const PER_MONTH: Record<Freq, number> = { weekly: 52 / 12, biweekly: 26 / 12, semimonthly: 2, monthly: 1 };

export interface Recurrence { frequency: Freq; typical: number; count: number; last: string }

/** A series is recurring when it has 3+ entries at a steady gap and a steady amount. */
export function detectRecurrence(items: { date: string; amount: number }[]): Recurrence | null {
  if (items.length < 3) return null;
  const sorted = [...items].sort((a, b) => a.date.localeCompare(b.date));
  const gaps: number[] = [];
  for (let i = 1; i < sorted.length; i++) gaps.push(daysBetween(sorted[i - 1].date, sorted[i].date));
  const med = median(gaps);
  const amounts = sorted.map((s) => Math.abs(s.amount));
  const typical = median(amounts);
  if (typical <= 0) return null;

  let freq: Freq | null = null;
  let inBand: (g: number) => boolean = () => false;
  if (med >= 5 && med <= 9) { freq = "weekly"; inBand = (g) => g >= 5 && g <= 9; }
  else if (med >= 11 && med <= 18) {
    // Biweekly pay lands on the same weekday; semi-monthly pay (15th/last) wanders across weekdays.
    const days = sorted.map((s) => new Date(toTime(s.date)).getUTCDay());
    const counts = new Map<number, number>();
    for (const d of days) counts.set(d, (counts.get(d) ?? 0) + 1);
    const top = Math.max(...counts.values());
    const sameWeekday = top / days.length >= 0.8;
    if (sameWeekday && med <= 15) { freq = "biweekly"; inBand = (g) => g >= 11 && g <= 17; }
    else { freq = "semimonthly"; inBand = (g) => g >= 12 && g <= 18; }
  } else if (med >= 26 && med <= 34) { freq = "monthly"; inBand = (g) => g >= 26 && g <= 34; }
  if (!freq) return null;

  const gapOk = gaps.filter(inBand).length / gaps.length >= 0.7;
  const amtOk = amounts.filter((a) => Math.abs(a - typical) <= typical * 0.15).length / amounts.length >= 0.7;
  if (!gapOk || !amtOk) return null;
  return { frequency: freq, typical, count: sorted.length, last: sorted[sorted.length - 1].date };
}

// ── Income ────────────────────────────────────────────────────────────────────

export function detectIncome(txns: InTxn[], now: string, override: number | null): IncomeResult {
  const since = addDays(now, -180);
  const credits = txns.filter(
    (t) => t.amount < 0 && !t.isExcluded && !t.isPending && t.category !== "Transfer" &&
      t.accountType === "depository" && t.date >= since && t.date <= now && !isCardPayment(t.name)
  );

  const groups = new Map<string, InTxn[]>();
  for (const t of credits) {
    const k = merchantKey(t.name);
    groups.set(k, [...(groups.get(k) ?? []), t]);
  }

  const sources: IncomeSource[] = [];
  const recurringKeys = new Set<string>();
  let minCount = Infinity;
  for (const [k, rows] of groups) {
    const rec = detectRecurrence(rows);
    if (!rec) continue;
    const stale = daysBetween(rec.last, now) > PERIOD[rec.frequency] * 2.5; // an old job, not current income
    if (stale) continue;
    recurringKeys.add(k);
    minCount = Math.min(minCount, rec.count);
    const latest = [...rows].sort((a, b) => b.date.localeCompare(a.date))[0];
    sources.push({ name: titleCase(latest.name.toLowerCase()), monthly: r2(rec.typical * PER_MONTH[rec.frequency]), frequency: rec.frequency });
  }

  // Everything else that is plainly income (freelance, side work): typical month over the months we can see.
  const irregular = credits.filter((t) => t.category === "Income" && !recurringKeys.has(merchantKey(t.name)));
  let irregularMonthly = 0;
  if (irregular.length > 0) {
    const all = txns.filter((t) => t.date >= since);
    const earliest = all.reduce((m, t) => (t.date < m ? t.date : m), now);
    const curMonth = monthKey(now);
    const months: string[] = [];
    let cursor = monthKey(addDays(`${curMonth}-01`, -1)); // previous (complete) month
    for (let i = 0; i < 6; i++) {
      if (`${cursor}-28` < earliest.slice(0, 7) + "-01") break;
      months.push(cursor);
      cursor = monthKey(addDays(`${cursor}-01`, -1));
    }
    if (months.length === 0) months.push(curMonth);
    const totals = months.map((m) => irregular.filter((t) => monthKey(t.date) === m).reduce((s, t) => s - t.amount, 0));
    irregularMonthly = median(totals);
    if (irregularMonthly > 0) sources.push({ name: "Other deposits", monthly: r2(irregularMonthly), frequency: "irregular" });
  }

  const recurringMonthly = sources.filter((s) => s.frequency !== "irregular").reduce((s, x) => s + x.monthly, 0);
  const detected = r2(recurringMonthly + (irregularMonthly > 0 ? irregularMonthly : 0));
  sources.sort((a, b) => b.monthly - a.monthly);

  if (override != null) {
    return { monthly: r2(override), source: "manual", confidence: "high", sources };
  }
  if (detected <= 0) return { monthly: 0, source: "none", confidence: "none", sources: [] };
  const confidence = recurringKeys.size > 0 ? (minCount >= 4 ? "high" : "medium") : "low";
  return { monthly: detected, source: "detected", confidence, sources };
}

// ── Outflow ───────────────────────────────────────────────────────────────────

const FIXED_NAME_RE = /\b(rent|mortgage|insurance|loan|lease|premium|hoa|tuition)\b/i;
const FIXED_CATEGORIES = new Set(["Bills & Utilities", "Subscriptions"]);

export function computeOutflow(txns: InTxn[], now: string): OutflowResult {
  const empty: OutflowResult = { monthlyAverage: 0, fixed: 0, variable: 0, byCategory: [], fixedByCategory: {} };
  const spend = txns.filter(
    (t) => !t.isExcluded && !t.isPending && !NON_SPENDING.has(t.category) && !isCardPayment(t.name) && t.date <= now
  );
  if (spend.length === 0) return empty;

  const earliest = spend.reduce((m, t) => (t.date < m ? t.date : m), now);
  const span = daysBetween(earliest, now) + 1;

  // Volatile spenders get a longer window so one odd month doesn't set the plan.
  const windowTotal = (from: number, to: number) =>
    spend.filter((t) => t.amount > 0 && t.date >= addDays(now, -to) && t.date < addDays(now, -from)).reduce((s, t) => s + t.amount, 0);
  const thirds = [windowTotal(0, 30), windowTotal(30, 60), windowTotal(60, 90)];
  const mean = thirds.reduce((a, b) => a + b, 0) / 3;
  const sd = Math.sqrt(thirds.reduce((a, b) => a + (b - mean) ** 2, 0) / 3);
  const volatile = mean > 0 && sd / mean > 0.35;
  const W = volatile && span >= 150 ? 180 : 90;
  const cutoff = addDays(now, -W);
  const inWin = spend.filter((t) => t.date >= cutoff);
  const eff = Math.min(W, span);
  const months = eff >= 14 ? eff / 30.4 : 1;

  // fixed merchants: steady gap + amount, or inherently fixed by category/name
  const byMerchant = new Map<string, InTxn[]>();
  for (const t of inWin) if (t.amount > 0) {
    const k = merchantKey(t.name);
    byMerchant.set(k, [...(byMerchant.get(k) ?? []), t]);
  }
  const fixedKeys = new Set<string>();
  for (const [k, rows] of byMerchant) {
    const inherent = rows.every((r) => FIXED_CATEGORIES.has(r.category)) || rows.some((r) => FIXED_NAME_RE.test(r.name));
    const rec = detectRecurrence(rows);
    const monthlyRec = rows.length >= 2 && rec != null && rec.frequency === "monthly";
    if (inherent || monthlyRec) fixedKeys.add(k);
  }

  const total: Record<string, number> = {};
  const fixedTotal: Record<string, number> = {};
  for (const t of inWin) {
    total[t.category] = (total[t.category] ?? 0) + t.amount; // refunds (negative) net against spending
    if (t.amount > 0 && fixedKeys.has(merchantKey(t.name))) fixedTotal[t.category] = (fixedTotal[t.category] ?? 0) + t.amount;
  }

  const byCategory: CategoryOutflow[] = [];
  const fixedByCategory: Record<string, number> = {};
  let fixed = 0, all = 0;
  for (const [cat, amt] of Object.entries(total)) {
    if (amt <= 0) continue;
    const monthly = amt / months;
    const f = Math.min(fixedTotal[cat] ?? 0, amt) / months;
    fixedByCategory[cat] = r2(f);
    fixed += f; all += monthly;
    byCategory.push({ category: cat, monthlyAverage: r2(monthly), isFixed: f >= monthly * 0.5 });
  }
  byCategory.sort((a, b) => b.monthlyAverage - a.monthlyAverage);
  return { monthlyAverage: r2(all), fixed: r2(fixed), variable: r2(all - fixed), byCategory, fixedByCategory };
}

// ── Budget ────────────────────────────────────────────────────────────────────

const TRIM: Record<string, number> = {
  Dining: 0.10, Shopping: 0.10, Entertainment: 0.10, Travel: 0.10,
  Groceries: 0.05, Transport: 0.05, Other: 0.05, Home: 0.05, Health: 0.05,
};

export function roundNice(v: number): number {
  const step = v < 100 ? 5 : 10;
  return Math.max(5, Math.round(v / step) * step);
}

/** "Average + trim": keep fixed bills as they are, shave 5-10% off flexible spending. */
export function suggestBudget(outflow: OutflowResult): { total: number; items: BudgetItem[] } {
  const items: BudgetItem[] = [];
  for (const c of outflow.byCategory) {
    if (c.monthlyAverage < 10) continue;
    const fixed = outflow.fixedByCategory[c.category] ?? 0;
    const variable = Math.max(0, c.monthlyAverage - fixed);
    const trimmed = fixed + variable * (1 - (TRIM[c.category] ?? 0));
    items.push({ category: c.category, amount: roundNice(trimmed) });
  }
  return { total: items.reduce((s, i) => s + i.amount, 0), items };
}

// ── Health + investing ────────────────────────────────────────────────────────

const DEBT_RE = /(mortgage|loan|student|navient|nelnet|sallie|auto finance|car payment|lendingclub|upstart)/i;

export interface InsightsInput {
  txns: InTxn[];
  accounts: InAcct[];
  now: string;
  incomeOverride: number | null;
  birthYear: number | null;
}

export function buildInsights(input: InsightsInput) {
  const { txns, accounts, now, incomeOverride, birthYear } = input;
  const live = accounts.filter((a) => !a.hidden);
  const income = detectIncome(txns, now, incomeOverride);
  const outflow = computeOutflow(txns, now);
  const budget = suggestBudget(outflow);

  const sum = (f: (a: InAcct) => boolean) => live.filter(f).reduce((s, a) => s + a.balance, 0);
  const isSavings = (a: InAcct) => a.type === "depository" && /sav|cd|money market/i.test(a.subtype ?? "");
  const savings = sum(isSavings);
  const cash = sum((a) => a.type === "depository" && !isSavings(a));
  const invested = sum((a) => a.type === "investment");
  const other = sum((a) => a.type === "other");
  const liquid = cash + savings;
  const totalAssets = liquid + invested + other;

  const cards = live.filter((a) => a.type === "credit");
  const limit = cards.reduce((s, a) => s + (a.limit ?? 0), 0);
  const utilization = limit > 0 ? cards.reduce((s, a) => s + a.balance, 0) / limit : null;

  // debt payments over the same trailing window as outflow
  const since = addDays(now, -90);
  const debtTxns = txns.filter((t) => t.amount > 0 && !t.isExcluded && !t.isPending && t.date >= since && DEBT_RE.test(t.name));
  const earliest = txns.reduce((m, t) => (t.date < m ? t.date : m), now);
  const span = Math.min(90, daysBetween(earliest, now) + 1);
  const debtMonthly = debtTxns.reduce((s, t) => s + t.amount, 0) / (span >= 14 ? span / 30.4 : 1);

  const health = {
    savingsRate: income.monthly > 0 && outflow.monthlyAverage > 0 ? r2((income.monthly - outflow.monthlyAverage) / income.monthly) : null,
    emergencyFundMonths: outflow.monthlyAverage > 0 && liquid > 0 ? Math.round((liquid / outflow.monthlyAverage) * 10) / 10 : null,
    creditUtilization: utilization == null ? null : r2(utilization),
    debtPaymentRatio: income.monthly > 0 && debtMonthly > 0 ? r2(debtMonthly / income.monthly) : null,
  };

  const slices = [
    { label: "Cash", amount: cash },
    { label: "Savings", amount: savings },
    { label: "Investments", amount: invested },
    { label: "Other assets", amount: other },
  ].filter((s) => s.amount > 0);
  const allocation = slices.map((s) => ({ label: s.label, amount: r2(s.amount), percent: totalAssets > 0 ? Math.round((s.amount / totalAssets) * 1000) / 10 : 0 }));

  const notes = buildNotes({ health, income, invested, liquid, birthYear, nowYear: Number(now.slice(0, 4)), outflowMonthly: outflow.monthlyAverage, hasAccounts: live.length > 0 });

  const months = new Set(txns.map((t) => monthKey(t.date)));
  return {
    income,
    outflow: { monthlyAverage: outflow.monthlyAverage, fixed: outflow.fixed, variable: outflow.variable, byCategory: outflow.byCategory },
    budget,
    health,
    investing: { totalInvested: r2(invested), allocation, notes },
    dataQuality: { monthsOfData: months.size, transactionCount: txns.length },
  };
}

interface NoteCtx {
  health: { savingsRate: number | null; emergencyFundMonths: number | null; creditUtilization: number | null };
  income: IncomeResult; invested: number; liquid: number; birthYear: number | null; nowYear: number; outflowMonthly: number; hasAccounts: boolean;
}
const pct = (x: number) => `${Math.round(x * 100)}%`;

export function buildNotes(c: NoteCtx) {
  const notes: { id: string; title: string; detail: string; tone: "good" | "info" | "attention" }[] = [];
  if (!c.hasAccounts) return notes;
  const m = c.health.emergencyFundMonths;
  if (m != null) {
    if (m < 3) notes.push({ id: "emergency-fund", title: "Emergency cushion", detail: `Your cash covers about ${m} months of spending. Many people aim for 3–6 months.`, tone: "attention" });
    else if (m <= 6) notes.push({ id: "emergency-fund", title: "Emergency cushion", detail: `Your cash covers about ${m} months of spending, within the 3–6 months many people aim for.`, tone: "good" });
    else notes.push({ id: "cash-drag", title: "Cash above a typical cushion", detail: `Your cash covers about ${m} months of spending. Cash beyond roughly 6 months may earn less than other options, so many people put the extra toward retirement or other goals.`, tone: "info" });
  }
  const sr = c.health.savingsRate;
  if (sr != null) {
    if (sr >= 0.2) notes.push({ id: "savings-rate", title: "Savings rate", detail: `You're keeping about ${pct(sr)} of income. Many people aim for 15–20% or more.`, tone: "good" });
    else if (sr < 0.05) notes.push({ id: "savings-rate", title: "Savings rate", detail: `You're keeping about ${pct(Math.max(sr, 0))} of income. Many people aim for 15–20%, and small trims in flexible categories can help.`, tone: "attention" });
    else notes.push({ id: "savings-rate", title: "Savings rate", detail: `You're keeping about ${pct(sr)} of income. Many people aim for 15–20% or more.`, tone: "info" });
  }
  const u = c.health.creditUtilization;
  if (u != null) {
    if (u >= 0.3) notes.push({ id: "card-utilization", title: "Card balances", detail: `Your cards use about ${pct(u)} of their limits. Many people aim to stay under 30%, and under 10% is often considered ideal for credit scores.`, tone: "attention" });
    else if (u <= 0.1) notes.push({ id: "card-utilization", title: "Card balances", detail: `Your cards use about ${pct(u)} of their limits, within the under-10% range many people aim for.`, tone: "good" });
  }
  if (c.income.source !== "none") {
    notes.push({ id: "retirement-rate", title: "Retirement saving", detail: "Many people aim to put aside about 15% of income for retirement, including any employer match.", tone: "info" });
    notes.push({ id: "employer-match", title: "Employer match", detail: "If your employer matches 401(k) contributions, many people contribute at least enough to receive the full match.", tone: "info" });
  }
  if (c.invested > 0) {
    const age = c.birthYear ? c.nowYear - c.birthYear : null;
    if (age != null && age >= 18 && age <= 90) {
      const stocks = Math.min(100, Math.max(0, 110 - age));
      notes.push({ id: "allocation-rule", title: "Allocation rule of thumb", detail: `A common rule of thumb (110 minus your age) points to roughly ${stocks}% in stocks at ${age}. Your own goals and comfort with risk matter more than any rule.`, tone: "info" });
    } else {
      notes.push({ id: "add-age", title: "Allocation ideas", detail: "Add your birth year to see an age-based allocation rule of thumb.", tone: "info" });
    }
  }
  return notes;
}
