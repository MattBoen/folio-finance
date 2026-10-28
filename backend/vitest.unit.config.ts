import { defineConfig } from "vitest/config";

// Pure-function tests only: no database, no setup file.
export default defineConfig({
  test: { environment: "node", globals: true, include: ["tests/insights.test.ts", "tests/vehicles.test.ts", "tests/categories.test.ts", "tests/account-delete.test.ts"] },
});
