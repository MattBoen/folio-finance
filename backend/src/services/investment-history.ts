import { and, eq, isNull, inArray, sql } from "drizzle-orm";
import { db } from "../db/client.js";
import { accounts, plaidItems, securityPrices, priceFetches } from "../db/schema.js";
import { plaid } from "./plaid-client.js";
import { decryptToken } from "./encryption.js";

// ── Pure rebuild ─────────────────────────────────────────────────────────────

export interface SecurityInfo {
  ticker: string | null;
  isCash: boolean;
  /** Price to use when no history exists for the ticker. */
  fallbackPrice: number;
}
export interface HoldingNow {
  accountId: string;
  key: string;
  quantity: number;
}
export interface InvTxn {
  accountId: string;
  key: string | null;
  date: string; // YYYY-MM-DD
  quantity: number; // shares added (buy) or removed (sell, negative)
  amount: number; // Plaid sign: positive = cash leaves the account
}
/** ticker -> closes sorted oldest first */
export type PriceTable = Map<string, { date: string; close: number }[]>;

export function priceOn(table: PriceTable, ticker: string | null, date: string, fallback: number): number {
  if (!ticker) return fallback;
  const series = table.get(ticker);
  if (!series || series.length === 0) return fallback;
  if (date < series[0].date) return series[0].close;
  let lo = 0;
  let hi = series.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (series[mid].date <= date) lo = mid;
    else hi = mid - 1;
  }
  return series[lo].close;
}

/**
 * Value of the given accounts' investments at the close of each day in `days`.
 * Starts from today's holdings and undoes buys, sells and cash movements going backwards,
 * pricing each position with that day's close.
 */
export function rebuildInvested(
  securities: Map<string, SecurityInfo>,
  holdings: HoldingNow[],
  txns: InvTxn[],
  prices: PriceTable,
  days: string[]
): Map<string, number> {
  const qty = new Map<string, number>(); // `${account}|${key}`
  const cash = new Map<string, number>(); // account -> cash balance
  for (const h of holdings) {
    const s = securities.get(h.key);
    if (s?.isCash) cash.set(h.accountId, (cash.get(h.accountId) ?? 0) + h.quantity * s.fallbackPrice);
    else qty.set(`${h.accountId}|${h.key}`, h.quantity);
  }

  const sorted = [...txns].sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : 0)); // newest first
  let next = 0;
  const out = new Map<string, number>();

  for (const day of [...days].sort().reverse()) {
    while (next < sorted.length && sorted[next].date > day) {
      const t = sorted[next++];
      cash.set(t.accountId, (cash.get(t.accountId) ?? 0) + t.amount);
      if (t.key && !securities.get(t.key)?.isCash) {
        const k = `${t.accountId}|${t.key}`;
        qty.set(k, (qty.get(k) ?? 0) - t.quantity);
      }
    }
    let total = 0;
    for (const v of cash.values()) total += v;
    for (const [k, q] of qty) {
      if (Math.abs(q) < 1e-9) continue;
      const s = securities.get(k.slice(k.indexOf("|") + 1));
      if (!s) continue;
      total += q * priceOn(prices, s.ticker, day, s.fallbackPrice);
    }
    out.set(day, total);
  }
  return out;
}

// ── Prices (Yahoo Finance chart endpoint, no key; cached in the database) ────

const PRICE_TTL_MS = 20 * 60 * 60 * 1000;
const RETRY_FAILED_MS = 24 * 60 * 60 * 1000;

