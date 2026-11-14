// Pure functions: find the bills and subscriptions hiding in a year of transactions, and say when each is next due.
// No database access here so every rule can be unit-tested.
import { NON_SPENDING, isCardPayment } from "./categories.js";
import { daysBetween, detectRecurrence, isoDay, median, merchantKey, toTime, type InTxn } from "./insights.js";

export type BillFrequency = "weekly" | "biweekly" | "semimonthly" | "monthly" | "yearly";

export interface RecurringItem {
  /** Stable id (the merchant key), used by the app to hide something that isn't really a bill. */
  id: string;
  name: string;
  amount: number;              // what one charge usually is
  frequency: BillFrequency;
  monthly: number;             // what it costs per month, on average
  yearly: number;
  lastDate: string;
  nextDate: string;
  category: string;
  isSubscription: boolean;     // streaming, software, memberships: things you can cancel
  /** True when the amount varies a bit (utilities), so the app shows "about". */
  estimated: boolean;
  /** Set when the latest charge is noticeably different from the one before. */
  priceChange: { from: number; to: number } | null;
  count: number;
}

export interface UpcomingBill { id: string; name: string; amount: number; date: string; estimated: boolean }

export interface RecurringResult {
  items: RecurringItem[];
  monthlyTotal: number;
  yearlyTotal: number;
  subscriptionsMonthly: number;
  /** Everything due in the next 30 days, soonest first. */
  upcoming: UpcomingBill[];
  dueNext30: number;
  /** What is still due between today and the end of this month. */
  dueThisMonth: number;
}

const PER_MONTH: Record<BillFrequency, number> = { weekly: 52 / 12, biweekly: 26 / 12, semimonthly: 2, monthly: 1, yearly: 1 / 12 };
const SUBSCRIPTION_CATEGORY = "Subscriptions";
const r2 = (n: number) => Math.round(n * 100) / 100;

function addMonthsClamped(date: string, months: number): string {
  const [y, m, d] = date.split("-").map(Number);
  const first = new Date(Date.UTC(y, m - 1 + months, 1));
  const last = new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth() + 1, 0)).getUTCDate();
  return isoDay(Date.UTC(first.getUTCFullYear(), first.getUTCMonth(), Math.min(d, last)));
}

/** The next time a charge is due, on or after `now`. */
export function nextDue(last: string, freq: BillFrequency, now: string): string {
  let next = last;
  for (let i = 0; i < 400; i++) {
    if (next >= now) return next;
    if (freq === "weekly") next = isoDay(toTime(next) + 7 * 86_400_000);
    else if (freq === "biweekly") next = isoDay(toTime(next) + 14 * 86_400_000);
    else if (freq === "semimonthly") next = isoDay(toTime(next) + 15 * 86_400_000);
    else if (freq === "monthly") next = addMonthsClamped(next, 1);
    else next = addMonthsClamped(next, 12);
  }
  return next;
}

/** Every date a bill falls on from `from` to `to`, for weekly-type bills that land more than once. */
function occurrences(last: string, freq: BillFrequency, from: string, to: string): string[] {
  const out: string[] = [];
  let d = nextDue(last, freq, from);
  for (let i = 0; i < 12 && d <= to; i++) {
    out.push(d);
    if (freq === "weekly") d = isoDay(toTime(d) + 7 * 86_400_000);
    else if (freq === "biweekly") d = isoDay(toTime(d) + 14 * 86_400_000);
    else if (freq === "semimonthly") d = isoDay(toTime(d) + 15 * 86_400_000);
    else if (freq === "monthly") d = addMonthsClamped(d, 1);
    else d = addMonthsClamped(d, 12);
  }
  return out;
}

function displayName(names: string[]): string {
  // The shortest repeated name is usually the clean one ("Netflix" beats "NETFLIX.COM 866-579-7172 CA").
  const counts = new Map<string, number>();
  for (const n of names) counts.set(n, (counts.get(n) ?? 0) + 1);
  const best = [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].length - b[0].length)[0][0];
  const cleaned = best.replace(/\s+\d{3}[-\s]?\d{3}[-\s]?\d{4}.*$/, "").replace(/\s+[A-Z]{2}$/, "").trim();
  return cleaned || best;
}

/** Looser check for bills whose amount moves around (electric, water): steady monthly rhythm, amount within 40%. */
function looseMonthly(items: { date: string; amount: number }[]): { typical: number; last: string; count: number } | null {
  if (items.length < 3) return null;
  const sorted = [...items].sort((a, b) => a.date.localeCompare(b.date));
  const gaps: number[] = [];
  for (let i = 1; i < sorted.length; i++) gaps.push(daysBetween(sorted[i - 1].date, sorted[i].date));
  if (gaps.filter((g) => g >= 26 && g <= 35).length / gaps.length < 0.75) return null;
  const amounts = sorted.map((s) => Math.abs(s.amount));
  const typical = median(amounts);
  if (typical <= 0 || amounts.filter((a) => Math.abs(a - typical) <= typical * 0.4).length / amounts.length < 0.75) return null;
  return { typical, last: sorted[sorted.length - 1].date, count: sorted.length };
}

