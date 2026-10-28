import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { eq } from "drizzle-orm";
import type Stripe from "stripe";
import { db } from "../src/db/client.js";
import { users } from "../src/db/schema.js";
import { billingStatus, isEntitled, recordSubscription } from "../src/services/billing.js";
import { app } from "../src/index.js";

let uid = "";

beforeAll(async () => {
  [{ id: uid }] = await db.insert(users).values({ email: `bill-${Date.now()}@example.com`, passwordHash: "x" }).returning({ id: users.id });
});
afterAll(async () => {
  delete process.env.BILLING_ENFORCED;
  await db.delete(users).where(eq(users.id, uid));
});

const fakeSub = (status: string): Stripe.Subscription =>
  ({ id: "sub_test", status, cancel_at_period_end: false, trial_end: null, items: { data: [{ price: { recurring: { interval: "month" } }, current_period_end: 1893456000 }] } }) as unknown as Stripe.Subscription;

describe("billing", () => {
  it("lets everyone in while billing isn't switched on", async () => {
    delete process.env.BILLING_ENFORCED;
    expect(await isEntitled(uid)).toBe(true);
  });

  it("locks people without a subscription once it is on, and opens for an active or trialing one", async () => {
    process.env.BILLING_ENFORCED = "true";
    expect((await billingStatus(uid)).entitled).toBe(false);
    await recordSubscription(uid, "cus_test", fakeSub("trialing"));
    const s = await billingStatus(uid);
    expect(s).toMatchObject({ entitled: true, status: "trialing", interval: "month" });
    const [u] = await db.select({ plan: users.plan }).from(users).where(eq(users.id, uid));
    expect(u.plan).toBe("pro");
  });

  it("locks again when the subscription ends", async () => {
    process.env.BILLING_ENFORCED = "true";
    await recordSubscription(uid, "cus_test", fakeSub("canceled"));
    expect((await billingStatus(uid)).entitled).toBe(false);
    const [u] = await db.select({ plan: users.plan }).from(users).where(eq(users.id, uid));
    expect(u.plan).toBe("free");
  });

  it("rejects a webhook with no valid signature", async () => {
    process.env.STRIPE_SECRET_KEY = "sk_test_x";
    process.env.STRIPE_WEBHOOK_SECRET = "whsec_x";
    const res = await app.request("/billing/webhook", { method: "POST", headers: { "stripe-signature": "t=1,v1=bad" }, body: "{}" });
    expect(res.status).toBe(400);
    delete process.env.STRIPE_SECRET_KEY;
    delete process.env.STRIPE_WEBHOOK_SECRET;
  });
});