async function fetchYahooCloses(ticker: string, from: string): Promise<{ date: string; close: number }[]> {
  const p1 = Math.floor(Date.parse(`${from}T00:00:00Z`) / 1000) - 7 * 86400;
  const p2 = Math.floor(Date.now() / 1000) + 86400;
  const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(ticker)}?period1=${p1}&period2=${p2}&interval=1d`;
  const res = await fetch(url, { headers: { "User-Agent": "Mozilla/5.0" }, signal: AbortSignal.timeout(10_000) });
  if (!res.ok) throw new Error(`Yahoo ${res.status}`);
  const body: any = await res.json();
  const r = body?.chart?.result?.[0];
  const ts: number[] = r?.timestamp ?? [];
  const closes: (number | null)[] = r?.indicators?.quote?.[0]?.close ?? [];
  const out: { date: string; close: number }[] = [];
  ts.forEach((t, i) => {
    const c = closes[i];
    if (c != null && Number.isFinite(c)) out.push({ date: new Date(t * 1000).toISOString().slice(0, 10), close: c });
  });
  return out;
}

/** Makes sure each ticker has closes cached back to `from`, then returns them all. Tickers Yahoo doesn't know are left out. */
export async function loadPrices(tickers: string[], from: string): Promise<PriceTable> {
  const unique = [...new Set(tickers)];
  if (unique.length === 0) return new Map();
  const fetched = await db.select().from(priceFetches).where(inArray(priceFetches.ticker, unique));
  const meta = new Map(fetched.map((f) => [f.ticker, f]));
  const now = Date.now();

  for (const ticker of unique) {
    const m = meta.get(ticker);
    const age = m ? now - m.fetchedAt.getTime() : Infinity;
    const coversFrom = m?.ok && m.fromDate <= from;
    if (m && age < (m.ok ? PRICE_TTL_MS : RETRY_FAILED_MS) && (coversFrom || !m.ok)) continue;
    try {
      const rows = await fetchYahooCloses(ticker, from);
      for (let i = 0; i < rows.length; i += 500) {
        await db
          .insert(securityPrices)
          .values(rows.slice(i, i + 500).map((r) => ({ ticker, date: r.date, close: r.close.toFixed(6) })))
          .onConflictDoUpdate({ target: [securityPrices.ticker, securityPrices.date], set: { close: sql`excluded.close` } });
      }
      await upsertFetch(ticker, rows.length > 0, from);
    } catch (err) {
      console.warn(`[prices] ${ticker} failed:`, (err as Error).message);
      await upsertFetch(ticker, false, from);
    }
  }

  const rows = await db.select().from(securityPrices).where(inArray(securityPrices.ticker, unique)).orderBy(securityPrices.date);
  const table: PriceTable = new Map();
  for (const r of rows) {
    const list = table.get(r.ticker) ?? [];
    list.push({ date: r.date, close: parseFloat(r.close) });
    table.set(r.ticker, list);
  }
  return table;
}

async function upsertFetch(ticker: string, ok: boolean, fromDate: string) {
  await db
    .insert(priceFetches)
    .values({ ticker, ok, fromDate, fetchedAt: new Date() })
    .onConflictDoUpdate({ target: priceFetches.ticker, set: { ok, fromDate, fetchedAt: new Date() } });
}

// ── Plaid investments (cached in memory so frequent syncs don't re-bill) ─────

interface PlaidInvData {
  securities: Map<string, SecurityInfo>;
  holdings: HoldingNow[];
  txns: InvTxn[];
  accountIds: Set<string>; // our account ids that were rebuilt
}
const CACHE_TTL_MS = 6 * 60 * 60 * 1000;
const cache = new Map<string, { at: number; data: PlaidInvData | null }>();

async function fetchPlaidInvestments(userId: string): Promise<PlaidInvData | null> {
  const hit = cache.get(userId);
  if (hit && Date.now() - hit.at < CACHE_TTL_MS) return hit.data;

  const items = await db.select().from(plaidItems).where(eq(plaidItems.userId, userId));
  const ours = await db
    .select({ id: accounts.id, plaidAccountId: accounts.plaidAccountId })
    .from(accounts)
    .where(and(eq(accounts.userId, userId), eq(accounts.type, "investment"), isNull(accounts.deletedAt)));
  const idByPlaid = new Map(ours.filter((a) => a.plaidAccountId).map((a) => [a.plaidAccountId!, a.id]));

  const data: PlaidInvData = { securities: new Map(), holdings: [], txns: [], accountIds: new Set() };
  const end = new Date().toISOString().slice(0, 10);
  const startD = new Date();
  startD.setFullYear(startD.getFullYear() - 2);
  const start = startD.toISOString().slice(0, 10);

  for (const item of items) {
    try {
      const token = decryptToken(item.accessTokenEnc, item.accessTokenIv);
      const { data: h } = await plaid.investmentsHoldingsGet({ access_token: token });
      for (const s of h.securities) {
        const isCash = s.type === "cash" || s.is_cash_equivalent === true && !s.ticker_symbol;
        data.securities.set(s.security_id, {
          ticker: isCash ? null : (s.ticker_symbol ?? null),
          isCash,
          fallbackPrice: isCash ? 1 : (s.close_price ?? 0),
        });
      }
      for (const hold of h.holdings) {
        const id = idByPlaid.get(hold.account_id);
        if (!id) continue;
        data.accountIds.add(id);
        // use the bank's own price for this holding when the security record has none
        const info = data.securities.get(hold.security_id);
        if (info && !info.fallbackPrice && hold.institution_price) info.fallbackPrice = hold.institution_price;
        data.holdings.push({ accountId: id, key: hold.security_id, quantity: hold.quantity });
      }

      let offset = 0;
      for (;;) {
        const { data: t } = await plaid.investmentsTransactionsGet({
          access_token: token,
          start_date: start,
          end_date: end,
          options: { count: 500, offset },
        });
        for (const s of t.securities) {
          if (!data.securities.has(s.security_id)) {
            const isCash = s.type === "cash";
            data.securities.set(s.security_id, {
              ticker: isCash ? null : (s.ticker_symbol ?? null),
              isCash,
              fallbackPrice: isCash ? 1 : (s.close_price ?? 0),
            });
          }
        }
        for (const tx of t.investment_transactions) {
          const id = idByPlaid.get(tx.account_id);
          if (!id) continue;
          data.accountIds.add(id);
          data.txns.push({ accountId: id, key: tx.security_id ?? null, date: tx.date, quantity: tx.quantity ?? 0, amount: tx.amount ?? 0 });
        }
        offset += t.investment_transactions.length;
        if (t.investment_transactions.length === 0 || offset >= t.total_investment_transactions) break;
      }
    } catch (err: any) {
      // item without the Investments product, or not ready yet: leave its accounts flat
      const code = err?.response?.data?.error_code ?? err?.message;
      console.warn(`[investments] skipped item ${item.id}:`, code);
    }
  }

  const result = data.accountIds.size > 0 ? data : null;
  cache.set(userId, { at: Date.now(), data: result });
  return result;
}

/**
 * Rebuilt investment value per day for the accounts Plaid can give holdings for.
 * Returns null when there is nothing to rebuild. `rebuiltAccountIds` are the accounts covered.
 */
export async function investedHistory(
  userId: string,
  days: string[]
): Promise<{ byDay: Map<string, number>; rebuiltAccountIds: Set<string> } | null> {
  if (days.length === 0) return null;
  const data = await fetchPlaidInvestments(userId);
  if (!data) return null;
  const tickers: string[] = [];
  for (const s of data.securities.values()) if (s.ticker) tickers.push(s.ticker);
  const prices = await loadPrices(tickers, [...days].sort()[0]);
  const byDay = rebuildInvested(data.securities, data.holdings, data.txns, prices, days);
  return { byDay, rebuiltAccountIds: data.accountIds };
}

export function clearInvestmentCache(userId?: string) {
  if (userId) cache.delete(userId);
  else cache.clear();
}
