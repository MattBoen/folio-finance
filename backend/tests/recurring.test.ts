import { detectRecurringBills, nextDue } from "../src/services/recurring.js";
import type { InTxn } from "../src/services/insights.js";

const NOW = "2026-11-06";

function tx(date: string, amount: number, name: string, category = "Subscriptions", extra: Partial<InTxn> = {}): InTxn {
  return { date, amount, name, category, isExcluded: false, isPending: false, accountType: "depository", ...extra };
}
const monthly = (name: string, amount: number, day: string, category = "Subscriptions", months = ["2026-07", "2026-08", "2026-09", "2026-10"]) =>
  months.map((m) => tx(`${m}-${day}`, amount, name, category));

describe("detectRecurringBills", () => {
  it("finds a monthly subscription and says when it is next due", () => {
    const r = detectRecurringBills(monthly("NETFLIX.COM", 15.49, "12"), NOW);
    expect(r.items).toHaveLength(1);
    expect(r.items[0].frequency).toBe("monthly");
    expect(r.items[0].isSubscription).toBe(true);
    expect(r.items[0].nextDate).toBe("2026-11-12");
    expect(r.subscriptionsMonthly).toBeCloseTo(15.49, 2);
    expect(r.upcoming[0]).toMatchObject({ date: "2026-11-12", amount: 15.49 });
  });

  it("ignores one-off purchases and things that happen only twice", () => {
    const r = detectRecurringBills([tx("2026-09-03", 40, "Target", "Shopping"), tx("2026-10-04", 52, "Target", "Shopping")], NOW);
    expect(r.items).toHaveLength(0);
  });

  it("catches utility bills whose amount moves around, and marks them as estimates", () => {
    const amounts = [88, 112, 95, 131];
    const t = ["2026-07", "2026-08", "2026-09", "2026-10"].map((m, i) => tx(`${m}-20`, amounts[i], "XCEL ENERGY", "Bills & Utilities"));
    const r = detectRecurringBills(t, NOW);
    expect(r.items).toHaveLength(1);
    expect(r.items[0].estimated).toBe(true);
    expect(r.items[0].isSubscription).toBe(false);
  });

  it("flags a price increase on the latest charge", () => {
    const t = [...monthly("SPOTIFY", 10.99, "05", "Subscriptions", ["2026-06", "2026-07", "2026-08", "2026-09"]), tx("2026-10-05", 12.99, "SPOTIFY")];
    const r = detectRecurringBills(t, NOW);
    expect(r.items[0].priceChange).toEqual({ from: 10.99, to: 12.99 });
  });

  it("skips card payments, transfers, income and excluded rows", () => {
    const t = [
      ...monthly("CHASE CREDIT CRD AUTOPAY PAYMENT", 900, "01", "Other"),
      ...monthly("Transfer to savings", 500, "03", "Transfer"),
      ...monthly("ACME PAYROLL", -3000, "15", "Income"),
      ...monthly("Gym", 40, "09", "Health").map((x) => ({ ...x, isExcluded: true })),
    ];
    expect(detectRecurringBills(t, NOW).items).toHaveLength(0);
  });

  it("drops a subscription that stopped months ago", () => {
    const r = detectRecurringBills(monthly("OLD APP", 4.99, "10", "Subscriptions", ["2026-01", "2026-02", "2026-03", "2026-04"]), NOW);
    expect(r.items).toHaveLength(0);
  });

  it("adds every weekly occurrence in the next 30 days", () => {
    const t = ["2026-10-09", "2026-10-16", "2026-10-23", "2026-10-30"].map((d) => tx(d, 25, "Weekly Meal Kit", "Groceries"));
    const r = detectRecurringBills(t, NOW);
    expect(r.items[0].frequency).toBe("weekly");
    expect(r.upcoming.filter((u) => u.id === r.items[0].id).length).toBeGreaterThanOrEqual(4);
  });

  it("finds a yearly charge, but not from a single one", () => {
    expect(detectRecurringBills([tx("2025-11-19", 129, "ANNUAL PLAN")], NOW).items).toHaveLength(0);
    const r = detectRecurringBills([tx("2024-11-20", 129, "ANNUAL PLAN"), tx("2025-11-19", 129, "ANNUAL PLAN")], NOW);
    expect(r.items[0]?.frequency).toBe("yearly");
    expect(r.items[0]?.nextDate).toBe("2026-11-19");
  });

  it("sums what is still due this month", () => {
    const r = detectRecurringBills([...monthly("NETFLIX.COM", 15.49, "12"), ...monthly("Rent Co", 1500, "01", "Bills & Utilities"), ...monthly("Gym Club", 40, "28", "Health")], NOW);
    // Netflix (12th) and the gym (28th) are still ahead in November; rent (1st) already went out.
    expect(r.dueThisMonth).toBeCloseTo(15.49 + 40, 2);
  });
});

describe("nextDue", () => {
  it("clamps month ends", () => {
    expect(nextDue("2026-01-31", "monthly", "2026-02-10")).toBe("2026-02-28");
  });
});
