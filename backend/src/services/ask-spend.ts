// Ask Folio's spend tracking in Postgres: dollars per user per month, plus the whole-app total.
// The rules and prices live in ask-cost.ts.
import { and, eq, sql } from "drizzle-orm";
import { db } from "../db/client.js";
import { askSpend } from "../db/schema.js";
import { globalMonthlyLimit, userMonthlyLimit } from "./ask-cost.js";

export const monthKey = (d = new Date()) => d.toISOString().slice(0, 7);
const toMicro = (usd: number) => Math.round(usd * 1_000_000);

export async function getSpend(userId: string, month = monthKey()): Promise<{ user: number; global: number }> {
  const [u] = await db.select({ micro: askSpend.microUsd }).from(askSpend).where(and(eq(askSpend.userId, userId), eq(askSpend.month, month)));
  const [g] = await db.select({ micro: sql<string>`coalesce(sum(${askSpend.microUsd}), 0)` }).from(askSpend).where(eq(askSpend.month, month));
  return { user: (u?.micro ?? 0) / 1_000_000, global: Number(g?.micro ?? 0) / 1_000_000 };
}

/** Which limit (if any) is already reached. */
export async function limitReached(userId: string): Promise<"global" | "user" | null> {
  const s = await getSpend(userId);
  if (s.global >= globalMonthlyLimit()) return "global";
  if (s.user >= userMonthlyLimit()) return "user";
  return null;
}

export async function addSpend(userId: string, usd: number): Promise<void> {
  if (!(usd > 0)) return;
  const micro = toMicro(usd);
  await db
    .insert(askSpend)
    .values({ userId, month: monthKey(), microUsd: micro, questions: 1 })
    .onConflictDoUpdate({
      target: [askSpend.userId, askSpend.month],
      set: { microUsd: sql`${askSpend.microUsd} + ${micro}`, questions: sql`${askSpend.questions} + 1` },
    });
}
