import { describe, it, expect } from "vitest";
import { rebuildHistory } from "../src/services/snapshot-backfill.js";

describe("rebuildHistory", () => {
  it("walks a bank balance back through spending and deposits", () => {
    const days = rebuildHistory(
      [{ id: "chk", type: "depository", balance: 1000 }],
      [
        { accountId: "chk", date: "2026-10-27", amount: 50 }, // spent 50 yesterday
        { accountId: "chk", date: "2026-10-25", amount: -200 }, // deposit
      ],
      "2026-10-28"
    );
    const by = Object.fromEntries(days.map((d) => [d.date, d.netWorth]));
    expect(by["2026-10-27"]).toBe(1000);
    expect(by["2026-10-26"]).toBe(1050);
    expect(by["2026-10-25"]).toBe(1050);
    expect(by["2026-10-24"]).toBe(850);
  });

  it("treats card balances as debt that shrinks going back when you spent", () => {
    const days = rebuildHistory(
      [
        { id: "chk", type: "depository", balance: 500 },
        { id: "cc", type: "credit", balance: 300 },
      ],
      [{ accountId: "cc", date: "2026-10-27", amount: 100 }],
      "2026-10-28"
    );
    expect(days[days.length - 1].totalLiabilities).toBe(300);
    expect(days[0].totalLiabilities).toBe(200);
    expect(days[0].netWorth).toBe(300);
  });

  it("holds accounts with no transactions at today's value and ignores today", () => {
    const days = rebuildHistory(
      [{ id: "car", type: "other", balance: 20000 }, { id: "chk", type: "depository", balance: 100 }],
      [{ accountId: "chk", date: "2026-10-26", amount: 10 }, { accountId: "chk", date: "2026-10-28", amount: 5 }],
      "2026-10-28"
    );
    expect(days.at(-1)!.date).toBe("2026-10-27");
    expect(days.at(-1)!.totalAssets).toBe(20105);
    expect(days[0].totalAssets).toBe(20115);
  });
});
