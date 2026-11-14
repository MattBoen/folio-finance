import { and, eq, isNull } from "drizzle-orm";
import { db } from "../db/client.js";
import { accounts, plaidItems, userSettings } from "../db/schema.js";

/**
 * Credit use: card balances ÷ card limits. Banks usually report each card's limit; when one doesn't
 * (Apple Card, for example), you type it in and that number is used from then on. Your number always wins.
 *
 * Charge cards (Amex Green, Gold, Platinum...) have no preset spending limit. Current FICO (8 and 9) and
 * VantageScore leave them out of utilization entirely, since there's no limit to divide by, so they're left
 * out here too: neither the balance nor a limit counts. Folio recognizes Amex's charge cards on its own;
 * you can mark any card that way, or undo it.
 */

export type LimitChoice = number | "none";
export interface CardIn { id: string; name: string; institution: string | null; balance: number; reported: number | null }

/** Amex's US charge cards. They report no limit, and aren't counted in utilization. */
export function looksLikeChargeCard(c: CardIn): boolean {
  const amex = /american express|amex/i.test(`${c.institution ?? ""} ${c.name}`);
  return amex && c.reported == null && /\b(green|gold|platinum|centurion)\b/i.test(c.name);
}

export function summarizeCredit(cards: CardIn[], yours: Record<string, LimitChoice>) {
  const rows = cards.map((c) => {
    const mine = yours[c.id];
    const balance = r2(Math.max(0, c.balance));
    const charge = mine === "none" || (mine === undefined && looksLikeChargeCard(c));
    if (charge) {
      return { id: c.id, name: c.name, institution: c.institution, balance, limit: null as number | null, used: null as number | null,
        limitSource: mine === "none" ? "you" : "rules", noLimit: true };
    }
    const typed = typeof mine === "number" && mine > 0 ? mine : null;
    const limit = typed ?? (c.reported != null && c.reported > 0 ? c.reported : null);
    return {
      id: c.id, name: c.name, institution: c.institution, balance,
      limit: limit == null ? null : r2(limit),
      used: limit ? r2(balance / limit) : null,
      limitSource: typed != null ? "you" : limit != null ? "bank" : "none",
      noLimit: false,
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
    missing: rows.filter((r) => r.limit == null && !r.noLimit).length,
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

/**
 * Saves your card limits: a number, "none" for a card with no preset limit (left out of credit use),
 * or null to go back to what the bank reports (and Folio's own charge-card guess).
 */
export async function saveCreditLimits(userId: string, limits: Record<string, number | "none" | null>) {
  const [settings] = await db.select({ creditLimits: userSettings.creditLimits }).from(userSettings).where(eq(userSettings.userId, userId));
  const next: Record<string, LimitChoice> = { ...(settings?.creditLimits ?? {}) };
  for (const [id, v] of Object.entries(limits)) {
    if (v === "none" || (typeof v === "number" && v > 0)) next[id] = v; else delete next[id];
  }
  const set = { creditLimits: next, updatedAt: new Date() };
  await db.insert(userSettings).values({ userId, ...set }).onConflictDoUpdate({ target: userSettings.userId, set });
  return getCreditUse(userId);
}
