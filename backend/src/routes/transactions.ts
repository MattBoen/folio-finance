import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import { eq, and, isNull, gte, lte, desc, sql, ilike } from "drizzle-orm";
import { alias } from "drizzle-orm/pg-core";
import { db } from "../db/client.js";
import { transactions, accounts, categories } from "../db/schema.js";
import { requireAuth } from "../middleware/auth.js";
import { takeNetWorthSnapshot } from "../services/plaid-sync.js";
import { normalizeCategory } from "../services/categories.js";

const router = new Hono();

const userCat = alias(categories, "user_cat");
const plaidCat = alias(categories, "plaid_cat");
const categoryNameExpr = sql<string | null>`coalesce(${userCat.name}, ${plaidCat.name})`;

const txSelect = {
  id: transactions.id,
  accountId: transactions.accountId,
  accountName: accounts.name,
  amount: transactions.amount,
  date: transactions.date,
  name: transactions.name,
  userName: transactions.userName,
  merchantName: transactions.merchantName,
  categoryName: categoryNameExpr,
  note: transactions.note,
  isPending: transactions.isPending,
  isExcluded: transactions.isExcluded,
  lat: transactions.lat,
  lon: transactions.lon,
  place: transactions.place,
};

function fromTx(q: any) {
  return q
    .from(transactions)
    .leftJoin(accounts, eq(transactions.accountId, accounts.id))
    .leftJoin(userCat, eq(transactions.userCategoryId, userCat.id))
    .leftJoin(plaidCat, eq(transactions.categoryId, plaidCat.id));
}

// Raw category names (Plaid, seeded, user-typed) are folded into Folio's small vocabulary on the way out.
function withNormalizedCategory<T extends { categoryName: string | null }>(row: T): T {
  return row && row.categoryName ? { ...row, categoryName: normalizeCategory(row.categoryName) } : row;
}

async function loadTransaction(userId: string, id: string) {
  const [row] = await fromTx(db.select(txSelect)).where(
    and(eq(transactions.id, id), eq(transactions.userId, userId), isNull(transactions.deletedAt))
  );
  return withNormalizedCategory(row);
}

async function findOrCreateCategory(name: string): Promise<string> {
  const [existing] = await db
    .select({ id: categories.id })
    .from(categories)
    .where(ilike(categories.name, name))
    .limit(1);
  if (existing) return existing.id;
  const [created] = await db
    .insert(categories)
    .values({ name, isSystem: true })
    .returning({ id: categories.id });
  return created.id;
}

// Effect of a signed (Plaid-style) amount on a manual account's balance.
function balanceDelta(type: string, signedAmount: number): number {
  return type === "credit" || type === "loan" ? signedAmount : -signedAmount;
}

async function adjustManualBalance(accountId: string, userId: string, delta: number) {
  await db
    .update(accounts)
    .set({
      balanceCurrent: sql`(coalesce(${accounts.balanceCurrent}, 0) + ${delta.toFixed(2)}::numeric)`,
      updatedAt: new Date(),
    })
    .where(and(eq(accounts.id, accountId), eq(accounts.userId, userId)));
}

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

    const rows = await fromTx(db.select(txSelect))
      .where(and(...conditions))
      .orderBy(desc(transactions.date))
      .limit(limit)
      .offset(offset);

    const [{ count }] = await db
      .select({ count: sql<number>`count(*)::int` })
      .from(transactions)
      .where(and(...conditions));

    return c.json({ transactions: rows.map(withNormalizedCategory), total: count, limit, offset });
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
      category: z.string().min(1).max(60).optional(),
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
    if (patch.category !== undefined) set.userCategoryId = await findOrCreateCategory(patch.category.trim());

    const [updated] = await db
      .update(transactions)
      .set(set)
      .where(
        and(eq(transactions.id, txnId), eq(transactions.userId, userId), isNull(transactions.deletedAt))
      )
      .returning({ id: transactions.id });

    if (!updated) return c.json({ error: "Not found" }, 404);
    return c.json({ ok: true, transaction: await loadTransaction(userId, txnId) });
  }
);

