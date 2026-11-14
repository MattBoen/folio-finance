import SwiftUI

/// Emergency fund, editable: Folio picks which accounts count and you correct it with a toggle;
/// you also choose what it's measured against. Opens from the Emergency fund tile on Money health.
struct EmergencyFundView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var fund: EmergencyFund?
    @State private var sorting = false
    @State private var error: String?
    @State private var confirmReset = false

    enum Basis: String, CaseIterable, Identifiable {
        case essentials, usual, budget
        var id: String { rawValue }
        var title: String {
            switch self {
            case .essentials: "Essentials"
            case .usual: "Usual spending"
            case .budget: "Your budget"
            }
        }
        var detail: String {
            switch self {
            case .essentials: "Bills, groceries, gas and health: what you'd still pay if money got tight."
            case .usual: "Everything you normally spend in a month."
            case .budget: "The monthly budget you set on Spending."
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .plan)
                ScrollView {
                    VStack(spacing: 14) {
                        if let error { ErrorBanner(message: error) { Task { await load() } } }
                        if let fund {
                            headline(fund).entrance(0)
                            accountsCard(fund).entrance(1)
                            basisCard(fund).entrance(2)
                            footer(fund)
                        } else {
                            ProgressView().controlSize(.large).padding(.top, 80)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                    .animation(Motion.spring, value: fund?.months)
                    .animation(Motion.spring, value: sorting)
                }
            }
            .navigationTitle("Emergency fund")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Have Folio sort your accounts again?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Sort again") { Task { await reset() } }
            } message: { Text("Your own choices are cleared and Folio decides again from scratch. You can still change anything after.") }
        }
        .task { await load() }
    }

    // MARK: Pieces

    private func headline(_ f: EmergencyFund) -> some View {
        let basis = Basis(rawValue: f.basis) ?? .essentials
        let per = monthly(basis, f)
        let level = f.months.map { HealthMetric.emergency.level($0) }
        return Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your emergency fund covers").font(.subheadline).foregroundStyle(.secondary)
                CountingText(f.months.map { String(format: "%.1f months", $0) } ?? "—")
                    .font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .sensitive()
                CountingText("\(money(f.total)) set aside · \(per.map { money($0) + " a month of " + basis.title.lowercased() } ?? "no spending yet")")
                    .font(.footnote).foregroundStyle(.secondary).sensitive()
                if let level {
                    let step = HealthMetric.emergency.ladder[level]
                    Label("\(step.label) · 3 to 6 months is a common goal", systemImage: level == 0 ? "checkmark.circle.fill" : level == 1 ? "minus.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(step.color)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(step.color.opacity(0.14), in: Capsule())
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func accountsCard(_ f: EmergencyFund) -> some View {
        VStack(spacing: 8) {
            SectionTitle("Counts toward it", trailing: sorting ? nil : "Tap to change")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    if sorting {
                        HStack(spacing: 10) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Folio is sorting your accounts…").font(.subheadline).foregroundStyle(.secondary)
                                #if PERSONAL
                                Text("Your Mac's Ask Folio does this. It can take a minute.").font(.caption).foregroundStyle(.tertiary)
                                #endif
                            }
                            Spacer()
                        }
                        .padding(16)
                        Divider()
                    }
                    if f.accounts.isEmpty {
                        Text("Add a checking or savings account to see this.").font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(24)
                    }
                    ForEach(f.accounts) { a in
                        accountRow(a)
                        if a.id != f.accounts.last?.id { Divider().padding(.leading, 62) }
                    }
                }
            }
        }
    }

    private func accountRow(_ a: EmergencyFund.Account) -> some View {
        let tint = a.kind == "savings" ? AccountGroup.savings.color : AccountGroup.cash.color
        return Toggle(isOn: Binding(get: { a.included }, set: { v in Task { await set(a.id, v) } })) {
            HStack(spacing: 12) {
                IconBadge(symbol: a.kind == "savings" ? "leaf.fill" : "banknote.fill", color: tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(a.name).font(.body).lineLimit(1)
                        CountingText(money(a.balance)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().sensitive()
                    }
                    HStack(spacing: 4) {
                        // Only Ask Folio's own picks get its sparkles; rules and your choices are plain text.
                        if a.source == "ai" { Image(systemName: "sparkles") }
                        Text(a.reason).lineLimit(2)
                    }
                    .font(.caption).foregroundStyle(a.source == "ai" ? Color.indigo : .secondary)
                }
            }
        }
        .tint(.green)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .opacity(a.included ? 1 : 0.75)
        .sensoryFeedback(.selection, trigger: a.included)
    }

    private func monthly(_ b: Basis, _ f: EmergencyFund) -> Double? {
        switch b {
        case .essentials: f.monthly.essentials > 0 ? f.monthly.essentials : nil
        case .usual: f.monthly.usual > 0 ? f.monthly.usual : nil
        case .budget: f.monthly.budget
        }
    }

    private func basisCard(_ f: EmergencyFund) -> some View {
        VStack(spacing: 8) {
            SectionTitle("Measured against")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Basis.allCases) { b in
                        let amount = monthly(b, f)
                        let chosen = f.basis == b.rawValue
                        Button {
                            guard amount != nil, !chosen else { return }
                            Task { await setBasis(b) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(chosen ? Color.accentColor : Color.secondary.opacity(0.5))
                                    .contentTransition(.symbolEffect(.replace))
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(b.title).font(.body.weight(chosen ? .semibold : .regular))
                                        Spacer()
                                        CountingText(amount.map { money($0) + " / mo" } ?? "Not set")
                                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit().sensitive()
                                    }
                                    Text(b.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    if b == .essentials && chosen && !f.essentials.isEmpty {
                                        CountingText(f.essentials.map { "\($0.category) \(money($0.monthly))" }.joined(separator: " · "))
                                            .font(.caption2).foregroundStyle(.tertiary).sensitive()
                                    }
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableRowStyle())
                        .opacity(amount == nil ? 0.45 : 1)
                        .sensoryFeedback(.selection, trigger: chosen)
                        if b != Basis.allCases.last { Divider().padding(.leading, 52) }
                    }
                }
            }
        }
    }

    private var rulesNote: String {
        #if PERSONAL
        "Folio guessed from account names and types for now. Your Mac's Ask Folio sorts them properly the next time it's reachable. Anything you change stays the way you set it."
        #else
        "Folio guessed from account names and types: savings counts, checking doesn't. Turn on Ask Folio and it sorts them for you by looking at what each account is for."
        #endif
    }

    private func footer(_ f: EmergencyFund) -> some View {
        VStack(spacing: 10) {
            Text(f.sortedBy == "ai"
                 ? "Ask Folio sorted these from your account names and the money moving into them. Anything you change stays the way you set it."
                 : rulesNote)
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Have Folio sort them again") { confirmReset = true }
                .font(.subheadline.weight(.semibold))
                .disabled(sorting)
            Text("General information based on your own data, not financial advice.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16).padding(.top, 4)
    }

    // MARK: Data

    private func load() async {
        error = nil
        do {
            let f: EmergencyFund = try await auth.withFreshToken(.emergencyFund)
            withAnimation(Motion.spring) { fund = f }
            if f.canSort { await sort() }
        } catch APIError.server(404, _) {
            self.error = "This screen needs the newest Folio server. It works as soon as that update is live."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Ask Folio's AI looks over the accounts. If it can't (off, out of credits), the rules' guess stays.
    private func sort() async {
        sorting = true
        if let f: EmergencyFund = try? await auth.withFreshToken(.sortEmergencyFund) {
            withAnimation(Motion.spring) { fund = f }
            changed()
        }
        sorting = false
    }

    private func set(_ id: String, _ on: Bool) async {
        if var f = fund, let i = f.accounts.firstIndex(where: { $0.id == id }) {
            f.accounts[i].included = on
            f.accounts[i].source = "you"
            f.accounts[i].reason = on ? "You chose to count this" : "You chose to leave this out"
            withAnimation(Motion.spring) { fund = f }
        }
        await save(.saveEmergencyFund(included: [id: on]))
    }

    private func setBasis(_ b: Basis) async {
        withAnimation(Motion.spring) { fund?.basis = b.rawValue }
        await save(.saveEmergencyFund(basis: b.rawValue))
    }

    private func reset() async {
        await save(.saveEmergencyFund(reset: true))
        if fund?.canSort == true { await sort() }
    }

    private func save(_ endpoint: Endpoint) async {
        do {
            let f: EmergencyFund = try await auth.withFreshToken(endpoint)
            withAnimation(Motion.spring) { fund = f }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            changed()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func changed() { NotificationCenter.default.post(name: .healthChanged, object: nil) }
}
