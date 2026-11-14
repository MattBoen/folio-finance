import { AttemptLimiter, WINDOW_MS, currentCode, resetCode, verifyResetCode } from "../src/services/password-reset.js";

const T0 = Date.UTC(2026, 10, 6, 12, 0, 0);

describe("password reset codes", () => {
  it("makes a 6-digit code that verifies right away", () => {
    const code = currentCode("a@b.com", "hash1", T0);
    expect(code).toMatch(/^\d{6}$/);
    expect(verifyResetCode("a@b.com", "hash1", code, T0)).toBe(true);
  });

  it("still works in the next 15 minutes, then expires", () => {
    const code = currentCode("a@b.com", "hash1", T0);
    expect(verifyResetCode("a@b.com", "hash1", code, T0 + WINDOW_MS)).toBe(true);
    expect(verifyResetCode("a@b.com", "hash1", code, T0 + 3 * WINDOW_MS)).toBe(false);
  });

  it("stops working once the password changes (so a code is single-use)", () => {
    const code = currentCode("a@b.com", "hash1", T0);
    expect(verifyResetCode("a@b.com", "hash2-new-password", code, T0)).toBe(false);
  });

  it("is tied to one account and rejects wrong or malformed codes", () => {
    const code = currentCode("a@b.com", "hash1", T0);
    expect(verifyResetCode("other@b.com", "hash1", code, T0)).toBe(false);
    const wrong = String((Number(code) + 1) % 1_000_000).padStart(6, "0");
    expect(verifyResetCode("a@b.com", "hash1", wrong, T0)).toBe(false);
    expect(verifyResetCode("a@b.com", "hash1", "12345", T0)).toBe(false);
    expect(verifyResetCode("a@b.com", "hash1", "abcdef", T0)).toBe(false);
  });

  it("gives different codes in different windows", () => {
    expect(resetCode("a@b.com", "h", 1)).not.toBe(resetCode("a@b.com", "h", 2));
  });
});

describe("AttemptLimiter", () => {
  it("allows a few tries, blocks the rest, and recovers after the window", () => {
    const l = new AttemptLimiter(3, 1000);
    expect([l.take("x", 0), l.take("x", 1), l.take("x", 2), l.take("x", 3)]).toEqual([true, true, true, false]);
    expect(l.take("y", 3)).toBe(true);
    expect(l.take("x", 1500)).toBe(true);
  });
  it("clear() forgives", () => {
    const l = new AttemptLimiter(1, 1000);
    l.take("x", 0);
    expect(l.take("x", 1)).toBe(false);
    l.clear("x");
    expect(l.take("x", 2)).toBe(true);
  });
});
