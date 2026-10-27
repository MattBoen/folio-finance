import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import { eq, and, isNull, gte, lte, desc, sql } from "drizzle-orm";
import { db } from "../db/client.js";
import { transactions, accounts, categories } from "../db/schema.js";
import { requireAuth } from "../middleware/auth.js";

const router = new Hono();

// ── List transactions ─────────────────────────────────────────────────────────
router.get(
  "/",
  requireAuth,
  zValidator(
    "query",
    z.object({
      from: z.string().optional(),           // YYYY-MM-DD
      to: z.string().optional(),             // YYYY-MM-DD
      account_id: z.string().uuid().optional(),
      limit: z.coerce.number().int().min(1).max(500).default(100),
      offset: z.coerce.number().int().min(0).default(0),
      pending: z.enum(["true", "false"]).optional(),
    })
  ),
  async (c) => {
    const { userId } = c.get("auth");
    const { from, to, account_id, limit, offset, pending } = c.req.valid("query");

    const conditions = [
      eq(transactions.userId, userId),
      isNull(transactions.deletedAt),
    ];

    if (from) conditions.push(gte(transactions.date, from));
    if (to) conditions.push(lte(transactions.date, to));
    if (account_id) conditions.push(eq(transactions.accountId, account_id));
    if (pending === "true") conditions.push(eq(transactions.isPending, true));
    if (pending === "false") conditions.push(eq(transactions.isPending, false));

    const rows = await db
      .select({
        id: transactions.id,
        accountId: transactions.accountId,
        accountName: accounts.name,
        amount: transactions.amount,
        date: transactions.date,
        name: transactions.name,
        userName: transactions.userName,
        merchantName: transactions.merchantName,
        categoryName: categories.name,
        note: transactions.note,
        isPending: transactions.isPending,
        isExcluded: transactions.isExcluded,
        lat: transactions.lat,
        lon: transactions.lon,
      })
      .from(transactions)
      .leftJoin(accounts, eq(transactions.accountId, accounts.id))
      .leftJoin(categories, eq(transactions.userCategoryId, categories.id))
      .where(and(...conditions))
      .orderBy(desc(transactions.date))
      .limit(limit)
      .offset(offset);

    const [{ count }] = await db
      .select({ count: sql<number>`count(*)::int` })
      .from(transactions)
      .where(and(...conditions));

    return c.json({ transactions: rows, total: count, limit, offset });
  }
);

// ── Update transaction (rename, note, category, exclude) ─────────────────────
router.patch(
  "/:id",
  requireAuth,
  zValidator(
    "json",
    z.object({
      user_name: z.string().max(100).optional(),
      note: z.string().max(500).optional(),
      user_category_id: z.string().uuid().nullable().optional(),
      is_excluded: z.boolean().optional(),
    })
  ),
  async (c) => {
    const { userId } = c.get("auth");
    const txnId = c.req.param("id");
    const patch = c.req.valid("json");

    const set: Record<string, unknown> = { updatedAt: new Date() };
    if (patch.user_name !== undefined) set.userName = patch.user_name;
    if (patch.note !== undefined) set.note = patch.note;
    if (patch.user_category_id !== undefined) set.userCategoryId = patch.user_category_id;
    if (patch.is_excluded !== undefined) set.isExcluded = patch.is_excluded;

    const [updated] = await db
      .update(transactions)
      .set(set)
      .where(and(eq(transactions.id, txnId), eq(transactions.userId, userId)))
      .returning({ id: transactions.id });

    if (!updated) return c.json({ error: "Not found" }, 404);
    return c.json({ ok: true });
  }
);

// ── Spending summary (for Spending tab) ───────────────────────────────────────
router.get(
  "/spending/summary",
  requireAuth,
  zValidator(
    "query",
    z.object({
      from: z.string(),
      to: z.string(),
    })
  ),
  async (c) => {
    const { userId } = c.get("auth");
    const { from, to } = c.req.valid("query");

    const rows = await db
      .select({
        categoryName: categories.name,
        categoryId: transactions.userCategoryId,
        total: sql<string>`sum(${transactions.amount})::text`,
        count: sql<number>`count(*)::int`,
      })
      .from(transactions)
      .leftJoin(categories, eq(transactions.userCategoryId, categories.id))
      .where(
        and(
          eq(transactions.userId, userId),
          isNull(transactions.deletedAt),
          eq(transactions.isExcluded, false),
          eq(transactions.isPending, false),
          gte(transactions.date, from),
          lte(transactions.date, to)
        )
      )
      .groupBy(transactions.userCategoryId, categories.name)
      .orderBy(desc(sql`sum(${transactions.amount})`));

    return c.json({ summary: rows });
  }
);

export { router as transactionsRouter };
