// Keeps car values moving: a car with a known yearly mileage is re-estimated as the odometer climbs.
import { and, eq, isNull, lt } from "drizzle-orm";
import { db } from "../db/client.js";
import { accounts, vehicles } from "../db/schema.js";
import { estimateManual, projectedMiles } from "./vehicles.js";

const STALE_DAYS = 30;

/** Re-estimates this customer's cars whose value came from an estimate (not typed in) and has gone stale. Returns true if any changed. */
export async function refreshVehicleValues(userId: string, now: Date = new Date()): Promise<boolean> {
  const cutoff = new Date(now.getTime() - STALE_DAYS * 86_400_000);
  const rows = await db
    .select({
      id: vehicles.id, accountId: vehicles.accountId, year: vehicles.year, make: vehicles.make, model: vehicles.model,
      trim: vehicles.trim, miles: vehicles.miles, annualMiles: vehicles.annualMiles, valuedAt: vehicles.valuedAt, source: vehicles.valuationSource,
    })
    .from(vehicles)
    .innerJoin(accounts, eq(vehicles.accountId, accounts.id))
    .where(and(eq(vehicles.userId, userId), isNull(accounts.deletedAt), lt(vehicles.valuedAt, cutoff)));

  let changed = false;
  for (const v of rows) {
    if (!v.annualMiles || v.source === "manual") continue;
    const miles = projectedMiles(v.miles, v.annualMiles, v.valuedAt, now);
    const est = estimateManual({ year: v.year, make: v.make, model: v.model, trim: v.trim, miles }, now);
    await db.update(vehicles).set({ miles, valuedAt: now }).where(eq(vehicles.id, v.id));
    await db.update(accounts).set({ balanceCurrent: est.estimatedValue.toFixed(2), updatedAt: now }).where(eq(accounts.id, v.accountId));
    changed = true;
  }
  return changed;
}
