// Read-only data the Ask assistant's tools can see. Everything is scoped to one user id.
import { and, asc, desc, eq, gte, isNull, lte } from "drizzle-orm";
import { alias } from "drizzle-orm/pg-core";
import { db } from "../db/client.js";
import { accounts, categories, netWorthSnapshots, plaidItems, transactions, vehicles } from "../db/schema.js";
import { describeChange, type ChangeOp } from "./ask-changes.js";
import { projectedMiles } from "./vehicles.js";
import { NON_SPENDING, normalizeCategory } from "./categories.js";
import { computeInsightsForUser, todayIso } from "./insight-data.js";
import { merchantKey } from "./insights.js";
import { budgetsResponse } from "../routes/budgets.js";

const r2 = (n: number) => Math.round(n * 100) / 100;

export type GroupName = "Cash" | "Savings" | "Investments" | "Physical assets" | "Credit cards" | "Loans";

export function groupOf(type: string, subtype: string | null): GroupName {
  if (type === "credit") return "Credit cards";
  if (type === "loan") return "Loans";
  if (type === "investment") return "Investments";
  if (type === "other") return "Physical assets";
  return /sav|^cd$|money market/i.test(subtype ?? "") ? "Savings" : "Cash";
}

export interface AcctRow { id: string; connected: boolean; subtype: string | null; name: string; group: GroupName; balance: number; institution: string | null; limit: number | null }

async function loadAccounts(userId: string): Promise<AcctRow[]> {
  const rows = await db
    .select({
      id: accounts.id, plaidItemId: accounts.plaidItemId, name: accounts.name, type: accounts.type, subtype: accounts.subtype, balance: accounts.balanceCurrent,
      limit: accounts.balanceLimit, official: accounts.officialName, inst: plaidItems.institutionName,
    })
    .from(accounts)
    .leftJoin(plaidItems, eq(accounts.plaidItemId, plaidItems.id))
    .where(and(eq(accounts.userId, userId), isNull(accounts.deletedAt), eq(accounts.isHidden, false)));
  return rows.map((r) => ({
    id: r.id,
    connected: r.plaidItemId != null,
    subtype: r.subtype,
    name: r.name,
    group: groupOf(r.type, r.subtype),
    balance: r2(parseFloat(r.balance ?? "0")),
    institution: r.inst ?? r.official ?? null,
    limit: r.limit != null ? parseFloat(r.limit) : null,
  }));
}

export async function getOverview(userId: string) {
  const list = await loadAccounts(userId);
  const byGroup: Record<string, number> = {};
  let assets = 0, liabilities = 0;
  for (const a of list) {
    byGroup[a.group] = r2((byGroup[a.group] ?? 0) + a.balance);
    if (a.group === "Credit cards" || a.group === "Loans") liabilities += a.balance; else assets += a.balance;
  }
  return { netWorth: r2(assets - liabilities), assets: r2(assets), liabilities: r2(liabilities), byGroup, accountCount: list.length };
}

export async function getAccountsList(userId: string) {
  const list = await loadAccounts(userId);
  return { accounts: list.slice(0, 40).map((a) => ({ id: a.id, name: a.name, group: a.group, balance: a.balance, institution: a.institution, connectedToBank: a.connected })), total: list.length };
}

export async function getVehicles(userId: string) {
  const rows = await db
    .select({ accountId: vehicles.accountId, name: accounts.name, year: vehicles.year, make: vehicles.make, model: vehicles.model, trim: vehicles.trim, miles: vehicles.miles, annualMiles: vehicles.annualMiles, valuedAt: vehicles.valuedAt, value: accounts.balanceCurrent })
    .from(vehicles)
    .innerJoin(accounts, eq(vehicles.accountId, accounts.id))
    .where(and(eq(vehicles.userId, userId), isNull(accounts.deletedAt)));
  return {
    vehicles: rows.map((v) => ({
      id: v.accountId, name: v.name, year: v.year, make: v.make, model: v.model, trim: v.trim,
      miles: v.miles, annualMilesYouDrive: v.annualMiles, estimatedMilesNow: projectedMiles(v.miles, v.annualMiles, v.valuedAt),
      value: r2(parseFloat(v.value ?? "0")),
    })),
  };
}

