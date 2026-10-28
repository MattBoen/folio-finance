import { describe, it, expect, afterEach } from "vitest";
import { encryptToken, decryptToken } from "../src/services/encryption.js";

const original = process.env.ENCRYPTION_KEY;
afterEach(() => { process.env.ENCRYPTION_KEY = original; });

describe("token encryption", () => {
  it("round-trips with a 64-char hex key", () => {
    process.env.ENCRYPTION_KEY = "ab".repeat(32);
    const { enc, iv } = encryptToken("access-production-123");
    expect(decryptToken(enc, iv)).toBe("access-production-123");
  });

  it("round-trips with a generated non-hex key (what the host dashboard produces)", () => {
    process.env.ENCRYPTION_KEY = "kF3p9QzXv2LmN8rT1yB6wHcJd0sUaEoI4gVnRb7Z5Mk=";
    const { enc, iv } = encryptToken("access-production-456");
    expect(decryptToken(enc, iv)).toBe("access-production-456");
  });

  it("still fails clearly when no key is set", () => {
    delete process.env.ENCRYPTION_KEY;
    expect(() => encryptToken("x")).toThrow(/ENCRYPTION_KEY/);
  });
});
