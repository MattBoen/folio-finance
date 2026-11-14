import { and, eq, isNull } from "drizzle-orm";
import { db } from "../db/client.js";
import { accounts, plaidItems, userSettings } from "../db/schema.js";

/**
 * Credit use: card balances ÷ card limits. Banks usually report each card's limit; when one doesn't
 * (Apple Card, for example), you type it in and that number is used from then on. Your number always wins.
 */

export interface CardIn { id: string; name: string; institution: string | null; balance: number; reported: number | null }

export function summarizeCredit(cards: CardIn[], yours: Record<string, number>) {
  const rows = cards.map((c) => {
    const mine = yours[c.id];
    const limit = mine != null && mine > 0 ? mine : c.reported != null && c.reported > 0 ? c.reported : null;
    return {
      id: c.id,
      name: c.name,
      institution: c.institution,
      balance: r2(Math.max(0, c.balance)),
      limit: limit == null ? null : r2(limit),
      limitSource: mine != null && mine > 0 ? "you" : limit != null ? "bank" : "none",
      used: limit ? r2(Math.max(0, c.balance) / limit) : null,
    };
  });
  const counted = rows.filter((r) => r.limit != null);
  const limitTotal = counted.reduce((s, r) => s + (r.limit ?? 0), 0);
  const balanceTotal = counted.reduce((s, r) => s + r.balance, 0);
  return {
    cards: rows,
    balance: r2(balanceTotal),
    limit: r2(limitTotal),
    rate: limitTotal > 0 ? r2(balanceTotal / limitTotal) : null,
    missing: rows.filter((r) => r.limit == null).length,
  };
}

const r2 = (n: number) => Math.round(n * 100) / 100;

export async function getCreditUse(userId: string) {
  const rows = await db
    .select({ id: accounts.id, name: accounts.name, balance: accounts.balanceCurrent, limit: accounts.balanceLimit, institution: plaidItems.institutionName })
    .from(accounts)
    .leftJoin(plaidItems, eq(accounts.plaidItemId, plaidItems.id))
    .where(and(eq(accounts.userId, userId), eq(accounts.type, "credit"), eq(accounts.isHidden, false), isNull(accounts.deletedAt)));
  const [settings] = await db.select({ creditLimits: userSettings.creditLimits }).from(userSettings).where(eq(userSettings.userId, userId));
  return summarizeCredit(
    rows.map((r) => ({ id: r.id, name: r.name, institution: r.institution, balance: parseFloat(r.balance ?? "0"), reported: r.limit != null ? parseFloat(r.limit) : null })),
    settings?.creditLimits ?? {}
  );
}

/** Saves card limits you typed. A null or 0 clears yours and goes back to what the bank reports. */
export async function saveCreditLimits(userId: string, limits: Record<string, number | null>) {
  const [settings] = await db.select({ creditLimits: userSettings.creditLimits }).from(userSettings).where(eq(userSettings.userId, userId));
  const next = { ...(settings?.creditLimits ?? {}) };
  for (const [id, v] of Object.entries(limits)) {
    if (v != null && v > 0) next[id] = v; else delete next[id];
  }
  const set = { creditLimits: next, updatedAt: new Date() };
  await db.insert(userSettings).values({ userId, ...set }).onConflictDoUpdate({ target: userSettings.userId, set });
  return getCreditUse(userId);
}
