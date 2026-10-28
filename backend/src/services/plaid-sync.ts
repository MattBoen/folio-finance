import { eq, and, isNull } from "drizzle-orm";
import { db } from "../db/client.js";
import { plaidItems, accounts, transactions, netWorthSnapshots, categories } from "../db/schema.js";
import { plaid } from "./plaid-client.js";
import { decryptToken } from "./encryption.js";
import type { AccountBase, Transaction } from "plaid";

export async function syncItem(plaidItemId: string, userId: string): Promise<void> {
  const [item] = await db
    .select()
    .from(plaidItems)
    .where(and(eq(plaidItems.id, plaidItemId), eq(plaidItems.userId, userId)));

  if (!item) throw new Error("Item not found");

  const accessToken = decryptToken(item.accessTokenEnc, item.accessTokenIv);

  await syncAccounts(item.id, userId, accessToken);
  await syncTransactions(item, userId, accessToken);
  await takeNetWorthSnapshot(userId);
}

async function syncAccounts(
  plaidItemId: string,
  userId: string,
  accessToken: string
): Promise<void> {
  const { data } = await plaid.accountsGet({ access_token: accessToken });

  for (const acct of data.accounts) {
    await db
      .insert(accounts)
      .values({
        userId,
        plaidItemId,
        plaidAccountId: acct.account_id,
        name: acct.name,
        officialName: acct.official_name ?? null,
        type: acct.type,
        subtype: acct.subtype ?? null,
        balanceCurrent: acct.balances.current?.toString() ?? null,
        balanceAvailable: acct.balances.available?.toString() ?? null,
        balanceLimit: acct.balances.limit?.toString() ?? null,
        currency: acct.balances.iso_currency_code ?? "USD",
        mask: acct.mask ?? null,
        lastSyncedAt: new Date(),
      })
      .onConflictDoUpdate({
        target: accounts.plaidAccountId,
        set: {
          balanceCurrent: acct.balances.current?.toString() ?? null,
          balanceAvailable: acct.balances.available?.toString() ?? null,
          balanceLimit: acct.balances.limit?.toString() ?? null,
          lastSyncedAt: new Date(),
          updatedAt: new Date(),
        },
      });
  }
}

async function syncTransactions(
  item: typeof plaidItems.$inferSelect,
  userId: string,
  accessToken: string
): Promise<void> {
  let cursor = item.transactionCursor ?? undefined;
  let hasMore = true;

  while (hasMore) {
    const data = await syncPage(accessToken, cursor);
    // Fresh items can stay PRODUCT_NOT_READY for a while; Plaid's webhook triggers another sync.
    if (!data) return;

    await upsertTransactions(data.added, userId);
    await upsertTransactions(data.modified, userId);
    await removeTransactions(data.removed.map((r) => r.transaction_id));

    cursor = data.next_cursor;
    hasMore = data.has_more;
  }

  await db
    .update(plaidItems)
    .set({ transactionCursor: cursor, updatedAt: new Date() })
    .where(eq(plaidItems.id, item.id));
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Initial transaction pulls can fail with PRODUCT_NOT_READY for a few seconds after linking.
async function syncPage(accessToken: string, cursor: string | undefined) {
  for (let attempt = 0; ; attempt++) {
    try {
      const { data } = await plaid.transactionsSync({ access_token: accessToken, cursor });
      return data;
    } catch (err) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const code = (err as any)?.response?.data?.error_code;
      if (code !== "PRODUCT_NOT_READY") throw err;
      if (attempt >= 4) return null;
      await sleep(2000 * (attempt + 1));
    }
  }
}

const CATEGORY_BY_PRIMARY: Record<string, string> = {
  FOOD_AND_DRINK: "Dining",
  TRANSPORTATION: "Transport",
  TRAVEL: "Travel",
  GENERAL_MERCHANDISE: "Shopping",
  RENT_AND_UTILITIES: "Bills & Utilities",
  HOME_IMPROVEMENT: "Home",
  ENTERTAINMENT: "Entertainment",
  MEDICAL: "Health",
  PERSONAL_CARE: "Health",
  INCOME: "Income",
  TRANSFER_IN: "Transfer",
  TRANSFER_OUT: "Transfer",
  LOAN_PAYMENTS: "Transfer",
  BANK_FEES: "Fees",
  GENERAL_SERVICES: "Services",
  GOVERNMENT_AND_NON_PROFIT: "Other",
};

