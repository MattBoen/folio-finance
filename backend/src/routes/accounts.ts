import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import { eq, and, isNull, gte, desc } from "drizzle-orm";
import { db } from "../db/client.js";
import { accounts, plaidItems, netWorthSnapshots } from "../db/schema.js";
import { requireAuth } from "../middleware/auth.js";

const router = new Hono();

// ── List accounts ─────────────────────────────────────────────────────────────
router.get("/", requireAuth, async (c) => {
  const { userId } = c.get("auth");

  const rows = await db
    .select({
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
      institutionName: plaidItems.institutionName,
    })
    .from(accounts)
    .leftJoin(plaidItems, eq(accounts.plaidItemId, plaidItems.id))
    .where(and(eq(accounts.userId, userId), isNull(accounts.deletedAt)));

  return c.json({ accounts: rows });
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
    return c.json({ ok: true });
  }
);

// ── Net worth history ─────────────────────────────────────────────────────────
router.get(
  "/net-worth/history",
  requireAuth,
  zValidator("query", z.object({ days: z.coerce.number().int().min(7).max(365).default(90) })),
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
      })
      .from(netWorthSnapshots)
      .where(and(eq(netWorthSnapshots.userId, userId), gte(netWorthSnapshots.date, sinceDate)))
      .orderBy(desc(netWorthSnapshots.date))
      .limit(days);

    return c.json({ snapshots: rows });
  }
);

export { router as accountsRouter };
