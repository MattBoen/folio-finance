import { aiPick, rulePick, summarize, type CashAccount, type Picks } from "../src/services/emergency-fund.js";

const acct = (id: string, name: string, subtype: string | null, balance: number, deposits: string[] = []): CashAccount =>
  ({ id, name, institution: "Bank", subtype, balance, deposits });

const checking = acct("a1", "Everyday Checking", "checking", 2000);
const savings = acct("a2", "High Yield Savings", "savings", 9000);
const house = acct("a3", "House Fund", "savings", 15000);
const tagged = acct("a4", "Savings 4421", "savings", 6000, ["Auto-transfer to Emergency Fund"]);

describe("rulePick", () => {
  it("counts general savings and leaves out checking", () => {
    expect(rulePick(savings).emergency).toBe(true);
    expect(rulePick(checking).emergency).toBe(false);
  });
  it("leaves out savings named for another goal, and isn't sure about it", () => {
    expect(rulePick(house)).toMatchObject({ emergency: false, confident: false });
  });
  it("is certain when deposits say emergency fund", () => {
    expect(rulePick(tagged)).toMatchObject({ emergency: true, confident: true });
  });
});

const picksFrom = (list: CashAccount[], by: "ai" | "rules" = "rules"): Picks =>
  ({ signature: "x", at: "", by, picks: Object.fromEntries(list.map((a) => [a.id, rulePick(a)])) });

describe("summarize", () => {
  const base = {
    cash: [checking, savings, house],
    included: {},
    basis: "essentials" as const,
    monthly: { essentials: 1500, usual: 3000, budget: 2500 },
    essentials: [{ category: "Groceries", monthly: 500 }],
  };

  it("measures included accounts against essentials by default", () => {
    const r = summarize({ ...base, picks: picksFrom(base.cash) });
    expect(r.total).toBe(9000);
    expect(r.months).toBe(6);
    expect(r.question?.accountId).toBe("a3");
  });

  it("your choices win over Folio's and stop the question", () => {
    const r = summarize({ ...base, included: { a3: true, a2: false }, picks: picksFrom(base.cash) });
    expect(r.total).toBe(15000);
    expect(r.accounts.find((a) => a.id === "a3")?.source).toBe("you");
    expect(r.question).toBeNull();
  });

  it("can measure against usual spending or the budget", () => {
    expect(summarize({ ...base, basis: "usual", picks: picksFrom(base.cash) }).months).toBe(3);
    expect(summarize({ ...base, basis: "budget", picks: picksFrom(base.cash) }).months).toBe(3.6);
  });

  it("falls back to essentials when there's no budget", () => {
    const r = summarize({ ...base, basis: "budget", monthly: { ...base.monthly, budget: null }, picks: picksFrom(base.cash) });
    expect(r.basis).toBe("essentials");
  });
});

describe("aiPick", () => {
  const fake = (text: string) => ({ messages: { create: async () => ({ content: [{ type: "text", text }] }) } });

  it("reads the model's JSON", async () => {
    const out = await aiPick([checking, savings], fake('Here: {"accounts":[{"id":"a1","emergency":false,"confident":true,"reason":"Bills account"},{"id":"a2","emergency":true,"confident":true,"reason":"General savings"}]}'));
    expect(out?.a2.emergency).toBe(true);
    expect(out?.a1.reason).toBe("Bills account");
  });

  it("keeps what a cut-off reply finished and uses the rules for the rest", async () => {
    const out = await aiPick([checking, savings], fake('{"accounts":[{"id":"a1","emergency":true,"reason":"Holds the cushion"},{"id":"a2","emerg'));
    expect(out?.a1).toMatchObject({ emergency: true, reason: "Holds the cushion" });
    expect(out?.a2).toMatchObject({ emergency: true, reason: "General savings" });
  });

  it("gives up when the reply is junk", async () => {
    expect(await aiPick([checking], fake("sorry"))).toBeNull();
  });
});

describe("rulePick names", () => {
  it("treats other named funds as saving for something else, and asks", () => {
    expect(rulePick(acct("g", "Gift Fund", "savings", 400))).toMatchObject({ emergency: false, confident: false });
    expect(rulePick(acct("e", "Emergency Fund", "savings", 5000))).toMatchObject({ emergency: true, confident: true });
  });
});

import { savingsSummary } from "../src/services/emergency-fund.js";

describe("savingsSummary", () => {
  const monthly = { essentials: 1000, usual: 3000, budget: 2500 };
  it("follows the emergency fund's yardstick by default", () => {
    const r = savingsSummary({ monthly: 4000, source: "detected" }, monthly, "essentials", null);
    expect(r).toMatchObject({ basis: "essentials", followsFund: true, spending: 1000, leftOver: 3000, rate: 0.75 });
  });
  it("uses its own yardstick once you pick one", () => {
    const r = savingsSummary({ monthly: 4000, source: "manual" }, monthly, "essentials", "usual");
    expect(r).toMatchObject({ basis: "usual", followsFund: false, rate: 0.25 });
  });
  it("has no rate without income", () => {
    expect(savingsSummary({ monthly: 0, source: "none" }, monthly, "usual", null).rate).toBeNull();
  });
});
