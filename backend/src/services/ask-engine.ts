// The Ask Folio assistant: Claude with tool use over one user's own data.
// Numbers come from the tools; the model only words them. Nothing here logs message text or tool results.
import { z } from "zod";
import { NON_SPENDING, normalizeCategory } from "./categories.js";
import { SP500_AS_OF, SP500_CAVEAT, sp500ReturnBetween } from "./sp500.js";
import type { BudgetProposal } from "./ask-store.js";
import type { SpendingArgs } from "./ask-data.js";

export interface Fact { label: string; value: string }
export interface ProposalOut { id: string; kind: "budget"; title: string; detail: string; category: string; currentAmount: number; newAmount: number }
export interface ChatMessage { role: "user" | "assistant"; content: string }

/** What the tools read and write. The real implementation is services/ask-data + ask-store; tests inject fakes. */
export interface AskData {
  overview(userId: string): Promise<{ netWorth: number; assets: number; liabilities: number; byGroup: Record<string, number>; accountCount: number }>;
  accounts(userId: string): Promise<{ accounts: { name: string; group: string; balance: number; institution: string | null }[]; total: number }>;
  budget(userId: string): Promise<{ month: string; totalLimit: number; totalSpent: number; left: number; categories: { category: string; limit: number; spent: number }[] }>;
  spending(userId: string, a: SpendingArgs): Promise<{ from: string; to: string; total: number; transactionCount: number; topMerchants: { name: string; total: number; count: number }[]; byCategory: { category: string; total: number }[]; filters: { category: string | null; merchant: string | null } }>;
  income(userId: string): Promise<{ monthlyIncome: number; source: string; confidence: string; sources: { name: string; monthly: number; frequency: string }[]; usualMonthlySpending: number }>;
  health(userId: string): Promise<{ savingsRate: number | null; emergencyFundMonths: number | null; creditUtilization: number | null; debtPaymentRatio: number | null; monthlyIncome: number; usualMonthlySpending: number; monthsOfData: number }>;
  investments(userId: string): Promise<{ totalInvested: number; investmentAccounts: { name: string; balance: number; institution: string | null }[]; allocation: { label: string; amount: number; percent: number }[]; notes: { title: string; detail: string }[]; savingsRate: number | null }>;
  netWorthWindow(userId: string, from: string, to: string): Promise<{ startDate: string; endDate: string; start: number; end: number; snapshots: number } | null>;
  currentBudgetAmount(userId: string, category: string): Promise<number>;
  createProposal(userId: string, payload: BudgetProposal): Promise<string>;
}

const money = (n: number) => (n < 0 ? "-" : "") + "$" + Math.abs(Math.round(n)).toLocaleString("en-US");
const money2 = (n: number) => (n < 0 ? "-" : "") + "$" + Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const pct = (x: number) => `${Math.round(x * 100)}%`;

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine((s) => !Number.isNaN(Date.parse(s)), "not a real date");

export interface ToolCtx { userId: string; today: string; data: AskData }
interface ToolOut { result: unknown; facts: Fact[]; proposal?: ProposalOut }

interface ToolDef<S extends z.ZodType> {
  name: string;
  description: string;
  schema: S;
  run(args: z.infer<S>, ctx: ToolCtx): Promise<ToolOut>;
}
function tool<S extends z.ZodType>(t: ToolDef<S>): ToolDef<S> { return t; }

const monthStart = (today: string) => `${today.slice(0, 7)}-01`;
const addMonths = (iso: string, m: number) => {
  const d = new Date(iso + "T00:00:00Z");
  d.setUTCMonth(d.getUTCMonth() + m);
  return d.toISOString().slice(0, 10);
};

