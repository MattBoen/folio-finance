// VIN validation, decoding (NHTSA vPIC, free) and a market-value estimate.

export interface DecodedVin {
  vin: string; year: number; make: string; model: string;
  /** Set only when the decoder names exactly one trim. */
  trim: string | null;
  /** Candidate trims when the decoder can't tell which one this VIN is. */
  trims: string[];
  /** e.g. "4-door SUV · 2.3L 4-cyl · AWD" */
  details: string | null;
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

export type Retention = "exceptional" | "high" | "standard" | "low";

// First-year loss and yearly loss for years 2-3. After year 3 the yearly loss eases to half, because older cars keep
// settling toward a floor instead of falling at the same rate forever. Never below 12% of the original price.
const RETENTION: Record<Retention, { y1: number; yr: number }> = {
  exceptional: { y1: 0.05, yr: 0.05 },
  high: { y1: 0.10, yr: 0.07 },
  standard: { y1: 0.20, yr: 0.15 },
  low: { y1: 0.25, yr: 0.18 },
};

export function depreciationFactor(ageYears: number, tier: Retention = "standard"): number {
  const { y1, yr } = RETENTION[tier];
  const age = Math.max(0, ageYears);
  let f: number;
  if (age < 1) f = 1 - y1 * age;
  else {
    f = (1 - y1) * Math.pow(1 - yr, Math.min(age, 3) - 1);
    if (age > 3) f *= Math.pow(1 - yr * 0.5, age - 3);
  }
  return Math.max(0.12, f);
}

/** Years since Jan 1 of the model year, never under half a year (a brand-new car still has some age). */
export function ageYears(modelYear: number, now: Date = new Date()): number {
  const years = (now.getTime() - Date.UTC(modelYear, 0, 1)) / (365.25 * 86_400_000);
  return Math.max(0.5, years);
}

export function annualMiles(miles: number, age: number): number {
  return Math.round(miles / Math.max(0.5, age));
}

// ── Trim factor ───────────────────────────────────────────────────────────────
// A trim moves price a lot (a Bronco Base vs a Wildtrak). Without a trim database, bucket by well-known names.
const TRIM_TOP = ["badlands", "wildtrak", "everglades", "platinum", "raptor", "denali", "king ranch", "rubicon", "trd pro", "trailhawk", "summit", "sahara", "type r", "performance", "amg", "m", "plaid", "trx", "hellcat", "zr2", "high country", "capstone", "at4x", "x-pro", "sx prestige", "calligraphy", "heritage limited"];
const TRIM_UPPER = ["outer banks", "limited", "touring", "sel", "titanium", "lariat", "premium", "black diamond", "laredo", "overland", "xle", "xse", "ex-l", "slt", "ltz", "premier", "st-line", "sport touring", "elite", "reserve", "trail boss", "laramie", "sv", "sl", "sx", "trd off-road", "x-line"];
const TRIM_MID = ["big bend", "sport", "le", "xlt", "ex", "latitude", "preferred", "se", "lt", "rst", "rs", "gt", "st", "n line", "xrt", "z71", "sr5", "trd sport", "big horn", "rebel", "willys", "altitude", "select", "elevation", "s", "activ", "si"];
const TRIM_BASE = ["base", "standard", "xl", "lx", "work", "wt", "l", "custom", "tradesman", "pro", "sr", "standard range", "ecoboost"];

function hasWord(text: string, phrase: string): boolean {
  const esc = phrase.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(^|[^a-z0-9])${esc}([^a-z0-9]|$)`).test(text);
}

export function trimFactor(trim: string | null | undefined): number {
  const t = (trim ?? "").trim().toLowerCase();
  if (!t) return 1.1;
  if (TRIM_TOP.some((w) => hasWord(t, w))) return 1.35;
  if (TRIM_UPPER.some((w) => hasWord(t, w))) return 1.2;
  if (TRIM_MID.some((w) => hasWord(t, w))) return 1.1;
  if (TRIM_BASE.some((w) => hasWord(t, w))) return 1.0;
  return 1.1;
}

export interface Estimate extends Valuation { annualMiles: number; ageYears: number }

/** Dollars per mile off the 12,000-a-year yardstick: pricier cars lose more per mile. Capped at +/-15% so a typo can't wreck the value. */
export function mileageAdjustment(value: number, age: number, miles: number): number {
  const rate = value < 20_000 ? 0.05 : value < 40_000 ? 0.07 : value < 70_000 ? 0.09 : 0.10;
  const adj = (12_000 * age - miles) * rate;
  return Math.max(-0.15 * value, Math.min(0.15 * value, adj));
}

export function estimateValue(args: {
  originalPrice: number; year: number; miles: number; now?: Date; trim?: string | null; applyTrim?: boolean; tier?: Retention;
}): Valuation {
  const age = ageYears(args.year, args.now);
  const original = args.originalPrice * (args.applyTrim === false ? 1 : trimFactor(args.trim));
  const base = original * depreciationFactor(age, args.tier ?? "standard");
  const value = Math.max(500, base + mileageAdjustment(base, age, args.miles));
  const spread = age <= 3 ? 0.10 : 0.12;
  const round = (n: number) => Math.round(n / 10) * 10;
  return { estimatedValue: round(value), lowValue: round(value * (1 - spread)), highValue: round(value * (1 + spread)), source: "estimate" };
}

// ── Body style from the model name (for estimates without a VIN) ───────────────
const TRUCKS = ["f-150", "f150", "f-250", "f250", "f-350", "silverado", "sierra", "ram", "tacoma", "tundra", "colorado", "canyon", "ranger", "frontier", "ridgeline", "maverick", "gladiator", "titan"];
const SUVS = ["bronco", "explorer", "escape", "expedition", "edge", "wrangler", "4runner", "tahoe", "suburban", "yukon", "highlander", "cr-v", "crv", "rav4", "grand cherokee", "cherokee", "telluride", "pilot", "palisade", "santa fe", "tucson", "sorento", "sportage", "rogue", "pathfinder", "outback", "forester", "crosstrek", "equinox", "traverse", "blazer", "model y", "model x", "cx-5", "cx-50", "land cruiser", "sequoia", "durango", "compass", "murano", "kona", "seltos", "soul", "bronco sport", "trailblazer"];
const VANS = ["odyssey", "sienna", "pacifica", "transit", "caravan", "carnival"];
const CARS = ["civic", "accord", "camry", "corolla", "altima", "sentra", "malibu", "mustang", "model 3", "model s", "elantra", "sonata", "jetta", "3 series", "c-class", "charger", "challenger", "camaro", "prius", "mazda3", "impreza", "legacy", "fusion", "optima", "k5"];

export function inferBodyClass(model: string): string {
  const m = model.trim().toLowerCase();
  const has = (list: string[]) => list.some((x) => m === x || m.startsWith(x + " ") || m.startsWith(x + "-"));
  if (has(TRUCKS)) return "Pickup";
  if (has(SUVS)) return "Sport Utility Vehicle (SUV)";
  if (has(VANS)) return "Minivan";
  if (has(CARS)) return "Sedan/Saloon";
  return "";
}

// Fallback for models that aren't in the curated trim table below: an approximate base MSRP, scaled by a trim keyword factor.
const BASE_MSRP: Record<string, number> = {
  "chevrolet|camaro": 30000, "chevrolet|malibu": 26000, "chevrolet|colorado": 32000,
  "toyota|prius": 28000, "honda|ridgeline": 41000,
  "nissan|altima": 27000, "nissan|frontier": 33000,
  "hyundai|elantra": 22000, "hyundai|santafe": 30000,
  "gmc|yukon": 65000, "bmw|3series": 47000, "mercedesbenz|cclass": 48000, "mazda|cx5": 28000, "volkswagen|jetta": 22000,
  "dodge|charger": 33000, "dodge|challenger": 34000, "dodge|durango": 40000,
};
const HIGH_RESALE = new Set(["honda|ridgeline", "chevrolet|colorado"]);

const REF_YEAR = 2024; // the curated prices below are in roughly 2024 dollars
/** Older model years cost less new (about 3% a year). */
function yearScale(year: number): number {
  return Math.pow(0.97, REF_YEAR - Math.min(year, REF_YEAR + 3));
}

function fallbackKey(make: string, model: string): string | null {
  const mk = norm(make);
  let md = norm(model);
  md = MODEL_ALIASES[md] ?? md;
  if (BASE_MSRP[`${mk}|${md}`]) return `${mk}|${md}`;
  return Object.keys(BASE_MSRP).find((k) => {
    const [kMake, kModel] = k.split("|");
    return kMake === mk && kModel.length >= 4 && md.startsWith(kModel);
  }) ?? null;
}

/** One estimate path for both the VIN lookup and manual entry. */
function estimateCore(
  args: { year: number; make: string; model: string; trim?: string | null; miles: number; bodyClass?: string; vehicleType?: string; basePrice?: number | null },
  now: Date,
): Valuation {
  const spec = findModel(args.make, args.model);
  if (args.basePrice != null) {
    // a decoder-supplied price already belongs to this VIN's trim, so no trim factor
    return estimateValue({ originalPrice: args.basePrice, year: args.year, miles: args.miles, now, applyTrim: false, tier: spec?.tier });
  }
  if (spec) {
    const t = resolveTrim(spec, args.trim);
    return estimateValue({ originalPrice: t.price * yearScale(args.year), year: args.year, miles: args.miles, now, applyTrim: false, tier: t.tier ?? spec.tier });
  }
  const key = fallbackKey(args.make, args.model);
  const price = key
    ? BASE_MSRP[key] * yearScale(args.year)
    : heuristicOriginalPrice(args.make, args.bodyClass || inferBodyClass(args.model), args.vehicleType ?? "", args.year, REF_YEAR);
  return estimateValue({ originalPrice: price, year: args.year, miles: args.miles, now, trim: args.trim, tier: key && HIGH_RESALE.has(key) ? "high" : "standard" });
}

/** Manual entry (no VIN): make/model/year/trim/miles in, estimate plus age and annual miles out. */
export function estimateManual(args: { year: number; make: string; model: string; trim?: string | null; miles: number }, now: Date = new Date()): Estimate {
  const v = estimateCore(args, now);
  const age = ageYears(args.year, now);
  return { ...v, annualMiles: annualMiles(args.miles, age), ageYears: Math.round(age * 10) / 10 };
}

// ── External lookups (fail soft) ──────────────────────────────────────────────

const ACRONYM_MAKES: Record<string, string> = { BMW: "BMW", GMC: "GMC", KIA: "Kia", RAM: "Ram", MINI: "MINI", FIAT: "Fiat", "MERCEDES-BENZ": "Mercedes-Benz", "LAND ROVER": "Land Rover", "ALFA ROMEO": "Alfa Romeo", "ROLLS-ROYCE": "Rolls-Royce", "ASTON MARTIN": "Aston Martin", "MAZDA": "Mazda", "AUDI": "Audi", "FORD": "Ford", "RIVIAN": "Rivian", "LUCID": "Lucid" };

export function displayMake(raw: string): string {
  const t = raw.trim();
  const mapped = ACRONYM_MAKES[t.toUpperCase()];
  if (mapped) return mapped;
  return t === t.toUpperCase() ? t.toLowerCase().replace(/(^|[\s-])([a-z])/g, (_m, a: string, b: string) => a + b.toUpperCase()) : t;
}

export function displayModel(raw: string): string {
  const t = raw.trim();
  // keep short or numeric names exactly as given (F-150, CR-V, RAV4, 3 Series); title-case long shouting ones (MUSTANG)
  if (t === t.toUpperCase() && t.length > 4 && !/\d/.test(t)) return t.toLowerCase().replace(/(^|[\s-])([a-z])/g, (_m, a: string, b: string) => a + b.toUpperCase());
  return t;
}

const CAB_STYLE = /^(regular cab|extended cab|ext(ended)? ?cab|super ?cab|super ?crew|crew ?cab|crew ?max|double cab|quad cab|king cab|access cab|mega cab|standard cab|cab ?& ?chassis|club cab|reg cab|sportcab)$/i;
const NOT_A_TRIM = /(\bdoor\b|\bdr\b|\bwd\b|\bawd\b|4x[24]|\bsedan\b|\bcoupe\b|\bsuv\b|\bwagon\b|\bpickup\b|\bhatchback\b|\bconvertible\b|\bvan\b|^\d+$)/i;

/** The decoder packs trims in several fields, sometimes as a comma list. Split, clean, and set cab styles aside. */
export function parseTrims(fields: { Trim?: string; Trim2?: string; Series?: string; Series2?: string }, model: string): { trims: string[]; trim: string | null; cabStyle: string | null } {
  const seen = new Set<string>();
  const trims: string[] = [];
  let cabStyle: string | null = null;
  for (const raw of [fields.Trim, fields.Trim2, fields.Series, fields.Series2]) {
    for (const part of (raw ?? "").split(",")) {
      const t = part.trim();
      if (!t) continue;
      if (CAB_STYLE.test(t)) { cabStyle = cabStyle ?? t; continue; }
      if (t.toLowerCase() === model.trim().toLowerCase() || t.length > 30 || NOT_A_TRIM.test(t)) continue;
      const key = t.toLowerCase();
      if (!seen.has(key)) { seen.add(key); trims.push(t); }
    }
  }
  return { trims, trim: trims.length === 1 ? trims[0] : null, cabStyle };
}

function bodyShort(bodyClass: string): string {
  const b = bodyClass.toLowerCase();
  if (/suv|sport utility/.test(b)) return "SUV";
  if (/pickup/.test(b)) return "pickup";
  if (/sedan|saloon/.test(b)) return "sedan";
  if (/coupe/.test(b)) return "coupe";
  if (/hatchback/.test(b)) return "hatchback";
  if (/wagon/.test(b)) return "wagon";
  if (/convertible|roadster/.test(b)) return "convertible";
  if (/van/.test(b)) return "van";
  return "";
}

function driveShort(d: string): string {
  const s = d.toLowerCase();
  if (/awd|all-wheel/.test(s)) return "AWD";
  if (/4wd|4-wheel|4x4/.test(s)) return "4WD";
  if (/fwd|front-wheel/.test(s)) return "FWD";
  if (/rwd|rear-wheel/.test(s)) return "RWD";
  return "";
}

export function buildDetails(r: Record<string, string>, cabStyle: string | null): string | null {
  const parts: string[] = [];
  const body = bodyShort(r.BodyClass ?? "");
  const doors = parseInt(r.Doors ?? "", 10);
  const shape = [cabStyle, Number.isFinite(doors) && doors > 0 ? `${doors}-door` : "", body].filter(Boolean).join(" ");
  if (shape) parts.push(shape);
  const fuel = (r.FuelTypePrimary ?? "").toLowerCase();
  const disp = parseFloat(r.DisplacementL ?? "");
  const cyl = parseInt(r.EngineCylinders ?? "", 10);
  if (fuel.includes("electric") && !Number.isFinite(disp)) parts.push("Electric");
  else if (Number.isFinite(disp)) {
    const turbo = /^(y|yes)/i.test(r.Turbo ?? "") ? " turbo" : "";
    const diesel = fuel.includes("diesel") ? " diesel" : "";
    parts.push(`${disp.toFixed(1)}L${Number.isFinite(cyl) ? ` ${cyl}-cyl` : ""}${turbo}${diesel}`);
  }
  const drive = driveShort(r.DriveType ?? "");
  if (drive) parts.push(drive);
  return parts.length ? parts.join(" \u00b7 ") : null;
}

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
    const model = displayModel(r.Model);
    const { trims, trim, cabStyle } = parseTrims(r, model);
    return {
      vin, year, make: displayMake(r.Make), model, trim, trims,
      details: buildDetails(r, cabStyle),
      bodyClass: r.BodyClass ?? "", vehicleType: r.VehicleType ?? "",
      basePrice: Number.isFinite(price) && price > 0 ? price : null,
    };
  } catch {
    return null;
  }
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

export async function valueVehicle(v: DecodedVin, miles: number, env: { MARKETCHECK_API_KEY?: string }, now: Date = new Date(), trimOverride?: string | null): Promise<Estimate> {
  const age = ageYears(v.year, now);
  const extra = { annualMiles: annualMiles(miles, age), ageYears: Math.round(age * 10) / 10 };
  if (env.MARKETCHECK_API_KEY) {
    const price = await marketCheckValue(v.vin, miles, env.MARKETCHECK_API_KEY);
    if (price) {
      const round = (n: number) => Math.round(n / 10) * 10;
      return { estimatedValue: round(price), lowValue: round(price * 0.93), highValue: round(price * 1.07), source: "MarketCheck", ...extra };
    }
  }
  const est = estimateCore({ year: v.year, make: v.make, model: v.model, trim: trimOverride ?? v.trim, miles, bodyClass: v.bodyClass, vehicleType: v.vehicleType, basePrice: v.basePrice }, now);
  return { ...est, ...extra };
}

// ── Curated trims for popular US models (base to top) ─────────────────────────
const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");

const TRIM_TABLE: Record<string, string[]> = {
  "ford|bronco": ["Base", "Big Bend", "Black Diamond", "Outer Banks", "Badlands", "Wildtrak", "Everglades", "Heritage", "Raptor"],
  "ford|broncosport": ["Base", "Big Bend", "Outer Banks", "Badlands", "Heritage", "Heritage Limited"],
  "ford|f150": ["XL", "STX", "XLT", "Lariat", "King Ranch", "Platinum", "Limited", "Tremor", "Raptor"],
  "ford|mustang": ["EcoBoost", "EcoBoost Premium", "GT", "GT Premium", "Mach 1", "Dark Horse", "Shelby GT500"],
  "ford|explorer": ["Base", "XLT", "Limited", "ST-Line", "ST", "Platinum", "King Ranch", "Timberline"],
  "ford|escape": ["S", "SE", "SEL", "Titanium", "ST-Line", "Platinum", "Active"],
  "chevrolet|silverado1500": ["WT", "Custom", "LT", "RST", "LTZ", "High Country", "ZR2", "Trail Boss"],
  "chevrolet|equinox": ["L", "LS", "LT", "RS", "Premier", "ACTIV"],
  "chevrolet|tahoe": ["LS", "LT", "RST", "Z71", "Premier", "High Country"],
  "chevrolet|camaro": ["LS", "LT", "RS", "SS", "ZL1"],
  "chevrolet|malibu": ["L", "LS", "RS", "LT", "Premier"],
  "toyota|camry": ["LE", "SE", "XLE", "XSE", "TRD"],
  "toyota|corolla": ["L", "LE", "SE", "XSE", "Apex"],
  "toyota|rav4": ["LE", "XLE", "XLE Premium", "Adventure", "TRD Off-Road", "Limited", "Prime SE", "Prime XSE"],
  "toyota|tacoma": ["SR", "SR5", "TRD Sport", "TRD Off-Road", "Limited", "TRD Pro"],
  "toyota|tundra": ["SR", "SR5", "Limited", "Platinum", "1794 Edition", "TRD Pro", "Capstone"],
  "toyota|4runner": ["SR5", "TRD Sport", "TRD Off-Road", "Limited", "Venture", "TRD Pro"],
  "toyota|highlander": ["L", "LE", "XLE", "Limited", "Platinum", "Bronze Edition"],
  "toyota|prius": ["L", "LE", "XLE", "Limited"],
  "honda|civic": ["LX", "Sport", "EX", "Touring", "Si", "Type R"],
  "honda|accord": ["LX", "EX", "Sport", "EX-L", "Touring", "Hybrid"],
  "honda|crv": ["LX", "EX", "EX-L", "Sport", "Sport Touring", "Touring"],
  "honda|pilot": ["LX", "EX-L", "Sport", "TrailSport", "Touring", "Elite", "Black Edition"],
  "jeep|wrangler": ["Sport", "Sport S", "Willys", "Sahara", "Rubicon", "Rubicon 392", "4xe"],
  "jeep|grandcherokee": ["Laredo", "Altitude", "Limited", "Overland", "Summit", "Trailhawk", "Summit Reserve"],
  "jeep|gladiator": ["Sport", "Sport S", "Willys", "Overland", "Rubicon", "Mojave"],
  "ram|1500": ["Tradesman", "Big Horn", "Laramie", "Rebel", "Limited", "TRX", "Longhorn"],
  "tesla|model3": ["Standard Range", "Long Range", "Performance"],
  "tesla|modely": ["Standard Range", "Long Range", "Performance"],
  "tesla|models": ["Long Range", "Plaid"],
  "tesla|modelx": ["Long Range", "Plaid"],
  "subaru|outback": ["Base", "Premium", "Limited", "Touring", "Onyx Edition", "Wilderness"],
  "subaru|forester": ["Base", "Premium", "Sport", "Limited", "Touring", "Wilderness"],
  "subaru|crosstrek": ["Base", "Premium", "Sport", "Limited", "Wilderness"],
  "nissan|altima": ["S", "SR", "SV", "SL", "Platinum"],
  "nissan|rogue": ["S", "SV", "SL", "Platinum"],
  "hyundai|elantra": ["SE", "SEL", "N Line", "Limited", "N"],
  "hyundai|tucson": ["SE", "SEL", "N Line", "XRT", "Limited"],
  "hyundai|santafe": ["SE", "SEL", "XRT", "Limited", "Calligraphy"],
  "kia|telluride": ["LX", "S", "EX", "SX", "SX Prestige", "X-Line", "X-Pro"],
  "kia|sorento": ["LX", "S", "EX", "SX", "SX Prestige", "X-Line"],
  "kia|sportage": ["LX", "EX", "SX", "X-Line", "X-Pro", "SX Prestige"],
  "gmc|sierra1500": ["Pro", "SLE", "Elevation", "SLT", "AT4", "AT4X", "Denali", "Denali Ultimate"],
  "gmc|yukon": ["SLE", "SLT", "AT4", "Denali"],
  "bmw|3series": ["330i", "330i xDrive", "M340i", "M3"],
  "mercedesbenz|cclass": ["C 300", "C 300 4MATIC", "AMG C 43", "AMG C 63"],
  "mazda|cx5": ["S", "Select", "Preferred", "Carbon Edition", "Premium", "Turbo"],
  "volkswagen|jetta": ["S", "Sport", "SE", "SEL", "GLI"],
  "dodge|charger": ["SXT", "GT", "R/T", "Scat Pack", "Hellcat"],
  "dodge|challenger": ["SXT", "GT", "R/T", "Scat Pack", "Hellcat"],
  "dodge|durango": ["SXT", "GT", "R/T", "Citadel", "SRT 392", "Hellcat"],
  "chevrolet|colorado": ["WT", "LT", "Z71", "Trail Boss", "ZR2"],
  "nissan|frontier": ["S", "SV", "PRO-4X", "PRO-X"],
  "honda|ridgeline": ["Sport", "RTL", "RTL-E", "TrailSport", "Black Edition"],
};

const MODEL_ALIASES: Record<string, string> = { silverado: "silverado1500", sierra: "sierra1500", ram: "1500", ram1500: "1500", cclass: "cclass", "3": "3series" };

/** Curated trims for a make/model (base to top), or [] when the model isn't known. Prefers the priced table. */
export function lookupTrims(make: string, model: string): string[] {
  const spec = findModel(make, model);
  if (spec) return spec.trims.map((t) => t.name);
  const mk = norm(make);
  let md = norm(model);
  md = MODEL_ALIASES[md] ?? md;
  const exact = TRIM_TABLE[`${mk}|${md}`];
  if (exact) return exact;
  // a decoded model like "Silverado 1500 LT" still finds "silverado1500"
  const hit = Object.keys(TRIM_TABLE).find((k) => {
    const [kMake, kModel] = k.split("|");
    return kMake === mk && kModel.length >= 4 && (md.startsWith(kModel) || (md.length >= 4 && kModel.startsWith(md)));
  });
  return hit ? TRIM_TABLE[hit] : [];
}

// ── Priced trim table ─────────────────────────────────────────────────────────
// Typical-equipped new price per trim in about 2024 dollars (not base MSRP: real cars carry options), plus a resale class per model.
// These are curated approximations, not market data. Flags: H = halo trim (left out of the "middle trim" default), X = exceptional resale.
interface PricedTrim { name: string; price: number; halo?: boolean; tier?: Retention }
interface ModelSpec { key: string; tier: Retention; trims: PricedTrim[] }

const MODELS: Record<string, ModelSpec> = {};
function def(key: string, tier: Retention, trims: Array<[string, number] | [string, number, string]>): void {
  MODELS[key] = {
    key, tier,
    trims: trims.map(([name, price, flags]) => ({ name, price, halo: flags?.includes("H") || undefined, tier: flags?.includes("X") ? "exceptional" : undefined })),
  };
}

def("ford|bronco", "exceptional", [["Base", 43000], ["Big Bend", 46500], ["Black Diamond", 48000], ["Outer Banks", 50000], ["Badlands", 54500], ["Wildtrak", 57000], ["Everglades", 53500], ["Heritage", 49000], ["Raptor", 100000, "HX"]]);
def("ford|broncosport", "high", [["Base", 33000], ["Big Bend", 35500], ["Outer Banks", 38500], ["Badlands", 40500], ["Heritage", 36500], ["Heritage Limited", 39500]]);
def("ford|f150", "high", [["XL", 42000], ["STX", 46000], ["XLT", 52000], ["Lariat", 63000], ["King Ranch", 72000], ["Platinum", 75000], ["Limited", 84000], ["Tremor", 68000], ["Raptor", 90000, "HX"]]);
def("ford|f150lightning", "low", [["Pro", 55000], ["XLT", 62000], ["Lariat", 78000], ["Platinum", 92000]]);
def("ford|ranger", "high", [["XL", 33500], ["XLT", 38000], ["Lariat", 45000], ["Raptor", 58000, "H"]]);
def("ford|maverick", "high", [["XL", 25000], ["XLT", 29000], ["Lariat", 34000], ["Tremor", 36500]]);
def("ford|mustang", "high", [["EcoBoost", 34000], ["EcoBoost Premium", 40000], ["GT", 46000], ["GT Premium", 51000], ["Mach 1", 62000], ["Dark Horse", 63000], ["Shelby GT500", 90000, "H"]]);
def("ford|explorer", "standard", [["Base", 40000], ["XLT", 45000], ["Limited", 53000], ["ST-Line", 52000], ["ST", 58000], ["Platinum", 61000], ["King Ranch", 62000], ["Timberline", 56000]]);
def("ford|escape", "standard", [["S", 31000], ["SE", 33500], ["SEL", 36000], ["Titanium", 39000], ["ST-Line", 37000], ["Platinum", 41000], ["Active", 35000]]);
def("ford|mustangmache", "low", [["Select", 44000], ["Premium", 51000], ["California Route 1", 54000], ["GT", 62000], ["GT Performance", 66000]]);
def("jeep|wrangler", "high", [["Sport", 38000], ["Sport S", 41500], ["Willys", 46000], ["Sahara", 52000], ["Rubicon", 57000], ["Rubicon 392", 95000, "H"], ["4xe", 58000]]);
def("jeep|gladiator", "high", [["Sport", 41000], ["Sport S", 44000], ["Willys", 48000], ["Overland", 53000], ["Rubicon", 57000], ["Mojave", 56000]]);
def("jeep|grandcherokee", "standard", [["Laredo", 42000], ["Altitude", 46000], ["Limited", 52000], ["Overland", 60000], ["Summit", 68000], ["Trailhawk", 58000], ["Summit Reserve", 72000]]);
def("chevrolet|silverado1500", "standard", [["WT", 40000], ["Custom", 46000], ["LT", 54000], ["RST", 58000], ["LTZ", 65000], ["High Country", 72000], ["ZR2", 74000], ["Trail Boss", 60000]]);
def("chevrolet|equinox", "standard", [["L", 28500], ["LS", 30000], ["LT", 32500], ["RS", 34500], ["Premier", 36500], ["ACTIV", 34000]]);
def("chevrolet|tahoe", "high", [["LS", 62000], ["LT", 69000], ["RST", 74000], ["Z71", 75000], ["Premier", 80000], ["High Country", 85000]]);
def("chevrolet|suburban", "high", [["LS", 65000], ["LT", 72000], ["RST", 77000], ["Z71", 78000], ["Premier", 83000], ["High Country", 88000]]);
def("gmc|sierra1500", "standard", [["Pro", 40000], ["SLE", 47000], ["Elevation", 54000], ["SLT", 60000], ["AT4", 66000], ["AT4X", 78000], ["Denali", 73000], ["Denali Ultimate", 85000, "H"]]);
def("ram|1500", "standard", [["Tradesman", 42000], ["Big Horn", 50000], ["Laramie", 60000], ["Rebel", 62000], ["Limited", 72000], ["TRX", 100000, "H"], ["Longhorn", 68000]]);
def("toyota|tacoma", "high", [["SR", 34000], ["SR5", 37500], ["TRD Sport", 42000], ["TRD Off-Road", 44000], ["Limited", 51000], ["TRD Pro", 58000]]);
def("toyota|tundra", "high", [["SR", 46000], ["SR5", 50000], ["Limited", 58000], ["Platinum", 64000], ["1794 Edition", 64500], ["TRD Pro", 74000], ["Capstone", 80000]]);
def("toyota|4runner", "high", [["SR5", 44000], ["TRD Sport", 47000], ["TRD Off-Road", 49500], ["Limited", 55000], ["Venture", 49000], ["TRD Pro", 58000]]);
def("toyota|camry", "high", [["LE", 28500], ["SE", 30500], ["XLE", 34500], ["XSE", 35000], ["TRD", 33500]]);
def("toyota|corolla", "high", [["L", 23500], ["LE", 24500], ["SE", 26500], ["XSE", 28500], ["Apex", 27500]]);
def("toyota|rav4", "high", [["LE", 31500], ["XLE", 33500], ["XLE Premium", 36000], ["Adventure", 38000], ["TRD Off-Road", 39500], ["Limited", 41500], ["Prime SE", 45000], ["Prime XSE", 48500]]);
def("toyota|highlander", "high", [["L", 40500], ["LE", 42000], ["XLE", 45500], ["Limited", 50500], ["Platinum", 54000], ["Bronze Edition", 51000]]);
def("honda|civic", "high", [["LX", 25000], ["Sport", 27500], ["EX", 29000], ["Touring", 31500], ["Si", 30500], ["Type R", 46000, "HX"]]);
def("honda|accord", "high", [["LX", 29500], ["EX", 31500], ["Sport", 32500], ["EX-L", 34500], ["Touring", 38500], ["Hybrid", 35000]]);
def("honda|crv", "high", [["LX", 31500], ["EX", 34500], ["EX-L", 37000], ["Sport", 35000], ["Sport Touring", 40000], ["Touring", 41500]]);
def("honda|pilot", "high", [["LX", 42500], ["EX-L", 46500], ["Sport", 45000], ["TrailSport", 49500], ["Touring", 50500], ["Elite", 53500], ["Black Edition", 54500]]);
def("tesla|model3", "low", [["Standard Range", 40000], ["Long Range", 46000], ["Performance", 54000]]);
def("tesla|modely", "low", [["Standard Range", 45000], ["Long Range", 50000], ["Performance", 55000]]);
def("tesla|models", "low", [["Long Range", 90000], ["Plaid", 110000]]);
def("tesla|modelx", "low", [["Long Range", 100000], ["Plaid", 120000]]);
def("tesla|cybertruck", "low", [["All-Wheel Drive", 80000], ["Cyberbeast", 100000]]);
def("subaru|outback", "high", [["Base", 30000], ["Premium", 33000], ["Limited", 38500], ["Touring", 42000], ["Onyx Edition", 38000], ["Wilderness", 40500]]);
def("subaru|forester", "high", [["Base", 29500], ["Premium", 32500], ["Sport", 34000], ["Limited", 37000], ["Touring", 39500], ["Wilderness", 36000]]);
def("subaru|crosstrek", "high", [["Base", 26500], ["Premium", 28500], ["Sport", 30000], ["Limited", 32500], ["Wilderness", 31500]]);
def("kia|telluride", "high", [["LX", 38000], ["S", 41000], ["EX", 45000], ["SX", 49000], ["SX Prestige", 53000], ["X-Line", 50000], ["X-Pro", 52000]]);
def("hyundai|palisade", "high", [["SE", 38500], ["SEL", 43000], ["XRT", 45500], ["Limited", 51000], ["Calligraphy", 54000]]);
def("kia|sorento", "standard", [["LX", 32500], ["S", 36000], ["EX", 40500], ["SX", 44500], ["SX Prestige", 48000], ["X-Line", 44500]]);
def("hyundai|tucson", "standard", [["SE", 28500], ["SEL", 31500], ["N Line", 35500], ["XRT", 34000], ["Limited", 38000]]);
def("nissan|rogue", "standard", [["S", 29500], ["SV", 32500], ["SL", 37000], ["Platinum", 40500]]);

const MODEL_KEYS = Object.keys(MODELS).sort((a, b) => b.length - a.length);

/** Curated spec for a make/model; tolerant of case, punctuation and trailing trim words ("Silverado 1500 LT"). */
export function findModel(make: string, model: string): ModelSpec | null {
  const mk = norm(make);
  let md = norm(model);
  md = MODEL_ALIASES[md] ?? md;
  const exact = MODELS[`${mk}|${md}`];
  if (exact) return exact;
  const hit = MODEL_KEYS.find((k) => {
    const [kMake, kModel] = k.split("|");
    return kMake === mk && kModel.length >= 4 && md.startsWith(kModel);
  });
  return hit ? MODELS[hit] : null;
}

function tokens(s: string): string[] {
  return s.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
}

/** The trim in the middle of the lineup, skipping halo trims; the sensible guess when we don't know the trim. */
export function middleTrim(spec: ModelSpec): PricedTrim {
  const core = spec.trims.filter((t) => !t.halo);
  const list = core.length ? core : spec.trims;
  return list[Math.floor((list.length - 1) / 2)];
}

/** Match the user's trim text to a curated trim: exact, then the longest trim name found as a phrase, then all its words. Unknown means middle. */
export function resolveTrim(spec: ModelSpec, text: string | null | undefined): PricedTrim {
  const t = (text ?? "").trim().toLowerCase();
  if (!t) return middleTrim(spec);
  const exact = spec.trims.find((x) => norm(x.name) === norm(t));
  if (exact) return exact;
  const byLength = [...spec.trims].sort((a, b) => b.name.length - a.name.length);
  const phrase = byLength.find((x) => hasWord(t, x.name.toLowerCase()));
  if (phrase) return phrase;
  const words = tokens(t);
  const allWords = byLength.find((x) => tokens(x.name).every((w) => words.includes(w)));
  return allWords ?? middleTrim(spec);
}
