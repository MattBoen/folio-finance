import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import { eq, and, isNull, gte, desc, sql } from "drizzle-orm";
import { db } from "../db/client.js";
import { accounts, plaidItems, netWorthSnapshots } from "../db/schema.js";
import { requireAuth } from "../middleware/auth.js";
import { takeNetWorthSnapshot } from "../services/plaid-sync.js";

const router = new Hono();

const accountSelect = {
  id: accounts.id,
  name: accounts.name,
  officialName: accounts.officialName,
  type: accounts.type,
  subtype: accounts.subtype,
  balanceCurrent: accounts.balanceCurrent,
  balanceAvailable: accounts.balanceAvailable,
  balanceLimit: accounts.balanceLimit,
  currency: accounts.currency,
  mask: accounts.mask,
  isHidden: accounts.isHidden,
  lastSyncedAt: accounts.lastSyncedAt,
  plaidItemId: accounts.plaidItemId,
  institutionName: sql<string | null>`coalesce(${plaidItems.institutionName}, ${accounts.officialName})`,
};

export async function loadAccount(userId: string, id: string) {
  const [row] = await db
    .select(accountSelect)
    .from(accounts)
    .leftJoin(plaidItems, eq(accounts.plaidItemId, plaidItems.id))
    .where(and(eq(accounts.id, id), eq(accounts.userId, userId), isNull(accounts.deletedAt)));
  return row;
}

// ── List accounts ─────────────────────────────────────────────────────────────
router.get("/", requireAuth, async (c) => {
  const { userId } = c.get("auth");

  const rows = await db
    .select(accountSelect)
    .from(accounts)
    .leftJoin(plaidItems, eq(accounts.plaidItemId, plaidItems.id))
    .where(and(eq(accounts.userId, userId), isNull(accounts.deletedAt)));

  return c.json({ accounts: rows });
});

// ── Manual accounts ───────────────────────────────────────────────────────────
const accountTypes = ["depository", "credit", "loan", "investment", "other"] as const;

router.post(
  "/manual",
  requireAuth,
  zValidator(
    "json",
    z.object({
      name: z.string().min(1).max(80),
      type: z.enum(accountTypes),
      subtype: z.string().max(40).optional(),
      balance: z.number().min(0),
      institution_name: z.string().max(80).optional(),
    })
  ),
  async (c) => {
    const { userId } = c.get("auth");
    const body = c.req.valid("json");

    const [created] = await db
      .insert(accounts)
      .values({
        userId,
        name: body.name,
        type: body.type,
        subtype: body.subtype ?? null,
        balanceCurrent: body.balance.toFixed(2),
        officialName: body.institution_name ?? null,
      })
      .returning({ id: accounts.id });

    await takeNetWorthSnapshot(userId);
    return c.json({ account: await loadAccount(userId, created.id) }, 201);
  }
);

router.patch(
  "/:id",
  requireAuth,
  zValidator(
    "json",
    z.object({
      name: z.string().min(1).max(80).optional(),
      balance: z.number().min(0).optional(),
      institution_name: z.string().max(80).optional(),
    })
  ),
  async (c) => {
    const { userId } = c.get("auth");
    const id = c.req.param("id");
    const body = c.req.valid("json");

    const [acct] = await db
      .select({ plaidItemId: accounts.plaidItemId })
      .from(accounts)
      .where(and(eq(accounts.id, id), eq(accounts.userId, userId), isNull(accounts.deletedAt)));
    if (!acct) return c.json({ error: "Not found" }, 404);
    // Connected accounts keep their balance from the bank, but can be renamed.
    if (acct.plaidItemId && (body.balance !== undefined || body.institution_name !== undefined)) {
      return c.json({ error: "Connected accounts update automatically" }, 400);
    }

    const set: Record<string, unknown> = { updatedAt: new Date() };
    if (body.name !== undefined) set.name = body.name;
    if (body.balance !== undefined) set.balanceCurrent = body.balance.toFixed(2);
    if (body.institution_name !== undefined) set.officialName = body.institution_name;

    await db
      .update(accounts)
      .set(set)
      .where(and(eq(accounts.id, id), eq(accounts.userId, userId)));

    await takeNetWorthSnapshot(userId);
    return c.json({ account: await loadAccount(userId, id) });
  }
);

router.delete("/:id", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  const id = c.req.param("id");

  const [acct] = await db
    .select({ plaidItemId: accounts.plaidItemId })
    .from(accounts)
    .where(and(eq(accounts.id, id), eq(accounts.userId, userId), isNull(accounts.deletedAt)));
  if (!acct) return c.json({ error: "Not found" }, 404);
  if (acct.plaidItemId) return c.json({ error: "Connected accounts update automatically" }, 400);

  await db
    .update(accounts)
    .set({ deletedAt: new Date(), updatedAt: new Date() })
    .where(and(eq(accounts.id, id), eq(accounts.userId, userId)));

  await takeNetWorthSnapshot(userId);
  return c.json({ ok: true });
});

// ── Hide / unhide account ─────────────────────────────────────────────────────
router.patch(
  "/:id/hidden",
  requireAuth,
  zValidator("json", z.object({ hidden: z.boolean() })),
  async (c) => {
    const { userId } = c.get("auth");
    const accountId = c.req.param("id");
    const { hidden } = c.req.valid("json");

    const [updated] = await db
      .update(accounts)
      .set({ isHidden: hidden, updatedAt: new Date() })
      .where(and(eq(accounts.id, accountId), eq(accounts.userId, userId)))
      .returning({ id: accounts.id });

    if (!updated) return c.json({ error: "Not found" }, 404);
    await takeNetWorthSnapshot(userId);
    return c.json({ ok: true });
  }
);

// ── Net worth history ─────────────────────────────────────────────────────────
router.get(
  "/net-worth/history",
  requireAuth,
  zValidator("query", z.object({ days: z.coerce.number().int().min(7).max(1095).default(90) })),
  async (c) => {
    const { userId } = c.get("auth");
    const { days } = c.req.valid("query");

    const since = new Date();
    since.setDate(since.getDate() - days);
    const sinceDate = since.toISOString().slice(0, 10);

    const rows = await db
      .select({
        date: netWorthSnapshots.date,
        netWorth: netWorthSnapshots.netWorth,
        totalAssets: netWorthSnapshots.totalAssets,
        totalLiabilities: netWorthSnapshots.totalLiabilities,
        invested: netWorthSnapshots.invested,
      })
      .from(netWorthSnapshots)
      .where(and(eq(netWorthSnapshots.userId, userId), gte(netWorthSnapshots.date, sinceDate)))
      .orderBy(desc(netWorthSnapshots.date))
      .limit(days);

    return c.json({ snapshots: rows });
  }
);

export { router as accountsRouter };