export const TOOLS = [
  tool({
    name: "get_overview",
    description: "The user's net worth, total assets and liabilities, and totals per group (Cash, Savings, Investments, Physical assets, Credit cards, Loans).",
    schema: z.object({}),
    async run(_a, { userId, data }) {
      const o = await data.overview(userId);
      return { result: o, facts: [{ label: "Net worth", value: money(o.netWorth) }, { label: "Assets", value: money(o.assets) }, { label: "Liabilities", value: money(o.liabilities) }] };
    },
  }),
  tool({
    name: "get_accounts",
    description: "The user's accounts with group, balance and institution.",
    schema: z.object({}),
    async run(_a, { userId, data }) {
      const r = await data.accounts(userId);
      return { result: r, facts: [{ label: "Accounts", value: String(r.total) }] };
    },
  }),
  tool({
    name: "get_budget",
    description: "This month's budget: each category's monthly limit and how much is spent so far, plus totals.",
    schema: z.object({}),
    async run(_a, { userId, data }) {
      const b = await data.budget(userId);
      const facts: Fact[] = b.categories.length
        ? [{ label: "Budget this month", value: `${money(b.totalSpent)} of ${money(b.totalLimit)}` }, ...b.categories.slice(0, 4).map((c) => ({ label: `${c.category} budget`, value: `${money(c.spent)} of ${money(c.limit)}` }))]
        : [];
      return { result: b, facts };
    },
  }),
  tool({
    name: "get_spending",
    description: "Spending (money out, excluding transfers and excluded transactions) between two dates, optionally for one category or merchant (case-insensitive 'contains'). Defaults to this month so far. Returns the total, count, top merchants and categories.",
    schema: z.object({ from: isoDate.optional(), to: isoDate.optional(), category: z.string().max(60).optional(), merchant: z.string().max(60).optional() }),
    async run(a, { userId, today, data }) {
      const from = a.from ?? monthStart(today);
      const to = a.to ?? today;
      if (to < from) throw new Error("'to' must not be before 'from'");
      if (Date.parse(to) - Date.parse(from) > 400 * 86_400_000) throw new Error("date range is limited to about 13 months");
      const r = await data.spending(userId, { from, to, category: a.category, merchant: a.merchant });
      const what = a.merchant ? a.merchant : a.category ? a.category : "Spending";
      const when = from === monthStart(today) && to === today ? "this month" : `${from} to ${to}`;
      return { result: r, facts: [{ label: `${what} ${when}`, value: money2(r.total) }, { label: "Transactions", value: String(r.transactionCount) }] };
    },
  }),
  tool({
    name: "get_income",
    description: "The user's detected (or manually set) monthly income, its sources, and usual monthly spending.",
    schema: z.object({}),
    async run(_a, { userId, data }) {
      const r = await data.income(userId);
      return { result: r, facts: [{ label: "Monthly income", value: r.monthlyIncome > 0 ? money(r.monthlyIncome) : "not found yet" }] };
    },
  }),
  tool({
    name: "get_health_metrics",
    description: "Savings rate, emergency fund (months of spending in cash), credit utilization and debt-payment ratio. Null means not enough data.",
    schema: z.object({}),
    async run(_a, { userId, data }) {
      const h = await data.health(userId);
      const facts: Fact[] = [];
      if (h.savingsRate != null) facts.push({ label: "Savings rate", value: pct(h.savingsRate) });
      if (h.emergencyFundMonths != null) facts.push({ label: "Emergency fund", value: `${h.emergencyFundMonths} months` });
      if (h.creditUtilization != null) facts.push({ label: "Credit use", value: pct(h.creditUtilization) });
      if (h.debtPaymentRatio != null) facts.push({ label: "Debt payments", value: pct(h.debtPaymentRatio) });
      return { result: h, facts };
    },
  }),
  tool({
    name: "get_investments",
    description: "Investment account balances, the allocation across cash/savings/investments/other, and general notes. Holdings-level detail (individual funds, performance) is NOT available.",
    schema: z.object({}),
    async run(_a, { userId, data }) {
      const r = await data.investments(userId);
      const facts: Fact[] = [{ label: "Invested", value: money(r.totalInvested) }];
      if (r.savingsRate != null) facts.push({ label: "Savings rate", value: pct(r.savingsRate) });
      return { result: r, facts };
    },
  }),
  tool({
    name: "compare_to_sp500",
    description: `Roughly compare the change in the user's net worth with the S&P 500 total return over a recent window (months) or a full past calendar year (2019-2024). S&P data is approximate (as of ${SP500_AS_OF}) and unavailable for recent periods. Always relay the caveat.`,
    schema: z.object({ months: z.number().int().min(1).max(60).optional(), year: z.number().int().min(2019).max(2024).optional() }),
    async run(a, { userId, today, data }) {
      const to = a.year ? (`${a.year}-12-31` < today ? `${a.year}-12-31` : today) : today;
      const from = a.year ? `${a.year}-01-01` : addMonths(today, -(a.months ?? 12));
      const w = await data.netWorthWindow(userId, from, to);
      const sp = sp500ReturnBetween(from, to);
      const userPct = w && w.start > 0 ? Math.round(((w.end - w.start) / w.start) * 10000) / 100 : null;
      const result = {
        window: { from, to },
        yourNetWorthChangePct: userPct,
        yourNetWorthStart: w?.start ?? null, yourNetWorthEnd: w?.end ?? null, snapshotsFound: w?.snapshots ?? 0,
        sp500TotalReturnPct: sp,
        sp500Note: sp == null ? `S&P 500 data in Folio is approximate and only covers 2019-2024 (as of ${SP500_AS_OF}), so it isn't available for this window.` : `Approximate, as of ${SP500_AS_OF}.`,
        caveat: SP500_CAVEAT,
      };
      const facts: Fact[] = [];
      if (userPct != null) facts.push({ label: "Your net worth change", value: `${userPct}%` });
      if (sp != null) facts.push({ label: "S&P 500 total return (approx.)", value: `${sp}%` });
      return { result, facts };
    },
  }),
  tool({
    name: "propose_budget_change",
    description: "Propose changing the monthly budget for one spending category. This does NOT apply anything: the user must tap Confirm in the app. Use newAmount 0 to remove the category's budget.",
    schema: z.object({ category: z.string().min(1).max(60), newAmount: z.number().min(0).max(10_000_000), reason: z.string().max(200).optional() }),
    async run(a, { userId, data }) {
      const category = normalizeCategory(a.category);
      if (NON_SPENDING.has(category)) throw new Error(`${category} can't have a budget`);
      const currentAmount = await data.currentBudgetAmount(userId, category);
      const newAmount = Math.round(a.newAmount);
      const payload: BudgetProposal = {
        kind: "budget", category, currentAmount, newAmount,
        title: `Change ${category} budget`,
        detail: newAmount <= 0 ? `Remove the ${money(currentAmount)} a month ${category} budget.` : `From ${money(currentAmount)} to ${money(newAmount)} a month.`,
      };
      const id = await data.createProposal(userId, payload);
      return {
        result: { status: "awaiting_user_confirmation", category, currentAmount, newAmount },
        facts: [{ label: `${category} budget`, value: `${money(currentAmount)} → ${money(newAmount)}` }],
        proposal: { id, ...payload },
      };
    },
  }),
];

