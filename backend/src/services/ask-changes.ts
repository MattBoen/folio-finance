// Everything Ask Folio can change on the customer's behalf. It only ever proposes: nothing here runs until the
// customer taps Confirm, and every id is checked against the customer's own data before it is described or applied.
import { z } from "zod";
import { and, eq, inArray, isNull, sql } from "drizzle-orm";
import { db } from "../db/client.js";
import { accounts, transactions, userSettings, vehicles } from "../db/schema.js";
import { findOrCreateCategory } from "./category-db.js";
import { normalizeCategory } from "./categories.js";
import { estimateManual, projectedMiles } from "./vehicles.js";
import { takeNetWorthSnapshot } from "./plaid-sync.js";

const id = z.string().uuid();
const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine((s) => !Number.isNaN(Date.parse(s)), "not a real date");

export const ACCOUNT_KINDS = ["checking", "savings", "credit_card", "loan", "investment", "physical_asset"] as const;

export const changeOp = z.discriminatedUnion("op", [
  z.object({ op: z.literal("update_account"), accountId: id, name: z.string().min(1).max(80).optional(), balance: z.number().min(0).max(1_000_000_000).optional(), hidden: z.boolean().optional() }),
  z.object({ op: z.literal("delete_account"), accountId: id }),
  z.object({ op: z.literal("update_vehicle"), accountId: id, value: z.number().min(0).max(100_000_000).optional(), miles: z.number().int().min(0).max(2_000_000).optional(), annualMiles: z.number().int().min(0).max(200_000).optional(), reestimate: z.boolean().optional() }),
  z.object({ op: z.literal("set_transactions_excluded"), transactionIds: z.array(id).min(1).max(50), excluded: z.boolean() }),
  z.object({ op: z.literal("edit_transaction"), transactionId: id, name: z.string().min(1).max(100).optional(), category: z.string().min(1).max(60).optional(), note: z.string().max(500).optional() }),
  z.object({ op: z.literal("add_transaction"), accountId: id, kind: z.enum(["expense", "income"]), amount: z.number().positive().max(100_000_000), date: isoDate, name: z.string().min(1).max(100), category: z.string().min(1).max(60).optional() }),
  z.object({ op: z.literal("create_account"), name: z.string().min(1).max(80), kind: z.enum(ACCOUNT_KINDS), balance: z.number().min(0).max(1_000_000_000) }),
  z.object({ op: z.literal("set_income"), monthly: z.number().min(0).max(100_000_000).nullable() }),
]);
export type ChangeOp = z.infer<typeof changeOp>;

const usd = (n: number) => "$" + Math.abs(n).toLocaleString("en-US", { minimumFractionDigits: n % 1 ? 2 : 0, maximumFractionDigits: 2 });

async function ownAccount(userId: string, accountId: string) {
  const [a] = await db
    .select({ id: accounts.id, name: accounts.name, type: accounts.type, plaidItemId: accounts.plaidItemId, balance: accounts.balanceCurrent })
    .from(accounts)
    .where(and(eq(accounts.id, accountId), eq(accounts.userId, userId), isNull(accounts.deletedAt)));
  if (!a) throw new Error("That account wasn't found.");
  const [car] = await db.select({ id: vehicles.id }).from(vehicles).where(and(eq(vehicles.accountId, accountId), eq(vehicles.userId, userId)));
  return { ...a, isVehicle: car != null };
}

async function ownTransactions(userId: string, ids: string[]) {
  const rows = await db
    .select({ id: transactions.id, name: transactions.name, userName: transactions.userName, amount: transactions.amount, date: transactions.date })
    .from(transactions)
    .where(and(inArray(transactions.id, ids), eq(transactions.userId, userId), isNull(transactions.deletedAt)));
  if (rows.length !== new Set(ids).size) throw new Error("One of those transactions wasn't found.");
  return rows;
}

