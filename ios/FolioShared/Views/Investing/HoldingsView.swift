import SwiftUI

/// The top positions across every investment account, with what each is worth and how it has done since you bought it.
struct HoldingsCard: View {
    let summary: HoldingsSummary
    let accounts: [Account]

    var body: some View {
        NavigationLink { HoldingsScreen(summary: summary, accounts: accounts) } label: {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("What you own").font(.headline)
                        Spacer()
                        Text("All \(summary.holdings.count)").font(.subheadline).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    if let g = summary.gain, let p = summary.gainPercent {
                        HStack(spacing: 8) {
                            CountingText(signedMoney(g)).font(.title3.bold()).foregroundStyle(g >= 0 ? Color.up : Color.down).monospacedDigit().sensitive()
                            Text("(\(p >= 0 ? "+" : "")\(String(format: "%.1f", p))%) since you bought").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(summary.holdings.prefix(5)) { HoldingRow(h: $0) }
                    if summary.holdings.count > 5 { Text("and \(summary.holdings.count - 5) more").font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct HoldingRow: View {
    let h: HoldingsSummary.Holding
    var body: some View {
        HStack(spacing: 12) {
            Text((h.ticker ?? "CASH").prefix(5))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 46, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(h.name).font(.subheadline).lineLimit(1)
                Text(h.kind == "cash" ? "Cash" : "\(h.quantity.formatted(.number.precision(.fractionLength(0...2)))) shares · \(String(format: "%.0f", h.weight))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                CountingText(money(h.value)).font(.subheadline.weight(.semibold)).monospacedDigit().sensitive()
                if let p = h.gainPercent {
                    Text("\(p >= 0 ? "+" : "")\(String(format: "%.1f", p))%").font(.caption.weight(.semibold)).foregroundStyle(p >= 0 ? Color.up : Color.down).monospacedDigit()
                }
            }
        }
    }
}

/// Every position, grouped by account, with a split by type at the top.
struct HoldingsScreen: View {
    let summary: HoldingsSummary
    let accounts: [Account]

    private var groups: [(name: String, rows: [HoldingsSummary.Holding], total: Double)] {
        Dictionary(grouping: summary.holdings, by: \.accountId)
            .map { id, rows in
                let name = accounts.first { $0.id == id }?.name ?? (id.hasPrefix("demo-") ? id.replacingOccurrences(of: "demo-", with: "").capitalized : "Account")
                return (name, rows.sorted { $0.value > $1.value }, rows.reduce(0) { $0 + $1.value })
            }
            .sorted { $0.total > $1.total }
    }

    var body: some View {
        ZStack {
            Wash(tone: .plan)
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Total invested").font(.subheadline).foregroundStyle(.secondary)
                            CountingText(money(summary.total)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit().sensitive()
                            if let g = summary.gain, let p = summary.gainPercent {
                                CountingText("\(signedMoney(g)) (\(p >= 0 ? "+" : "")\(String(format: "%.1f", p))%) since you bought")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(g >= 0 ? Color.up : Color.down).monospacedDigit().sensitive()
                                if summary.coveredValue < summary.total * 0.95 {
                                    CountingText("Counts the \(money(summary.coveredValue)) where your broker reports what you paid.").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            if !summary.byKind.isEmpty {
                                GeometryReader { geo in
                                    HStack(spacing: 2) {
                                        ForEach(Array(summary.byKind.enumerated()), id: \.element.id) { i, k in
                                            Capsule().fill(kindColor(i)).frame(width: max(4, geo.size.width * k.percent / 100))
                                        }
                                    }
                                }.frame(height: 10)
                                ForEach(Array(summary.byKind.enumerated()), id: \.element.id) { i, k in
                                    HStack {
                                        Circle().fill(kindColor(i)).frame(width: 9, height: 9)
                                        Text(k.kind).font(.subheadline)
                                        Spacer()
                                        Text("\(String(format: "%.0f", k.percent))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                        CountingText(money(k.value)).font(.subheadline.weight(.medium)).monospacedDigit().frame(width: 88, alignment: .trailing).sensitive()
                                    }
                                }
                            }
                        }
                    }
                    ForEach(groups, id: \.name) { g in
                        VStack(spacing: 8) {
                            SectionTitle(g.name, trailing: money(g.total))
                            Card(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(g.rows.enumerated()), id: \.element.id) { i, r in
                                        if i > 0 { Divider().padding(.leading, 74) }
                                        HoldingRow(h: r).padding(.horizontal, 16).padding(.vertical, 11)
                                    }
                                }
                            }
                        }
                    }
                    Text("Values and what you paid come from your broker through Plaid and can be a day behind. Some accounts don't share what you paid, so those positions show no gain. General information, not financial advice.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 12)
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("What you own")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func kindColor(_ i: Int) -> Color { [Color.indigo, .teal, .orange, .pink, .gray][i % 5] }
}
