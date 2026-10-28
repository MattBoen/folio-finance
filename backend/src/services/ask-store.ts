// Ask Folio's small bits of state: the opt-in flag, daily counts, and pending budget changes.
// Message text is never stored.
import { and, eq, sql } from "drizzle-orm";
import { db } from "../db/client.js";
import { askProposals, askUsage, budgets, userSettings } from "../db/schema.js";
import { findOrCreateCategory } from "./category-db.js";
import { normalizeCategory } from "./categories.js";
import { applyChanges, changeOp, type ChangeOp } from "./ask-changes.js";
import { z } from "zod";

export const PROPOSAL_TTL_MS = 15 * 60_000;

export function dailyLimit(): number {
  const n = Number(process.env.ASK_DAILY_LIMIT);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 30;
}

const today = () => new Date().toISOString().slice(0, 10);

export interface AskSettings { enabled: boolean; dailyLimit: number; usedToday: number }

export async function getAskSettings(userId: string): Promise<AskSettings> {
  const [s] = await db.select({ enabled: userSettings.askEnabled }).from(userSettings).where(eq(userSettings.userId, userId));
  const [u] = await db.select({ count: askUsage.count }).from(askUsage).where(and(eq(askUsage.userId, userId), eq(askUsage.day, today())));
  return { enabled: s?.enabled ?? false, dailyLimit: dailyLimit(), usedToday: u?.count ?? 0 };
}

export async function setAskEnabled(userId: string, enabled: boolean): Promise<AskSettings> {
  const now = new Date();
  await db
    .insert(userSettings)
    .values({ userId, askEnabled: enabled, askConsentedAt: enabled ? now : null })
    .onConflictDoUpdate({
      target: userSettings.userId,
      set: enabled
        ? { askEnabled: true, askConsentedAt: sql`coalesce(${userSettings.askConsentedAt}, ${now})`, updatedAt: now }
        : { askEnabled: false, updatedAt: now },
    });
  return getAskSettings(userId);
}

/** Atomically counts one question against today's limit. Returns false when the limit is already reached. */
export async function consumeAsk(userId: string, limit = dailyLimit()): Promise<boolean> {
  const rows = await db
    .insert(askUsage)
    .values({ userId, day: today(), count: 1 })
    .onConflictDoUpdate({
      target: [askUsage.userId, askUsage.day],
      set: { count: sql`${askUsage.count} + 1` },
      setWhere: sql`${askUsage.count} < ${limit}`,
    })
    .returning({ count: askUsage.count });
  return rows.length > 0;
}

export async function refundAsk(userId: string): Promise<void> {
  await db
    .update(askUsage)
    .set({ count: sql`greatest(${askUsage.count} - 1, 0)` })
    .where(and(eq(askUsage.userId, userId), eq(askUsage.day, today())));
}

export interface BudgetProposal {
  kind: "budget";
  title: string;
  detail: string;
  category: string;
  currentAmount: number;
  newAmount: number;
}

export interface BudgetPlanItem { category: string; currentAmount: number; newAmount: number }

/** A whole budget at once: one Confirm applies every category. */
export interface BudgetPlanProposal {
  kind: "budget_plan";
  title: string;
  detail: string;
  category: string;
  currentAmount: number;
  newAmount: number;
  items: BudgetPlanItem[];
}

/** Any mix of edits to accounts, cars, transactions and income, confirmed with one tap. */
export interface ChangesProposal {
  kind: "changes";
  title: string;
  detail: string;
  category: string;
  currentAmount: number;
  newAmount: number;
  ops: ChangeOp[];
}

export type Proposal = BudgetProposal | BudgetPlanProposal | ChangesProposal;

export async function createProposal(userId: string, payload: Proposal): Promise<string> {
  const [row] = await db
    .insert(askProposals)
    .values({ userId, payload, expiresAt: new Date(Date.now() + PROPOSAL_TTL_MS) })
    .returning({ id: askProposals.id });
  return row.id;
}

export type ConfirmResult =
  | { ok: true; message: string }
  | { ok: false; status: 404 | 409 | 410; error: string };

