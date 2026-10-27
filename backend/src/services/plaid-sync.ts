import { eq, and, isNull } from "drizzle-orm";
import { db } from "../db/client.js";
import { plaidItems, accounts, transactions, netWorthSnapshots } from "../db/schema.js";
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
    const { data } = await plaid.transactionsSync({
      access_token: accessToken,
      cursor,
    });

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

async function upsertTransactions(txns: Transaction[], userId: string): Promise<void> {
  for (const txn of txns) {
    const [acct] = await db
      .select({ id: accounts.id })
      .from(accounts)
      .where(and(eq(accounts.plaidAccountId, txn.account_id), eq(accounts.userId, userId)));

    if (!acct) continue;

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

  for (const acct of userAccounts) {
    const bal = parseFloat(acct.balanceCurrent ?? "0");
    if (acct.type === "credit" || acct.type === "loan") {
      totalLiabilities += bal;
    } else {
      totalAssets += bal;
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
    })
    .onConflictDoUpdate({
      target: [netWorthSnapshots.userId, netWorthSnapshots.date],
      set: {
        totalAssets: totalAssets.toFixed(2),
        totalLiabilities: totalLiabilities.toFixed(2),
        netWorth: (totalAssets - totalLiabilities).toFixed(2),
      },
    });
}
