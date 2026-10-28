import SwiftUI
import Charts

struct OverviewView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var accounts: [Account] = []
    @State private var points: [Pt] = []
    @State private var monthTxns: [Transaction] = []
    @State private var budgets: [BudgetLine] = []
    @State private var range: Span = .ytd
    @State private var isLoading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var selectedDate: Date?
    @State private var showAddAccount = false
    @State private var detail: Transaction?

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

    private func accounts(in g: AccountGroup) -> [Account] {
        visible.filter { $0.group == g }.sorted { $0.currentBalance > $1.currentBalance }
    }

    private var assets: Double { AccountGroup.allCases.filter { !$0.isLiability }.reduce(0) { $0 + total($1) } }
    private var liabilities: Double { AccountGroup.allCases.filter(\.isLiability).reduce(0) { $0 + total($1) } }
    private var netWorth: Double { assets - liabilities }

    private var counted: [Transaction] {
        monthTxns.filter { !$0.isExcluded && !$0.category.lowercased().contains("transfer") }
    }
    private var spentThisMonth: Double { counted.filter(\.isDebit).reduce(0) { $0 + $1.doubleAmount } }
    private var earnedThisMonth: Double { counted.filter { !$0.isDebit }.reduce(0) { $0 + abs($1.doubleAmount) } }

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
                            thisMonthCard.flowIn()
                            if !budgets.isEmpty { budgetCard.flowIn() }
                            recentCard.flowIn()
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
            .sheet(item: $detail) { t in
                TransactionDetailView(transaction: t, all: monthTxns) { Task { await load() } }
            }
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
                Label("\(signedMoney(delta)) \(range.label)", systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
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

    // MARK: This month

    private var thisMonthCard: some View {
        let net = earnedThisMonth - spentThisMonth
        let top = max(earnedThisMonth, spentThisMonth, 1)
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(Date().formatted(.dateTime.month(.wide))).font(.headline)
                    Spacer()
                    Text(net >= 0 ? "\(money(net)) ahead" : "\(money(-net)) over")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(net >= 0 ? Color.up : Color.down)
                        .sensitive()
                }
                monthBar("Income", earnedThisMonth, top, .up)
                monthBar("Spent", spentThisMonth, top, Color(hex: 0x5E5CE6))
            }
        }
    }

    private func monthBar(_ label: String, _ value: Double, _ top: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(money(value)).font(.subheadline.weight(.semibold)).monospacedDigit().sensitive()
            }
            ProgressBar(fraction: value / top, color: color)
        }
    }

    // MARK: Budget glance

    private var budgetCard: some View {
        let total = budgets.reduce(0) { $0 + $1.monthlyAmount }
        let spent = budgets.reduce(0) { $0 + $1.spent }
        let tight = budgets.filter { $0.monthlyAmount > 0 }.sorted { $0.spent / $0.monthlyAmount > $1.spent / $1.monthlyAmount }.prefix(3)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Budget").font(.headline)
                    Spacer()
                    Text(spent > total ? "\(money(spent - total)) over" : "\(money(total - spent)) left")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(spent > total ? Color.down : .primary)
                        .sensitive()
                }
                ProgressBar(fraction: total > 0 ? spent / total : 0, color: spent > total ? .red : spent / max(total, 1) > 0.85 ? .orange : .green)
                ForEach(Array(tight)) { b in
                    HStack {
                        Text(b.category).font(.subheadline)
                        Spacer()
                        Text("\(money(b.spent)) of \(money(b.monthlyAmount))")
                            .font(.caption).foregroundStyle(b.spent > b.monthlyAmount ? Color.down : .secondary).monospacedDigit().sensitive()
                    }
                }
            }
        }
    }

    // MARK: Recent activity

    private var recentCard: some View {
        let recent = monthTxns.sorted { $0.date > $1.date }.prefix(5)
        return VStack(spacing: 8) {
            SectionTitle("Recent activity")
            if recent.isEmpty {
                Card { Text("Nothing yet this month.").font(.subheadline).foregroundStyle(.secondary) }
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(recent)) { t in
                            Button { detail = t } label: {
                                TransactionRow(transaction: t)
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if t.id != recent.last?.id { Divider().padding(.leading, 66) }
                        }
                    }
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
        // Everything below is optional: accounts still show if any of it can't load.
        if let c: NetWorthHistoryResponse = try? await auth.withFreshToken(.netWorthHistory(days: range.days)) {
            points = Self.makePoints(c)
        }
        let now = Date()
        let start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now)) ?? now
        if let t: TransactionsResponse = try? await auth.withFreshToken(.transactions(from: dayString(start), to: dayString(now), limit: 500)) {
            monthTxns = t.transactions
        }
        if let b: BudgetsResponse = try? await auth.withFreshToken(.budgets) {
            budgets = b.budgets
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