/** Applies a stored proposal for this user. Another user's id, or an unknown one, is a 404. */
export async function confirmProposal(userId: string, proposalId: string): Promise<ConfirmResult> {
  const [p] = await db
    .select()
    .from(askProposals)
    .where(and(eq(askProposals.id, proposalId), eq(askProposals.userId, userId)));
  if (!p) return { ok: false, status: 404, error: "Not found" };
  if (p.appliedAt || p.dismissedAt) return { ok: false, status: 409, error: "That change was already handled." };
  if (p.expiresAt.getTime() < Date.now()) return { ok: false, status: 410, error: "That suggestion expired. Ask again." };

  const stored = p.payload as Proposal;
  if (stored.kind === "budget_plan") return applyPlan(userId, proposalId, stored);
  if (stored.kind === "changes") return applyChangesProposal(userId, proposalId, stored);
  if (stored.kind !== "budget") return { ok: false, status: 404, error: "Not found" };
  const payload = stored;
  const category = normalizeCategory(payload.category);
  const categoryId = await findOrCreateCategory(category);
  const amount = Math.max(0, payload.newAmount).toFixed(2);

  await db.transaction(async (tx) => {
    // Claim the proposal first so a double tap can't apply it twice.
    const claimed = await tx
      .update(askProposals)
      .set({ appliedAt: new Date() })
      .where(and(eq(askProposals.id, proposalId), eq(askProposals.userId, userId), sql`${askProposals.appliedAt} is null`))
      .returning({ id: askProposals.id });
    if (claimed.length === 0) throw new Error("already-applied");
    if (payload.newAmount <= 0) {
      await tx.delete(budgets).where(and(eq(budgets.userId, userId), eq(budgets.categoryId, categoryId)));
    } else {
      await tx
        .insert(budgets)
        .values({ userId, categoryId, monthlyAmount: amount })
        .onConflictDoUpdate({
          target: [budgets.userId, budgets.categoryId],
          set: { monthlyAmount: amount, isActive: true, updatedAt: new Date() },
        });
    }
  }).catch((e: Error) => {
    if (e.message === "already-applied") return;
    throw e;
  });

  const verb = payload.newAmount <= 0 ? "removed" : "set to $" + Math.round(payload.newAmount).toLocaleString("en-US");
  return { ok: true, message: `${category} budget ${verb}.` };
}

async function applyChangesProposal(userId: string, proposalId: string, p: ChangesProposal): Promise<ConfirmResult> {
  const ops = z.array(changeOp).safeParse(p.ops);
  if (!ops.success) return { ok: false, status: 404, error: "Not found" };
  // Claim it first so a double tap can't apply it twice; give it back if the changes can't be made.
  const claimed = await db
    .update(askProposals)
    .set({ appliedAt: new Date() })
    .where(and(eq(askProposals.id, proposalId), eq(askProposals.userId, userId), sql`${askProposals.appliedAt} is null`))
    .returning({ id: askProposals.id });
  if (claimed.length === 0) return { ok: false, status: 409, error: "That change was already handled." };
  try {
    const n = await applyChanges(userId, ops.data);
    return { ok: true, message: n === 1 ? "Done. That change is made." : `Done. ${n} changes made.` };
  } catch (e) {
    await db.update(askProposals).set({ appliedAt: null }).where(eq(askProposals.id, proposalId));
    return { ok: false, status: 409, error: (e as Error).message || "Those changes couldn't be made." };
  }
}

async function applyPlan(userId: string, proposalId: string, plan: BudgetPlanProposal): Promise<ConfirmResult> {
  const resolved = await Promise.all(
    plan.items.map(async (i) => ({ ...i, categoryId: await findOrCreateCategory(normalizeCategory(i.category)) }))
  );
  await db.transaction(async (tx) => {
    const claimed = await tx
      .update(askProposals)
      .set({ appliedAt: new Date() })
      .where(and(eq(askProposals.id, proposalId), eq(askProposals.userId, userId), sql`${askProposals.appliedAt} is null`))
      .returning({ id: askProposals.id });
    if (claimed.length === 0) throw new Error("already-applied");
    for (const i of resolved) {
      if (i.newAmount <= 0) {
        await tx.delete(budgets).where(and(eq(budgets.userId, userId), eq(budgets.categoryId, i.categoryId)));
      } else {
        const amount = Math.max(0, i.newAmount).toFixed(2);
        await tx
          .insert(budgets)
          .values({ userId, categoryId: i.categoryId, monthlyAmount: amount })
          .onConflictDoUpdate({
            target: [budgets.userId, budgets.categoryId],
            set: { monthlyAmount: amount, isActive: true, updatedAt: new Date() },
          });
      }
    }
  }).catch((e: Error) => {
    if (e.message === "already-applied") return;
    throw e;
  });
  const total = plan.items.reduce((s, i) => s + Math.max(0, i.newAmount), 0);
  return { ok: true, message: `Budget set: ${plan.items.length} categories, $${Math.round(total).toLocaleString("en-US")} a month.` };
}

export async function dismissProposal(userId: string, proposalId: string): Promise<boolean> {
  const rows = await db
    .update(askProposals)
    .set({ dismissedAt: new Date() })
    .where(and(eq(askProposals.id, proposalId), eq(askProposals.userId, userId), sql`${askProposals.appliedAt} is null`))
    .returning({ id: askProposals.id });
  return rows.length > 0;
}
