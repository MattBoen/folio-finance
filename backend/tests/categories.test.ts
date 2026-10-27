import { normalizeCategory, isCardPayment } from "../src/services/categories.js";

describe("normalizeCategory", () => {
  it.each([
    ["FOOD_AND_DRINK_GROCERIES", "Groceries"],
    ["Food & Drink", "Dining"],
    ["Restaurants", "Dining"],
    ["Transportation", "Transport"],
    ["RENT_AND_UTILITIES", "Bills & Utilities"],
    ["Health & Fitness", "Health"],
    ["Personal Care", "Health"],
    ["TRANSFER_IN", "Transfer"],
    ["LOAN_PAYMENTS", "Transfer"],
    ["Income", "Income"],
    ["General Merchandise", "Shopping"],
    ["Fees", "Other"],
    ["Services", "Other"],
    ["something unheard of", "Other"],
  ])("%s -> %s", (raw, expected) => expect(normalizeCategory(raw)).toBe(expected));

  it("handles empty input", () => {
    expect(normalizeCategory(null)).toBe("Other");
    expect(normalizeCategory(undefined)).toBe("Other");
  });
});

describe("isCardPayment", () => {
  it("flags card and loan payment descriptions but not purchases", () => {
    expect(isCardPayment("AUTOPAY PAYMENT - THANK YOU")).toBe(true);
    expect(isCardPayment("Chase Credit Card Payment")).toBe(true);
    expect(isCardPayment("Whole Foods Market")).toBe(false);
  });
});