export interface FindTxArgs { from?: string; to?: string; merchant?: string; category?: string; minAmount?: number; maxAmount?: number; includeExcluded?: boolean }

export async function findTransactions(userId: string, a: FindTxArgs) {
  const userCat = alias(categories, "user_cat");
  const plaidCat = alias(categories, "plaid_cat");
  const rows = await db
    .select({
      id: transactions.id, date: transactions.date, amount: transactions.amount, name: transactions.name, userName: transactions.userName,
      merchant: transactions.merchantName, userCat: userCat.name, plaidCat: plaidCat.name, excluded: transactions.isExcluded, account: accounts.name,
    })
    .from(transactions)
    .leftJoin(accounts, eq(transactions.accountId, accounts.id))
    .leftJoin(userCat, eq(transactions.userCategoryId, userCat.id))
    .leftJoin(plaidCat, eq(transactions.categoryId, plaidCat.id))
    .where(and(eq(transactions.userId, userId), isNull(transactions.deletedAt), a.from ? gte(transactions.date, a.from) : undefined, a.to ? lte(transactions.date, a.to) : undefined))
    .orderBy(desc(transactions.date))
    .limit(600);
  const m = a.merchant?.toLowerCase();
  const c = a.category ? normalizeCategory(a.category) : null;
  const out = rows
    .map((r) => ({
      id: r.id, date: r.date, name: r.userName || r.merchant || r.name, amount: r2(parseFloat(r.amount)),
      category: normalizeCategory(r.userCat ?? r.plaidCat ?? (parseFloat(r.amount) > 0 ? "Other" : "Income")), excluded: r.excluded, account: r.account,
    }))
    .filter((r) => (a.includeExcluded ? true : true) && (!m || r.name.toLowerCase().includes(m)) && (!c || r.category === c)
      && (a.minAmount == null || Math.abs(r.amount) >= a.minAmount) && (a.maxAmount == null || Math.abs(r.amount) <= a.maxAmount))
    .slice(0, 25);
  return { transactions: out, note: "Positive amounts are money out, negative are money in." };
}

export async function describeChanges(userId: string, ops: ChangeOp[]): Promise<string[]> {
  const lines: string[] = [];
  for (const op of ops) lines.push(await describeChange(userId, op));
  return lines;
}

export async function getBudget(userId: string) {
  const b = await budgetsResponse(userId);
  const items = b.budgets.slice(0, 30);
  const limit = r2(items.reduce((s, x) => s + x.monthlyAmount, 0));
  const spent = r2(items.reduce((s, x) => s + x.spent, 0));
  return { month: b.month, totalLimit: limit, totalSpent: spent, left: r2(limit - spent), categories: items.map((x) => ({ category: x.category, limit: x.monthlyAmount, spent: x.spent })) };
}

export interface SpendingArgs { from: string; to: string; category?: string; merchant?: string }

