import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { Hono } from "hono";
import { runAsk, toolSchemas, TOOLS, type AskData, type AskClient } from "../src/services/ask-engine.js";
import { sp500ReturnBetween } from "../src/services/sp500.js";

// ── Engine ────────────────────────────────────────────────────────────────────

const TODAY = "2026-10-27";

function fakeData(over: Partial<AskData> = {}): AskData {
  return {
    overview: async () => ({ netWorth: 129127, assets: 141611, liabilities: 12484, byGroup: {}, accountCount: 6 }),
    accounts: async () => ({ accounts: [], total: 0 }),
    budget: async () => ({ month: "2026-10", totalLimit: 3000, totalSpent: 1200, left: 1800, categories: [{ category: "Groceries", limit: 800, spent: 610 }] }),
    spending: async (_u, a) => ({ from: a.from, to: a.to, total: 142.3, transactionCount: 3, topMerchants: [{ name: "Whole Foods", total: 142.3, count: 3 }], byCategory: [{ category: "Groceries", total: 142.3 }], filters: { category: null, merchant: a.merchant ?? null } }),
    income: async () => ({ monthlyIncome: 6300, source: "detected", confidence: "high", sources: [], usualMonthlySpending: 3770 }),
    health: async () => ({ savingsRate: 0.4, emergencyFundMonths: 6.2, creditUtilization: 0.12, debtPaymentRatio: null, monthlyIncome: 6300, usualMonthlySpending: 3770, monthsOfData: 4 }),
    investments: async () => ({ totalInvested: 103791, investmentAccounts: [], allocation: [], notes: [], savingsRate: 0.4 }),
    netWorthWindow: async () => ({ startDate: "2023-01-03", endDate: "2023-12-29", start: 100000, end: 118000, snapshots: 200 }),
    currentBudgetAmount: async () => 800,
    createProposal: async () => "11111111-1111-4111-8111-111111111111",
    ...over,
  };
}

/** A fake model that replays scripted responses and records what it was sent. */
function scripted(responses: any[]) {
  const calls: any[] = [];
  const client: AskClient = {
    messages: { create: async (params: any) => { calls.push(JSON.parse(JSON.stringify(params))); const r = responses.shift(); if (r instanceof Error) throw r; return r; } },
  };
  return { client, calls };
}
const toolUse = (id: string, name: string, input: unknown) => ({ stop_reason: "tool_use", content: [{ type: "tool_use", id, name, input }] });
const text = (t: string) => ({ stop_reason: "end_turn", content: [{ type: "text", text: t }] });
const run = (client: AskClient, data = fakeData(), messages = [{ role: "user" as const, content: "How much at Whole Foods this month?" }]) =>
  runAsk({ client, model: "m", userId: "u1", userHash: "hash123", today: TODAY, messages, data });

