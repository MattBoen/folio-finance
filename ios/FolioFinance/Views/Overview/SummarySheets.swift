import SwiftUI
import Charts

private func dbl(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }

/// "By type": each group is one row (icon, share, total) that drops down to its accounts.
private struct TypeDropdownCard: View {
    let groups: [AccountGroup]
    let accounts: [Account]
    let total: Double
    @State private var open: Set<AccountGroup> = []

    var body: some View {
        let present = groups.filter { g in accounts.contains { $0.group == g } }
        VStack(spacing: 8) {
            SectionTitle("By type")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(present) { g in
                        let list = accounts.filter { $0.group == g }.sorted { $0.currentBalance > $1.currentBalance }
                        let sum = list.reduce(0) { $0 + dbl($1.currentBalance) }
                        let isOpen = open.contains(g)
                        VStack(spacing: 0) {
                            Button {
                                withAnimation(Motion.spring) {
                                    if isOpen { open.remove(g) } else { open.insert(g) }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 12) {
                                        IconBadge(symbol: g.symbol, color: g.color, size: 34)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(g.rawValue).font(.body)
                                            Text("\(list.count) account\(list.count == 1 ? "" : "s") · \(Int((sum / max(total, 1) * 100).rounded()))%")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 8)
                                        Text((g.isLiability ? "−" : "") + money(sum)).font(.body.weight(.semibold)).monospacedDigit().sensitive()
                                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                                    }
                                    ProgressBar(fraction: sum / max(total, 1), color: g.color)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if isOpen {
                                VStack(spacing: 0) {
                                    ForEach(list) { a in
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(a.name).font(.subheadline).lineLimit(1)
                                                Text(detail(a, group: g)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                            Spacer(minLength: 8)
                                            Text((a.isLiability ? "−" : "") + money(a.currentBalance, cents: true))
                                                .font(.subheadline).monospacedDigit().sensitive()
                                        }
                                        .padding(.leading, 62).padding(.trailing, 16).padding(.vertical, 8)
                                    }
                                }
                                .padding(.bottom, 6)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            if g != present.last { Divider().padding(.leading, 62) }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .sensoryFeedback(.selection, trigger: open)
    }

    private func detail(_ a: Account, group g: AccountGroup) -> String {
        var sub = a.institutionName ?? a.typeLabel
        if g == .credit, let limitText = a.balanceLimit, let limit = Decimal(string: limitText), limit > 0 {
            sub += " · \(Int((dbl(a.currentBalance) / dbl(limit) * 100).rounded()))% of \(money(limit)) limit"
        }
        return sub
    }
}

struct AssetsSummarySheet: View {
    let accounts: [Account]
    let netWorth: Double

    var body: some View {
        let assets = accounts.filter { !$0.isLiability }
        let total = assets.reduce(0) { $0 + dbl($1.currentBalance) }
        let groups = AccountGroup.allCases.filter { !$0.isLiability }
        let biggest = groups.map { g in (g, assets.filter { $0.group == g }.reduce(0) { $0 + dbl($1.currentBalance) }) }.max { $0.1 < $1.1 }
        var caption: String?
        if let biggest, biggest.1 > 0 {
            caption = "Biggest holding: \(biggest.0.rawValue) (\(Int((biggest.1 / max(total, 1) * 100).rounded()))% of assets)"
            if netWorth > 0 { caption! += ". Assets equal \(Int((total / netWorth * 100).rounded()))% of your net worth." }
        }
        return BreakdownSheet(title: "Assets", headline: money(total), caption: caption) {
            TypeDropdownCard(groups: groups, accounts: assets, total: total)
        }
    }
}

struct LiabilitiesSummarySheet: View {
    let accounts: [Account]
    let assetsTotal: Double

    var body: some View {
        let debts = accounts.filter(\.isLiability)
        let total = debts.reduce(0) { $0 + dbl($1.currentBalance) }
        let caption = assetsTotal > 0 ? "Liabilities are \(Int((total / assetsTotal * 100).rounded()))% of your assets" : nil
        return BreakdownSheet(title: "Liabilities", headline: "−" + money(total), caption: caption, tone: .spending) {
            TypeDropdownCard(groups: AccountGroup.allCases.filter(\.isLiability), accounts: debts, total: total)
        }
    }
}

struct NetWorthSummarySheet: View {
    let assets: Double
    let liabilities: Double
    @EnvironmentObject private var auth: AuthManager
    @State private var series: [(date: Date, value: Double)] = []

    private var netWorth: Double { assets - liabilities }

    private func change(since start: Date) -> Double? {
        guard let first = series.first(where: { $0.date >= start }) ?? series.first, let last = series.last, series.count >= 2 else { return nil }
        return last.value - first.value
    }

    private var ranges: [(String, Date)] {
        let cal = Calendar.current, now = Date()
        return [
            ("Past month", cal.date(byAdding: .day, value: -30, to: now) ?? now),
            ("Past 3 months", cal.date(byAdding: .day, value: -90, to: now) ?? now),
            ("This year", cal.date(from: DateComponents(year: cal.component(.year, from: now), month: 1, day: 1)) ?? now),
            ("Past year", cal.date(byAdding: .day, value: -365, to: now) ?? now),
        ]
    }

    var body: some View {
        BreakdownSheet(
            title: "Net worth", headline: money(netWorth), caption: "Assets minus liabilities",
            sections: [
                BreakdownSection(title: "What makes it up", rows: [
                    BreakdownRow(symbol: "arrow.up.right", color: .green, title: "Assets", value: "+" + money(assets), valueColor: .up),
                    BreakdownRow(symbol: "arrow.down.right", color: .red, title: "Liabilities", value: "−" + money(liabilities), valueColor: .down),
                ]),
                BreakdownSection(title: "How it changed", rows: ranges.compactMap { name, start in
                    guard let c = change(since: start) else { return nil }
                    return BreakdownRow(title: name, value: signedMoney(c), valueColor: c >= 0 ? .up : .down)
                }),
            ]
        ) {
            if series.count >= 2 {
                Card {
                    Chart {
                        ForEach(Array(series.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("Date", p.date), y: .value("Net worth", p.value))
                                .foregroundStyle(Color.heroTop).interpolationMethod(.monotone)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxis(.hidden)
                    .frame(height: 110)
                    .sensitive()
                }
            }
        }
        .task {
            if let r: NetWorthHistoryResponse = try? await auth.withFreshToken(.netWorthHistory(days: 365)) {
                series = r.snapshots
                    .compactMap { s in parseDay(s.date).map { (date: $0, value: dbl(s.netWorthDecimal)) } }
                    .sorted { $0.date < $1.date }
            }
        }
    }
}
