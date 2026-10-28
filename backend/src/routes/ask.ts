import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import { createHmac } from "node:crypto";
import { requireAuth } from "../middleware/auth.js";
import { rateLimit } from "../middleware/rate-limit.js";
import { getAnthropic } from "../services/anthropic.js";
import * as data from "../services/ask-data.js";
import * as store from "../services/ask-store.js";
import { runAsk, type AskClient, type AskData } from "../services/ask-engine.js";

const router = new Hono();

const realData: AskData = {
  overview: data.getOverview,
  accounts: data.getAccountsList,
  budget: data.getBudget,
  spending: data.getSpending,
  income: data.getIncome,
  health: data.getHealth,
  investments: data.getInvestments,
  netWorthWindow: data.getNetWorthWindow,
  currentBudgetAmount: data.getCurrentBudgetAmount,
  createProposal: store.createProposal,
  vehicles: data.getVehicles,
  findTransactions: data.findTransactions,
  describeChanges: data.describeChanges,
};

/** An opaque, stable id for Anthropic's abuse detection. Not reversible without the server's key. */
function userHash(userId: string): string {
  return createHmac("sha256", process.env.ENCRYPTION_KEY ?? "folio").update(userId).digest("hex").slice(0, 32);
}

const body = z.object({
  messages: z.array(z.object({ role: z.enum(["user", "assistant"]), content: z.string().min(1).max(2000) })).min(1).max(100),
});

router.post("/", requireAuth, rateLimit({ max: 10, windowMs: 60_000 }), zValidator("json", body), async (c) => {
  const { userId } = c.get("auth");
  const messages = c.req.valid("json").messages.slice(-10);
  if (messages[messages.length - 1].role !== "user") return c.json({ error: "The last message must be from you." }, 400);
  while (messages.length > 1 && messages[0].role !== "user") messages.shift();

  const settings = await store.getAskSettings(userId);
  if (!settings.enabled) return c.json({ error: "Turn on Ask in Settings first.", code: "ask_disabled" }, 403);

  const client = getAnthropic();
  if (!client) return c.json({ error: "Ask isn't available right now.", code: "ask_unavailable" }, 503);

  if (!(await store.consumeAsk(userId, settings.dailyLimit))) {
    return c.json({ error: `You've reached today's limit of ${settings.dailyLimit} questions. It resets tomorrow.`, code: "ask_limit" }, 429);
  }

  const started = Date.now();
  const hash = userHash(userId);
  try {
    const out = await runAsk({
      client: client as unknown as AskClient,
      model: process.env.ASK_MODEL || "claude-sonnet-5-5",
      userId, userHash: hash, today: data.todayIso(), messages, data: realData,
    });
    // Metadata only: never the question, the answer, or any numbers.
    console.log(`[ask] user=${hash.slice(0, 8)} tools=${out.tools.join(",") || "none"} rounds=${out.rounds} ms=${Date.now() - started}`);
    return c.json({ answer: out.answer, facts: out.facts, proposal: out.proposal });
  } catch (e) {
    await store.refundAsk(userId).catch(() => {});
    console.error(`[ask] user=${hash.slice(0, 8)} failed status=${(e as { status?: number }).status ?? "n/a"} ms=${Date.now() - started}`);
    return c.json({ error: "Ask couldn't answer just now. Please try again.", code: "ask_failed" }, 502);
  }
});

// The iPhone app sends snake_case keys (proposal_id); accept that and the camelCase spelling.
const proposalBody = z
  .object({ proposalId: z.string().uuid().optional(), proposal_id: z.string().uuid().optional() })
  .refine((b) => b.proposalId || b.proposal_id, "proposalId is required")
  .transform((b) => ({ proposalId: (b.proposalId ?? b.proposal_id) as string }));

router.post("/confirm", requireAuth, rateLimit({ max: 20, windowMs: 60_000 }), zValidator("json", proposalBody), async (c) => {
  const { userId } = c.get("auth");
  const r = await store.confirmProposal(userId, c.req.valid("json").proposalId);
  if (!r.ok) return c.json({ error: r.error }, r.status);
  return c.json({ ok: true, message: r.message });
});

router.post("/dismiss", requireAuth, rateLimit({ max: 20, windowMs: 60_000 }), zValidator("json", proposalBody), async (c) => {
  const { userId } = c.get("auth");
  const ok = await store.dismissProposal(userId, c.req.valid("json").proposalId);
  if (!ok) return c.json({ error: "Not found" }, 404);
  return c.json({ ok: true });
});

export { router as askRouter };