describe("ask engine", () => {
  it("runs the tool loop and returns the answer with the exact numbers used", async () => {
    const { client, calls } = scripted([toolUse("t1", "get_spending", { merchant: "Whole Foods" }), text("You spent $142.30 at Whole Foods this month.")]);
    const out = await run(client);
    expect(out.answer).toContain("$142.30");
    expect(out.facts).toContainEqual({ label: "Whole Foods this month", value: "$142.30" });
    expect(out.tools).toEqual(["get_spending"]);
    expect(calls).toHaveLength(2);
    // defaults: this month so far
    const toolResult = calls[1].messages.at(-1).content[0];
    expect(toolResult.type).toBe("tool_result");
    expect(JSON.parse(toolResult.content).from).toBe("2026-10-01");
    expect(calls[0].metadata).toEqual({ user_id: "hash123" });
    expect(calls[0].system).toContain("2026-10-27");
  });

  it("rejects bad tool arguments without crashing, and lets the model recover", async () => {
    const { client, calls } = scripted([toolUse("t1", "get_spending", { from: "last tuesday" }), text("Sorry, which dates?")]);
    const out = await run(client);
    const tr = calls[1].messages.at(-1).content[0];
    expect(tr.is_error).toBe(true);
    expect(tr.content).toMatch(/Invalid arguments/);
    expect(out.answer).toBe("Sorry, which dates?");
  });

  it("handles unknown tools and tool failures as errors", async () => {
    const data = fakeData({ overview: async () => { throw new Error("db down"); } });
    const { client, calls } = scripted([
      { stop_reason: "tool_use", content: [{ type: "tool_use", id: "a", name: "delete_everything", input: {} }, { type: "tool_use", id: "b", name: "get_overview", input: {} }] },
      text("I couldn't load that."),
    ]);
    await run(client, data);
    const results = calls[1].messages.at(-1).content;
    expect(results.map((r: any) => r.is_error)).toEqual([true, true]);
  });

  it("creates a budget proposal that is returned to the app and never applies it", async () => {
    const createProposal = vi.fn(async () => "22222222-2222-4222-8222-222222222222");
    const { client } = scripted([toolUse("t1", "propose_budget_change", { category: "groceries", newAmount: 900, reason: "spending more" }), text("I suggest $900. Tap Confirm to apply.")]);
    const out = await run(client, fakeData({ createProposal }));
    expect(createProposal).toHaveBeenCalledWith("u1", expect.objectContaining({ kind: "budget", category: "Groceries", currentAmount: 800, newAmount: 900 }));
    expect(out.proposal).toMatchObject({ id: "22222222-2222-4222-8222-222222222222", kind: "budget", category: "Groceries", currentAmount: 800, newAmount: 900, title: "Change Groceries budget", detail: "From $800 to $900 a month." });
  });

  it("won't propose budgets for income or transfers", async () => {
    const createProposal = vi.fn(async () => "x");
    const { client, calls } = scripted([toolUse("t1", "propose_budget_change", { category: "Income", newAmount: 100 }), text("ok")]);
    const out = await run(client, fakeData({ createProposal }));
    expect(createProposal).not.toHaveBeenCalled();
    expect(out.proposal).toBeNull();
    expect(calls[1].messages.at(-1).content[0].is_error).toBe(true);
  });

  it("validates tool arguments with zod (limits, ranges)", () => {
    const spending = TOOLS.find((t) => t.name === "get_spending")!;
    expect(spending.schema.safeParse({ merchant: "x".repeat(61) }).success).toBe(false);
    expect(spending.schema.safeParse({ from: "2026-02-31x" }).success).toBe(false);
    const propose = TOOLS.find((t) => t.name === "propose_budget_change")!;
    expect(propose.schema.safeParse({ category: "Dining", newAmount: -5 }).success).toBe(false);
    expect(propose.schema.safeParse({ category: "Dining", newAmount: 250 }).success).toBe(true);
  });

  it("proposes a whole budget as one confirmable plan, skipping income and duplicates", async () => {
    let saved: any = null;
    const data = fakeData({ currentBudgetAmount: async (_u, c) => (c === "Groceries" ? 800 : 0), createProposal: async (_u, p) => { saved = p; return "22222222-2222-4222-8222-222222222222"; } });
    const { client } = scripted([
      toolUse("t1", "propose_budget_plan", { items: [{ category: "groceries", amount: 650.4 }, { category: "Dining", amount: 250 }, { category: "Groceries", amount: 999 }, { category: "Income", amount: 6000 }] }),
      text("Here's a budget. Tap Confirm to apply it."),
    ]);
    const out = await run(client, data);
    expect(out.proposal?.kind).toBe("budget_plan");
    expect(saved.items).toEqual([
      { category: "Groceries", currentAmount: 800, newAmount: 650 },
      { category: "Dining", currentAmount: 0, newAmount: 250 },
    ]);
    expect(out.proposal?.newAmount).toBe(900);
    expect(out.proposal?.detail).toContain("Total: $900");
  });

  it("publishes JSON-schema tools the API accepts", () => {
    const schemas = toolSchemas();
    expect(schemas.map((s) => s.name)).toEqual(["get_overview", "get_accounts", "get_budget", "get_spending", "get_income", "get_health_metrics", "get_investments", "compare_to_sp500", "propose_budget_change", "propose_budget_plan"]);
    for (const s of schemas) { expect(s.input_schema.type).toBe("object"); expect(s.description.length).toBeGreaterThan(10); }
    expect(schemas.find((s) => s.name === "propose_budget_change")!.input_schema).toMatchObject({ required: ["category", "newAmount"] });
  });

  it("compare_to_sp500 always carries the caveat, and says unavailable for recent windows", async () => {
    const past = scripted([toolUse("t1", "compare_to_sp500", { year: 2023 }), text("done")]);
    await run(past.client);
    const r1 = JSON.parse(past.calls[1].messages.at(-1).content[0].content);
    expect(r1.sp500TotalReturnPct).toBeCloseTo(26.29, 1);
    expect(r1.yourNetWorthChangePct).toBe(18);
    expect(r1.caveat).toMatch(/rough comparison/i);

    const recent = scripted([toolUse("t1", "compare_to_sp500", { months: 6 }), text("done")]);
    await run(recent.client);
    const r2 = JSON.parse(recent.calls[1].messages.at(-1).content[0].content);
    expect(r2.sp500TotalReturnPct).toBeNull();
    expect(r2.sp500Note).toMatch(/only covers 2019-2024/);
    expect(r2.caveat).toMatch(/rough comparison/i);
  });

  it("falls back after too many tool rounds", async () => {
    const { client, calls } = scripted(Array.from({ length: 6 }, (_, i) => toolUse(`t${i}`, "get_overview", {})));
    const out = await run(client);
    expect(calls).toHaveLength(6);
    expect(out.answer).toMatch(/simpler question/);
  });

  it("retries once without temperature if the model rejects it", async () => {
    const err: any = Object.assign(new Error("temperature is not supported for this model"), { status: 400 });
    const { client, calls } = scripted([err, text("ok")]);
    const out = await run(client);
    expect(out.answer).toBe("ok");
    expect(calls[0].temperature).toBe(0.2);
    expect(calls[1].temperature).toBeUndefined();
  });
});

