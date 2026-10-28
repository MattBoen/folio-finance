import SwiftUI

/// Add a car by VIN (looks up the model and trims) or by typing the details. Can add more than one car.
struct CarEntryView: View {
    var onSaved: (String) -> Void = { _ in }

    @EnvironmentObject private var auth: AuthManager

    private struct Draft {
        var vin: String?
        var year = ""
        var make = ""
        var model = ""
        var trim = ""
        var miles = ""
        var value = ""
        var details: String?
        var range: (low: Double, high: Double)?
        var source = "estimate"
    }

    @State private var manual = false
    @State private var vin = ""
    @State private var draft = Draft()
    @State private var trimOptions: [String] = []
    @State private var found = false
    @State private var busy = false
    @State private var estimating = false
    @State private var saved: [String] = []
    @State private var error: String?

    private var yearValue: Int? { Int(draft.year).flatMap { (1981...2100).contains($0) ? $0 : nil } }
    private var milesValue: Int? { Int(draft.miles.filter(\.isNumber)) }
    private var detailsReady: Bool { yearValue != nil && !draft.make.trimmingCharacters(in: .whitespaces).isEmpty && !draft.model.trimmingCharacters(in: .whitespaces).isEmpty && milesValue != nil }

    /// Miles per year since January 1 of the model year, matching the server's estimate.
    private var annualMiles: Int? {
        guard let y = yearValue, let m = milesValue,
              let start = Calendar.current.date(from: DateComponents(year: y, month: 1, day: 1)) else { return nil }
        let years = max(0.5, Date().timeIntervalSince(start) / (365.25 * 86_400))
        return Int((Double(m) / years).rounded())
    }

