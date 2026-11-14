import SwiftUI

/// Credit use, editable: each card's balance and limit. When the bank doesn't report a limit (Apple Card, for one),
/// you type it in once and it's used from then on. Opens from the Credit use tile on Money health.
struct CreditUseView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var use: CreditUse?
    @State private var error: String?
    @State private var editing: CreditUse.Card?

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .plan)
                ScrollView {
                    VStack(spacing: 14) {
                        if let error { ErrorBanner(message: error) { Task { await load() } } }
                        if let use {
                            headline(use).entrance(0)
                            cardsCard(use).entrance(1)
                            Text("Using under 30% of your limits generally helps your credit score. Paying a card down before its statement closes lowers what's reported. Charge cards with no preset limit aren't counted, the same way current credit scores treat them.")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                .padding(.horizontal, 16).padding(.top, 4)
                            Text("General information based on your own data, not financial advice.")
                                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                        } else {
                            ProgressView().controlSize(.large).padding(.top, 80)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                    .animation(Motion.spring, value: use?.rate)
                }
            }
            .navigationTitle("Credit use")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { card in
                CardLimitSheet(card: card) { choice in Task { await save(card.id, choice) } }
            }
        }
        .task { await load() }
    }

    private func headline(_ u: CreditUse) -> some View {
        let level = u.rate.map { HealthMetric.credit.level($0) }
        return Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("You're using").font(.subheadline).foregroundStyle(.secondary)
                CountingText(u.rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .sensitive()
                CountingText(u.rate == nil
                             ? (u.missing > 0 ? "Add a card limit below to see this" : "Charge cards with no preset limit aren't counted")
                             : "\(money(u.balance)) of \(money(u.limit)) in card limits")
                    .font(.footnote).foregroundStyle(.secondary).sensitive()
                if let level {
                    let step = HealthMetric.credit.ladder[level]
                    Label("\(step.label) · under 30% helps your credit score", systemImage: level == 0 ? "checkmark.circle.fill" : level == 1 ? "minus.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(step.color)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(step.color.opacity(0.14), in: Capsule())
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cardsCard(_ u: CreditUse) -> some View {
        VStack(spacing: 8) {
            SectionTitle("Your cards", trailing: "Tap to set a limit")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    if u.cards.isEmpty {
                        Text("No credit cards yet.").font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(24)
                    }
                    ForEach(u.cards) { c in
                        Button { Haptic.tap(); editing = c } label: { cardRow(c) }
                            .buttonStyle(PressableRowStyle())
                        if c.id != u.cards.last?.id { Divider().padding(.leading, 62) }
                    }
                }
            }
        }
    }

    private func cardRow(_ c: CreditUse.Card) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: "creditcard.fill", color: AccountGroup.credit.color, size: 34)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(c.name).font(.body).lineLimit(1)
                    Spacer(minLength: 8)
                    CountingText(c.noLimit ? "Not counted" : c.used.map { "\(Int(($0 * 100).rounded()))%" } ?? "Add limit")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(c.noLimit ? Color.secondary : c.used == nil ? Color.accentColor : .primary)
                        .sensitive()
                }
                if let used = c.used {
                    ProgressBar(fraction: used, color: used > 0.30 ? .red : used > 0.10 ? .orange : .green)
                }
                CountingText(c.noLimit
                             ? "\(money(c.balance)) balance · no preset limit (charge card)"
                             : c.limit.map { "\(money(c.balance)) of \(money($0))" + (c.limitSource == "you" ? " · limit you entered" : "") }
                                ?? "\(money(c.balance)) balance · your bank didn't send a limit")
                    .font(.caption).foregroundStyle(.secondary).sensitive()
            }
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: Data

    private func load() async {
        error = nil
        do {
            let u: CreditUse = try await auth.withFreshToken(.creditUse)
            withAnimation(Motion.spring) { use = u }
        } catch APIError.server(404, _) {
            self.error = "This screen needs the newest Folio server. It works as soon as that update is live."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save(_ id: String, _ choice: Endpoint.CardLimit) async {
        do {
            let u: CreditUse = try await auth.withFreshToken(.saveCreditLimit(id: id, choice))
            withAnimation(Motion.spring) { use = u }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            NotificationCenter.default.post(name: .healthChanged, object: nil)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Set a card's limit, or say it has no preset limit (a charge card, left out of credit use).
private struct CardLimitSheet: View {
    let card: CreditUse.Card
    var onSave: (Endpoint.CardLimit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var noLimit = false
    @FocusState private var focused: Bool

    private var value: Double? { Double(text.replacingOccurrences(of: ",", with: "")) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("No preset limit", isOn: $noLimit.animation(Motion.spring))
                        .tint(.green)
                } footer: {
                    Text("Charge cards like the Amex Green, Gold and Platinum have no preset limit. Current credit scores leave them out of credit use, so Folio does too.")
                }
                if !noLimit {
                    Section {
                        HStack {
                            Text("$").foregroundStyle(.secondary)
                            TextField("0", text: $text).keyboardType(.numberPad).focused($focused)
                        }
                    } header: { Text("Credit limit") } footer: {
                        Text("It's on your card's statement or in its app. Folio uses it to work out how much of your credit you're using.")
                    }
                }
                if card.limitSource == "you" {
                    Section { Button("Go back to what my bank reports") { onSave(.bank); dismiss() } }
                }
            }
            .navigationTitle(card.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSave(noLimit ? .noLimit : .amount(value ?? 0)); dismiss()
                    } label: { Text("Save").bold() }
                    .disabled(!noLimit && (value ?? 0) <= 0)
                }
            }
            .onAppear {
                noLimit = card.noLimit
                if let l = card.limit { text = String(Int(l.rounded())) }
                if !noLimit { focused = true }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
