// Pure functions: turn raw positions into what the Investing tab shows. No database or network, so every rule is testable.
import type { HoldingDetail } from "./investment-history.js";

export interface HoldingRow {
  accountId: string;
  ticker: string | null;
  name: string;
  kind: string;
  quantity: number;
  price: number;
  value: number;
  /** Gain or loss in dollars and percent, only when the bank reports what was paid. */
  gain: number | null;
  gainPercent: number | null;
  /** Share of all invested money (0-100). */
  weight: number;
}

export interface HoldingsSummary {
  holdings: HoldingRow[];
  total: number;
  /** Totals only over positions where the cost is known, so the gain is never overstated. */
  gain: number | null;
  gainPercent: number | null;
  coveredValue: number;
  byKind: { kind: string; value: number; percent: number }[];
}

const r2 = (n: number) => Math.round(n * 100) / 100;
const KIND_LABEL: Record<string, string> = { equity: "Stocks", etf: "ETFs", "mutual fund": "Mutual funds", "fixed income": "Bonds", cash: "Cash", derivative: "Options", cryptocurrency: "Crypto" };
export const kindLabel = (k: string) => KIND_LABEL[k] ?? "Other";

export function summarizeHoldings(raw: HoldingDetail[]): HoldingsSummary {
  const rows = raw.filter((h) => Number.isFinite(h.value) && Math.abs(h.value) >= 0.005);
  const total = rows.reduce((t, h) => t + h.value, 0);

  const holdings: HoldingRow[] = rows
    .map((h) => {
      const known = h.costBasis != null && h.costBasis > 0 && h.kind !== "cash";
      const gain = known ? h.value - (h.costBasis as number) : null;
      return {
        accountId: h.accountId,
        ticker: h.ticker,
        name: h.name,
        kind: h.kind,
        quantity: h.quantity,
        price: r2(h.price),
        value: r2(h.value),
        gain: gain == null ? null : r2(gain),
        gainPercent: gain == null ? null : r2((gain / (h.costBasis as number)) * 100),
        weight: total > 0 ? r2((h.value / total) * 100) : 0,
      };
    })
    .sort((a, b) => b.value - a.value);

  const known = rows.filter((h) => h.costBasis != null && h.costBasis > 0 && h.kind !== "cash");
  const paid = known.reduce((t, h) => t + (h.costBasis as number), 0);
  const worth = known.reduce((t, h) => t + h.value, 0);
  const gain = known.length ? worth - paid : null;

  const kinds = new Map<string, number>();
  for (const h of rows) kinds.set(h.kind, (kinds.get(h.kind) ?? 0) + h.value);
  const byKind = [...kinds.entries()]
    .map(([kind, value]) => ({ kind: kindLabel(kind), value: r2(value), percent: total > 0 ? r2((value / total) * 100) : 0 }))
    .sort((a, b) => b.value - a.value);

  return {
    holdings,
    total: r2(total),
    gain: gain == null ? null : r2(gain),
    gainPercent: gain == null || paid <= 0 ? null : r2((gain / paid) * 100),
    coveredValue: r2(worth),
    byKind,
  };
}