/** Checks one change against the customer's data and says what it would do, in plain English. Throws if it isn't allowed. */
export async function describeChange(userId: string, op: ChangeOp): Promise<string> {
  switch (op.op) {
    case "update_account": {
      const a = await ownAccount(userId, op.accountId);
      const parts: string[] = [];
      if (op.name && op.name !== a.name) parts.push(`rename to "${op.name}"`);
      if (op.balance !== undefined) {
        if (a.plaidItemId) throw new Error(`${a.name} is connected to a bank, so its balance updates by itself.`);
        parts.push(`set the ${a.isVehicle ? "value" : "balance"} to ${usd(op.balance)}`);
      }
      if (op.hidden !== undefined) parts.push(op.hidden ? "hide it from your totals" : "show it in your totals again");
      if (parts.length === 0) throw new Error("Nothing to change on that account.");
      return `${a.name}: ${parts.join(", ")}`;
    }
    case "delete_account": {
      const a = await ownAccount(userId, op.accountId);
      if (a.plaidItemId) throw new Error(`${a.name} is connected to a bank and can only be hidden.`);
      return `Delete ${a.name} (${usd(parseFloat(a.balance ?? "0"))})`;
    }
    case "update_vehicle": {
      const a = await ownAccount(userId, op.accountId);
      if (!a.isVehicle) throw new Error(`${a.name} isn't a car.`);
      const parts: string[] = [];
      if (op.value !== undefined) parts.push(`value ${usd(op.value)}`);
      if (op.miles !== undefined) parts.push(`${op.miles.toLocaleString("en-US")} miles on the odometer`);
      if (op.annualMiles !== undefined) parts.push(`${op.annualMiles.toLocaleString("en-US")} miles a year`);
      if (op.reestimate) parts.push("re-estimate the value");
      if (parts.length === 0) throw new Error("Nothing to change on that car.");
      return `${a.name}: ${parts.join(", ")}`;
    }
    case "set_transactions_excluded": {
      const rows = await ownTransactions(userId, op.transactionIds);
      const names = rows.slice(0, 3).map((r) => r.userName || r.name).join(", ");
      return `${op.excluded ? "Exclude" : "Include"} ${rows.length} transaction${rows.length === 1 ? "" : "s"} ${op.excluded ? "from" : "in"} spending (${names}${rows.length > 3 ? ", …" : ""})`;
    }
    case "edit_transaction": {
      const [t] = await ownTransactions(userId, [op.transactionId]);
      const parts: string[] = [];
      if (op.name) parts.push(`rename to "${op.name}"`);
      if (op.category) parts.push(`category ${normalizeCategory(op.category)}`);
      if (op.note !== undefined) parts.push(op.note ? "add a note" : "clear the note");
      if (parts.length === 0) throw new Error("Nothing to change on that transaction.");
      return `${t.userName || t.name} (${t.date}): ${parts.join(", ")}`;
    }
    case "add_transaction": {
      const a = await ownAccount(userId, op.accountId);
      return `Add ${op.kind === "income" ? "income" : "an expense"} of ${usd(op.amount)}: ${op.name}, ${op.date}, on ${a.name}`;
    }
    case "create_account":
      return `Add ${op.kind.replace("_", " ")} account "${op.name}" with ${usd(op.balance)}`;
    case "set_income":
      return op.monthly == null ? "Go back to the income Folio detects" : `Set monthly income to ${usd(op.monthly)}`;
  }
}

const KIND_TO_TYPE: Record<(typeof ACCOUNT_KINDS)[number], { type: "depository" | "credit" | "loan" | "investment" | "other"; subtype: string | null }> = {
  checking: { type: "depository", subtype: "checking" },
  savings: { type: "depository", subtype: "savings" },
  credit_card: { type: "credit", subtype: null },
  loan: { type: "loan", subtype: null },
  investment: { type: "investment", subtype: null },
  physical_asset: { type: "other", subtype: null },
};

