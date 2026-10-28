// Subscriptions through Stripe web checkout. Stripe is the source of truth; webhooks keep our table in step.
import Stripe from "stripe";
import { eq } from "drizzle-orm";
import { db } from "../db/client.js";
import { subscriptions, users } from "../db/schema.js";

export const PRICES = { month: 10.49, year: 74.99 } as const;

/** Billing only locks the app once this is switched on, so beta users keep working until launch. */
export function billingEnforced(): boolean {
  return process.env.BILLING_ENFORCED === "true";
}

export function trialDays(): number {
  const n = Number(process.env.BILLING_TRIAL_DAYS ?? 7);
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : 7;
}

export function stripeClient(): Stripe | null {
  const key = process.env.STRIPE_SECRET_KEY;
  return key ? new Stripe(key) : null;
}

export function priceIdFor(interval: "month" | "year"): string | undefined {
  return interval === "month" ? process.env.STRIPE_PRICE_MONTHLY : process.env.STRIPE_PRICE_YEARLY;
}

export const ACTIVE_STATUSES = new Set(["trialing", "active", "past_due"]);

export interface BillingStatus {
  enforced: boolean;
  configured: boolean;
  entitled: boolean;
  status: string;
  interval: string | null;
  currentPeriodEnd: string | null;
  trialEnd: string | null;
  cancelAtPeriodEnd: boolean;
  trialDays: number;
  monthlyPrice: number;
  yearlyPrice: number;
}

export async function billingStatus(userId: string): Promise<BillingStatus> {
  const [u] = await db.select({ plan: users.plan }).from(users).where(eq(users.id, userId));
  const [s] = await db.select().from(subscriptions).where(eq(subscriptions.userId, userId));
  const subscribed = !!s && ACTIVE_STATUSES.has(s.status);
  const comped = u?.plan === "pro";
  return {
    enforced: billingEnforced(),
    configured: !!process.env.STRIPE_SECRET_KEY && !!process.env.STRIPE_PRICE_MONTHLY && !!process.env.STRIPE_PRICE_YEARLY,
    entitled: !billingEnforced() || subscribed || comped,
    status: s?.status ?? (comped ? "active" : "none"),
    interval: s?.interval ?? null,
    currentPeriodEnd: s?.currentPeriodEnd?.toISOString() ?? null,
    trialEnd: s?.trialEnd?.toISOString() ?? null,
    cancelAtPeriodEnd: s?.cancelAtPeriodEnd ?? false,
    trialDays: trialDays(),
    monthlyPrice: PRICES.month,
    yearlyPrice: PRICES.year,
  };
}

export async function isEntitled(userId: string): Promise<boolean> {
  if (!billingEnforced()) return true;
  return (await billingStatus(userId)).entitled;
}

const fromUnix = (n: number | null | undefined) => (n ? new Date(n * 1000) : null);

/** Writes a Stripe subscription into our table and keeps users.plan in step. */
export async function recordSubscription(userId: string, customerId: string, sub: Stripe.Subscription): Promise<void> {
  const item = sub.items.data[0];
  const periodEnd = (item as unknown as { current_period_end?: number })?.current_period_end ?? (sub as unknown as { current_period_end?: number }).current_period_end;
  const values = {
    stripeCustomerId: customerId,
    stripeSubscriptionId: sub.id,
    status: sub.status,
    interval: item?.price?.recurring?.interval ?? null,
    currentPeriodEnd: fromUnix(periodEnd),
    trialEnd: fromUnix(sub.trial_end),
    cancelAtPeriodEnd: sub.cancel_at_period_end,
    updatedAt: new Date(),
  };
  await db.insert(subscriptions).values({ userId, ...values }).onConflictDoUpdate({ target: subscriptions.userId, set: values });
  await db.update(users).set({ plan: ACTIVE_STATUSES.has(sub.status) ? "pro" : "free" }).where(eq(users.id, userId));
}

export async function userIdForCustomer(customerId: string): Promise<string | null> {
  const [s] = await db.select({ userId: subscriptions.userId }).from(subscriptions).where(eq(subscriptions.stripeCustomerId, customerId));
  return s?.userId ?? null;
}
