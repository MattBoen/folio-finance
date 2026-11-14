import { summarizeHoldings } from "../src/services/holdings.js";
import type { HoldingDetail } from "../src/services/investment-history.js";

const h = (over: Partial<HoldingDetail>): HoldingDetail => ({ accountId: "a1", ticker: "VTI", name: "Vanguard Total Market", kind: "etf", quantity: 10, price: 100, value: 1000, costBasis: 800, ...over });

describe("summarizeHoldings", () => {
  it("works out gain and percent per position and in total", () => {
    const s = summarizeHoldings([h({}), h({ ticker: "AAPL", name: "Apple", kind: "equity", value: 500, costBasis: 600 })]);
    expect(s.total).toBe(1500);
    expect(s.holdings[0]).toMatchObject({ ticker: "VTI", gain: 200, gainPercent: 25 });
    expect(s.holdings[1]).toMatchObject({ ticker: "AAPL", gain: -100 });
    expect(s.gain).toBe(100);
    expect(s.gainPercent).toBe(7.14); // 100 on 1,400 paid
  });

  it("never invents a gain when the cost isn't known", () => {
    const s = summarizeHoldings([h({ costBasis: null }), h({ ticker: "BND", kind: "fixed income", value: 500, costBasis: 450 })]);
    expect(s.holdings.find((x) => x.ticker === "VTI")?.gain).toBeNull();
    expect(s.gain).toBe(50);               // only the position with a known cost
    expect(s.coveredValue).toBe(500);
    expect(s.total).toBe(1500);
  });

  it("leaves the gain empty when nothing has a cost", () => {
    const s = summarizeHoldings([h({ costBasis: null })]);
    expect(s.gain).toBeNull();
    expect(s.gainPercent).toBeNull();
  });

  it("keeps cash out of the gain and groups by kind", () => {
    const s = summarizeHoldings([h({}), h({ ticker: null, name: "Cash", kind: "cash", value: 250, price: 1, quantity: 250, costBasis: 250 })]);
    expect(s.gain).toBe(200);
    expect(s.byKind.map((k) => k.kind)).toEqual(["ETFs", "Cash"]);
    expect(s.byKind[1].percent).toBe(20);
  });

  it("sorts biggest first, weights sum to about 100, and drops empty positions", () => {
    const s = summarizeHoldings([h({ value: 100, ticker: "A" }), h({ value: 900, ticker: "B" }), h({ value: 0, ticker: "Z" })]);
    expect(s.holdings.map((x) => x.ticker)).toEqual(["B", "A"]);
    expect(s.holdings[0].weight).toBe(90);
  });

  it("handles no holdings", () => {
    expect(summarizeHoldings([])).toMatchObject({ total: 0, gain: null, holdings: [], byKind: [] });
  });
});
