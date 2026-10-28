import {
  ageYears, annualMiles, buildDetails, decodeVin, depreciationFactor, displayMake, displayModel, estimateManual, estimateValue,
  hasValidCheckDigit, heuristicOriginalPrice, inferBodyClass, isValidVinFormat, lookupTrims, marketCheckValue, mileageAdjustment, normalizeVin,
  parseTrims, trimFactor, valueVehicle, findModel, middleTrim, resolveTrim,
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
    expect(depreciationFactor(3)).toBeCloseTo(0.8 * 0.85 ** 2, 5);
    expect(depreciationFactor(5)).toBeCloseTo(0.8 * 0.85 ** 2 * 0.925 ** 2, 5); // the yearly loss eases after year 3
    expect(depreciationFactor(40)).toBe(0.12);
  });
  it("keeps value better for high-retention classes and worse for low", () => {
    for (const age of [1, 3, 6]) {
      expect(depreciationFactor(age, "exceptional")).toBeGreaterThan(depreciationFactor(age, "high"));
      expect(depreciationFactor(age, "high")).toBeGreaterThan(depreciationFactor(age, "standard"));
      expect(depreciationFactor(age, "standard")).toBeGreaterThan(depreciationFactor(age, "low"));
    }
    expect(depreciationFactor(1, "high")).toBeCloseTo(0.9, 5);
  });
  it("scales the per-mile rate with price and caps the adjustment at 15%", () => {
    expect(mileageAdjustment(15_000, 5, 40_000)).toBeCloseTo(20_000 * 0.05, 5);
    expect(mileageAdjustment(30_000, 5, 40_000)).toBeCloseTo(20_000 * 0.07, 5);
    expect(mileageAdjustment(50_000, 5, 40_000)).toBeCloseTo(20_000 * 0.09, 5);
    expect(mileageAdjustment(15_000, 5, 900_000)).toBeCloseTo(-0.15 * 15_000, 5);
    expect(mileageAdjustment(15_000, 1, 0)).toBeCloseTo(600, 5); // 12,000 under the yardstick x $0.05, within the cap
  });
  it("adjusts for mileage against 12,000 a year and gives a range", () => {
    const now = new Date(Date.UTC(2026, 0, 1));
    const age = ageYears(2021, now);
    const args = { originalPrice: 30000, year: 2021, now, applyTrim: false };
    const avg = estimateValue({ ...args, miles: 12_000 * age });
    expect(avg.estimatedValue).toBeCloseTo(30000 * depreciationFactor(age), -1);
    expect(avg.lowValue).toBeLessThan(avg.estimatedValue);
    expect(avg.highValue).toBeGreaterThan(avg.estimatedValue);
    expect(avg.source).toBe("estimate");
    const high = estimateValue({ ...args, miles: 12_000 * age + 40_000 });
    expect(avg.estimatedValue - high.estimatedValue).toBeCloseTo(2000, -1); // 40,000 extra miles x $0.05 (still under the 15% cap)
    expect(estimateValue({ ...args, miles: 20_000 }).estimatedValue).toBeGreaterThan(avg.estimatedValue);
  });
  it("never returns a zero or negative value", () => {
    expect(estimateValue({ originalPrice: 3000, year: 1995, miles: 900000, now: new Date(Date.UTC(2026, 0, 1)) }).estimatedValue).toBeGreaterThanOrEqual(500);
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
    const now = new Date(Date.UTC(2026, 0, 1));
    const est = await valueVehicle(v, 60000, {}, now);
    expect(est.source).toBe("estimate");
    // a decoder-supplied base price already belongs to this VIN's trim, so no trim factor is applied
    const age = ageYears(2021, now);
    const base = 25000 * depreciationFactor(age, "high"); // Civic is a high-retention model
    expect(est.estimatedValue).toBeCloseTo(base + mileageAdjustment(base, age, 60_000), -1);
    expect(est.annualMiles).toBe(Math.round(60000 / age));
  });
});

describe("age and annual miles", () => {
  const now = new Date(Date.UTC(2026, 9, 28)); // Oct 28, 2026
  it("measures age from Jan 1 of the model year, never under half a year", () => {
    expect(ageYears(2023, now)).toBeCloseTo(3.82, 1);
    expect(ageYears(2026, new Date(Date.UTC(2026, 0, 10)))).toBe(0.5);
    expect(ageYears(2027, now)).toBe(0.5);
  });
  it("derives annual miles from miles and age", () => {
    expect(annualMiles(41_200, ageYears(2023, now))).toBe(Math.round(41_200 / ageYears(2023, now)));
    expect(annualMiles(41_200, ageYears(2023, now))).toBeGreaterThan(10_000);
    expect(annualMiles(41_200, ageYears(2023, now))).toBeLessThan(11_500);
    expect(annualMiles(9_000, 0.5)).toBe(18_000);
  });
});