export async function getSpending(userId: string, a: SpendingArgs) {
  const userCat = alias(categories, "user_cat");
  const plaidCat = alias(categories, "plaid_cat");
  const rows = await db
    .select({
      date: transactions.date, amount: transactions.amount, name: transactions.name, userName: transactions.userName,
      merchant: transactions.merchantName, userCat: userCat.name, plaidCat: plaidCat.name,
      excluded: transactions.isExcluded, pending: transactions.isPending,
    })
    .from(transactions)
    .innerJoin(accounts, eq(transactions.accountId, accounts.id))
    .leftJoin(userCat, eq(transactions.userCategoryId, userCat.id))
    .leftJoin(plaidCat, eq(transactions.categoryId, plaidCat.id))
    .where(and(
      eq(transactions.userId, userId), isNull(transactions.deletedAt), isNull(accounts.deletedAt),
      gte(transactions.date, a.from), lte(transactions.date, a.to)
    ))
    .orderBy(desc(transactions.date))
    .limit(5000);

  const wantCat = a.category ? normalizeCategory(a.category) : null;
  const wantMerchant = a.merchant?.trim().toLowerCase() || null;
  let total = 0, count = 0;
  const merchants = new Map<string, { name: string; total: number; count: number }>();
  const cats = new Map<string, number>();
  for (const r of rows) {
    const amount = parseFloat(r.amount);
    const category = normalizeCategory(r.userCat ?? r.plaidCat);
    if (amount <= 0 || r.excluded || NON_SPENDING.has(category)) continue;
    const display = r.userName ?? r.merchant ?? r.name;
    if (wantCat && category !== wantCat) continue;
    if (wantMerchant && !`${display} ${r.name} ${r.merchant ?? ""}`.toLowerCase().includes(wantMerchant)) continue;
    total += amount; count++;
    const key = merchantKey(display) || display.toLowerCase();
    const m = merchants.get(key) ?? { name: display, total: 0, count: 0 };
    m.total += amount; m.count++; merchants.set(key, m);
    cats.set(category, (cats.get(category) ?? 0) + amount);
  }
  return {
    from: a.from, to: a.to, filters: { category: wantCat, merchant: a.merchant ?? null },
    total: r2(total), transactionCount: count,
    topMerchants: [...merchants.values()].sort((x, y) => y.total - x.total).slice(0, 8).map((m) => ({ name: m.name, total: r2(m.total), count: m.count })),
    byCategory: [...cats].sort((x, y) => y[1] - x[1]).slice(0, 10).map(([category, t]) => ({ category, total: r2(t) })),
  };
}

export async function getIncome(userId: string) {
  const { income, outflow } = await computeInsightsForUser(userId);
  return { monthlyIncome: income.monthly, source: income.source, confidence: income.confidence, sources: income.sources.slice(0, 8), usualMonthlySpending: outflow.monthlyAverage };
}

export async function getHealth(userId: string) {
  const i = await computeInsightsForUser(userId);
  return { ...i.health, monthlyIncome: i.income.monthly, usualMonthlySpending: i.outflow.monthlyAverage, monthsOfData: i.dataQuality.monthsOfData };
}

export async function getInvestments(userId: string) {
  const i = await computeInsightsForUser(userId);
  const list = (await loadAccounts(userId)).filter((a) => a.group === "Investments");
  return {
    totalInvested: i.investing.totalInvested,
    investmentAccounts: list.slice(0, 20).map((a) => ({ name: a.name, balance: a.balance, institution: a.institution })),
    allocation: i.investing.allocation,
    notes: i.investing.notes.slice(0, 5).map((n) => ({ title: n.title, detail: n.detail })),
    savingsRate: i.health.savingsRate,
  };
}

/** First and last net-worth snapshot inside [from, to]. */
export async function getNetWorthWindow(userId: string, from: string, to: string) {
  const rows = await db
    .select({ date: netWorthSnapshots.date, netWorth: netWorthSnapshots.netWorth })
    .from(netWorthSnapshots)
    .where(and(eq(netWorthSnapshots.userId, userId), gte(netWorthSnapshots.date, from), lte(netWorthSnapshots.date, to)))
    .orderBy(asc(netWorthSnapshots.date));
  if (rows.length === 0) return null;
  const first = rows[0], last = rows[rows.length - 1];
  return { startDate: first.date, endDate: last.date, start: parseFloat(first.netWorth), end: parseFloat(last.netWorth), snapshots: rows.length };
}

export async function getCurrentBudgetAmount(userId: string, category: string): Promise<number> {
  const b = await budgetsResponse(userId);
  return b.budgets.find((x) => x.category === normalizeCategory(category))?.monthlyAmount ?? 0;
}

export { todayIso };
