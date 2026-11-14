import SwiftUI

/// Savings rate, editable: your income (Edit), the spending it's measured against, and what's left.
/// Spending follows the emergency fund's choice unless you pick something else here. Opens from Money health.
struct SavingsRateView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var rate: SavingsRate?
    @State private var error: String?
    @State private var editIncome = false

    private typealias Basis = EmergencyFundView.Basis

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .plan)
                ScrollView {
                    VStack(spacing: 14) {
                        if let error { ErrorBanner(message: error) { Task { await load() } } }
                        if let rate {
                            headline(rate).entrance(0)
                            workings(rate).entrance(1)
                            basisCard(rate).entrance(2)
                            Text("General information based on your own data, not financial advice.")
                                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                                .padding(.horizontal, 16).padding(.top, 4)
                        } else {
                            ProgressView().controlSize(.large).padding(.top, 80)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                    .animation(Motion.spring, value: rate?.rate)
                }
            }
            .navigationTitle("Savings rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $editIncome) {
                IncomeSheet(current: rate?.income ?? 0, isManual: rate?.incomeSource == "manual") {
                    Task { await load(); changed() }
                }
            }
        }
        .task { await load() }
    }

    // MARK: Pieces

    private func headline(_ r: SavingsRate) -> some View {
        let level = r.rate.map { HealthMetric.savings.level($0) }
        return Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("You keep").font(.subheadline).foregroundStyle(.secondary)
                CountingText(r.rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .sensitive()
                Text(r.rate == nil ? "Add your income to see this" : "of your income each month")
                    .font(.footnote).foregroundStyle(.secondary)
                if let level {
                    let step = HealthMetric.savings.ladder[level]
                    Label("\(step.label) · many people aim for 15% or more", systemImage: level == 0 ? "checkmark.circle.fill" : level == 1 ? "minus.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(step.color)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(step.color.opacity(0.14), in: Capsule())
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Income − spending = left over, each line clear about where it came from.
    private func workings(_ r: SavingsRate) -> some View {
        let basis = Basis(rawValue: r.basis) ?? .usual
        return VStack(spacing: 8) {
            SectionTitle("How it's worked out")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        IconBadge(symbol: "arrow.down.circle.fill", color: .green, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Income").font(.body)
                            Text(r.incomeSource == "manual" ? "The amount you entered" : "Found from your paychecks")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        CountingText(money(r.income)).font(.body.weight(.semibold)).monospacedDigit().sensitive()
                        Button("Edit") { editIncome = true }.font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider().padding(.leading, 62)
                    row(symbol: "cart.fill", color: .indigo, title: "Spending", sub: basis.title, value: "−" + money(r.spending))
                    Divider().padding(.leading, 62)
                    row(symbol: r.leftOver >= 0 ? "leaf.fill" : "exclamationmark.triangle.fill", color: r.leftOver >= 0 ? .green : .orange,
                        title: r.leftOver >= 0 ? "Left over" : "Short by", sub: "Each month", value: money(abs(r.leftOver)),
                        valueColor: r.leftOver >= 0 ? Color.up : Color.down)
                }
            }
        }
    }

    private func row(symbol: String, color: Color, title: String, sub: String, value: String, valueColor: Color = .primary) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            CountingText(value).font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(valueColor).sensitive()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func monthly(_ b: Basis, _ r: SavingsRate) -> Double? {
        switch b {
        case .essentials: r.monthly.essentials > 0 ? r.monthly.essentials : nil
        case .usual: r.monthly.usual > 0 ? r.monthly.usual : nil
        case .budget: r.monthly.budget
        }
    }

    private func basisCard(_ r: SavingsRate) -> some View {
        let fundTitle = (Basis(rawValue: r.fundBasis) ?? .essentials).title.lowercased()
        return VStack(spacing: 8) {
            SectionTitle("Spending counted as")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Basis.allCases) { b in
                        let amount = monthly(b, r)
                        let chosen = r.basis == b.rawValue
                        Button {
                            guard amount != nil, !chosen else { return }
                            Task { await save(b.rawValue) }
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
            Group {
                if r.followsFund {
                    Text("Matches your emergency fund (\(fundTitle)). Pick another here to set it separately.")
                } else {
                    Button("Match my emergency fund (\(fundTitle))") { Task { await save("match") } }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.top, 4)
        }
    }

    // MARK: Data

    private func load() async {
        error = nil
        do {
            let r: SavingsRate = try await auth.withFreshToken(.savingsRate)
            withAnimation(Motion.spring) { rate = r }
        } catch APIError.server(404, _) {
            self.error = "This screen needs the newest Folio server. It works as soon as that update is live."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save(_ basis: String) async {
        if basis != "match" { withAnimation(Motion.spring) { rate?.basis = basis } }
        do {
            let r: SavingsRate = try await auth.withFreshToken(.saveSavingsRate(basis: basis))
            withAnimation(Motion.spring) { rate = r }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            changed()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func changed() { NotificationCenter.default.post(name: .healthChanged, object: nil) }
}