/** Yearly charges (insurance, annual plans): two charges about a year apart for about the same amount. */
function yearly(items: { date: string; amount: number }[]): { typical: number; last: string; count: number } | null {
  if (items.length < 2) return null;
  const sorted = [...items].sort((a, b) => a.date.localeCompare(b.date));
  const a = sorted[sorted.length - 2], b = sorted[sorted.length - 1];
  const gap = daysBetween(a.date, b.date);
  const x = Math.abs(a.amount), y = Math.abs(b.amount);
  if (gap < 350 || gap > 380 || Math.abs(x - y) > Math.max(x, y) * 0.15) return null;
  return { typical: y, last: b.date, count: sorted.length };
}

export function detectRecurringBills(txns: InTxn[], now: string): RecurringResult {
  const groups = new Map<string, InTxn[]>();
  for (const t of txns) {
    if (t.isExcluded || t.isPending || t.amount <= 0) continue;           // money going out, settled
    if (NON_SPENDING.has(t.category) || isCardPayment(t.name)) continue;  // not transfers or card payoffs
    if (t.accountType === "investment") continue;
    const k = merchantKey(t.name);
    if (!k) continue;
    const g = groups.get(k);
    if (g) g.push(t); else groups.set(k, [t]);
  }

  const items: RecurringItem[] = [];
  for (const [key, list] of groups) {
    const series = list.map((t) => ({ date: t.date, amount: t.amount }));
    let freq: BillFrequency | null = null, typical = 0, last = "", count = 0, estimated = false;

    const rec = detectRecurrence(series);
    if (rec) {
      freq = rec.frequency; typical = rec.typical; last = rec.last; count = rec.count;
      // Steady rhythm but the amount drifts (a utility bill): show it as "about".
      estimated = list.filter((t) => Math.abs(t.amount - typical) <= typical * 0.05).length / list.length < 0.8;
    }
    else {
      const loose = looseMonthly(series);
      if (loose) { freq = "monthly"; typical = loose.typical; last = loose.last; count = loose.count; estimated = true; }
      else {
        const yr = yearly(series);
        if (yr) { freq = "yearly"; typical = yr.typical; last = yr.last; count = yr.count; }
      }
    }
    if (!freq) continue;
    // A bill that stopped months ago isn't coming up anymore.
    const stale = freq === "yearly" ? 400 : freq === "monthly" ? 75 : 45;
    if (daysBetween(last, now) > stale) continue;

    const sorted = [...list].sort((a, b) => a.date.localeCompare(b.date));
    const latest = sorted[sorted.length - 1].amount, before = sorted.length > 1 ? sorted[sorted.length - 2].amount : latest;
    const priceChange = Math.abs(latest - before) >= Math.max(0.5, before * 0.05) && !estimated ? { from: r2(before), to: r2(latest) } : null;
    const category = sorted[sorted.length - 1].category;
    const monthly = typical * PER_MONTH[freq];
    items.push({
      id: key,
      name: displayName(list.map((t) => t.name)),
      amount: r2(typical),
      frequency: freq,
      monthly: r2(monthly),
      yearly: r2(monthly * 12),
      lastDate: last,
      nextDate: nextDue(last, freq, now),
      category,
      isSubscription: category === SUBSCRIPTION_CATEGORY,
      estimated,
      priceChange,
      count,
    });
  }
  items.sort((a, b) => b.monthly - a.monthly);

  const end30 = isoDay(toTime(now) + 30 * 86_400_000);
  const endMonth = isoDay(Date.UTC(Number(now.slice(0, 4)), Number(now.slice(5, 7)), 0));
  const upcoming: UpcomingBill[] = [];
  let dueThisMonth = 0;
  for (const it of items) {
    for (const date of occurrences(it.lastDate, it.frequency, now, end30)) {
      upcoming.push({ id: it.id, name: it.name, amount: it.amount, date, estimated: it.estimated });
      if (date <= endMonth) dueThisMonth += it.amount;
    }
  }
  upcoming.sort((a, b) => a.date.localeCompare(b.date) || b.amount - a.amount);

  const monthlyTotal = items.reduce((t, i) => t + i.monthly, 0);
  return {
    items,
    monthlyTotal: r2(monthlyTotal),
    yearlyTotal: r2(monthlyTotal * 12),
    subscriptionsMonthly: r2(items.filter((i) => i.isSubscription).reduce((t, i) => t + i.monthly, 0)),
    upcoming,
    dueNext30: r2(upcoming.reduce((t, u) => t + u.amount, 0)),
    dueThisMonth: r2(dueThisMonth),
  };
}
