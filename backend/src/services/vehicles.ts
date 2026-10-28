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

/** ~20% off in year one, ~15%/yr after that, never below 12% of the original price. */
export function depreciationFactor(ageYears: number): number {
  const age = Math.max(0, ageYears);
  const f = age < 1 ? 1 - 0.2 * age : 0.8 * Math.pow(0.85, age - 1);
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

export function estimateValue(args: {
  originalPrice: number; year: number; miles: number; now?: Date; trim?: string | null; applyTrim?: boolean;
}): Valuation {
  const age = ageYears(args.year, args.now);
  const original = args.originalPrice * (args.applyTrim === false ? 1 : trimFactor(args.trim));
  const base = original * depreciationFactor(age);
  // $0.05 per mile against the 12,000-a-year yardstick, capped so a typo can't zero out the car
  const adjust = Math.max(-0.25 * base, Math.min(0.25 * base, (12_000 * age - args.miles) * 0.05));
  const value = Math.max(500, base + adjust);
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

// Approximate base-trim MSRP (2025 dollars) for popular models; the trim factor scales it up. Much better than the make-tier guess.
const BASE_MSRP: Record<string, number> = {
  "ford|bronco": 42000, "ford|broncosport": 33000, "ford|f150": 40000, "ford|mustang": 33000, "ford|explorer": 39000, "ford|escape": 30000,
  "chevrolet|silverado1500": 38000, "chevrolet|equinox": 28000, "chevrolet|tahoe": 62000, "chevrolet|camaro": 30000, "chevrolet|malibu": 26000, "chevrolet|colorado": 32000,
  "toyota|camry": 28000, "toyota|corolla": 23000, "toyota|rav4": 30000, "toyota|tacoma": 33000, "toyota|tundra": 42000, "toyota|4runner": 42000, "toyota|highlander": 40000, "toyota|prius": 28000,
  "honda|civic": 24000, "honda|accord": 28000, "honda|crv": 30000, "honda|pilot": 42000, "honda|ridgeline": 41000,
  "jeep|wrangler": 33000, "jeep|grandcherokee": 40000, "jeep|gladiator": 38000, "ram|1500": 40000,
  "tesla|model3": 40000, "tesla|modely": 45000, "tesla|models": 80000, "tesla|modelx": 90000,
  "subaru|outback": 30000, "subaru|forester": 28000, "subaru|crosstrek": 26000, "nissan|altima": 27000, "nissan|rogue": 29000, "nissan|frontier": 33000,
  "hyundai|elantra": 22000, "hyundai|tucson": 28000, "hyundai|santafe": 30000, "kia|telluride": 37000, "kia|sorento": 31000, "kia|sportage": 27000,
  "gmc|sierra1500": 40000, "gmc|yukon": 65000, "bmw|3series": 47000, "mercedesbenz|cclass": 48000, "mazda|cx5": 28000, "volkswagen|jetta": 22000,
  "dodge|charger": 33000, "dodge|challenger": 34000, "dodge|durango": 40000,
};
// Models that hold their value far better than the generic curve assumes.
const HIGH_RESALE = new Set(["ford|bronco", "jeep|wrangler", "jeep|gladiator", "toyota|tacoma", "toyota|4runner", "toyota|tundra", "toyota|landcruiser", "honda|ridgeline", "chevrolet|colorado"]);

function tableKey(make: string, model: string): string | null {
  const mk = norm(make);
  let md = norm(model);
  md = MODEL_ALIASES[md] ?? md;
  if (BASE_MSRP[`${mk}|${md}`]) return `${mk}|${md}`;
  return Object.keys(BASE_MSRP).find((k) => {
    const [kMake, kModel] = k.split("|");
    return kMake === mk && kModel.length >= 4 && md.startsWith(kModel);
  }) ?? null;
}

/** Estimated original price: the curated base MSRP (deflated for older model years) or the make-tier guess. */
export function originalPriceFor(make: string, model: string, bodyClass: string, vehicleType: string, year: number, nowYear: number): { price: number; curated: boolean; highResale: boolean } {
  const key = tableKey(make, model);
  if (key) return { price: BASE_MSRP[key] * Math.pow(0.97, Math.max(0, nowYear - year)), curated: true, highResale: HIGH_RESALE.has(key) };
  return { price: heuristicOriginalPrice(make, bodyClass || inferBodyClass(model), vehicleType, year, nowYear), curated: false, highResale: false };
}

function withResale(v: Valuation, highResale: boolean): Valuation {
  if (!highResale) return v;
  const f = 1.3;
  const round = (n: number) => Math.round(n / 10) * 10;
  return { ...v, estimatedValue: round(v.estimatedValue * f), lowValue: round(v.lowValue * f), highValue: round(v.highValue * f) };
}

/** Manual entry (no VIN): make/model/year/trim/miles in, estimate plus age and annual miles out. */
export function estimateManual(args: { year: number; make: string; model: string; trim?: string | null; miles: number }, now: Date = new Date()): Estimate {
  const o = originalPriceFor(args.make, args.model, inferBodyClass(args.model), "", args.year, now.getFullYear());
  const v = withResale(estimateValue({ originalPrice: o.price, year: args.year, miles: args.miles, now, trim: args.trim }), o.highResale);
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
  const knownPrice = v.basePrice != null;
  const o = originalPriceFor(v.make, v.model, v.bodyClass, v.vehicleType, v.year, now.getFullYear());
  const est = estimateValue({ originalPrice: v.basePrice ?? o.price, year: v.year, miles, now, trim: trimOverride ?? v.trim, applyTrim: !knownPrice });
  return { ...withResale(est, o.highResale && !knownPrice), ...extra };
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

/** Curated trims for a make/model, or [] when the model isn't in the table. */
export function lookupTrims(make: string, model: string): string[] {
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