export function toolSchemas() {
  return TOOLS.map((t) => {
    const json = z.toJSONSchema(t.schema) as Record<string, unknown>;
    delete json.$schema;
    return { name: t.name, description: t.description, input_schema: { type: "object" as const, properties: (json.properties ?? {}) as Record<string, unknown>, ...(json.required ? { required: json.required as string[] } : {}) } };
  });
}

export function systemPrompt(today: string): string {
  return [
    "You are Folio's assistant inside a personal finance app. You answer questions about THIS user's own finances.",
    `Today is ${today}.`,
    "Rules:",
    "- Use the tools to look up numbers. Never invent or estimate figures. If a tool returns no data or null, say that data isn't available yet.",
    "- Be concise: 2 to 5 short sentences, plain language, no markdown tables. Mention the specific numbers you used.",
    "- Investing: give general information only, not personalized advice. Never tell the user to buy, sell, or hold a specific security.",
    "- For compare_to_sp500, always tell the user the comparison is rough and repeat the caveat in one short sentence.",
    "- You cannot change anything yourself. To change a budget, call propose_budget_change, then tell the user a Confirm button is shown below your answer.",
    "- If asked something unrelated to the user's finances in this app, politely say you can only help with their Folio data.",
  ].join("\n");
}

// ── Model client (structural, so tests can fake it) ──────────────────────────

