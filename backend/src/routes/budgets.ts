import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import { and, eq } from "drizzle-orm";
import { db } from "../db/client.js";
import { budgets, categories } from "../db/schema.js";
import { requireAuth } from "../middleware/auth.js";
import { findOrCreateCategory } from "../services/category-db.js";
import { NON_SPENDING, normalizeCategory } from "../services/categories.js";
import { computeInsightsForUser, loadInsightInputs, todayIso } from "../services/insight-data.js";

const router = new Hono();

async function budgetsResponse(userId: string) {
  const now = todayIso();
  const month = now.slice(0, 7);
  const monthStart = `${month}-01`;

  const lines = await db
    .select({ id: budgets.id, category: categories.name, monthlyAmount: budgets.monthlyAmount })
    .from(budgets)
    .leftJoin(categories, eq(budgets.categoryId, categories.id))
    .where(and(eq(budgets.userId, userId), eq(budgets.isActive, true)));

  const { txns } = await loadInsightInputs(userId, now, 40);
  const spent: Record<string, number> = {};
  for (const t of txns) {
    if (t.date < monthStart || t.date > now || t.isExcluded || t.isPending || NON_SPENDING.has(t.category)) continue;
    spent[t.category] = (spent[t.category] ?? 0) + t.amount;
  }

  return {
    month,
    budgets: lines
      .map((l) => {
        const category = normalizeCategory(l.category);
        return {
          id: l.id,
          category,
          monthlyAmount: parseFloat(l.monthlyAmount),
          spent: Math.round(Math.max(0, spent[category] ?? 0) * 100) / 100,
        };
      })
      .sort((a, b) => b.monthlyAmount - a.monthlyAmount),
  };
}

async function replaceBudgets(userId: string, items: { category: string; amount: number }[]) {
  const merged = new Map<string, number>();
  for (const i of items) {
    if (i.amount <= 0) continue;
    const cat = normalizeCategory(i.category);
    if (NON_SPENDING.has(cat)) continue;
    merged.set(cat, (merged.get(cat) ?? 0) + i.amount);
  }
  const ids = new Map<string, string>();
  for (const cat of merged.keys()) ids.set(cat, await findOrCreateCategory(cat));

  await db.transaction(async (tx) => {
    await tx.delete(budgets).where(eq(budgets.userId, userId));
    if (merged.size > 0) {
      await tx.insert(budgets).values(
        [...merged].map(([cat, amount]) => ({ userId, categoryId: ids.get(cat)!, monthlyAmount: amount.toFixed(2) }))
      );
    }
  });
}

router.get("/", requireAuth, async (c) => c.json(await budgetsResponse(c.get("auth").userId)));

router.post("/generate", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  const insights = await computeInsightsForUser(userId);
  await replaceBudgets(userId, insights.budget.items);
  return c.json(await budgetsResponse(userId));
});

router.put(
  "/",
  requireAuth,
  zValidator(
    "json",
    z.object({
      items: z.array(z.object({ category: z.string().min(1).max(60), amount: z.number().max(100_000_000) })).max(50),
    })
  ),
  async (c) => {
    const { userId } = c.get("auth");
    await replaceBudgets(userId, c.req.valid("json").items);
    return c.json(await budgetsResponse(userId));
  }
);

export { router as budgetsRouter };
