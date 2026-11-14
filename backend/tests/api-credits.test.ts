import { describe, it, expect } from "vitest";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// Paid Anthropic API credits are for Ask Folio ONLY. If this test fails, something new is spending credits:
// move it to a free source (bank data, Apple Maps, plain rules) instead of loosening this test.

const SRC = join(__dirname, "..", "src");
const files = (dir: string): string[] =>
  readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    return statSync(p).isDirectory() ? files(p) : p.endsWith(".ts") ? [p] : [];
  });
const rel = (p: string) => p.slice(SRC.length + 1).replace(/\\/g, "/");
const using = (re: RegExp) => files(SRC).filter((p) => re.test(readFileSync(p, "utf8"))).map(rel).sort();

describe("API credits are only for Ask Folio", () => {
  it("only the Anthropic client file reads the API key", () => {
    expect(using(/ANTHROPIC_API_KEY|ASK_API_KEY/)).toEqual(["services/anthropic.ts"]);
  });
  it("only the Anthropic client file imports the SDK", () => {
    expect(using(/@anthropic-ai\/sdk/)).toEqual(["services/anthropic.ts"]);
  });
  it("only the Ask route asks for the client", () => {
    expect(using(/getAnthropic\s*\(/)).toEqual(["routes/ask.ts", "services/anthropic.ts"]);
  });
  it("nothing else talks to the Anthropic API directly", () => {
    expect(using(/api\.anthropic\.com/)).toEqual([]);
  });
});
