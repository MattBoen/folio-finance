import { defineConfig } from "vitest/config";

// Pure-function tests only: no database, no setup file.
export default defineConfig({
  test: { environment: "node", globals: true, include: ["tests/insights.test.ts", "tests/vehicles.test.ts", "tests/categories.test.ts", "tests/account-delete.test.ts", "tests/ask.test.ts", "tests/encryption.test.ts", "tests/recurring.test.ts", "tests/password-reset.test.ts", "tests/holdings.test.ts", "tests/api-credits.test.ts", "tests/emergency-fund.test.ts", "tests/credit-use.test.ts"] },
});
