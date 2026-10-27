import {
  buildInsights, computeOutflow, detectIncome, detectRecurrence, merchantKey, roundNice, suggestBudget,
  type InAcct, type InTxn, type OutflowResult,
} from "../src/services/insights.js";

const NOW = "2026-10-27"; // a Tuesday

function tx(date: string, amount: number, name: string, category: string, extra: Partial<InTxn> = {}): InTxn {
  return { date, amount, name, category, isExcluded: false, isPending: false, accountType: "depository", ...extra };
}
const pay = (date: string, amount = -2000, name = "ACME CORP PAYROLL") => tx(date, amount, name, "Income");

describe("detectRecurrence", () => {
  it("recognizes a steady biweekly series on one weekday", () => {
    const r = detectRecurrence(["2026-09-11", "2026-09-25", "2026-10-09", "2026-10-23"].map((date) => ({ date, amount: -2000 })));
    expect(r?.frequency).toBe("biweekly");
  });
  it("rejects wildly varying amounts", () => {
    const amounts = [-100, -900, -250, -1500];
    const dates = ["2026-07-01", "2026-08-01", "2026-09-01", "2026-10-01"];
    expect(detectRecurrence(dates.map((date, i) => ({ date, amount: amounts[i] })))).toBeNull();
  });
  it("needs at least three occurrences", () => {
    expect(detectRecurrence([{ date: "2026-09-01", amount: -1 }, { date: "2026-10-01", amount: -1 }])).toBeNull();
  });
});

describe("detectIncome", () => {
  it("annualizes biweekly paychecks (26 per year)", () => {
    const dates = ["2026-08-14", "2026-08-28", "2026-09-11", "2026-09-25", "2026-10-09", "2026-10-23"];
    const r = detectIncome(dates.map((d) => pay(d)), NOW, null);
    expect(r.source).toBe("detected");
    expect(r.confidence).toBe("high");
    expect(r.sources[0].frequency).toBe("biweekly");
    expect(r.monthly).toBeCloseTo((2000 * 26) / 12, 1);
  });

  it("detects a monthly salary", () => {
    const r = detectIncome(["2026-07-01", "2026-08-01", "2026-09-01", "2026-10-01"].map((d) => pay(d, -5000, "Employer Direct Deposit")), NOW, null);
    expect(r.monthly).toBe(5000);
    expect(r.sources[0].frequency).toBe("monthly");
  });

  it("uses the median month for irregular freelance income, with low confidence", () => {
    const txns = [
      tx("2026-06-10", -1200, "Client A", "Income"), tx("2026-07-22", -300, "Client B", "Income"),
      tx("2026-08-03", -2500, "Client C", "Income"), tx("2026-09-15", -800, "Client D", "Income"),
      tx("2026-10-02", -1700, "Client E", "Income"),
    ];
    const r = detectIncome(txns, NOW, null);
    expect(r.confidence).toBe("low");
    expect(r.monthly).toBe(1000); // median of Jun-Sep = 300, 800, 1200, 2500
    expect(r.sources[0].frequency).toBe("irregular");
  });

  it("ignores transfers, excluded rows and card payments", () => {
    const weekly = ["2026-09-29", "2026-10-06", "2026-10-13", "2026-10-20"];
    expect(detectIncome(weekly.map((d) => tx(d, -500, "Transfer from Savings", "Transfer")), NOW, null).source).toBe("none");
    expect(detectIncome(weekly.map((d) => pay(d, -500, "Side gig")).map((t) => ({ ...t, isExcluded: true })), NOW, null).source).toBe("none");
    expect(detectIncome(weekly.map((d) => tx(d, -500, "Credit Card Payment", "Income")), NOW, null).source).toBe("none");
  });

  it("drops a job whose paychecks stopped", () => {
    const old = ["2026-05-01", "2026-05-15", "2026-05-29", "2026-06-12"].map((d) => pay(d));
    expect(detectIncome(old, NOW, null).source).toBe("none");
  });

  it("honors a manual override", () => {
    const r = detectIncome([], NOW, 6500);
    expect(r).toMatchObject({ monthly: 6500, source: "manual", confidence: "high" });
  });

  it("reports nothing for a brand-new user", () => {
    expect(detectIncome([], NOW, null)).toEqual({ monthly: 0, source: "none", confidence: "none", sources: [] });
  });
});

describe("computeOutflow", () => {
  const rent = ["2026-08-01", "2026-09-01", "2026-10-01"].map((d) => tx(d, 1500, "Greenway Rent", "Home"));
  const dining = ["2026-08-10", "2026-08-24", "2026-09-07", "2026-09-21", "2026-10-05", "2026-10-19"].map((d, i) => tx(d, 60 + i * 13, `Cafe ${i}`, "Dining"));

  it("splits fixed bills from flexible spending and skips transfers and card payments", () => {
    const noise = [
      tx("2026-09-15", 800, "Chase Credit Card Payment", "Transfer"),
      tx("2026-09-20", 700, "AUTOPAY PAYMENT", "Other"),
      tx("2026-09-21", 300, "Move to savings", "Transfer"),
    ];
    const o = computeOutflow([...rent, ...dining, ...noise], NOW);
    expect(o.byCategory.map((c) => c.category)).toEqual(["Home", "Dining"]);
    expect(o.byCategory[0].isFixed).toBe(true);
    expect(o.byCategory[1].isFixed).toBe(false);
    const diningTotal = dining.reduce((s, t) => s + t.amount, 0);
    expect(o.monthlyAverage).toBeCloseTo((4500 + diningTotal) / (88 / 30.4), 0);
    expect(o.fixed + o.variable).toBeCloseTo(o.monthlyAverage, 1);
    expect(o.fixed).toBeGreaterThan(1400);
  });

  it("returns zeros with no data", () => {
    expect(computeOutflow([], NOW)).toMatchObject({ monthlyAverage: 0, fixed: 0, variable: 0, byCategory: [] });
  });
});

