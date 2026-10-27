import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import { eq } from "drizzle-orm";
import { db } from "../db/client.js";
import { userSettings } from "../db/schema.js";
import { requireAuth } from "../middleware/auth.js";

const router = new Hono();

async function current(userId: string) {
  const [s] = await db.select().from(userSettings).where(eq(userSettings.userId, userId));
  return {
    incomeOverride: s?.incomeOverride != null ? parseFloat(s.incomeOverride) : null,
    birthYear: s?.birthYear ?? null,
  };
}

router.get("/", requireAuth, async (c) => c.json(await current(c.get("auth").userId)));

// The iOS client omits null keys, so a missing/null "monthly" means "go back to detected income".
router.put(
  "/income",
  requireAuth,
  zValidator("json", z.object({ monthly: z.number().min(0).max(100_000_000).nullable().optional() })),
  async (c) => {
    const { userId } = c.get("auth");
    const { monthly } = c.req.valid("json");
    const value = monthly == null ? null : monthly.toFixed(2);
    await db
      .insert(userSettings)
      .values({ userId, incomeOverride: value })
      .onConflictDoUpdate({ target: userSettings.userId, set: { incomeOverride: value, updatedAt: new Date() } });
    return c.json(await current(userId));
  }
);

router.put(
  "/profile",
  requireAuth,
  zValidator("json", z.object({ birth_year: z.number().int().min(1900).max(new Date().getFullYear()).nullable().optional() })),
  async (c) => {
    const { userId } = c.get("auth");
    const birthYear = c.req.valid("json").birth_year ?? null;
    await db
      .insert(userSettings)
      .values({ userId, birthYear })
      .onConflictDoUpdate({ target: userSettings.userId, set: { birthYear, updatedAt: new Date() } });
    return c.json(await current(userId));
  }
);

export { router as settingsRouter };
