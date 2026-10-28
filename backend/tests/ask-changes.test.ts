/** Ask Folio's confirmed changes against a real database: they apply, stay scoped to the customer, and refuse what isn't allowed. */
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { eq, and } from "drizzle-orm";
import { db } from "../src/db/client.js";
import { users, accounts, transactions, vehicles, plaidItems } from "../src/db/schema.js";
import { applyChanges, describeChange } from "../src/services/ask-changes.js";

let a = "", b = "";
let carId = "", cashId = "", bankId = "", txId = "", otherAcct = "";

beforeAll(async () => {
  const stamp = Date.now();
  [{ id: a }] = await db.insert(users).values({ email: `chg-a-${stamp}@example.com`, passwordHash: "x" }).returning({ id: users.id });
  [{ id: b }] = await db.insert(users).values({ email: `chg-b-${stamp}@example.com`, passwordHash: "x" }).returning({ id: users.id });
  [{ id: carId }] = await db.insert(accounts).values({ userId: a, name: "Vehicle", type: "other", subtype: "vehicle", balanceCurrent: "20000.00" }).returning({ id: accounts.id });
  await db.insert(vehicles).values({ userId: a, accountId: carId, vin: "", year: 2022, make: "Ford", model: "Bronco", trim: "Big Bend", miles: 30000 });
  [{ id: cashId }] = await db.insert(accounts).values({ userId: a, name: "Cash", type: "depository", subtype: "checking", balanceCurrent: "100.00" }).returning({ id: accounts.id });
  const [item] = await db.insert(plaidItems).values({ userId: a, accessTokenEnc: "x", accessTokenIv: "x", itemId: `item-${stamp}` }).returning({ id: plaidItems.id });
  [{ id: bankId }] = await db.insert(accounts).values({ userId: a, plaidItemId: item.id, name: "Bank", type: "depository", subtype: "checking", balanceCurrent: "500.00" }).returning({ id: accounts.id });
  [{ id: txId }] = await db.insert(transactions).values({ userId: a, accountId: cashId, amount: "12.00", date: "2026-10-01", name: "Coffee" }).returning({ id: transactions.id });
  [{ id: otherAcct }] = await db.insert(accounts).values({ userId: b, name: "Theirs", type: "depository", balanceCurrent: "1.00" }).returning({ id: accounts.id });
});

afterAll(async () => {
  await db.delete(users).where(eq(users.id, a));
  await db.delete(users).where(eq(users.id, b));
});

describe("ask changes", () => {
  it("applies a mixed batch: car value and yearly miles, rename, exclude", async () => {
    const n = await applyChanges(a, [
      { op: "update_vehicle", accountId: carId, value: 38000, annualMiles: 9000 },
      { op: "update_account", accountId: carId, name: "Bronco Fund" },
      { op: "set_transactions_excluded", transactionIds: [txId], excluded: true },
    ]);
    expect(n).toBe(3);
    const [acct] = await db.select().from(accounts).where(eq(accounts.id, carId));
    expect(acct.name).toBe("Bronco Fund");
    expect(parseFloat(acct.balanceCurrent!)).toBe(38000);
    const [v] = await db.select().from(vehicles).where(eq(vehicles.accountId, carId));
    expect(v.annualMiles).toBe(9000);
    expect(v.valuationSource).toBe("manual");
    const [t] = await db.select().from(transactions).where(eq(transactions.id, txId));
    expect(t.isExcluded).toBe(true);
  });

  it("re-estimates a car from its details", async () => {
    await applyChanges(a, [{ op: "update_vehicle", accountId: carId, miles: 45000, reestimate: true }]);
    const [acct] = await db.select().from(accounts).where(eq(accounts.id, carId));
    expect(parseFloat(acct.balanceCurrent!)).not.toBe(38000);
    expect(parseFloat(acct.balanceCurrent!)).toBeGreaterThan(5000);
  });

  it("adds a transaction and moves a manual balance, recategorizes, and sets income", async () => {
    await applyChanges(a, [
      { op: "add_transaction", accountId: cashId, kind: "expense", amount: 40, date: "2026-10-02", name: "Gas", category: "Transport" },
      { op: "edit_transaction", transactionId: txId, name: "Blue Bottle", category: "Dining", note: "latte" },
      { op: "set_income", monthly: 6000 },
    ]);
    const [cash] = await db.select().from(accounts).where(eq(accounts.id, cashId));
    expect(parseFloat(cash.balanceCurrent!)).toBe(60);
    const [t] = await db.select().from(transactions).where(eq(transactions.id, txId));
    expect(t.userName).toBe("Blue Bottle");
    expect(t.note).toBe("latte");
  });

  it("refuses to touch another customer's data", async () => {
    await expect(applyChanges(a, [{ op: "update_account", accountId: otherAcct, name: "Mine now" }])).rejects.toThrow();
    await expect(describeChange(a, { op: "delete_account", accountId: otherAcct })).rejects.toThrow();
  });

  it("won't change a bank-fed balance or delete a bank-fed account", async () => {
    await expect(describeChange(a, { op: "update_account", accountId: bankId, balance: 1 })).rejects.toThrow(/updates by itself/);
    await expect(applyChanges(a, [{ op: "delete_account", accountId: bankId }])).rejects.toThrow();
    await applyChanges(a, [{ op: "update_account", accountId: bankId, name: "My Bank", hidden: true }]);
    const [acct] = await db.select().from(accounts).where(and(eq(accounts.id, bankId)));
    expect(acct.name).toBe("My Bank");
    expect(acct.isHidden).toBe(true);
  });

  it("is all or nothing", async () => {
    await expect(applyChanges(a, [
      { op: "update_account", accountId: cashId, name: "Changed" },
      { op: "update_account", accountId: otherAcct, name: "Nope" },
    ])).rejects.toThrow();
    const [cash] = await db.select().from(accounts).where(eq(accounts.id, cashId));
    expect(cash.name).toBe("Cash");
  });
});