interface Block { type: string; text?: string; id?: string; name?: string; input?: unknown }
interface ModelResponse { content: Block[]; stop_reason: string | null }
export interface AskClient { messages: { create(params: any): Promise<ModelResponse> } }

const MAX_ROUNDS = 6;
const MAX_RESULT_CHARS = 6000;

function clip(value: unknown): string {
  const s = JSON.stringify(value);
  return s.length > MAX_RESULT_CHARS ? s.slice(0, MAX_RESULT_CHARS) + '…(truncated)' : s;
}

async function callModel(client: AskClient, params: Record<string, unknown>): Promise<ModelResponse> {
  try {
    return await client.messages.create({ ...params, temperature: 0.2 });
  } catch (e) {
    const err = e as { status?: number; message?: string };
    if (err.status === 400 && /temperature/i.test(err.message ?? "")) return client.messages.create(params);
    throw e;
  }
}

export interface AskResult { answer: string; facts: Fact[]; proposal: ProposalOut | null; tools: string[]; rounds: number }

export async function runAsk(opts: {
  client: AskClient;
  model: string;
  userId: string;
  userHash: string;
  today: string;
  messages: ChatMessage[];
  data: AskData;
}): Promise<AskResult> {
  const { client, model, userId, today, data } = opts;
  const convo: { role: "user" | "assistant"; content: unknown }[] = opts.messages.map((m) => ({ role: m.role, content: m.content }));
  const facts = new Map<string, Fact>();
  const used: string[] = [];
  let proposal: ProposalOut | null = null;
  const ctx: ToolCtx = { userId, today, data };

  for (let round = 1; round <= MAX_ROUNDS; round++) {
    const res = await callModel(client, {
      model, max_tokens: 800, system: systemPrompt(today), tools: toolSchemas(), messages: convo,
      metadata: { user_id: opts.userHash },
    });

    const toolUses = res.content.filter((b) => b.type === "tool_use");
    if (res.stop_reason !== "tool_use" || toolUses.length === 0) {
      const answer = res.content.filter((b) => b.type === "text").map((b) => b.text ?? "").join("\n").trim();
      return { answer: answer || "I couldn't come up with an answer to that. Try asking another way.", facts: [...facts.values()].slice(0, 8), proposal, tools: used, rounds: round };
    }

    convo.push({ role: "assistant", content: res.content });
    const results = await Promise.all(
      toolUses.map(async (b) => {
        const def = TOOLS.find((t) => t.name === b.name);
        used.push(b.name ?? "unknown");
        if (!def) return { type: "tool_result", tool_use_id: b.id, is_error: true, content: "Unknown tool." };
        const parsed = def.schema.safeParse(b.input ?? {});
        if (!parsed.success) {
          return { type: "tool_result", tool_use_id: b.id, is_error: true, content: `Invalid arguments: ${parsed.error.issues.map((i) => `${i.path.join(".") || "input"} ${i.message}`).join("; ").slice(0, 300)}` };
        }
        try {
          const out = await (def as ToolDef<z.ZodType>).run(parsed.data, ctx);
          for (const f of out.facts) facts.set(f.label, f);
          if (out.proposal) proposal = out.proposal;
          return { type: "tool_result", tool_use_id: b.id, content: clip(out.result) };
        } catch (e) {
          return { type: "tool_result", tool_use_id: b.id, is_error: true, content: `Couldn't run that: ${(e as Error).message}`.slice(0, 300) };
        }
      })
    );
    convo.push({ role: "user", content: results });
  }

  return { answer: "That took more steps than I can do in one go. Try a simpler question.", facts: [...facts.values()].slice(0, 8), proposal, tools: used, rounds: MAX_ROUNDS };
}