describe("trims", () => {
  it("splits the decoder's comma list into candidates", () => {
    const r = parseTrims({ Trim: "Base, Big Bend, Black Diamond, Outer Banks, Badlands, Wildtrak, Everglades" }, "Bronco");
    expect(r.trims).toEqual(["Base", "Big Bend", "Black Diamond", "Outer Banks", "Badlands", "Wildtrak", "Everglades"]);
    expect(r.trim).toBeNull();
    expect(r.cabStyle).toBeNull();
  });
  it("sets a single trim and dedupes across fields", () => {
    const r = parseTrims({ Trim: "EX", Trim2: "ex", Series: "" }, "Accord");
    expect(r).toMatchObject({ trims: ["EX"], trim: "EX" });
  });
  it("keeps cab styles out of trims (they go to details)", () => {
    const r = parseTrims({ Trim: "SuperCrew" }, "F-150");
    expect(r.trims).toEqual([]);
    expect(r.trim).toBeNull();
    expect(r.cabStyle).toBe("SuperCrew");
    expect(buildDetails({ BodyClass: "Pickup", DriveType: "4WD/4-Wheel Drive/4x4", DisplacementL: "5.0", EngineCylinders: "8" }, r.cabStyle)).toBe("SuperCrew pickup \u00b7 5.0L 8-cyl \u00b7 4WD");
  });
  it("ignores body descriptions and the model name itself", () => {
    expect(parseTrims({ Trim: "Bronco, 4-Door, AWD", Series: "4 Door SUV" }, "Bronco").trims).toEqual([]);
  });
  it("builds a readable details line", () => {
    expect(buildDetails({ BodyClass: "Sport Utility Vehicle [SUV]/Multipurpose Vehicle [MPV]", Doors: "4", DriveType: "AWD/All-Wheel Drive", DisplacementL: "2.3", EngineCylinders: "4" }, null)).toBe("4-door SUV \u00b7 2.3L 4-cyl \u00b7 AWD");
  });
  it("orders the trim factor Wildtrak > Big Bend > Base", () => {
    expect(trimFactor("Wildtrak")).toBeGreaterThan(trimFactor("Big Bend"));
    expect(trimFactor("Big Bend")).toBeGreaterThan(trimFactor("Base"));
    expect(trimFactor("Outer Banks")).toBe(1.2);
    expect(trimFactor("Base")).toBe(1);
    expect(trimFactor(null)).toBe(1.1);
    expect(trimFactor("Mystery Package")).toBe(1.1);
    expect(trimFactor("M")).toBe(1.35);
  });
  it("prices a higher trim higher", () => {
    const now = new Date(Date.UTC(2026, 9, 28));
    const base = estimateManual({ year: 2023, make: "Ford", model: "Bronco", trim: "Base", miles: 41_200 }, now);
    const wild = estimateManual({ year: 2023, make: "Ford", model: "Bronco", trim: "Wildtrak", miles: 41_200 }, now);
    expect(wild.estimatedValue).toBeGreaterThan(base.estimatedValue);
  });
});

describe("estimate without a VIN", () => {
  const now = new Date(Date.UTC(2026, 9, 28));
  it("estimates from year, make, model and miles alone", () => {
    const e = estimateManual({ year: 2023, make: "Ford", model: "Bronco", miles: 41_200 }, now);
    expect(e.source).toBe("estimate");
    expect(e.estimatedValue).toBeGreaterThan(20_000);
    expect(e.estimatedValue).toBeLessThan(60_000);
    expect(e.lowValue).toBeLessThan(e.estimatedValue);
    expect(e.highValue).toBeGreaterThan(e.estimatedValue);
    expect(e.ageYears).toBeCloseTo(3.8, 1);
    expect(e.annualMiles).toBe(annualMiles(41_200, ageYears(2023, now)));
  });
  it("more miles means less value", () => {
    const lo = estimateManual({ year: 2021, make: "Toyota", model: "Camry", trim: "LE", miles: 20_000 }, now);
    const hi = estimateManual({ year: 2021, make: "Toyota", model: "Camry", trim: "LE", miles: 120_000 }, now);
    expect(lo.estimatedValue).toBeGreaterThan(hi.estimatedValue);
  });
  it("infers body style from the model name", () => {
    expect(inferBodyClass("F-150")).toBe("Pickup");
    expect(inferBodyClass("Bronco Sport")).toMatch(/SUV/);
    expect(inferBodyClass("Odyssey")).toBe("Minivan");
    expect(inferBodyClass("Accord")).toMatch(/Sedan/);
    expect(inferBodyClass("Mystery")).toBe("");
    const truck = estimateManual({ year: 2024, make: "Ford", model: "F-150", miles: 5000 }, now);
    const car = estimateManual({ year: 2024, make: "Ford", model: "Mustang", miles: 5000 }, now);
    expect(truck.estimatedValue).toBeGreaterThan(car.estimatedValue);
  });
});