/** Applies confirmed changes. All or nothing. */
export async function applyChanges(userId: string, ops: ChangeOp[]): Promise<number> {
  await db.transaction(async (tx) => {
    const now = new Date();
    for (const op of ops) {
      switch (op.op) {
        case "update_account": {
          const a = await ownAccount(userId, op.accountId);
          if (op.balance !== undefined && a.plaidItemId) throw new Error("Connected accounts update by themselves.");
          const set: Record<string, unknown> = { updatedAt: now };
          if (op.name) set.name = op.name;
          if (op.balance !== undefined) set.balanceCurrent = op.balance.toFixed(2);
          if (op.hidden !== undefined) set.isHidden = op.hidden;
          await tx.update(accounts).set(set).where(and(eq(accounts.id, op.accountId), eq(accounts.userId, userId)));
          if (op.balance !== undefined && a.isVehicle) await tx.update(vehicles).set({ valuationSource: "manual", valuedAt: now }).where(eq(vehicles.accountId, op.accountId));
          break;
        }
        case "delete_account": {
          const a = await ownAccount(userId, op.accountId);
          if (a.plaidItemId) throw new Error("Connected accounts can only be hidden.");
          await tx.update(accounts).set({ deletedAt: now, updatedAt: now }).where(and(eq(accounts.id, op.accountId), eq(accounts.userId, userId)));
          break;
        }
        case "update_vehicle": {
          const [v] = await tx.select().from(vehicles).where(and(eq(vehicles.accountId, op.accountId), eq(vehicles.userId, userId)));
          if (!v) throw new Error("That car wasn't found.");
          const miles = op.miles ?? v.miles;
          const annual = op.annualMiles === undefined ? v.annualMiles : op.annualMiles || null;
          let value = op.value;
          let source: "manual" | "estimate" | undefined = value !== undefined ? "manual" : undefined;
          if (op.reestimate || (value === undefined && op.miles !== undefined)) {
            const odometer = op.miles !== undefined ? miles : projectedMiles(v.miles, annual, v.valuedAt, now);
            value = estimateManual({ year: v.year, make: v.make, model: v.model, trim: v.trim, miles: odometer }, now).estimatedValue;
            source = "estimate";
          }
          await tx.update(vehicles).set({ miles, annualMiles: annual, valuedAt: now, ...(source ? { valuationSource: source } : {}) }).where(eq(vehicles.id, v.id));
          if (value !== undefined) await tx.update(accounts).set({ balanceCurrent: value.toFixed(2), updatedAt: now }).where(and(eq(accounts.id, op.accountId), eq(accounts.userId, userId)));
          break;
        }
        case "set_transactions_excluded": {
          await ownTransactions(userId, op.transactionIds);
          await tx.update(transactions).set({ isExcluded: op.excluded, updatedAt: now }).where(and(inArray(transactions.id, op.transactionIds), eq(transactions.userId, userId)));
          break;
        }
        case "edit_transaction": {
          await ownTransactions(userId, [op.transactionId]);
          const set: Record<string, unknown> = { updatedAt: now };
          if (op.name) set.userName = op.name;
          if (op.note !== undefined) set.note = op.note;
          if (op.category) set.userCategoryId = await findOrCreateCategory(normalizeCategory(op.category));
          await tx.update(transactions).set(set).where(and(eq(transactions.id, op.transactionId), eq(transactions.userId, userId)));
          break;
        }
        case "add_transaction": {
          const a = await ownAccount(userId, op.accountId);
          const signed = op.kind === "expense" ? op.amount : -op.amount;
          const categoryId = op.category ? await findOrCreateCategory(normalizeCategory(op.category)) : null;
          await tx.insert(transactions).values({ userId, accountId: a.id, amount: signed.toFixed(2), date: op.date, name: op.name, userCategoryId: categoryId });
          if (!a.plaidItemId) {
            const delta = a.type === "credit" || a.type === "loan" ? signed : -signed;
            await tx.update(accounts).set({ balanceCurrent: sql`(coalesce(${accounts.balanceCurrent}, 0) + ${delta.toFixed(2)}::numeric)`, updatedAt: now }).where(eq(accounts.id, a.id));
          }
          break;
        }
        case "create_account": {
          const m = KIND_TO_TYPE[op.kind];
          await tx.insert(accounts).values({ userId, name: op.name, type: m.type, subtype: m.subtype, balanceCurrent: op.balance.toFixed(2) });
          break;
        }
        case "set_income": {
          const value = op.monthly == null ? null : op.monthly.toFixed(2);
          await tx.insert(userSettings).values({ userId, incomeOverride: value }).onConflictDoUpdate({ target: userSettings.userId, set: { incomeOverride: value, updatedAt: now } });
          break;
        }
      }
    }
  });
  await takeNetWorthSnapshot(userId);
  return ops.length;
}
