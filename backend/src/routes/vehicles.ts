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
import {
  ageYears, annualMiles, decodeVin, estimateManual, isValidVinFormat, lookupTrims, marketCheckValue, normalizeVin, valueVehicle,
} from "../services/vehicles.js";

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
    // Fall back to the curated list when the decoder couldn't name the trims.
    const trims = decoded.trims.length ? decoded.trims : lookupTrims(decoded.make, decoded.model);
    return c.json({
      vin, year: decoded.year, make: decoded.make, model: decoded.model, trim: decoded.trim, trims, details: decoded.details, miles,
      annualMiles: value.annualMiles, ageYears: value.ageYears,
      estimatedValue: value.estimatedValue, lowValue: value.lowValue, highValue: value.highValue, source: value.source,
    });
  }
);

// Re-estimate without a VIN: after the customer picks a trim, or for a car entered by hand.
router.post(
  "/estimate",
  requireAuth,
  rateLimit({ max: 40, windowMs: 60_000 }),
  zValidator(
    "json",
    z.object({
      year: z.number().int().min(1950).max(new Date().getFullYear() + 2),
      make: z.string().min(1).max(60),
      model: z.string().min(1).max(80),
      trim: z.string().max(80).nullish(),
      miles: z.number().int().min(0).max(2_000_000),
      vin: z.string().min(11).max(30).optional(),
    })
  ),
  async (c) => {
    const b = c.req.valid("json");
    const now = new Date();
    if (b.vin && process.env.MARKETCHECK_API_KEY) {
      const vin = normalizeVin(b.vin);
      if (isValidVinFormat(vin)) {
        const price = await marketCheckValue(vin, b.miles, process.env.MARKETCHECK_API_KEY);
        if (price) {
          const round = (n: number) => Math.round(n / 10) * 10;
          const age = ageYears(b.year, now);
          return c.json({
            estimatedValue: round(price), lowValue: round(price * 0.93), highValue: round(price * 1.07), source: "MarketCheck",
            annualMiles: annualMiles(b.miles, age), ageYears: Math.round(age * 10) / 10,
          });
        }
      }
    }
    return c.json(estimateManual({ year: b.year, make: b.make, model: b.model, trim: b.trim, miles: b.miles }, now));
  }
);

router.get(
  "/trims",
  requireAuth,
  rateLimit({ max: 60, windowMs: 60_000 }),
  zValidator("query", z.object({ year: z.coerce.number().int().optional(), make: z.string().max(60), model: z.string().max(80) })),
  (c) => {
    const { make, model } = c.req.valid("query");
    return c.json({ trims: lookupTrims(make, model) });
  }
);

router.post(
  "/",
  requireAuth,
  zValidator(
    "json",
    z.object({
      vin: z.string().min(11).max(30).optional(),
      year: z.number().int().min(1950).max(new Date().getFullYear() + 2),
      make: z.string().min(1).max(60),
      model: z.string().min(1).max(80),
      trim: z.string().max(80).nullish(),
      miles: z.number().int().min(0).max(2_000_000),
      value: z.number().min(0).max(100_000_000),
      nickname: z.string().max(80).optional(),
    })
  ),
  async (c) => {
    const { userId } = c.get("auth");
    const b = c.req.valid("json");
    const [acct] = await db
      .insert(accounts)
      .values({
        userId,
        name: b.nickname?.trim() || [b.year, b.make, b.model, b.trim?.trim()].filter(Boolean).join(" "),
        type: "other",
        subtype: "vehicle",
        balanceCurrent: b.value.toFixed(2),
        officialName: "Vehicle value estimate",
      })
      .returning({ id: accounts.id });
    await db.insert(vehicles).values({
      userId, accountId: acct.id, vin: b.vin ? normalizeVin(b.vin) : "", year: b.year, make: b.make, model: b.model,
      trim: b.trim?.trim() || null, miles: b.miles,
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
    z.object({ miles: z.number().int().min(0).max(2_000_000), value: z.number().min(0).max(100_000_000), trim: z.string().max(80).nullish() })
  ),
  async (c) => {
    const { userId } = c.get("auth");
    const accountId = c.req.param("accountId");
    const { miles, value, trim } = c.req.valid("json");

    const [v] = await db
      .select({ id: vehicles.id, year: vehicles.year, make: vehicles.make, model: vehicles.model, nameTrim: vehicles.trim })
      .from(vehicles)
      .innerJoin(accounts, eq(vehicles.accountId, accounts.id))
      .where(and(eq(vehicles.accountId, accountId), eq(vehicles.userId, userId), isNull(accounts.deletedAt)));
    if (!v) return c.json({ error: "Not found" }, 404);

    const newTrim = trim === undefined ? v.nameTrim : trim?.trim() || null;
    await db.update(vehicles).set({ miles, trim: newTrim, valuedAt: new Date() }).where(and(eq(vehicles.id, v.id), eq(vehicles.userId, userId)));
    await db
      .update(accounts)
      .set({
        balanceCurrent: value.toFixed(2),
        ...(trim !== undefined ? { name: [v.year, v.make, v.model, newTrim].filter(Boolean).join(" ") } : {}),
        updatedAt: new Date(),
      })
      .where(and(eq(accounts.id, accountId), eq(accounts.userId, userId)));
    await takeNetWorthSnapshot(userId);
    return c.json({ account: await loadAccount(userId, accountId) });
  }
);

export { router as vehiclesRouter };
