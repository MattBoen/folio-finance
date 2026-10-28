import SwiftUI
import Charts

struct OverviewView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var accounts: [Account] = []
    @State private var points: [Pt] = []
    @State private var range: Span = .threeMonths
    @State private var showBreakdown = false
    @State private var isLoading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var selectedDate: Date?
    @State private var showAddAccount = false

    enum Span: String, CaseIterable, Identifiable {
        case month = "1M", threeMonths = "3M", ytd = "YTD", year = "1Y"
        var id: String { rawValue }
        /// Days of history to request (the API accepts 7 to 365).
        var days: Int {
            switch self {
            case .month: 30
            case .threeMonths: 90
            case .year: 365
            case .ytd: min(365, max(7, (Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 90)))
            }
        }
        var label: String {
            switch self { case .month: "past month"; case .threeMonths: "past 3 months"; case .ytd: "so far this year"; case .year: "past year" }
        }
    }

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

    private var rangeLabel: String { range.label }

    private func accounts(in g: AccountGroup) -> [Account] {
        visible.filter { $0.group == g }.sorted { $0.currentBalance > $1.currentBalance }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .balance)
                ScrollView {
                    VStack(spacing: 14) {
                        if let error { ErrorBanner(message: error) { Task { await load() } } }
                        Button {
                            withAnimation(.smooth(duration: 0.45)) { showBreakdown.toggle() }
                        } label: { hero }
                        .buttonStyle(PressableCardStyle())
                        .sensoryFeedback(.selection, trigger: showBreakdown)
                        if showBreakdown && !visible.isEmpty {
                            BreakdownCard(netWorth: netWorth, assets: assets, liabilities: liabilities, groups: AccountGroup.allCases.map { ($0, total($0), accounts(in: $0)) })
                                .transition(.asymmetric(insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity), removal: .opacity))
                        }
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
                            CompositionCard(title: "Assets", total: assets, rows: AccountGroup.allCases.filter { !$0.isLiability }.map { ($0, total($0), accounts(in: $0)) }).flowIn()
                            if liabilities > 0 {
                                CompositionCard(title: "Liabilities", total: liabilities, rows: AccountGroup.allCases.filter(\.isLiability).map { ($0, total($0), accounts(in: $0)) }).flowIn()
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
            HStack {
                Text("Net worth").font(.subheadline.weight(.semibold)).opacity(0.85)
                Spacer()
                Image(systemName: "chevron.down").font(.footnote.weight(.bold)).opacity(0.8)
                    .rotationEffect(.degrees(showBreakdown ? 180 : 0))
            }
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
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
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
        if let c: NetWorthHistoryResponse = try? await auth.withFreshToken(.netWorthHistory(days: range.days)) {
            points = Self.makePoints(c)
        }
        isLoading = false
        loaded = true
    }

    private func loadChart() async {
        if let resp: NetWorthHistoryResponse = try? await auth.withFreshToken(.netWorthHistory(days: range.days)) {
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

// MARK: - Press feedback

struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Account lines inside an expanded group

struct AccountLines: View {
    let accounts: [Account]
    var body: some View {
        VStack(spacing: 8) {
            ForEach(accounts) { a in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.name).font(.subheadline).lineLimit(1)
                        if let inst = a.institutionName { Text(inst).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 8)
                    Text((a.isLiability ? "−" : "") + money(a.currentBalance, cents: true))
                        .font(.subheadline).monospacedDigit().sensitive()
                }
            }
        }
        .padding(.leading, 38)
        .padding(.top, 2)
    }
}

// MARK: - Composition card (stacked bar + legend; tap a group to see its accounts)

struct CompositionCard: View {
    let title: String
    let total: Double
    let rows: [(AccountGroup, Double, [Account])]
    @State private var open: AccountGroup?

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
                        ForEach(active, id: \.0.id) { g, v, _ in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(g.color)
                                .opacity(open == nil || open == g ? 1 : 0.3)
                                .frame(width: max(4, (geo.size.width - CGFloat(active.count - 1) * 2) * v / max(total, 1)))
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(Capsule())
                .animation(.smooth, value: open)

                VStack(spacing: 12) {
                    ForEach(active, id: \.0.id) { g, v, accts in
                        VStack(spacing: 0) {
                            Button {
                                withAnimation(.smooth(duration: 0.4)) { open = open == g ? nil : g }
                            } label: {
                                HStack(spacing: 10) {
                                    IconBadge(symbol: g.symbol, color: g.color, size: 28)
                                    Text(g.rawValue).font(.subheadline)
                                    Spacer()
                                    Text("\(Int((v / max(total, 1) * 100).rounded()))%")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(money(v)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                        .frame(minWidth: 84, alignment: .trailing)
                                        .sensitive()
                                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                                        .rotationEffect(.degrees(open == g ? 90 : 0))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if open == g {
                                AccountLines(accounts: accts)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                    .padding(.bottom, 4)
                            }
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: open)
            }
        }
    }
}

// MARK: - What goes into net worth (assets and liabilities, each expandable down to accounts)

struct BreakdownCard: View {
    let netWorth: Double
    let assets: Double
    let liabilities: Double
    let groups: [(AccountGroup, Double, [Account])]

    @State private var side: Side?
    @State private var group: AccountGroup?
    private enum Side { case assets, liabilities }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("What makes up your net worth").font(.headline)
                sideRow("Assets", assets, .assets, color: .up)
                sideRow("Liabilities", liabilities, .liabilities, color: .down, negative: true)
                Divider()
                HStack {
                    Text("Net worth").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(money(netWorth)).font(.title3.bold()).monospacedDigit().sensitive()
                }
            }
        }
        .sensoryFeedback(.selection, trigger: side)
        .sensoryFeedback(.selection, trigger: group)
    }

    @ViewBuilder private func sideRow(_ title: String, _ value: Double, _ s: Side, color: Color, negative: Bool = false) -> some View {
        let rows = groups.filter { ($0.0.isLiability == (s == .liabilities)) && $0.1 > 0 }
        VStack(spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.4)) { side = side == s ? nil : s; group = nil }
            } label: {
                HStack {
                    Circle().fill(color).frame(width: 9, height: 9)
                    Text(title).font(.body)
                    Spacer()
                    Text((negative ? "−" : "+") + money(value)).font(.body.weight(.semibold)).monospacedDigit().sensitive()
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(side == s ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if side == s {
                VStack(spacing: 10) {
                    ForEach(rows, id: \.0.id) { g, v, accts in
                        VStack(spacing: 4) {
                            Button {
                                withAnimation(.smooth(duration: 0.4)) { group = group == g ? nil : g }
                            } label: {
                                HStack(spacing: 10) {
                                    IconBadge(symbol: g.symbol, color: g.color, size: 26)
                                    Text(g.rawValue).font(.subheadline)
                                    Spacer()
                                    Text(money(v)).font(.subheadline).monospacedDigit().sensitive()
                                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                                        .rotationEffect(.degrees(group == g ? 90 : 0))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if group == g { AccountLines(accounts: accts).transition(.opacity.combined(with: .move(edge: .top))) }
                        }
                    }
                }
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