describe("sp500ReturnBetween", () => {
  it("returns calendar-year totals and compounds across years", () => {
    expect(sp500ReturnBetween("2023-01-01", "2023-12-31")).toBeCloseTo(26.29, 1);
    expect(sp500ReturnBetween("2022-01-01", "2022-12-31")).toBeCloseTo(-18.11, 1);
    expect(sp500ReturnBetween("2023-01-01", "2024-12-31")).toBeCloseTo((1.2629 * 1.2502 - 1) * 100, 0);
    // half a year is roughly the square root of the year's growth
    expect(sp500ReturnBetween("2023-01-01", "2023-07-02")).toBeCloseTo((Math.sqrt(1.2629) - 1) * 100, 0);
  });
  it("is null when any part of the window lacks data", () => {
    expect(sp500ReturnBetween("2024-06-01", "2025-06-01")).toBeNull();
    expect(sp500ReturnBetween("2026-01-01", "2026-10-01")).toBeNull();
    expect(sp500ReturnBetween("2023-05-02", "2023-05-01")).toBeNull();
  });
});

// ── Routes ────────────────────────────────────────────────────────────────────

const state = {
  settings: { enabled: true, dailyLimit: 30, usedToday: 0 },
  consume: true,
  client: null as AskClient | null,
};
const store = {
  getAskSettings: vi.fn(async () => state.settings),
  setAskEnabled: vi.fn(async (_u: string, enabled: boolean) => ({ ...state.settings, enabled })),
  consumeAsk: vi.fn(async () => state.consume),
  refundAsk: vi.fn(async () => {}),
  createProposal: vi.fn(async () => "p1"),
  confirmProposal: vi.fn(async (userId: string, id: string) =>
    userId === "u1" && id === "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" ? { ok: true, message: "Groceries budget set to $900." } : { ok: false, status: 404, error: "Not found" }),
  dismissProposal: vi.fn(async (userId: string, id: string) => userId === "u1" && id === "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
};
let authUser = "u1";

vi.mock("../src/middleware/auth.js", () => ({
  requireAuth: async (c: any, next: any) => { c.set("auth", { userId: authUser, plan: "free" }); await next(); },
}));
vi.mock("../src/middleware/rate-limit.js", () => ({ rateLimit: () => async (_c: any, next: any) => { await next(); } }));
vi.mock("../src/services/ask-store.js", () => store);
vi.mock("../src/services/anthropic.js", () => ({ getAnthropic: () => state.client, askConfigured: () => !!state.client }));
vi.mock("../src/services/ask-data.js", () => ({
  todayIso: () => TODAY,
  getOverview: async () => ({ netWorth: 129127, assets: 141611, liabilities: 12484, byGroup: {}, accountCount: 6 }),
  getAccountsList: async () => ({ accounts: [], total: 0 }), getBudget: async () => ({ month: "2026-10", totalLimit: 0, totalSpent: 0, left: 0, categories: [] }),
  getSpending: async (_u: string, a: any) => ({ from: a.from, to: a.to, total: 142.3, transactionCount: 3, topMerchants: [], byCategory: [], filters: { category: null, merchant: null } }),
  getIncome: async () => ({}), getHealth: async () => ({}), getInvestments: async () => ({}), getNetWorthWindow: async () => null, getCurrentBudgetAmount: async () => 0,
}));
vi.mock("../src/db/client.js", () => ({ db: {} }));

const { askRouter } = await import("../src/routes/ask.js");
const { settingsRouter } = await import("../src/routes/settings.js");
const app = new Hono().route("/ask", askRouter).route("/settings", settingsRouter);
const post = (path: string, body: unknown) => app.request(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
const ask = (messages: any[]) => post("/ask", { messages });
const SECRET_QUESTION = "How much did I spend at Whole Foods this month, my SSN is 123-45-6789?";

beforeEach(() => {
  state.settings = { enabled: true, dailyLimit: 30, usedToday: 0 };
  state.consume = true;
  state.client = scripted([text("You spent $142.30.")]).client;
  authUser = "u1";
  Object.values(store).forEach((m) => m.mockClear());
});

describe("POST /ask gating", () => {
  it("is off by default: 403 ask_disabled until the user opts in", async () => {
    state.settings.enabled = false;
    const res = await ask([{ role: "user", content: "hi" }]);
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: "Turn on Ask in Settings first.", code: "ask_disabled" });
    expect(store.consumeAsk).not.toHaveBeenCalled();
  });

  it("503 ask_unavailable without an API key, and doesn't use up a question", async () => {
    state.client = null;
    const res = await ask([{ role: "user", content: "hi" }]);
    expect(res.status).toBe(503);
    expect((await res.json()).code).toBe("ask_unavailable");
    expect(store.consumeAsk).not.toHaveBeenCalled();
  });

  it("429 ask_limit once the daily cap is reached", async () => {
    state.consume = false;
    const res = await ask([{ role: "user", content: "hi" }]);
    expect(res.status).toBe(429);
    const j = await res.json();
    expect(j.code).toBe("ask_limit");
    expect(j.error).toMatch(/limit of 30/);
  });

  it("requires the last message to be from the user, and valid message shapes", async () => {
    expect((await ask([{ role: "user", content: "a" }, { role: "assistant", content: "b" }])).status).toBe(400);
    expect((await ask([])).status).toBe(400);
    expect((await ask([{ role: "user", content: "x".repeat(2001) }])).status).toBe(400);
    expect((await ask([{ role: "system", content: "x" }])).status).toBe(400);
  });

  it("answers with {answer, facts, proposal} and keeps only the last 10 messages", async () => {
    const s = scripted([toolUse("t1", "get_spending", { merchant: "Whole Foods" }), text("You spent $142.30 at Whole Foods this month.")]);
    state.client = s.client;
    const history = Array.from({ length: 14 }, (_, i) => ({ role: i % 2 === 0 ? "user" : "assistant", content: `m${i}` }));
    history.push({ role: "user", content: "How much at Whole Foods?" });
    const res = await ask(history);
    expect(res.status).toBe(200);
    const j = await res.json();
    expect(j.answer).toContain("$142.30");
    expect(j.facts).toContainEqual({ label: "Whole Foods this month", value: "$142.30" });
    expect(j.proposal).toBeNull();
    expect(s.calls[0].messages.length).toBeLessThanOrEqual(10);
    expect(s.calls[0].messages[0].role).toBe("user");
    expect(s.calls[0].messages.at(-1).content).toBe("How much at Whole Foods?");
    expect(JSON.stringify(s.calls[0])).not.toMatch(/@|u1/); // no email or user id leaves the server
  });

  it("returns 502 and refunds the question when the model call fails", async () => {
    state.client = scripted([Object.assign(new Error("overloaded"), { status: 529 })]).client;
    const res = await ask([{ role: "user", content: "hi" }]);
    expect(res.status).toBe(502);
    expect((await res.json()).code).toBe("ask_failed");
    expect(store.refundAsk).toHaveBeenCalledWith("u1");
  });

  it("never logs the question, answer or numbers", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    state.client = scripted([toolUse("t1", "get_spending", { merchant: "Whole Foods" }), text("You spent $142.30 at Whole Foods.")]).client;
    await ask([{ role: "user", content: SECRET_QUESTION }]);
    state.client = scripted([Object.assign(new Error(`bad request: ${SECRET_QUESTION}`), { status: 400 })]).client;
    await ask([{ role: "user", content: SECRET_QUESTION }]);
    const all = [...log.mock.calls, ...err.mock.calls].flat().join(" ");
    expect(all).toContain("[ask]");
    for (const leak of ["123-45-6789", "Whole Foods", "142.30", "SSN"]) expect(all).not.toContain(leak);
    log.mockRestore(); err.mockRestore();
  });
});