    var body: some View {
        VStack(spacing: 14) {
            if !saved.isEmpty { savedCard }
            if found || manual { detailsCard } else { vinCard }
            if let error { Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            actions
        }
        .animation(.smooth, value: found)
        .animation(.smooth, value: manual)
        .task(id: "\(draft.year)|\(draft.make)|\(draft.model)") { await loadTrimsForManual() }
        .onChange(of: draft.trim) { Task { await reestimate() } }
        .onChange(of: draft.miles) { Task { await reestimate(delay: true) } }
    }

    // MARK: Cards

    private var savedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(saved, id: \.self) { name in
                    HStack(spacing: 12) {
                        IconBadge(symbol: "checkmark", color: .green, size: 34)
                        Text(name).font(.headline)
                        Spacer()
                    }
                }
            }
        }
    }

    private var vinCard: some View {
        VStack(spacing: 10) {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    TextField("VIN (17 characters)", text: $vin)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body)
                        .onChange(of: vin) { _, v in
                            let cleaned = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(17))
                            if cleaned != v { vin = cleaned }
                        }
                        .padding(16)
                    Divider().padding(.leading, 16)
                    TextField("Mileage", text: $draft.miles).keyboardType(.numberPad).padding(16)
                }
            }
            Text("Find the VIN on the driver's side of the dashboard, the door jamb, or your insurance card.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detailsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                if manual {
                    VStack(spacing: 0) {
                        field("Year", $draft.year, keyboard: .numberPad)
                        Divider()
                        field("Make (e.g. Ford)", $draft.make)
                        Divider()
                        field("Model (e.g. Bronco)", $draft.model)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text([draft.year, draft.make, draft.model].joined(separator: " ")).font(.title3.bold())
                        if let d = draft.details { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }

                trimRow

                if manual {
                    Divider()
                    field("Mileage", $draft.miles, keyboard: .numberPad)
                }
                if let annual = annualMiles {
                    HStack(spacing: 8) {
                        Image(systemName: "gauge.with.dots.needle.50percent").foregroundStyle(.secondary)
                        Text("About \(annual.formatted()) miles a year")
                            .font(.subheadline)
                        Text(annual < 9_000 ? "Low" : annual > 15_000 ? "High" : "Typical")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background((annual > 15_000 ? Color.orange : annual < 9_000 ? Color.teal : Color.green).opacity(0.15), in: Capsule())
                        Spacer()
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Estimated value").font(.subheadline).foregroundStyle(.secondary)
                        if estimating { ProgressView().controlSize(.small) }
                    }
                    HStack {
                        Text("$").font(.title2.bold()).foregroundStyle(.secondary)
                        TextField("0", text: $draft.value).keyboardType(.numberPad)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                    }
                    if let r = draft.range {
                        Text("Typical range \(money(r.low)) to \(money(r.high)). \(draft.source == "estimate" ? "An estimate from age, mileage and trim." : "Based on recent market listings.") Edit it any time.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var trimRow: some View {
        if trimOptions.isEmpty {
            if manual {
                Divider()
                field("Trim (optional)", $draft.trim)
            }
        } else {
            Divider()
            HStack {
                Text("Trim").foregroundStyle(.secondary)
                Spacer()
                Picker("Trim", selection: $draft.trim) {
                    Text("Not sure").tag("")
                    ForEach(trimOptions, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(.primary)
            }
            if draft.trim.isEmpty && found {
                Text("Pick your trim for a closer value. The VIN alone can't tell these apart.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ title: String, _ text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(title, text: text).keyboardType(keyboard).padding(.vertical, 11)
    }

    // MARK: Buttons

    @ViewBuilder private var actions: some View {
        if found || manual {
            Button { Task { await save() } } label: {
                Group { if busy { ProgressView().tint(.white) } else { Text("Add to my accounts").font(.headline) } }
                    .frame(maxWidth: .infinity).frame(height: 30)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(busy || !detailsReady || Double(draft.value) == nil)
            Button(found ? "Look up a different VIN" : "Use a VIN instead") { reset(toManual: false) }.font(.subheadline)
        } else {
            Button { Task { await lookup() } } label: {
                Group { if busy { ProgressView().tint(.white) } else { Text("Look up my car").font(.headline) } }
                    .frame(maxWidth: .infinity).frame(height: 30)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(busy || vin.count != 17 || milesValue == nil)
            Button("Enter the details myself") { reset(toManual: true) }.font(.subheadline)
        }
    }

    private func reset(toManual: Bool) {
        draft = Draft(); trimOptions = []; found = false; manual = toManual; error = nil; vin = ""
    }

    // MARK: Data

    private func lookup() async {
        guard let miles = milesValue else { return }
        busy = true; error = nil
        do {
            let r: VehicleLookup = try await auth.withFreshToken(.vehicleLookup(vin: vin, miles: miles))
            draft = Draft(vin: r.vin ?? vin, year: String(r.year), make: r.make, model: r.model, trim: r.trim ?? "",
                          miles: String(miles), value: String(Int(r.estimatedValue.rounded())), details: r.details,
                          range: (r.lowValue, r.highValue), source: r.source)
            trimOptions = r.trims ?? (r.trim.map { [$0] } ?? [])
            found = true
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        busy = false
    }

    private func loadTrimsForManual() async {
        guard manual, let y = yearValue else { return }
        let make = draft.make.trimmingCharacters(in: .whitespaces), model = draft.model.trimmingCharacters(in: .whitespaces)
        guard !make.isEmpty, !model.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(600))
        if Task.isCancelled { return }
        if let r: TrimsResponse = try? await auth.withFreshToken(.vehicleTrims(year: y, make: make, model: model)) {
            trimOptions = r.trims
        }
        await reestimate()
    }

    private func reestimate(delay: Bool = false) async {
        guard detailsReady, let y = yearValue, let m = milesValue else { return }
        if delay { try? await Task.sleep(for: .milliseconds(700)); if Task.isCancelled { return } }
        estimating = true
        if let r: VehicleEstimate = try? await auth.withFreshToken(.vehicleEstimate(
            year: y, make: draft.make, model: draft.model, trim: draft.trim.isEmpty ? nil : draft.trim, miles: m, vin: draft.vin
        )) {
            draft.value = String(Int(r.estimatedValue.rounded()))
            draft.range = (r.lowValue, r.highValue)
            draft.source = r.source
        }
        estimating = false
    }

    private func save() async {
        guard let y = yearValue, let m = milesValue, let v = Double(draft.value) else { return }
        busy = true; error = nil
        do {
            let _: AccountResponse = try await auth.withFreshToken(.createVehicle(
                vin: draft.vin, year: y, make: draft.make.trimmingCharacters(in: .whitespaces), model: draft.model.trimmingCharacters(in: .whitespaces),
                trim: draft.trim.isEmpty ? nil : draft.trim, miles: m, value: v
            ))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            let name = [draft.year, draft.make, draft.model, draft.trim].filter { !$0.isEmpty }.joined(separator: " ")
            saved.append(name)
            onSaved(name)
            reset(toManual: false)
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        busy = false
    }
}

/// The same flow as a sheet, for adding a car later from Accounts.
struct AddCarSheet: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                CarEntryView { _ in onSaved() }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Wash(tone: .accounts))
            .navigationTitle("Add a Car")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}
