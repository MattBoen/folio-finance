import { describe, it, expect } from "vitest";
import { rebuildInvested, priceOn, type PriceTable } from "../src/services/investment-history.js";

const securities = new Map([
  ["vti", { ticker: "VTI", isCash: false, fallbackPrice: 110 }],
  ["usd", { ticker: null, isCash: true, fallbackPrice: 1 }],
  ["old", { ticker: null, isCash: false, fallbackPrice: 5 }],
]);
const prices: PriceTable = new Map([
  ["VTI", [
    { date: "2026-10-01", close: 100 },
    { date: "2026-10-05", close: 90 },
    { date: "2026-10-10", close: 110 },
  ]],
]);

describe("priceOn", () => {
  it("uses the last close on or before the day, the first close before history, and the fallback with none", () => {
    expect(priceOn(prices, "VTI", "2026-10-07", 1)).toBe(90);
    expect(priceOn(prices, "VTI", "2026-09-01", 1)).toBe(100);
    expect(priceOn(prices, "XYZ", "2026-10-07", 7)).toBe(7);
    expect(priceOn(prices, null, "2026-10-07", 7)).toBe(7);
  });
});

describe("rebuildInvested", () => {
  it("prices past shares at past closes and undoes a buy with its cash", () => {
    // today: 10 VTI + $100 cash. On Oct 8 bought 4 VTI for $400 cash.
    const out = rebuildInvested(
      securities,
      [{ accountId: "a", key: "vti", quantity: 10 }, { accountId: "a", key: "usd", quantity: 100 }],
      [{ accountId: "a", key: "vti", date: "2026-10-08", quantity: 4, amount: 400 }],
      prices,
      ["2026-10-06", "2026-10-09"]
    );
    expect(out.get("2026-10-09")).toBe(10 * 90 + 100); // buy already happened, price still 90
    expect(out.get("2026-10-06")).toBe(6 * 90 + 500); // 6 shares, $500 cash
  });

  it("includes positions that were fully sold since", () => {
    const out = rebuildInvested(
      securities,
      [{ accountId: "a", key: "usd", quantity: 300 }],
      [{ accountId: "a", key: "vti", date: "2026-10-08", quantity: -3, amount: -300 }],
      prices,
      ["2026-10-07"]
    );
    expect(out.get("2026-10-07")).toBe(3 * 90 + 0);
  });

  it("holds a security with no price history at its fallback price", () => {
    const out = rebuildInvested(securities, [{ accountId: "a", key: "old", quantity: 2 }], [], prices, ["2026-10-03"]);
    expect(out.get("2026-10-03")).toBe(10);
  });
});