describe("curated prices", () => {
  it("uses the curated base price and a resale boost for high-resale models", () => {
    const now = new Date(Date.UTC(2026, 9, 28));
    const bronco = estimateManual({ year: 2023, make: "Ford", model: "Bronco", trim: "Big Bend", miles: 41_200 }, now);
    const camry = estimateManual({ year: 2023, make: "Toyota", model: "Camry", trim: "SE", miles: 41_200 }, now);
    expect(bronco.estimatedValue).toBeGreaterThan(camry.estimatedValue);
    expect(bronco.estimatedValue).toBeGreaterThan(25_000);
  });
});

describe("curated trim list and casing", () => {
  it("finds trims case-insensitively and by alias", () => {
    expect(lookupTrims("FORD", "bronco")).toEqual(["Base", "Big Bend", "Black Diamond", "Outer Banks", "Badlands", "Wildtrak", "Everglades", "Heritage", "Raptor"]);
    expect(lookupTrims("Ford", "F-150")[0]).toBe("XL");
    expect(lookupTrims("Chevrolet", "Silverado")).toContain("High Country");
    expect(lookupTrims("Chevrolet", "Silverado 1500 LT")).toContain("Trail Boss");
    expect(lookupTrims("Mercedes-Benz", "C-Class")).toContain("C 300");
    expect(lookupTrims("Ford", "Pinto")).toEqual([]);
  });
  it("display-cases makes and models", () => {
    expect(displayMake("FORD")).toBe("Ford");
    expect(displayMake("BMW")).toBe("BMW");
    expect(displayMake("LAND ROVER")).toBe("Land Rover");
    expect(displayModel("MUSTANG")).toBe("Mustang");
    expect(displayModel("F-150")).toBe("F-150");
    expect(displayModel("CR-V")).toBe("CR-V");
  });
});

describe("decoding the Bronco payload", () => {
  const ok = (body: unknown) => (async () => ({ ok: true, json: async () => body })) as unknown as typeof fetch;
  it("returns candidate trims and a details line", async () => {
    const d = await decodeVin("1FMEE5DH2PLA12345", ok({ Results: [{
      Make: "FORD", Model: "Bronco", ModelYear: "2023", Trim: "Base, Big Bend, Black Diamond, Outer Banks, Badlands, Wildtrak, Everglades",
      BodyClass: "Sport Utility Vehicle [SUV]/Multipurpose Vehicle [MPV]", Doors: "4", DriveType: "AWD/All-Wheel Drive",
      DisplacementL: "2.3", EngineCylinders: "4", FuelTypePrimary: "Gasoline", VehicleType: "MULTIPURPOSE PASSENGER VEHICLE (MPV)", BasePrice: "",
    }] }));
    expect(d).toMatchObject({ year: 2023, make: "Ford", model: "Bronco", trim: null, details: "4-door SUV \u00b7 2.3L 4-cyl \u00b7 AWD" });
    expect(d?.trims).toHaveLength(7);
    const v = await valueVehicle(d!, 41_200, {}, new Date(Date.UTC(2026, 9, 28)));
    expect(v.annualMiles).toBeGreaterThan(10_000);
    expect(v.source).toBe("estimate");
  });
});


