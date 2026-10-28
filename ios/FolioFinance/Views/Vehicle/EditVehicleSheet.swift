import SwiftUI

/// Picks the right editor for an account: cars get their own, with odometer and yearly miles.
struct AccountEditSheet: View {
    let account: Account
    var onSaved: () -> Void

    var body: some View {
        if account.isManual && (account.subtype ?? "").lowercased() == "vehicle" {
            EditVehicleSheet(account: account, onSaved: onSaved)
        } else {
            EditAccountSheet(account: account, onSaved: onSaved)
        }
    }
}

private struct VehicleDetails: Decodable {
    let year: Int
    let make: String
    let model: String
    let trim: String?
    let miles: Int
    let annualMiles: Int?
    let averageAnnualMiles: Int
    let currentMiles: Int
    let valueIsManual: Bool
}

struct EditVehicleSheet: View {
    let account: Account
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager

    @State private var name: String
    @State private var valueText: String
    @State private var milesText = ""
    @State private var annualText = ""
    @State private var details: VehicleDetails?
    @State private var originalValue: String
    @State private var originalMiles = ""
    @State private var originalAnnual = ""
    @State private var saving = false
    @State private var estimating = false
    @State private var error: String?
    @State private var confirmDelete = false

    init(account: Account, onSaved: @escaping () -> Void) {
        self.account = account
        self.onSaved = onSaved
        let v = NSDecimalNumber(decimal: account.currentBalance).stringValue
        _name = State(initialValue: account.name)
        _valueText = State(initialValue: v)
        _originalValue = State(initialValue: v)
    }

    private func number(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: "")) }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && (number(valueText) ?? -1) >= 0 && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Name", text: $name) }

                Section {
                    HStack { Text("$").foregroundStyle(.secondary); TextField("0", text: $valueText).keyboardType(.decimalPad) }
                    Button {
                        Task { await reestimate() }
                    } label: {
                        HStack {
                            if estimating { ProgressView() } else { Image(systemName: "wand.and.stars") }
                            Text("Estimate from the car's details")
                        }
                    }
                    .disabled(estimating || details == nil)
                } header: { Text("Value") } footer: {
                    Text("Type your own number, or let Folio estimate it from the year, model, trim and mileage.")
                }

                Section {
                    HStack { Text("Odometer"); Spacer(); TextField("Miles", text: $milesText).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 140) }
                    HStack { Text("Miles you drive per year"); Spacer(); TextField(details.map { "≈ \($0.averageAnnualMiles.formatted())" } ?? "Optional", text: $annualText).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 120) }
                } header: { Text("Mileage") } footer: {
                    Text("Left blank, Folio figures it from the car's age and odometer. Either way it keeps the estimated value current as the odometer climbs. A value you type yourself stays put until you ask for an estimate.")
                }

                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }

                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text("Delete Account").font(.headline).frame(maxWidth: .infinity).frame(height: 30)
                    }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                } footer: { Text("Removes it from your net worth and history. This can't be undone.") }
            }
            .confirmationDialog("Delete \(account.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await remove() } }
            }
            .navigationTitle("Edit Car")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { if saving { ProgressView() } else { Text("Save").bold() } }
                        .disabled(!canSave)
                }
            }
            .task { await loadDetails() }
        }
        .presentationDetents([.large])
    }

    private func loadDetails() async {
        guard let d: VehicleDetails = try? await auth.withFreshToken(.vehicleDetails(accountId: account.id)) else { return }
        details = d
        milesText = String(d.currentMiles); originalMiles = milesText
        annualText = d.annualMiles.map(String.init) ?? ""; originalAnnual = annualText
    }

    private func reestimate() async {
        estimating = true; error = nil
        do {
            let r: AccountResponse = try await auth.withFreshToken(.updateVehicle(
                accountId: account.id, miles: Int(milesText.filter(\.isNumber)), annualMiles: Int(annualText.filter(\.isNumber)), reestimate: true
            ))
            let v = NSDecimalNumber(decimal: r.account.currentBalance).stringValue
            withAnimation(Motion.spring) { valueText = v }
            originalValue = v
            NotificationCenter.default.post(name: .accountsChanged, object: nil)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        estimating = false
    }

    private func save() async {
        saving = true; error = nil
        do {
            let newName = name.trimmingCharacters(in: .whitespaces)
            if newName != account.name {
                let _: AccountResponse = try await auth.withFreshToken(.renameAccount(id: account.id, name: newName))
                NotificationCenter.default.post(name: .accountRenamed, object: nil, userInfo: ["id": account.id, "name": newName])
            }
            let valueChanged = valueText != originalValue
            let milesChanged = milesText != originalMiles
            let annualChanged = annualText != originalAnnual
            if valueChanged || milesChanged || annualChanged {
                let _: AccountResponse = try await auth.withFreshToken(.updateVehicle(
                    accountId: account.id,
                    miles: milesChanged ? Int(milesText.filter(\.isNumber)) : nil,
                    annualMiles: annualChanged ? (Int(annualText.filter(\.isNumber)) ?? 0) : nil,
                    value: valueChanged ? number(valueText) : nil
                ))
            }
            NotificationCenter.default.post(name: .accountsChanged, object: nil)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onSaved()
            dismiss()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        saving = false
    }

    private func remove() async {
        saving = true; error = nil
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.deleteAccount(id: account.id))
            NotificationCenter.default.post(name: .accountRemoved, object: nil, userInfo: ["id": account.id])
            NotificationCenter.default.post(name: .accountsChanged, object: nil)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onSaved()
            dismiss()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        saving = false
    }
}
