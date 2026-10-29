import { describe, it, expect } from "vitest";
import { addressFromStatement, merchantKey, formatPlace } from "../src/services/merchant-places.js";

describe("addressFromStatement", () => {
  it("reads the street address off an Apple Card style line", () => {
    expect(addressFromStatement("MCDONALD'S F1234 1912 VALLEY BLUFFS DR SE MINOT 58701 ND USA", "Minot"))
      .toBe("1912 Valley Bluffs Dr SE, Minot, ND 58701");
  });

  it("finds the town after the street when the bank gave no city", () => {
    expect(addressFromStatement("CHUBS PUB 421 N UNIVERSITY DR FARGO 58102 ND USA"))
      .toBe("421 N University Dr, Fargo, ND 58102");
  });

  it("returns nothing for a line with only a town", () => {
    expect(addressFromStatement("AMAZON MKTPL*2K4 SEATTLE WA")).toBeNull();
    expect(addressFromStatement("SQ *COFFEE SHOP FARGO ND")).toBeNull();
    expect(addressFromStatement(null)).toBeNull();
  });
});

describe("merchantKey", () => {
  it("treats store-numbered spellings of one chain alike", () => {
    expect(merchantKey("MCDONALD'S F12345", null, "Fargo")).toBe(merchantKey("McDonald's #12345", null, "fargo"));
    expect(merchantKey("SQ *CHUBS PUB", null, null)).toBe(merchantKey("Chubs Pub", null, null));
  });

  it("keeps different store numbers and towns apart", () => {
    expect(merchantKey("Casey's", "3012", "Minot")).not.toBe(merchantKey("Casey's", "3013", "Minot"));
    expect(merchantKey("Casey's", null, "Minot")).not.toBe(merchantKey("Casey's", null, "Fargo"));
  });
});

describe("formatPlace", () => {
  it("only accepts a real street address", () => {
    expect(formatPlace({ address: "1912 Valley Bluffs Dr SE", city: "Minot", region: "ND", postal: "58701" }))
      .toBe("1912 Valley Bluffs Dr SE, Minot, ND 58701");
    expect(formatPlace({ address: null, city: "Minot", region: "ND", postal: null })).toBeNull();
    expect(formatPlace({ address: "Downtown", city: "Minot", region: "ND", postal: null })).toBeNull();
  });
});