describe("suggestBudget", () => {
  const outflow: OutflowResult = {
    monthlyAverage: 2427, fixed: 1500, variable: 927, fixedByCategory: { Home: 1500 },
    byCategory: [
      { category: "Home", monthlyAverage: 1500, isFixed: true },
      { category: "Groceries", monthlyAverage: 520, isFixed: false },
      { category: "Dining", monthlyAverage: 400, isFixed: false },
      { category: "Transport", monthlyAverage: 7, isFixed: false },
    ],
  };
  it("keeps fixed bills, trims flexible categories, rounds, and drops tiny ones", () => {
    const b = suggestBudget(outflow);
    expect(b.items).toEqual([
      { category: "Home", amount: 1500 },
      { category: "Groceries", amount: 490 },
      { category: "Dining", amount: 360 },
    ]);
    expect(b.total).toBe(2350);
  });
  it("rounds to $5 under $100 and $10 above", () => {
    expect(roundNice(42)).toBe(40);
    expect(roundNice(43)).toBe(45);
    expect(roundNice(1234)).toBe(1230);
    expect(roundNice(1)).toBe(5);
  });
});

describe("buildInsights", () => {
  const accounts: InAcct[] = [
    { type: "depository", subtype: "checking", balance: 6000, limit: null, hidden: false },
    { type: "depository", subtype: "savings", balance: 12000, limit: null, hidden: false },
    { type: "investment", subtype: null, balance: 50000, limit: null, hidden: false },
    { type: "credit", subtype: null, balance: 1500, limit: 10000, hidden: false },
    { type: "depository", subtype: "checking", balance: 99999, limit: null, hidden: true },
  ];
  const spend = ["2026-08-05", "2026-09-05", "2026-10-05"].map((d) => tx(d, 3000, "Landlord Rent", "Home"));

  it("computes savings rate, emergency fund, utilization and allocation", () => {
    const r = buildInsights({ txns: spend, accounts, now: NOW, incomeOverride: 5000, birthYear: 1990 });
    const o = r.outflow.monthlyAverage;
    expect(r.income.source).toBe("manual");
    expect(r.health.savingsRate).toBeCloseTo((5000 - o) / 5000, 2);
    expect(r.health.emergencyFundMonths).toBeCloseTo(18000 / o, 1);
    expect(r.health.creditUtilization).toBe(0.15);
    expect(r.investing.totalInvested).toBe(50000);
    expect(r.investing.allocation.map((a) => a.label)).toEqual(["Cash", "Savings", "Investments"]);
    expect(r.investing.allocation.reduce((s, a) => s + a.percent, 0)).toBeGreaterThan(99.5);
    expect(r.investing.notes.find((n) => n.id === "allocation-rule")?.detail).toContain("110 minus your age");
    expect(r.dataQuality).toEqual({ monthsOfData: 3, transactionCount: 3 });
  });

  it("asks for a birth year when none is set, and never says buy/sell", () => {
    const r = buildInsights({ txns: spend, accounts, now: NOW, incomeOverride: 5000, birthYear: null });
    expect(r.investing.notes.some((n) => n.id === "add-age")).toBe(true);
    for (const n of r.investing.notes) expect(`${n.title} ${n.detail}`).not.toMatch(/\b(buy|sell)\b/i);
  });

  it("is all zeros and empty arrays for a brand-new user", () => {
    const r = buildInsights({ txns: [], accounts: [], now: NOW, incomeOverride: null, birthYear: null });
    expect(r.income).toEqual({ monthly: 0, source: "none", confidence: "none", sources: [] });
    expect(r.outflow).toEqual({ monthlyAverage: 0, fixed: 0, variable: 0, byCategory: [] });
    expect(r.budget).toEqual({ total: 0, items: [] });
    expect(r.health).toEqual({ savingsRate: null, emergencyFundMonths: null, creditUtilization: null, debtPaymentRatio: null });
    expect(r.investing).toEqual({ totalInvested: 0, allocation: [], notes: [] });
    expect(r.dataQuality).toEqual({ monthsOfData: 0, transactionCount: 0 });
  });
});

describe("merchantKey", () => {
  it("collapses processor noise and digits", () => {
    expect(merchantKey("ACME CORP PAYROLL 10/23 ID#4432")).toBe(merchantKey("Acme Corp Payroll 09/25 ID#9911"));
  });
});
