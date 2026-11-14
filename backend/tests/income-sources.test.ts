import { classify, summarizeIncome, type CreditIn } from "../src/services/income-sources.js";

describe("classify (Matt's real deposit names)", () => {
  it.each([
    ["PPD PATRIOT GROWTH I PAYROLL", "Income", "wages"],
    ["Interest Payment", "Income", "interest"],
    ["IOD INTEREST PAID", "Income", "interest"],
    ["PPD IRS TREAS 310 TAX REF", "Income", "tax_refund"],
    ["PPD Tax Commissioner NDSTTAXRFD", "Income", "tax_refund"],
    ["ATM SURCHARGE REIMBURSEMENT", "Fees", "reimbursement"],
    ["CCD PATRIOT GROWTH I PAYABLES", "Uncategorized", "reimbursement"],
    ["UPSIDE UPSIDE PPD MATTHEW BOEN", "Income", "rewards"],
    ["VANGUARD DIVIDEND REINVEST", "Income", "dividends"],
    ["SSA TREAS 449", "Income", "benefits"],
    ["Zelle from Jake", "Transfer", "from_people"],
    ["Interest Adjustment", "Fees", "reimbursement"],
  ])("%s → %s", (name, cat, kind) => expect(classify(name, cat)).toBe(kind));
});

describe("summarizeIncome", () => {
  const c = (date: string, amount: number, name: string, account = "Checking", category = "Income"): CreditIn =>
    ({ date, amount, name, category, account, accountType: "depository" });
  const credits = [
    c("2026-10-01", 2000, "ACME PAYROLL"), c("2026-11-01", 2000, "ACME PAYROLL"),
    c("2026-10-31", 10, "Interest Payment", "Savings"), c("2026-11-30", 14, "Interest Payment", "Savings"),
    c("2026-04-17", 1200, "IRS TREAS 310 TAX REF"),
  ];
  it("counts paychecks and interest, not tax refunds, averaged over the history", () => {
    const r = summarizeIncome(credits, "2026-11-30", {}, null, "2026-05-30");
    expect(r.streams.find((s) => s.kind === "tax_refund")?.included).toBe(false);
    expect(r.streams.find((s) => s.kind === "interest")?.name).toBe("Interest · Savings");
    expect(r.detected).toBeGreaterThan(660); expect(r.detected).toBeLessThan(675);
  });
  it("your switches win, and a typed income wins over everything", () => {
    const refund = summarizeIncome(credits, "2026-11-30", {}, null, "2026-05-30").streams.find((s) => s.kind === "tax_refund")!;
    const on = summarizeIncome(credits, "2026-11-30", { [refund.key]: true }, null, "2026-05-30");
    expect(on.streams.find((s) => s.key === refund.key)).toMatchObject({ included: true, source: "you" });
    expect(summarizeIncome(credits, "2026-11-30", {}, 5000, null)).toMatchObject({ monthly: 5000, source: "manual" });
  });
});
