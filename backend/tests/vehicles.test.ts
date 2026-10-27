import {
  decodeVin, depreciationFactor, estimateValue, hasValidCheckDigit, heuristicOriginalPrice, isValidVinFormat,
  marketCheckValue, normalizeVin, valueVehicle,
} from "../src/services/vehicles.js";

const GOOD_VIN = "1HGCM82633A004352";

describe("VIN validation", () => {
  it("normalizes whitespace and case", () => expect(normalizeVin(" 1hgcm826 33a004352 ")).toBe(GOOD_VIN));
  it("accepts a well-formed VIN", () => expect(isValidVinFormat(GOOD_VIN)).toBe(true));
  it("rejects wrong length and the letters I, O, Q", () => {
    expect(isValidVinFormat("1HGCM82633A00435")).toBe(false);
    expect(isValidVinFormat("1HGCM82633A00435O")).toBe(false);
    expect(isValidVinFormat("1HGCM82633A00435I")).toBe(false);
    expect(isValidVinFormat("1HGCM82633A00435Q")).toBe(false);
  });
  it("checks the check digit", () => {
    expect(hasValidCheckDigit(GOOD_VIN)).toBe(true);
    expect(hasValidCheckDigit("1HGCM82643A004352")).toBe(false);
  });
});

describe("depreciation estimate", () => {
  it("drops ~20% in year one, ~15% a year after, with a floor", () => {
    expect(depreciationFactor(0)).toBe(1);
    expect(depreciationFactor(1)).toBeCloseTo(0.8, 5);
    expect(depreciationFactor(2)).toBeCloseTo(0.68, 5);
    expect(depreciationFactor(5)).toBeCloseTo(0.8 * 0.85 ** 4, 5);
    expect(depreciationFactor(40)).toBe(0.12);
  });
  it("adjusts for mileage against 12,000 a year and gives a range", () => {
    const avg = estimateValue({ originalPrice: 30000, year: 2021, miles: 60000, nowYear: 2026 });
    expect(avg.estimatedValue).toBe(12530);
    expect(avg.lowValue).toBeLessThan(avg.estimatedValue);
    expect(avg.highValue).toBeGreaterThan(avg.estimatedValue);
    expect(avg.source).toBe("estimate");
    const high = estimateValue({ originalPrice: 30000, year: 2021, miles: 100000, nowYear: 2026 });
    expect(high.estimatedValue).toBe(10530); // 40,000 extra miles x $0.05 = $2,000 less
    const low = estimateValue({ originalPrice: 30000, year: 2021, miles: 20000, nowYear: 2026 });
    expect(low.estimatedValue).toBeGreaterThan(avg.estimatedValue);
  });
  it("never returns a zero or negative value", () => {
    expect(estimateValue({ originalPrice: 3000, year: 1995, miles: 900000, nowYear: 2026 }).estimatedValue).toBeGreaterThanOrEqual(500);
  });
  it("tiers original price by make and body style", () => {
    const civic = heuristicOriginalPrice("Honda", "Sedan/Saloon", "PASSENGER CAR", 2026, 2026);
    const f150 = heuristicOriginalPrice("Ford", "Pickup", "TRUCK", 2026, 2026);
    const bmw = heuristicOriginalPrice("BMW", "Sedan/Saloon", "PASSENGER CAR", 2026, 2026);
    expect(f150).toBeGreaterThan(civic);
    expect(bmw).toBeGreaterThan(civic);
  });
});

describe("decoding and valuation", () => {
  const ok = (body: unknown) => (async () => ({ ok: true, json: async () => body })) as unknown as typeof fetch;

  it("reads make, model, year, trim and body class from NHTSA", async () => {
    const d = await decodeVin(GOOD_VIN, ok({ Results: [{ Make: "HONDA", Model: "Accord", ModelYear: "2003", Trim: "EX", BodyClass: "Sedan/Saloon", VehicleType: "PASSENGER CAR", BasePrice: "" }] }));
    expect(d).toMatchObject({ year: 2003, make: "Honda", model: "Accord", trim: "EX", basePrice: null });
  });
  it("returns null when the VIN can't be decoded or the network fails", async () => {
    expect(await decodeVin(GOOD_VIN, ok({ Results: [{ Make: "", Model: "", ModelYear: "" }] }))).toBeNull();
    expect(await decodeVin(GOOD_VIN, (async () => { throw new Error("offline"); }) as unknown as typeof fetch)).toBeNull();
  });
  it("uses MarketCheck when a key is present and falls back otherwise", async () => {
    expect(await marketCheckValue(GOOD_VIN, 50000, "k", ok({ marketcheck_price: 18250 }))).toBe(18250);
    expect(await marketCheckValue(GOOD_VIN, 50000, "k", ok({}))).toBeNull();
    const v = { vin: GOOD_VIN, year: 2021, make: "Honda", model: "Civic", trim: null, bodyClass: "Sedan/Saloon", vehicleType: "PASSENGER CAR", basePrice: 25000 };
    const est = await valueVehicle(v, 60000, {}, 2026);
    expect(est.source).toBe("estimate");
    expect(est.estimatedValue).toBe(10440); // 25,000 x 0.8 x 0.85^4 = 10,440
  });
});
