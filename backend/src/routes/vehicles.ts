import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import { and, eq, isNull } from "drizzle-orm";
import { db } from "../db/client.js";
import { accounts, vehicles } from "../db/schema.js";
import { requireAuth } from "../middleware/auth.js";
import { rateLimit } from "../middleware/rate-limit.js";
import { takeNetWorthSnapshot } from "../services/plaid-sync.js";
import { loadAccount } from "./accounts.js";
import { decodeVin, isValidVinFormat, normalizeVin, valueVehicle } from "../services/vehicles.js";

const router = new Hono();

// Never log VINs or request bodies from this router.

router.post(
  "/lookup",
  requireAuth,
  rateLimit({ max: 20, windowMs: 60_000 }),
  zValidator("json", z.object({ vin: z.string().min(11).max(30), miles: z.number().int().min(0).max(2_000_000) })),
  async (c) => {
    const { vin: raw, miles } = c.req.valid("json");
    const vin = normalizeVin(raw);
    if (!isValidVinFormat(vin)) {
      return c.json({ error: "A VIN is 17 letters and numbers (no I, O or Q). Check it and try again." }, 422);
    }
    const decoded = await decodeVin(vin);
    if (!decoded) {
      return c.json({ error: "We couldn't read that VIN. Double-check it and try again." }, 422);
    }
    const value = await valueVehicle(decoded, miles, { MARKETCHECK_API_KEY: process.env.MARKETCHECK_API_KEY });
    return c.json({
      vin, year: decoded.year, make: decoded.make, model: decoded.model, trim: decoded.trim, miles,
      estimatedValue: value.estimatedValue, lowValue: value.lowValue, highValue: value.highValue, source: value.source,
    });
  }
);

router.post(
  "/",
  requireAuth,
  zValidator(
    "json",
    z.object({
      vin: z.string().min(11).max(30),
      year: z.number().int().min(1950).max(new Date().getFullYear() + 2),
      make: z.string().min(1).max(60),
      model: z.string().min(1).max(80),
      trim: z.string().max(80).optional(),
      miles: z.number().int().min(0).max(2_000_000),
      value: z.number().min(0).max(100_000_000),
    })
  ),
  async (c) => {
    const { userId } = c.get("auth");
    const b = c.req.valid("json");
    const [acct] = await db
      .insert(accounts)
      .values({
        userId,
        name: `${b.year} ${b.make} ${b.model}`,
        type: "other",
        subtype: "vehicle",
        balanceCurrent: b.value.toFixed(2),
        officialName: "Vehicle value estimate",
      })
      .returning({ id: accounts.id });
    await db.insert(vehicles).values({
      userId, accountId: acct.id, vin: normalizeVin(b.vin), year: b.year, make: b.make, model: b.model,
      trim: b.trim ?? null, miles: b.miles,
    });
    await takeNetWorthSnapshot(userId);
    return c.json({ account: await loadAccount(userId, acct.id) }, 201);
  }
);

router.patch(
  "/:accountId",
  requireAuth,
  zValidator(
    "json",
    z.object({ miles: z.number().int().min(0).max(2_000_000), value: z.number().min(0).max(100_000_000) })
  ),
  async (c) => {
    const { userId } = c.get("auth");
    const accountId = c.req.param("accountId");
    const { miles, value } = c.req.valid("json");

    const [v] = await db
      .select({ id: vehicles.id })
      .from(vehicles)
      .innerJoin(accounts, eq(vehicles.accountId, accounts.id))
      .where(and(eq(vehicles.accountId, accountId), eq(vehicles.userId, userId), isNull(accounts.deletedAt)));
    if (!v) return c.json({ error: "Not found" }, 404);

    await db.update(vehicles).set({ miles, valuedAt: new Date() }).where(and(eq(vehicles.id, v.id), eq(vehicles.userId, userId)));
    await db
      .update(accounts)
      .set({ balanceCurrent: value.toFixed(2), updatedAt: new Date() })
      .where(and(eq(accounts.id, accountId), eq(accounts.userId, userId)));
    await takeNetWorthSnapshot(userId);
    return c.json({ account: await loadAccount(userId, accountId) });
  }
);

export { router as vehiclesRouter };