describe("proposals", () => {
  const mine = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  it("confirm applies the user's own proposal", async () => {
    const res = await post("/ask/confirm", { proposalId: mine });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, message: "Groceries budget set to $900." });
  });
  it("another user's proposal is a 404", async () => {
    authUser = "someone-else";
    const res = await post("/ask/confirm", { proposalId: mine });
    expect(res.status).toBe(404);
    expect(store.confirmProposal).toHaveBeenCalledWith("someone-else", mine);
  });
  it("rejects malformed ids", async () => {
    expect((await post("/ask/confirm", { proposalId: "nope" })).status).toBe(400);
  });
  it("dismiss works for the owner only", async () => {
    expect((await post("/ask/dismiss", { proposalId: mine })).status).toBe(200);
    authUser = "someone-else";
    expect((await post("/ask/dismiss", { proposalId: mine })).status).toBe(404);
  });
});

describe("/settings/ask", () => {
  it("reports opt-in state, limit and usage; PUT toggles it", async () => {
    state.settings = { enabled: false, dailyLimit: 30, usedToday: 2 };
    const g = await app.request("/settings/ask");
    expect(await g.json()).toEqual({ enabled: false, dailyLimit: 30, usedToday: 2 });
    const p = await app.request("/settings/ask", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ enabled: true }) });
    expect(p.status).toBe(200);
    expect(store.setAskEnabled).toHaveBeenCalledWith("u1", true);
    expect((await app.request("/settings/ask", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ enabled: "yes" }) })).status).toBe(400);
  });
});
