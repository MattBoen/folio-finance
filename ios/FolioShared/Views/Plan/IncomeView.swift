import SwiftUI

/// Income, editable: every kind of money coming in, grouped the way your tax forms group it (paychecks, interest,
/// dividends, side work...), each with a switch for whether it counts toward your usual monthly income.
/// Things that look like income but aren't (tax refunds, reimbursements, cash back) start switched off.
struct IncomeView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var data: IncomeStreams?
    @State private var error: String?
    @State private var typeIt = false

    /// Tax-form order: income first, then the things that aren't.
    private static let order = ["wages", "self_employment", "interest", "dividends", "benefits", "retirement", "rental", "other_income",
                                "tax_refund", "reimbursement", "rewards", "from_people", "other"]

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .plan)
                ScrollView {
                    VStack(spacing: 14) {
                        if let error { ErrorBanner(message: error) { Task { await load() } } }
                        if let data {
                            headline(data).entrance(0)
                            if data.streams.isEmpty {
                                EmptyStateCard(symbol: "arrow.down.circle", title: "No money coming in yet",
                                               message: "Paychecks, interest and other deposits show up here once your accounts have some history.")
                            }
                            ForEach(Array(groups(data).enumerated()), id: \.element.kind) { i, g in
                                group(g.kind, g.rows).entrance(min(i + 1, 4))
                            }
                            Text("Averaged over the last \(data.months >= 11.95 ? "12" : String(format: "%.0f", max(1, data.months.rounded()))) months. Moving money between your own accounts and paying cards aren't counted. Amounts are what landed in your account, after taxes.")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                .padding(.horizontal, 16).padding(.top, 4)
                            Text("General information based on your own data, not tax advice.")
                                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                        } else {
                            ProgressView().controlSize(.large).padding(.top, 80)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                    .animation(Motion.spring, value: data?.monthly)
                }
            }
            .navigationTitle("Income")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $typeIt) {
                IncomeSheet(current: data?.monthly ?? 0, isManual: data?.source == "manual") {
                    Task { await load(); changed() }
                }
            }
        }
        .task { await load() }
    }

    private func groups(_ d: IncomeStreams) -> [(kind: String, rows: [IncomeStreams.Stream])] {
        let byKind = Dictionary(grouping: d.streams, by: \.kind)
        return Self.order.compactMap { k in byKind[k].map { (k, $0.sorted { $0.last12 > $1.last12 }) } }
    }

    // MARK: Pieces

    private func headline(_ d: IncomeStreams) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Usual monthly income").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button(d.source == "manual" ? "Edit" : "Set it myself") { typeIt = true }
                        .font(.subheadline.weight(.semibold))
                }
                CountingText(money(d.monthly))
                    .font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .sensitive()
                CountingText(d.source == "manual"
                             ? "The amount you entered. Your switches below would make it \(money(d.detected))."
                             : "\(money(d.ytd)) so far this year from what's switched on")
                    .font(.footnote).foregroundStyle(.secondary).sensitive()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func group(_ kind: String, _ rows: [IncomeStreams.Stream]) -> some View {
        let first = rows.first
        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(first?.kindLabel ?? "").font(.title3.bold())
                if let form = first?.taxForm {
                    Text(form).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(rows) { s in
                        row(s)
                        if s.id != rows.last?.id { Divider().padding(.leading, 62) }
                    }
                }
            }
        }
    }

    private func symbol(_ kind: String) -> (String, Color) {
        switch kind {
        case "wages": ("briefcase.fill", .green)
        case "interest": ("percent", .teal)
        case "dividends": ("chart.line.uptrend.xyaxis", .purple)
        case "self_employment": ("hammer.fill", .orange)
        case "benefits": ("building.columns.fill", .blue)
        case "retirement": ("clock.fill", .indigo)
        case "rental": ("house.fill", .brown)
        case "tax_refund": ("doc.text.fill", .gray)
        case "reimbursement": ("arrow.uturn.backward", .gray)
        case "rewards": ("gift.fill", .pink)
        case "from_people": ("person.2.fill", .cyan)
        default: ("arrow.down.circle.fill", .gray)
        }
    }

    private func row(_ s: IncomeStreams.Stream) -> some View {
        let (sym, color) = symbol(s.kind)
        return Toggle(isOn: Binding(get: { s.included }, set: { v in Task { await set(s.key, v) } })) {
            HStack(spacing: 12) {
                IconBadge(symbol: sym, color: color, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.body).lineLimit(1)
                    CountingText("\(money(s.monthly)) / mo · \(money(s.ytd)) this year")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().sensitive()
                    Text(s.source == "you" ? (s.included ? "You chose to count this" : "You chose to leave this out")
                         : "\(s.count) deposit\(s.count == 1 ? "" : "s") · last \(shortDate(s.lastDate))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .tint(.green)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .opacity(s.included ? 1 : 0.75)
        .sensoryFeedback(.selection, trigger: s.included)
    }

    // MARK: Data

    private func load() async {
        error = nil
        do {
            let d: IncomeStreams = try await auth.withFreshToken(.income)
            withAnimation(Motion.spring) { data = d }
        } catch APIError.server(404, _) {
            self.error = "This screen needs the newest Folio server. It works as soon as that update is live."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func set(_ key: String, _ on: Bool) async {
        if var d = data, let i = d.streams.firstIndex(where: { $0.key == key }) {
            d.streams[i].included = on
            d.streams[i].source = "you"
            withAnimation(Motion.spring) { data = d }
        }
        do {
            let d: IncomeStreams = try await auth.withFreshToken(.saveIncomeStream(key: key, included: on))
            withAnimation(Motion.spring) { data = d }
            changed()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func changed() { NotificationCenter.default.post(name: .healthChanged, object: nil) }
}
