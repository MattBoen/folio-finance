import { and, eq, gte, isNull } from "drizzle-orm";
import { alias } from "drizzle-orm/pg-core";
import { db } from "../db/client.js";
import { accounts, categories, transactions, userSettings } from "../db/schema.js";
import { normalizeCategory } from "./categories.js";
import { buildInsights, isoDay, type InAcct, type InTxn } from "./insights.js";

export function todayIso(): string {
  return isoDay(Date.now());
}

export async function loadInsightInputs(userId: string, now: string, lookbackDays = 190) {
  const userCat = alias(categories, "user_cat");
  const plaidCat = alias(categories, "plaid_cat");
  const since = isoDay(Date.parse(now) - lookbackDays * 86_400_000);

  const rows = await db
    .select({
      date: transactions.date,
      amount: transactions.amount,
      name: transactions.name,
      userName: transactions.userName,
      userCat: userCat.name,
      plaidCat: plaidCat.name,
      isExcluded: transactions.isExcluded,
      isPending: transactions.isPending,
      accountType: accounts.type,
    })
    .from(transactions)
    .innerJoin(accounts, eq(transactions.accountId, accounts.id))
    .leftJoin(userCat, eq(transactions.userCategoryId, userCat.id))
    .leftJoin(plaidCat, eq(transactions.categoryId, plaidCat.id))
    .where(
      and(
        eq(transactions.userId, userId),
        isNull(transactions.deletedAt),
        isNull(accounts.deletedAt),
        gte(transactions.date, since)
      )
    );

  const txns: InTxn[] = rows.map((r) => ({
    date: r.date,
    amount: parseFloat(r.amount),
    name: r.userName ?? r.name,
    category: normalizeCategory(r.userCat ?? r.plaidCat),
    isExcluded: r.isExcluded,
    isPending: r.isPending,
    accountType: r.accountType,
  }));

  const acctRows = await db
    .select({
      type: accounts.type,
      subtype: accounts.subtype,
      balance: accounts.balanceCurrent,
      limit: accounts.balanceLimit,
      hidden: accounts.isHidden,
    })
    .from(accounts)
    .where(and(eq(accounts.userId, userId), isNull(accounts.deletedAt)));

  const accts: InAcct[] = acctRows.map((a) => ({
    type: a.type,
    subtype: a.subtype,
    balance: parseFloat(a.balance ?? "0"),
    limit: a.limit != null ? parseFloat(a.limit) : null,
    hidden: a.hidden,
  }));

  const [settings] = await db.select().from(userSettings).where(eq(userSettings.userId, userId));
  return {
    txns,
    accounts: accts,
    incomeOverride: settings?.incomeOverride != null ? parseFloat(settings.incomeOverride) : null,
    birthYear: settings?.birthYear ?? null,
  };
}

export async function computeInsightsForUser(userId: string, now = todayIso()) {
  const input = await loadInsightInputs(userId, now);
  return buildInsights({ ...input, now });
}
