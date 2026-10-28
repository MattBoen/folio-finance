import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import { eq } from "drizzle-orm";
import type Stripe from "stripe";
import { db } from "../db/client.js";
import { subscriptions, users } from "../db/schema.js";
import { requireAuth } from "../middleware/auth.js";
import { rateLimit } from "../middleware/rate-limit.js";
import { billingStatus, priceIdFor, recordSubscription, stripeClient, trialDays, userIdForCustomer } from "../services/billing.js";

const router = new Hono();

const appUrl = () => (process.env.APP_URL ?? "https://folio-finance-api.onrender.com").replace(/\/$/, "");

router.get("/status", requireAuth, async (c) => c.json(await billingStatus(c.get("auth").userId)));

router.post(
  "/checkout",
  requireAuth,
  rateLimit({ max: 10, windowMs: 60_000 }),
  zValidator("json", z.object({ interval: z.enum(["month", "year"]) })),
  async (c) => {
    const { userId } = c.get("auth");
    const { interval } = c.req.valid("json");
    const stripe = stripeClient();
    const price = priceIdFor(interval);
    if (!stripe || !price) return c.json({ error: "Subscriptions aren't open yet." }, 503);

    const [u] = await db.select({ email: users.email }).from(users).where(eq(users.id, userId));
    const [existing] = await db.select().from(subscriptions).where(eq(subscriptions.userId, userId));
    let customerId = existing?.stripeCustomerId;
    if (!customerId) {
      const customer = await stripe.customers.create({ email: u?.email ?? undefined, metadata: { userId } });
      customerId = customer.id;
      await db.insert(subscriptions).values({ userId, stripeCustomerId: customerId }).onConflictDoNothing();
    }
    // One free trial per customer: anyone who has had a subscription before pays from day one.
    const days = trialDays();
    const firstTime = !existing?.stripeSubscriptionId;
    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      customer: customerId,
      client_reference_id: userId,
      line_items: [{ price, quantity: 1 }],
      allow_promotion_codes: true,
      subscription_data: { metadata: { userId }, ...(firstTime && days > 0 ? { trial_period_days: days } : {}) },
      success_url: `${appUrl()}/billing/success`,
      cancel_url: `${appUrl()}/billing/cancel`,
    });
    return c.json({ url: session.url });
  }
);

router.post("/portal", requireAuth, rateLimit({ max: 10, windowMs: 60_000 }), async (c) => {
  const { userId } = c.get("auth");
  const stripe = stripeClient();
  const [s] = await db.select().from(subscriptions).where(eq(subscriptions.userId, userId));
  if (!stripe || !s?.stripeSubscriptionId) return c.json({ error: "No subscription to manage yet." }, 404);
  const session = await stripe.billingPortal.sessions.create({ customer: s.stripeCustomerId, return_url: `${appUrl()}/billing/success` });
  return c.json({ url: session.url });
});

// Stripe calls this when anything about a subscription changes. The signature proves it really came from Stripe.
router.post("/webhook", async (c) => {
  const stripe = stripeClient();
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!stripe || !secret) return c.json({ error: "Not configured" }, 503);
  const signature = c.req.header("stripe-signature");
  if (!signature) return c.json({ error: "Missing signature" }, 400);

  let event: Stripe.Event;
  try {
    event = stripe.webhooks.constructEvent(await c.req.text(), signature, secret);
  } catch {
    return c.json({ error: "Bad signature" }, 400);
  }

  try {
    if (event.type === "checkout.session.completed") {
      const session = event.data.object as Stripe.Checkout.Session;
      const subId = typeof session.subscription === "string" ? session.subscription : session.subscription?.id;
      const customerId = typeof session.customer === "string" ? session.customer : session.customer?.id;
      const userId = session.client_reference_id ?? (customerId ? await userIdForCustomer(customerId) : null);
      if (subId && customerId && userId) await recordSubscription(userId, customerId, await stripe.subscriptions.retrieve(subId));
    } else if (event.type === "customer.subscription.created" || event.type === "customer.subscription.updated" || event.type === "customer.subscription.deleted") {
      const sub = event.data.object as Stripe.Subscription;
      const customerId = typeof sub.customer === "string" ? sub.customer : sub.customer.id;
      const userId = sub.metadata?.userId || (await userIdForCustomer(customerId));
      if (userId) await recordSubscription(userId, customerId, sub);
    }
  } catch (e) {
    console.error(`[billing] webhook ${event.type} failed: ${(e as Error).message}`);
    return c.json({ error: "Failed" }, 500); // Stripe retries
  }
  return c.json({ received: true });
});

const page = (title: string, body: string) =>
  `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title>` +
  `<style>body{font-family:-apple-system,system-ui,sans-serif;background:#f2f2f7;color:#111;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0;padding:24px;text-align:center}` +
  `main{max-width:420px}h1{font-size:28px;margin:0 0 12px}p{font-size:17px;line-height:1.4;color:#444}</style></head><body><main><h1>${title}</h1><p>${body}</p></main></body></html>`;

router.get("/success", (c) => c.html(page("You're all set", "Your subscription is active. Switch back to the Folio app and you can start.")));
router.get("/cancel", (c) => c.html(page("No charge made", "You can close this page and go back to Folio whenever you're ready.")));

export { router as billingRouter };