function friendlyCategory(txn: Transaction): string {
  const pfc = txn.personal_finance_category;
  if (pfc?.detailed === "FOOD_AND_DRINK_GROCERIES") return "Groceries";
  return (pfc && CATEGORY_BY_PRIMARY[pfc.primary]) || "Other";
}

const categoryIds = new Map<string, string>();
async function categoryIdFor(name: string): Promise<string> {
  const cached = categoryIds.get(name);
  if (cached) return cached;
  const [existing] = await db.select({ id: categories.id }).from(categories).where(eq(categories.name, name));
  const id = existing
    ? existing.id
    : (await db.insert(categories).values({ name, isSystem: true }).returning({ id: categories.id }))[0].id;
  categoryIds.set(name, id);
  return id;
}

async function upsertTransactions(txns: Transaction[], userId: string): Promise<void> {
  for (const txn of txns) {
    const [acct] = await db
      .select({ id: accounts.id })
      .from(accounts)
      .where(and(eq(accounts.plaidAccountId, txn.account_id), eq(accounts.userId, userId)));

    if (!acct) continue;

    const categoryId = await categoryIdFor(friendlyCategory(txn));

    await db
      .insert(transactions)
      .values({
        userId,
        accountId: acct.id,
        plaidTransactionId: txn.transaction_id,
        plaidPendingTransactionId: txn.pending_transaction_id ?? null,
        amount: txn.amount.toString(),
        date: txn.date,
        name: txn.name,
        merchantName: txn.merchant_name ?? null,
        isPending: txn.pending,
        categoryId,
        lat: txn.location?.lat?.toString() ?? null,
        lon: txn.location?.lon?.toString() ?? null,
      })
      .onConflictDoUpdate({
        target: transactions.plaidTransactionId,
        set: {
          amount: txn.amount.toString(),
          name: txn.name,
          merchantName: txn.merchant_name ?? null,
          isPending: txn.pending,
          categoryId,
          updatedAt: new Date(),
        },
      });
  }
}

async function removeTransactions(plaidTxnIds: string[]): Promise<void> {
  for (const plaidTxnId of plaidTxnIds) {
    await db
      .update(transactions)
      .set({ deletedAt: new Date() })
      .where(eq(transactions.plaidTransactionId, plaidTxnId));
  }
}

export async function takeNetWorthSnapshot(userId: string): Promise<void> {
  const userAccounts = await db
    .select({
      type: accounts.type,
      balanceCurrent: accounts.balanceCurrent,
    })
    .from(accounts)
    .where(
      and(
        eq(accounts.userId, userId),
        eq(accounts.isHidden, false),
        isNull(accounts.deletedAt)
      )
    );

  let totalAssets = 0;
  let totalLiabilities = 0;
  let invested = 0;

  for (const acct of userAccounts) {
    const bal = parseFloat(acct.balanceCurrent ?? "0");
    if (acct.type === "credit" || acct.type === "loan") {
      totalLiabilities += bal;
    } else {
      totalAssets += bal;
      if (acct.type === "investment") invested += bal;
    }
  }

  const today = new Date().toISOString().split("T")[0];

  await db
    .insert(netWorthSnapshots)
    .values({
      userId,
      date: today,
      totalAssets: totalAssets.toFixed(2),
      totalLiabilities: totalLiabilities.toFixed(2),
      netWorth: (totalAssets - totalLiabilities).toFixed(2),
      invested: invested.toFixed(2),
    })
    .onConflictDoUpdate({
      target: [netWorthSnapshots.userId, netWorthSnapshots.date],
      set: {
        totalAssets: totalAssets.toFixed(2),
        totalLiabilities: totalLiabilities.toFixed(2),
        netWorth: (totalAssets - totalLiabilities).toFixed(2),
        invested: invested.toFixed(2),
      },
    });
}
