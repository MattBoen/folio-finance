import SwiftUI
import Charts

struct OverviewView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var accounts: [Account] = []
    @State private var points: [Pt] = []
    @State private var range = 90
    @State private var isLoading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var selectedDate: Date?
    @State private var showAddAccount = false

    struct Pt: Identifiable {
        let id: Int
        let date: Date
        let value: Double
    }

    private var visible: [Account] { accounts.filter { !$0.isHidden } }

    private func total(_ g: AccountGroup) -> Double {
        visible.filter { $0.group == g }.reduce(0) { $0 + NSDecimalNumber(decimal: $1.currentBalance).doubleValue }
    }

    private var assets: Double { AccountGroup.allCases.filter { !$0.isLiability }.reduce(0) { $0 + total($1) } }
    private var liabilities: Double { AccountGroup.allCases.filter(\.isLiability).reduce(0) { $0 + total($1) } }
    private var netWorth: Double { assets - liabilities }

    private var rangeLabel: String {
        switch range { case 30: "past month"; case 365: "past year"; default: "past 3 months" }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .balance)
                ScrollView {
                    VStack(spacing: 14) {
                        if let error { ErrorBanner(message: error) { Task { await load() } } }
                        hero
                        if loaded && visible.isEmpty {
                            EmptyStateCard(
                                symbol: "plus.circle.fill",
                                title: "Add your first account",
                                message: "Enter a checking, savings, investment or loan balance to see your net worth take shape."
                            )
                            Button { showAddAccount = true } label: {
                                Label("Add account", systemImage: "plus")
                                    .font(.headline).frame(maxWidth: .infinity).frame(height: 30)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        } else if !visible.isEmpty {
                            chartCard.flowIn()
                            CompositionCard(title: "Assets", total: assets, rows: AccountGroup.allCases.filter { !$0.isLiability }.map { ($0, total($0)) }).flowIn()
                            if liabilities > 0 {
                                CompositionCard(title: "Liabilities", total: liabilities, rows: AccountGroup.allCases.filter(\.isLiability).map { ($0, total($0)) }).flowIn()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .refreshable { await load() }
                .overlay {
                    if isLoading && !loaded { ProgressView().controlSize(.large) }
                }
            }
            .navigationTitle("Overview")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ProfileMenu() } }
            .sheet(isPresented: $showAddAccount) { AddAccountSheet { Task { await load() } } }
        }
        .task { await load() }
        .onChange(of: range) { Task { await loadChart() } }
    }

    // MARK: Hero

    private var hero: some View {
        let delta: Double? = points.count >= 2 ? (points.last!.value - points.first!.value) : nil
        return VStack(alignment: .leading, spacing: 6) {
            Text("Net worth").font(.subheadline.weight(.semibold)).opacity(0.85)
            Text(money(netWorth))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
                .sensitive()
            if let delta {
                Label("\(signedMoney(delta)) \(rangeLabel)", systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .opacity(0.95)
                    .sensitive()
            }
            HStack(spacing: 18) {
                Text("Assets \(money(assets))")
                Text("Liabilities \(money(liabilities))")
            }
            .font(.footnote)
            .opacity(0.85)
            .padding(.top, 2)
            .sensitive()
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.heroTop, .heroBottom], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .shadow(color: Color.heroBottom.opacity(0.3), radius: 16, y: 8)
    }

    // MARK: Chart

    private var shown: Pt? {
        guard let selectedDate else { return points.last }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    private var chartCard: some View {
        let lo = points.map(\.value).min() ?? 0
        let hi = points.map(\.value).max() ?? 1
        let pad = max(1, (hi - lo) * 0.18)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Range", selection: $range) {
                    Text("1M").tag(30); Text("3M").tag(90); Text("1Y").tag(365)
                }
                .pickerStyle(.segmented)

                if points.count >= 2, let shown {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(money(shown.value))
                            .font(.title2.bold()).monospacedDigit()
                            .contentTransition(.numericText())
                            .sensitive()
                        Text(shown.date.formatted(.dateTime.month(.wide).day().year()))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Chart {
                        ForEach(points) { p in
                            AreaMark(x: .value("Date", p.date), yStart: .value("Base", lo - pad), yEnd: .value("Net worth", p.value))
                                .foregroundStyle(LinearGradient(colors: [Color.heroTop.opacity(0.32), Color.heroTop.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Date", p.date), y: .value("Net worth", p.value))
                                .foregroundStyle(Color.heroTop)
                                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                                .interpolationMethod(.monotone)
                        }
                        if selectedDate != nil {
                            RuleMark(x: .value("Date", shown.date))
                                .foregroundStyle(.secondary.opacity(0.5))
                            PointMark(x: .value("Date", shown.date), y: .value("Net worth", shown.value))
                                .foregroundStyle(Color.heroTop)
                                .symbolSize(70)
                        }
                    }
                    .chartXSelection(value: $selectedDate)
                    .chartYScale(domain: (lo - pad)...(hi + pad))
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine()
                            AxisValueLabel { if let x = v.as(Double.self) { Text(compactMoney(x)) } }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .frame(height: 180)
                    .sensitive()
                } else {
                    Label("History builds up daily. Check back tomorrow for your trend line.", systemImage: "clock")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: Loading

    private func load() async {
        isLoading = true
        error = nil
        do {
            let a: AccountsResponse = try await auth.withFreshToken(.accounts)
            accounts = a.accounts
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        // The trend chart is optional: accounts still show if history can't load.
        if let c: NetWorthHistoryResponse = try? await auth.withFreshToken(.netWorthHistory(days: range)) {
            points = Self.makePoints(c)
        }
        isLoading = false
        loaded = true
    }

    private func loadChart() async {
        if let resp: NetWorthHistoryResponse = try? await auth.withFreshToken(.netWorthHistory(days: range)) {
            withAnimation(.smooth) { points = Self.makePoints(resp) }
        }
    }

    private static func makePoints(_ r: NetWorthHistoryResponse) -> [Pt] {
        r.snapshots
            .compactMap { s in parseDay(s.date).map { (d: $0, v: NSDecimalNumber(decimal: s.netWorthDecimal).doubleValue) } }
            .sorted { $0.d < $1.d }
            .enumerated()
            .map { Pt(id: $0.offset, date: $0.element.d, value: $0.element.v) }
    }
}

// MARK: - Composition card (stacked bar + legend, like the Mac balance sheet)

struct CompositionCard: View {
    let title: String
    let total: Double
    let rows: [(AccountGroup, Double)]

    var body: some View {
        let active = rows.filter { $0.1 > 0 }
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer()
                    Text(money(total)).font(.title3.bold()).monospacedDigit().sensitive()
                }
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(active, id: \.0.id) { g, v in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(g.color)
                                .frame(width: max(4, (geo.size.width - CGFloat(active.count - 1) * 2) * v / max(total, 1)))
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(Capsule())

                VStack(spacing: 10) {
                    ForEach(active, id: \.0.id) { g, v in
                        HStack(spacing: 10) {
                            IconBadge(symbol: g.symbol, color: g.color, size: 28)
                            Text(g.rawValue).font(.subheadline)
                            Spacer()
                            Text("\(Int((v / max(total, 1) * 100).rounded()))%")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(money(v)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                .frame(minWidth: 84, alignment: .trailing)
                                .sensitive()
                        }
                    }
                }
            }
        }
    }
}
