import { and, eq, isNull, sql } from "drizzle-orm";
import { db } from "../db/client.js";
import { accounts, transactions, netWorthSnapshots } from "../db/schema.js";

const MAX_DAYS = 1095;

export interface BackfillAccount {
  id: string;
  type: string;
  balance: number;
}

export interface BackfillTxn {
  accountId: string;
  date: string; // YYYY-MM-DD
  amount: number; // Plaid sign: positive = money out of a bank account / more owed on a card
}

export interface DayTotals {
  date: string;
  totalAssets: number;
  totalLiabilities: number;
  netWorth: number;
}

const isLiability = (type: string) => type === "credit" || type === "loan";

function addDays(date: string, n: number): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/**
 * Walks each account's balance backwards from today using its transactions.
 * Bank and card accounts move with their transactions; accounts that have none (investments,
 * manual assets like a car) are held at today's value because there is nothing to rebuild them from.
 * Returns one row per day from the earliest transaction up to (not including) `today`, oldest first.
 */
export function rebuildHistory(
  accts: BackfillAccount[],
  txns: BackfillTxn[],
  today: string
): DayTotals[] {
  const tracked = new Set(txns.map((t) => t.accountId));
  const earliest = txns.reduce((min, t) => (t.date < min ? t.date : min), today);
  const floor = addDays(today, -MAX_DAYS);
  // one day before the first transaction shows the balance the account opened with
  const opening = addDays(earliest, -1);
  const start = opening < floor ? floor : opening;
  if (start >= today) return [];

  // amount of transactions dated on each day, per account
  const byDay = new Map<string, Map<string, number>>();
  for (const t of txns) {
    if (t.date >= today) continue;
    const day = byDay.get(t.date) ?? new Map<string, number>();
    day.set(t.accountId, (day.get(t.accountId) ?? 0) + t.amount);
    byDay.set(t.date, day);
  }

  // balance at the END of `cursor` day; the end of yesterday is today's balance minus today's activity
  const balances = new Map(accts.map((a) => [a.id, a.balance]));
  const todayActivity = new Map<string, number>();
  for (const t of txns) {
    if (t.date >= today) todayActivity.set(t.accountId, (todayActivity.get(t.accountId) ?? 0) + t.amount);
  }
  for (const a of accts) {
    if (!tracked.has(a.id)) continue;
    const moved = todayActivity.get(a.id) ?? 0;
    balances.set(a.id, a.balance + (isLiability(a.type) ? -moved : moved));
  }

  const out: DayTotals[] = [];
  for (let day = addDays(today, -1); day >= start; day = addDays(day, -1)) {
    let assets = 0;
    let liabilities = 0;
    for (const a of accts) {
      const b = balances.get(a.id) ?? 0;
      if (isLiability(a.type)) liabilities += b;
      else assets += b;
    }
    out.push({ date: day, totalAssets: assets, totalLiabilities: liabilities, netWorth: assets - liabilities });

    // step back one day: undo that day's activity to get the previous day's closing balance
    const activity = byDay.get(day);
    if (activity) {
      for (const a of accts) {
        const moved = activity.get(a.id);
        if (!moved) continue;
        balances.set(a.id, (balances.get(a.id) ?? 0) + (isLiability(a.type) ? -moved : moved));
      }
    }
  }
  return out.reverse();
}

/** Fills the days before Folio started recording with balances rebuilt from transactions. Never touches real snapshots. */
export async function backfillSnapshots(userId: string): Promise<number> {
  const userAccounts = await db
    .select({ id: accounts.id, type: accounts.type, balance: accounts.balanceCurrent })
    .from(accounts)
    .where(and(eq(accounts.userId, userId), eq(accounts.isHidden, false), isNull(accounts.deletedAt)));
  if (userAccounts.length === 0) return 0;

  const rows = await db
    .select({ accountId: transactions.accountId, date: transactions.date, amount: transactions.amount })
    .from(transactions)
    .where(and(eq(transactions.userId, userId), eq(transactions.isPending, false), isNull(transactions.deletedAt)));
  if (rows.length === 0) return 0;

  const today = new Date().toISOString().slice(0, 10);
  const days = rebuildHistory(
    userAccounts.map((a) => ({ id: a.id, type: a.type, balance: parseFloat(a.balance ?? "0") })),
    rows.map((r) => ({ accountId: r.accountId, date: r.date, amount: parseFloat(r.amount) })),
    today
  );
  if (days.length === 0) return 0;

  for (let i = 0; i < days.length; i += 500) {
    const chunk = days.slice(i, i + 500);
    await db
      .insert(netWorthSnapshots)
      .values(
        chunk.map((d) => ({
          userId,
          date: d.date,
          totalAssets: d.totalAssets.toFixed(2),
          totalLiabilities: d.totalLiabilities.toFixed(2),
          netWorth: d.netWorth.toFixed(2),
          invested: null, // investment history can't be rebuilt from bank transactions
          estimated: true,
        }))
      )
      .onConflictDoUpdate({
        target: [netWorthSnapshots.userId, netWorthSnapshots.date],
        set: {
          totalAssets: sql`excluded.total_assets`,
          totalLiabilities: sql`excluded.total_liabilities`,
          netWorth: sql`excluded.net_worth`,
        },
        // only refresh days we estimated earlier; real recorded days stay as they are
        setWhere: eq(netWorthSnapshots.estimated, true),
      });
  }
  return days.length;
}
