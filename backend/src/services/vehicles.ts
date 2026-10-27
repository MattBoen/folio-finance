// VIN validation, decoding (NHTSA vPIC, free) and a market-value estimate.

export interface DecodedVin {
  vin: string; year: number; make: string; model: string; trim: string | null;
  bodyClass: string; vehicleType: string; basePrice: number | null;
}

export interface Valuation { estimatedValue: number; lowValue: number; highValue: number; source: string }

const VIN_RE = /^[A-HJ-NPR-Z0-9]{17}$/; // letters I, O and Q are never used in VINs

export function normalizeVin(raw: string): string {
  return raw.replace(/\s+/g, "").toUpperCase();
}

export function isValidVinFormat(vin: string): boolean {
  return VIN_RE.test(vin);
}

const TRANSLIT: Record<string, number> = {
  A: 1, B: 2, C: 3, D: 4, E: 5, F: 6, G: 7, H: 8, J: 1, K: 2, L: 3, M: 4, N: 5, P: 7, R: 9,
  S: 2, T: 3, U: 4, V: 5, W: 6, X: 7, Y: 8, Z: 9,
};
const WEIGHTS = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];

/** North American VINs carry a check digit in position 9. Used as a typo hint only, never to reject. */
export function hasValidCheckDigit(vin: string): boolean {
  if (!isValidVinFormat(vin)) return false;
  let sum = 0;
  for (let i = 0; i < 17; i++) {
    const ch = vin[i];
    const v = /\d/.test(ch) ? Number(ch) : TRANSLIT[ch];
    sum += v * WEIGHTS[i];
  }
  const rem = sum % 11;
  return vin[8] === (rem === 10 ? "X" : String(rem));
}

// ── Offline estimate ──────────────────────────────────────────────────────────
// Original price when the decoder doesn't know it: a rough 2025-dollar MSRP by make tier,
// scaled by body style, then deflated ~3%/yr for older model years.
const PREMIUM_LUXURY = ["porsche", "land rover", "maserati", "bentley", "rolls-royce", "ferrari", "lamborghini", "aston martin", "mclaren"];
const LUXURY = ["bmw", "mercedes-benz", "mercedes", "audi", "lexus", "acura", "infiniti", "volvo", "genesis", "cadillac", "lincoln", "jaguar", "alfa romeo", "tesla"];
const BASE_PRICE = { economy: 30_000, luxury: 55_000, premium: 100_000 };

export function heuristicOriginalPrice(make: string, bodyClass: string, vehicleType: string, year: number, nowYear: number): number {
  const m = make.toLowerCase();
  let base = BASE_PRICE.economy;
  if (PREMIUM_LUXURY.some((x) => m.includes(x))) base = BASE_PRICE.premium;
  else if (LUXURY.some((x) => m.includes(x))) base = BASE_PRICE.luxury;
  const b = `${bodyClass} ${vehicleType}`.toLowerCase();
  let body = 1;
  if (/pickup|truck/.test(b)) body = 1.35;
  else if (/suv|utility|multi-purpose|mpv|crossover/.test(b)) body = 1.15;
  else if (/van/.test(b)) body = 1.1;
  else if (/sedan|hatchback|coupe|saloon|liftback/.test(b)) body = 0.9;
  const deflate = Math.pow(0.97, Math.max(0, nowYear - year));
  return base * body * deflate;
}

/** ~20% off in year one, ~15%/yr after that, never below 12% of the original price. */
export function depreciationFactor(ageYears: number): number {
  const age = Math.max(0, ageYears);
  const f = age < 1 ? 1 - 0.2 * age : 0.8 * Math.pow(0.85, age - 1);
  return Math.max(0.12, f);
}

export function estimateValue(args: {
  originalPrice: number; year: number; miles: number; nowYear: number;
}): Valuation {
  const age = Math.max(0, args.nowYear - args.year);
  const base = args.originalPrice * depreciationFactor(age);
  // $0.05 per mile against the 12,000-a-year yardstick, capped so a typo can't zero out the car
  const adjust = Math.max(-0.25 * base, Math.min(0.25 * base, (12_000 * age - args.miles) * 0.05));
  const value = Math.max(500, base + adjust);
  const spread = age <= 3 ? 0.10 : 0.12;
  const round = (n: number) => Math.round(n / 10) * 10;
  return { estimatedValue: round(value), lowValue: round(value * (1 - spread)), highValue: round(value * (1 + spread)), source: "estimate" };
}

// ── External lookups (fail soft) ──────────────────────────────────────────────

export async function decodeVin(vin: string, fetcher: typeof fetch = fetch): Promise<DecodedVin | null> {
  try {
    const res = await fetcher(`https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/${encodeURIComponent(vin)}?format=json`, {
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) return null;
    const body = (await res.json()) as { Results?: Record<string, string>[] };
    const r = body.Results?.[0];
    if (!r) return null;
    const year = parseInt(r.ModelYear, 10);
    if (!r.Make || !r.Model || !Number.isFinite(year)) return null;
    const price = parseFloat(r.BasePrice);
    return {
      vin, year, make: titleMake(r.Make), model: r.Model.trim(),
      trim: r.Trim?.trim() || null,
      bodyClass: r.BodyClass ?? "", vehicleType: r.VehicleType ?? "",
      basePrice: Number.isFinite(price) && price > 0 ? price : null,
    };
  } catch {
    return null;
  }
}

function titleMake(s: string): string {
  const t = s.trim();
  return t === t.toUpperCase() && t.length > 3 ? t[0] + t.slice(1).toLowerCase() : t;
}

/** MarketCheck price prediction (optional, needs MARKETCHECK_API_KEY). Endpoint per their public docs; unverified here. */
export async function marketCheckValue(vin: string, miles: number, apiKey: string, fetcher: typeof fetch = fetch): Promise<number | null> {
  try {
    const url = new URL("https://api.marketcheck.com/v2/predict/car/us/marketcheck_price");
    url.searchParams.set("api_key", apiKey);
    url.searchParams.set("vin", vin);
    url.searchParams.set("miles", String(miles));
    url.searchParams.set("dealer_type", "franchise");
    const res = await fetcher(url, { signal: AbortSignal.timeout(8000) });
    if (!res.ok) return null;
    const body = (await res.json()) as { marketcheck_price?: number };
    return typeof body.marketcheck_price === "number" && body.marketcheck_price > 0 ? body.marketcheck_price : null;
  } catch {
    return null;
  }
}

export async function valueVehicle(v: DecodedVin, miles: number, env: { MARKETCHECK_API_KEY?: string }, nowYear = new Date().getFullYear()): Promise<Valuation> {
  if (env.MARKETCHECK_API_KEY) {
    const price = await marketCheckValue(v.vin, miles, env.MARKETCHECK_API_KEY);
    if (price) {
      const round = (n: number) => Math.round(n / 10) * 10;
      return { estimatedValue: round(price), lowValue: round(price * 0.93), highValue: round(price * 1.07), source: "MarketCheck" };
    }
  }
  const original = v.basePrice ?? heuristicOriginalPrice(v.make, v.bodyClass, v.vehicleType, v.year, nowYear);
  return estimateValue({ originalPrice: original, year: v.year, miles, nowYear });
}
