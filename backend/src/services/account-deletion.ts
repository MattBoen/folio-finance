import { eq, or, sql } from "drizzle-orm";
import { db } from "../db/client.js";
import { users, plaidItems, auditLog } from "../db/schema.js";
import { decryptToken } from "./encryption.js";
import { plaid } from "./plaid-client.js";

/** Tells Plaid to drop each of the user's connections. Best effort: failures are logged (never with tokens) and skipped. */
export async function removePlaidItems(userId: string): Promise<{ removed: number; failed: number }> {
  const items = await db.select().from(plaidItems).where(eq(plaidItems.userId, userId));
  let removed = 0;
  let failed = 0;
  for (const item of items) {
    try {
      await plaid.itemRemove({ access_token: decryptToken(item.accessTokenEnc, item.accessTokenIv) });
      removed++;
    } catch (err) {
      failed++;
      const code = (err as { response?: { data?: { error_code?: string } } })?.response?.data?.error_code;
      console.error("[account-deletion] plaid item removal failed", { itemId: item.id, code: code ?? "unknown" });
    }
  }
  return { removed, failed };
}

/**
 * Permanently deletes the user. Every table that references users (or accounts) cascades,
 * so this removes accounts, transactions, budgets, settings, vehicles, snapshots, sessions,
 * push tokens and Plaid items. audit_log is "set null" by design, so its rows are removed explicitly.
 */
export async function hardDeleteUser(userId: string): Promise<void> {
  await db.transaction(async (tx) => {
    await tx.delete(auditLog).where(or(eq(auditLog.userId, userId), sql`${auditLog.resourceId} = ${userId}`));
    await tx.delete(users).where(eq(users.id, userId));
  });
}
