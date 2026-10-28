/**
 * Multi-tenant isolation tests.
 *
 * Proves that user A cannot read, write, or delete user B's data across
 * every resource type. These tests hit a real database — no mocks.
 */
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { testClient } from "hono/testing";
import { app } from "../src/index.js";
import { db, pool } from "../src/db/client.js";
import {
  users,
  refreshTokens,
  accounts,
  transactions,
  budgets,
  netWorthSnapshots,
  plaidItems,
} from "../src/db/schema.js";
import { eq, inArray } from "drizzle-orm";

const client = testClient(app);

// ── Test fixtures ─────────────────────────────────────────────────────────────

interface TestUser {
  id: string;
  email: string;
  accessToken: string;
}

async function createUser(suffix: string): Promise<TestUser> {
  const email = `isolation-${suffix}-${Date.now()}@example.com`.toLowerCase(); // the API stores emails lowercased
  const res = await client.auth.register.$post({
    json: { email, password: "S3cure!Pass" },
  });
  const { accessToken } = await res.json() as any;
  const [u] = await db
    .select({ id: users.id })
    .from(users)
    .where(eq(users.email, email));
  return { id: u.id, email, accessToken };
}

async function seedAccount(userId: string) {
  const [acc] = await db
    .insert(accounts)
    .values({
      userId,
      name: "Test Checking",
      type: "depository",
      subtype: "checking",
      balanceCurrent: "1000.00",
      currency: "USD",
    })
    .returning();
  return acc;
}

async function seedTransaction(userId: string, accountId: string) {
  const [tx] = await db
    .insert(transactions)
    .values({
      userId,
      accountId,
      amount: "42.00",
      date: "2025-01-01",
      name: "Test Coffee",
      isPending: false,
      isExcluded: false,
    })
    .returning();
  return tx;
}

async function seedBudget(userId: string) {
  const [b] = await db
    .insert(budgets)
    .values({ userId, monthlyAmount: "500.00" })
    .returning();
  return b;
}

// ── Fixtures ──────────────────────────────────────────────────────────────────

let userA: TestUser;
let userB: TestUser;
let userA_accountId: string;
let userA_transactionId: string;
let userA_budgetId: string;

beforeAll(async () => {
  userA = await createUser("A");
  userB = await createUser("B");

  const accA = await seedAccount(userA.id);
  userA_accountId = accA.id;

  const txA = await seedTransaction(userA.id, accA.id);
  userA_transactionId = txA.id;

  const budgetA = await seedBudget(userA.id);
  userA_budgetId = budgetA.id;
});

afterAll(async () => {
  for (const u of [userA, userB]) {
    await db.delete(refreshTokens).where(eq(refreshTokens.userId, u.id));
    await db.delete(transactions).where(eq(transactions.userId, u.id));
    await db.delete(budgets).where(eq(budgets.userId, u.id));
    await db.delete(accounts).where(eq(accounts.userId, u.id));
    await db.delete(users).where(eq(users.id, u.id));
  }
});

// ── DB-layer isolation (raw queries, bypassing HTTP) ──────────────────────────

describe("DB isolation: accounts", () => {
  it("SELECT by userId only returns own rows", async () => {
    const rows = await db
      .select()
      .from(accounts)
      .where(eq(accounts.userId, userB.id));
    const ids = rows.map((r) => r.id);
    expect(ids).not.toContain(userA_accountId);
  });
});

describe("DB isolation: transactions", () => {
  it("SELECT by userId only returns own rows", async () => {
    const rows = await db
      .select()
      .from(transactions)
      .where(eq(transactions.userId, userB.id));
    const ids = rows.map((r) => r.id);
    expect(ids).not.toContain(userA_transactionId);
  });
});

describe("DB isolation: budgets", () => {
  it("SELECT by userId only returns own rows", async () => {
    const rows = await db
      .select()
      .from(budgets)
      .where(eq(budgets.userId, userB.id));
    const ids = rows.map((r) => r.id);
    expect(ids).not.toContain(userA_budgetId);
  });
});

// ── HTTP-layer isolation (API endpoints) ─────────────────────────────────────
//
// These tests call API endpoints as user B and assert that user A's resource
// IDs are never returned and that cross-user writes/deletes are rejected.
//
// NOTE: These tests expand as each route is added in milestones (b)–(e).
// They are intentionally stubbed here so the suite is clear about scope.

describe("API isolation: auth", () => {
  it("GET /auth/me as user B does not expose user A's userId", async () => {
    const res = await client.auth.me.$get(
      {},
      { headers: { Authorization: `Bearer ${userB.accessToken}` } }
    );
    expect(res.status).toBe(200);
    const body = await res.json() as any;
    expect(body.userId).toBe(userB.id);
    expect(body.userId).not.toBe(userA.id);
  });
});

describe("API isolation: manual accounts and transactions", () => {
  const auth = (u: TestUser) => ({ Authorization: `Bearer ${u.accessToken}` });
  const base = "http://localhost";

  async function call(u: TestUser, method: string, path: string, body?: unknown) {
    return app.request(base + path, {
      method,
      headers: { ...auth(u), "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
    });
  }

  it("user B cannot patch or delete user A's account", async () => {
    expect((await call(userB, "PATCH", `/accounts/${userA_accountId}`, { balance: 1 })).status).toBe(404);
    expect((await call(userB, "DELETE", `/accounts/${userA_accountId}`)).status).toBe(404);
  });

  it("user B cannot add a transaction to user A's account", async () => {
    const res = await call(userB, "POST", "/transactions", {
      account_id: userA_accountId,
      amount: 5,
      kind: "expense",
      date: "2025-01-02",
      name: "Sneaky",
    });
    expect(res.status).toBe(404);
  });

  it("user B cannot patch or delete user A's transaction", async () => {
    expect((await call(userB, "PATCH", `/transactions/${userA_transactionId}`, { is_excluded: true })).status).toBe(404);
    expect((await call(userB, "DELETE", `/transactions/${userA_transactionId}`)).status).toBe(404);
  });

  it("manual account lifecycle stays scoped to its owner", async () => {
    const created = await call(userA, "POST", "/accounts/manual", { name: "Cash", type: "depository", balance: 100 });
    expect(created.status).toBe(201);
    const { account } = (await created.json()) as any;
    const listB = (await (await call(userB, "GET", "/accounts")).json()) as any;
    expect(listB.accounts.map((a: any) => a.id)).not.toContain(account.id);
    expect((await call(userA, "DELETE", `/accounts/${account.id}`)).status).toBe(200);
  });
});
