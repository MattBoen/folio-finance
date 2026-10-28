// S&P 500 total-return (dividends reinvested), by calendar year.
// APPROXIMATE, as of Oct 2026; rounded to the nearest basis point from published index returns.
// Recent and partial years are intentionally absent: we don't guess.
export const SP500_AS_OF = "2026-10";
export const SP500_TOTAL_RETURN_BY_YEAR: Record<number, number> = {
  2019: 31.49,
  2020: 18.4,
  2021: 28.71,
  2022: -18.11,
  2023: 26.29,
  2024: 25.02,
};

const yearStart = (y: number) => Date.UTC(y, 0, 1);
const yearEnd = (y: number) => Date.UTC(y + 1, 0, 1);

/** Total return (%) for the inclusive ISO day range [from, to], spreading each calendar year's return evenly (compounded) across its days.
 *  Returns null unless every day of the window falls inside a year we have data for. */
export function sp500ReturnBetween(from: string, to: string): number | null {
  const a = Date.parse(from), b = Date.parse(to);
  if (!Number.isFinite(a) || !Number.isFinite(b) || b < a) return null;
  const last = b + 86_400_000; // `to` is a whole day, so the window runs through its end
  let growth = 1;
  for (let y = new Date(a).getUTCFullYear(); y <= new Date(last - 1).getUTCFullYear(); y++) {
    const r = SP500_TOTAL_RETURN_BY_YEAR[y];
    if (r == null) return null;
    const start = Math.max(a, yearStart(y)), end = Math.min(last, yearEnd(y));
    if (end <= start) continue;
    const fraction = (end - start) / (yearEnd(y) - yearStart(y));
    growth *= Math.pow(1 + r / 100, fraction);
  }
  return Math.round((growth - 1) * 10000) / 100;
}

export const SP500_CAVEAT =
  "This is a rough comparison. Folio compares the change in your total net worth, which includes deposits, withdrawals and non-investment accounts, to the S&P 500's total return. It doesn't track your contributions or individual holdings, so it isn't a true measure of how your investments performed.";
