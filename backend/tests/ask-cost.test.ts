import { describe, it, expect } from "vitest";
import { costOf, askModel, QUESTION_LIMIT_USD, DEFAULT_MODEL } from "../src/services/ask-cost.js";
import { runAsk, HISTORY_MESSAGES, HISTORY_CHARS, type AskClient } from "../src/services/ask-engine.js";

describe("Ask Folio money guards", () => {
  it("only ever uses Haiku", () => {
    expect(askModel("claude-opus-5-5")).toBe(DEFAULT_MODEL);
    expect(askModel("claude-sonnet-5-5")).toBe(DEFAULT_MODEL);
    expect(askModel(undefined)).toBe(DEFAULT_MODEL);
    expect(askModel("claude-haiku-5-5")).toBe("claude-haiku-5-5");
  });
  it("counts cached tokens at full price (and cache writes higher)", () => {
    expect(costOf({ input_tokens: 1_000_000 })).toBeCloseTo(0.1);
    expect(costOf({ cache_read_input_tokens: 1_000_000 })).toBeCloseTo(0.1);
    expect(costOf({ cache_creation_input_tokens: 1_000_000 })).toBeCloseTo(0.125);
    expect(costOf({ output_tokens: 1_000_000 })).toBeCloseTo(0.5);
    expect(costOf(undefined)).toBe(0);
  });
  const data: any = new Proxy({}, { get: () => async () => ({}) });
  const base = { userId: "u", userHash: "h", today: "2026-11-10", data, model: DEFAULT_MODEL };
  it("stops a question that passes the per-question cap and reports each cost", async () => {
    const costs: number[] = [];
    let calls = 0;
    const client: AskClient = { messages: { create: async () => { calls++; return { stop_reason: "tool_use", content: [{ type: "tool_use", id: "t" + calls, name: "get_overview", input: {} }], usage: { input_tokens: 1_000_000 } }; } } };
    const out = await runAsk({ ...base, client, messages: [{ role: "user", content: "hi" }], onCost: (c) => costs.push(c) });
    expect(calls).toBe(1);
    expect(costs[0]).toBeGreaterThanOrEqual(QUESTION_LIMIT_USD);
    expect(out.answer).toMatch(/simpler/);
  });
  it("sends only the last 8 messages, each cut to 1,500 characters, with a 1,500 token answer cap", async () => {
    let sent: any;
    const client: AskClient = { messages: { create: async (p: any) => { sent = p; return { stop_reason: "end_turn", content: [{ type: "text", text: "ok" }] }; } } };
    const messages = Array.from({ length: 12 }, (_, i) => ({ role: (i % 2 === 0 ? "user" : "assistant") as "user" | "assistant", content: "x".repeat(2000) }));
    messages.push({ role: "user", content: "last" });
    await runAsk({ ...base, client, messages });
    expect(sent.messages.length).toBe(HISTORY_MESSAGES);
    expect(sent.messages[0].content.length).toBeLessThanOrEqual(HISTORY_CHARS);
    expect(sent.max_tokens).toBe(1500);
    expect("temperature" in sent).toBe(false);
    expect(JSON.stringify(sent.tools)).not.toMatch(/web_search/);
  });
});
