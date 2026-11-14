import { Hono } from "hono";
import { requireAuth } from "../middleware/auth.js";
import { computeInsightsForUser, loadInsightInputs, todayIso } from "../services/insight-data.js";
import { detectRecurringBills } from "../services/recurring.js";
import { currentHoldings } from "../services/investment-history.js";
import { summarizeHoldings } from "../services/holdings.js";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import { getCreditUse, saveCreditLimits } from "../services/credit-use.js";
import { BASES, getEmergencyFund, getSavingsRate, saveEmergencyFund, saveSavingsRate } from "../services/emergency-fund.js";

const router = new Hono();

router.get("/", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  const insights = await computeInsightsForUser(userId);
  // The emergency fund tile uses the same accounts and yardstick as its own screen (your choices, then Folio's).
  const ef = await getEmergencyFund(userId).catch(() => null);
  if (ef) {
    insights.health.emergencyFundMonths = ef.months;
    insights.health.inputs.liquid = ef.total;
    insights.health.inputs.cashAccounts = ef.accounts.filter((a) => a.included).map((a) => ({ name: a.name, balance: a.balance, kind: a.kind === "savings" ? "savings" : "cash" }));
  }
  // Savings rate uses the same spending yardstick as its own screen (the emergency fund's, unless you changed it).
  const sr = await getSavingsRate(userId).catch(() => null);
  if (sr) insights.health.savingsRate = sr.rate;
  // Credit use counts limits you typed in, too.
  const cu = await getCreditUse(userId).catch(() => null);
  if (cu) {
    insights.health.creditUtilization = cu.rate;
    insights.health.inputs.cards = cu.cards.map((c) => ({ name: c.name, balance: c.balance, limit: c.limit }));
  }
  return c.json(insights);
});

// Which accounts make up your emergency fund and how many months it covers. Folio sorts them; you correct it.
router.get("/emergency-fund", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  return c.json(await getEmergencyFund(userId));
});

router.put(
  "/emergency-fund",
  requireAuth,
  zValidator("json", z.object({
    included: z.record(z.string().uuid(), z.boolean()).optional(),
    basis: z.enum(BASES as [string, ...string[]]).optional(),
    reset: z.boolean().optional(),
  })),
  async (c) => {
    const { userId } = c.get("auth");
    const body = c.req.valid("json") as Parameters<typeof saveEmergencyFund>[1];
    return c.json(await saveEmergencyFund(userId, body));
  }
);

// Bills and subscriptions found in the last year of transactions, and what is due next.
router.get("/recurring", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  const now = todayIso();
  const { txns } = await loadInsightInputs(userId, now, 400);
  return c.json(detectRecurringBills(txns, now));
});

// What you actually own in your investment accounts, what it is worth and how it has done since you bought it.
router.get("/holdings", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  return c.json(summarizeHoldings(await currentHoldings(userId)));
});

// Savings rate: income, the spending it's measured against, and what's left. Spending follows the emergency fund unless changed.
router.get("/savings-rate", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  return c.json(await getSavingsRate(userId));
});

router.put(
  "/savings-rate",
  requireAuth,
  zValidator("json", z.object({ basis: z.enum(["essentials", "usual", "budget", "match"]) })),
  async (c) => {
    const { userId } = c.get("auth");
    return c.json(await saveSavingsRate(userId, c.req.valid("json").basis as Parameters<typeof saveSavingsRate>[1]));
  }
);

// Credit use: each card's balance and limit (the bank's, or one you entered), and the total.
router.get("/credit-use", requireAuth, async (c) => {
  const { userId } = c.get("auth");
  return c.json(await getCreditUse(userId));
});

router.put(
  "/credit-use",
  requireAuth,
  zValidator("json", z.object({ limits: z.record(z.string().uuid(), z.union([z.number().min(0).max(10_000_000), z.literal("none")]).nullable()) })),
  async (c) => {
    const { userId } = c.get("auth");
    return c.json(await saveCreditLimits(userId, c.req.valid("json").limits));
  }
);

export { router as insightsRouter };
