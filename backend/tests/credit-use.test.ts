import { summarizeCredit } from "../src/services/credit-use.js";

const card = (id: string, balance: number, reported: number | null) => ({ id, name: id, institution: null, balance, reported });

describe("summarizeCredit", () => {
  it("uses the bank's limit, and yours when you've typed one", () => {
    const r = summarizeCredit([card("a", 500, 5000), card("b", 1000, null)], { b: 4000 });
    expect(r.cards[0]).toMatchObject({ limit: 5000, limitSource: "bank", used: 0.1 });
    expect(r.cards[1]).toMatchObject({ limit: 4000, limitSource: "you", used: 0.25 });
    expect(r.rate).toBe(0.17);
    expect(r.missing).toBe(0);
  });
  it("leaves cards without any limit out of the total", () => {
    const r = summarizeCredit([card("a", 500, 2000), card("b", 900, null)], {});
    expect(r).toMatchObject({ balance: 500, limit: 2000, rate: 0.25, missing: 1 });
  });
  it("has no rate with no limits at all", () => {
    expect(summarizeCredit([card("a", 100, null)], {}).rate).toBeNull();
  });
});