// ── Create manual transaction ────────────────────────────────────────────────
router.post(
  "/",
  requireAuth,
  zValidator(
    "json",
    z.object({
      account_id: z.string().uuid(),
      amount: z.number().positive(),
      kind: z.enum(["expense", "income"]),
      date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
      name: z.string().min(1).max(100),
      category: z.string().min(1).max(60).optional(),
      note: z.string().max(500).optional(),
    })
  ),
  async (c) => {
    const { userId } = c.get("auth");
    const body = c.req.valid("json");

    const [acct] = await db
      .select({ id: accounts.id, type: accounts.type, plaidItemId: accounts.plaidItemId })
      .from(accounts)
      .where(
        and(eq(accounts.id, body.account_id), eq(accounts.userId, userId), isNull(accounts.deletedAt))
      );
    if (!acct) return c.json({ error: "Account not found" }, 404);

    const signed = body.kind === "expense" ? body.amount : -body.amount;
    const categoryId = body.category ? await findOrCreateCategory(body.category.trim()) : null;

    const [created] = await db
      .insert(transactions)
      .values({
        userId,
        accountId: acct.id,
        amount: signed.toFixed(2),
        date: body.date,
        name: body.name,
        userCategoryId: categoryId,
        note: body.note ?? null,
      })
      .returning({ id: transactions.id });

    if (!acct.plaidItemId) {
      await adjustManualBalance(acct.id, userId, balanceDelta(acct.type, signed));
      await takeNetWorthSnapshot(userId);
    }

    return c.json({ transaction: await loadTransaction(userId, created.id) }, 201);
  }
);

// ── Delete manual transaction ────────────────────────────────────────────────
router.delete("/:id", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  const id = c.req.param("id");

  const [tx] = await db
    .select({
      accountId: transactions.accountId,
      amount: transactions.amount,
      plaidTransactionId: transactions.plaidTransactionId,
      accountType: accounts.type,
      plaidItemId: accounts.plaidItemId,
    })
    .from(transactions)
    .innerJoin(accounts, eq(transactions.accountId, accounts.id))
    .where(and(eq(transactions.id, id), eq(transactions.userId, userId), isNull(transactions.deletedAt)));

  if (!tx) return c.json({ error: "Not found" }, 404);
  if (tx.plaidTransactionId) return c.json({ error: "Synced transactions can't be deleted" }, 400);

  await db
    .update(transactions)
    .set({ deletedAt: new Date(), updatedAt: new Date() })
    .where(and(eq(transactions.id, id), eq(transactions.userId, userId)));

  if (!tx.plaidItemId) {
    await adjustManualBalance(tx.accountId, userId, -balanceDelta(tx.accountType, parseFloat(tx.amount)));
    await takeNetWorthSnapshot(userId);
  }
  return c.json({ ok: true });
});

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
        categoryName: categoryNameExpr,
        total: sql<string>`sum(${transactions.amount})::text`,
        count: sql<number>`count(*)::int`,
      })
      .from(transactions)
      .leftJoin(userCat, eq(transactions.userCategoryId, userCat.id))
      .leftJoin(plaidCat, eq(transactions.categoryId, plaidCat.id))
      .where(
        and(
          eq(transactions.userId, userId),
          isNull(transactions.deletedAt),
          eq(transactions.isExcluded, false),
          eq(transactions.isPending, false),
          sql`${transactions.amount} > 0`,
          gte(transactions.date, from),
          lte(transactions.date, to)
        )
      )
      .groupBy(categoryNameExpr)
      .orderBy(desc(sql`sum(${transactions.amount})`));

    // Several raw categories can fold into one Folio category, so merge them.
    const merged = new Map<string, { categoryName: string; total: number; count: number }>();
    for (const r of rows) {
      const name = normalizeCategory(r.categoryName);
      const m = merged.get(name) ?? { categoryName: name, total: 0, count: 0 };
      m.total += parseFloat(r.total);
      m.count += r.count;
      merged.set(name, m);
    }
    const summary = [...merged.values()]
      .filter((m) => m.categoryName !== "Transfer" && m.categoryName !== "Income")
      .sort((a, b) => b.total - a.total)
      .map((m) => ({ categoryName: m.categoryName, total: m.total.toFixed(2), count: m.count }));
    return c.json({ summary });
  }
);

export { router as transactionsRouter };