describe("trim-level pricing", () => {
  const now = new Date(Date.UTC(2026, 9, 28));
  const bronco = (trim: string | null, miles = 41_200) => estimateManual({ year: 2023, make: "Ford", model: "Bronco", trim, miles }, now).estimatedValue;

  it("prices a 2023 Bronco at about 41,000 miles near real market levels", () => {
    expect(bronco("Wildtrak")).toBeGreaterThanOrEqual(43_000);
    expect(bronco("Wildtrak")).toBeLessThanOrEqual(48_500);
    expect(bronco("Big Bend")).toBeGreaterThanOrEqual(35_000);
    expect(bronco("Big Bend")).toBeLessThanOrEqual(40_000);
    expect(bronco("Base")).toBeGreaterThanOrEqual(32_000);
    expect(bronco("Base")).toBeLessThanOrEqual(37_000);
    expect(bronco("Raptor")).toBeGreaterThan(70_000);
    expect(bronco("Raptor")).toBeLessThan(90_000);
  });
  it("orders trims Base < Big Bend < Badlands < Wildtrak", () => {
    expect(bronco("Base")).toBeLessThan(bronco("Big Bend"));
    expect(bronco("Big Bend")).toBeLessThan(bronco("Badlands"));
    expect(bronco("Badlands")).toBeLessThan(bronco("Wildtrak"));
  });
  it("a changed trim changes the value", () => {
    expect(bronco("Wildtrak")).not.toBe(bronco("Big Bend"));
    expect(bronco("Wildtrak") - bronco("Big Bend")).toBeGreaterThan(5_000);
  });
  it("prices ordinary cars sensibly too", () => {
    const camry = estimateManual({ year: 2018, make: "Toyota", model: "Camry", trim: "LE", miles: 90_000 }, now).estimatedValue;
    expect(camry).toBeGreaterThanOrEqual(14_000);
    expect(camry).toBeLessThanOrEqual(18_500);
    const civic = estimateManual({ year: 2021, make: "Honda", model: "Civic", trim: "Sport", miles: 40_000 }, now).estimatedValue;
    expect(civic).toBeGreaterThanOrEqual(19_000);
    expect(civic).toBeLessThanOrEqual(24_000);
  });
  it("uses the middle trim when the trim is missing or unknown", () => {
    const spec = findModel("Ford", "Bronco")!;
    const mid = middleTrim(spec);
    expect(mid.name).toBe("Outer Banks"); // halo trims (Raptor) don't pull the middle up
    expect(bronco(null)).toBe(bronco(mid.name));
    expect(bronco("Mystery Package")).toBe(bronco(mid.name));
    expect(bronco("")).toBe(bronco(mid.name));
  });
  it("matches trim text case-insensitively and by words", () => {
    const spec = findModel("Ford", "Bronco")!;
    expect(resolveTrim(spec, "wildtrak").name).toBe("Wildtrak");
    expect(resolveTrim(spec, "BIG BEND").name).toBe("Big Bend");
    expect(resolveTrim(spec, "Outer Banks 4-door").name).toBe("Outer Banks");
    expect(resolveTrim(spec, "Black Diamond").name).toBe("Black Diamond");
    const crv = findModel("Honda", "CR-V")!;
    expect(resolveTrim(crv, "Sport Touring").name).toBe("Sport Touring");
  });
  it("falls back to the tier and body heuristic for unknown models without throwing", () => {
    const e = estimateManual({ year: 2019, make: "Studebaker", model: "Zephyr", trim: "Deluxe", miles: 50_000 }, now);
    expect(e.estimatedValue).toBeGreaterThan(500);
    expect(e.source).toBe("estimate");
    const known = estimateManual({ year: 2019, make: "Nissan", model: "Altima", trim: "SV", miles: 50_000 }, now);
    expect(known.estimatedValue).toBeGreaterThan(500);
  });
  it("lists trims from the priced table, base to top", () => {
    expect(lookupTrims("Ford", "Bronco")).toEqual(["Base", "Big Bend", "Black Diamond", "Outer Banks", "Badlands", "Wildtrak", "Everglades", "Heritage", "Raptor"]);
    expect(lookupTrims("Ford", "F-150 Lightning")).toContain("Platinum");
    expect(lookupTrims("Ford", "Mustang Mach-E")).toContain("GT");
    expect(lookupTrims("Toyota", "Tacoma")[0]).toBe("SR");
  });
  it("covers the popular models", () => {
    const covered = [["Ford", "Bronco Sport"], ["Ford", "Maverick"], ["Ford", "Ranger"], ["Jeep", "Wrangler"], ["Jeep", "Gladiator"], ["Toyota", "4Runner"], ["Toyota", "Tundra"],
      ["Toyota", "RAV4"], ["Honda", "Accord"], ["Honda", "Pilot"], ["Tesla", "Model 3"], ["Tesla", "Model Y"], ["Tesla", "Cybertruck"], ["Subaru", "Outback"],
      ["Kia", "Telluride"], ["Hyundai", "Palisade"], ["Chevrolet", "Tahoe"], ["Chevrolet", "Suburban"], ["GMC", "Sierra 1500"], ["Ram", "1500"]];
    for (const [mk, md] of covered) expect(findModel(mk, md), `${mk} ${md}`).not.toBeNull();
  });
});
