import SwiftUI
import WidgetKit
import Charts

struct OverviewView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var accounts: [Account] = []
    /// The whole year, loaded once; switching ranges just trims it, so it's instant.
    @State private var allPoints: [Pt] = []
    @State private var monthTxns: [Transaction] = []
    @State private var budgets: [BudgetLine] = []
    @State private var range: Span = .ytd
    @State private var isLoading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var selectedDate: Date?
    @State private var showAddAccount = false
    @State private var showConnect = false
    @State private var showCar = false
    @State private var detail: Transaction?
    @State private var summary: Summary?
    @State private var recurring: Recurring?
    @State private var usualIncome: Double = 0
    @State private var insights: Insights?
    @State private var banks: [PlaidItem] = []
    @EnvironmentObject private var router: TabRouter
    @Namespace private var zoom
    /// Screens the month and budget tiles open in place (zooming out of the tile) instead of switching tabs.
    @State private var opened: Opened?

    enum Opened: String, Identifiable, Hashable { case month, health; var id: String { rawValue } }

    enum Summary: String, Identifiable { case netWorth, assets, liabilities; var id: String { rawValue } }

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

    private var points: [Pt] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -range.days, to: Date()) ?? .distantPast
        return allPoints.filter { $0.date >= cutoff }
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
                        if let b = banks.first(where: { $0.status != .active }) { bankAttention(b) }
                        TileButton { summary = .netWorth } content: { hero }.zoomSource(Summary.netWorth, in: zoom).flowIn(0)
                        if loaded && visible.isEmpty {
                            EmptyStateCard(
                                symbol: "plus.circle.fill",
                                title: "Add your first account",
                                message: "Connect your bank to see your net worth, spending and budget fill in on their own."
                            )
                            Button { showConnect = true } label: {
                                Label("Connect a bank", systemImage: "link")
                                    .font(.headline).frame(maxWidth: .infinity).frame(height: 30)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            Button("Add an account by hand") { showAddAccount = true }.font(.subheadline)
                        } else if !visible.isEmpty {
                            chartCard.flowIn(1)
                            thisMonthCard.zoomSource(Opened.month, in: zoom).flowIn(2)
                            if let r = recurring, !r.upcoming.isEmpty { comingUpCard(r).flowIn(2) }
                            recentCard.flowIn(3)
                            if let insights { healthCard(insights.health).zoomSource(Opened.health, in: zoom).flowIn(4) }
                            TileButton { summary = .assets } content: {
                                CompositionCard(title: "Assets", total: assets, rows: AccountGroup.allCases.filter { !$0.isLiability }.map { ($0, total($0)) })
                            }.zoomSource(Summary.assets, in: zoom).flowIn(5)
                            if liabilities > 0 {
                                TileButton { summary = .liabilities } content: {
                                    CompositionCard(title: "Liabilities", total: liabilities, rows: AccountGroup.allCases.filter(\.isLiability).map { ($0, total($0)) })
                                }.zoomSource(Summary.liabilities, in: zoom).flowIn(6)
                            }
                        } else {
                            ForEach(0..<2, id: \.self) { _ in Card { Color.clear.frame(height: 150) }.redacted(reason: .placeholder).shimmer() }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .folioRefresh {
                    async let banks: Void = BankSync.refreshForPull(auth)
                    await load()
                    await banks
                    await load()
                }
                .overlay {
                    if isLoading && !loaded { ProgressView().controlSize(.large) }
                }
            }
            .navigationTitle("Overview")
            .onReceive(NotificationCenter.default.publisher(for: .accountsChanged)) { _ in Task { await load() } }
            .onReceive(NotificationCenter.default.publisher(for: .healthChanged)) { _ in
                Task { if let i: Insights = try? await auth.withFreshToken(.insights) { withAnimation(.smooth) { insights = i } } }
            }
            .toolbar {
                #if !PERSONAL
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showConnect = true } label: { Label("Connect a bank", systemImage: "link") }
                        Button { showAddAccount = true } label: { Label("Add account by hand", systemImage: "square.and.pencil") }
                        Button { showCar = true } label: { Label("Add a car", systemImage: "car.fill") }
                    } label: { Image(systemName: "plus") }.accessibilityLabel("Add")
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) { ProfileMenu() }
            }
            .sheet(isPresented: $showAddAccount) { AddAccountSheet { Task { await load() } } }
            .sheet(isPresented: $showConnect, onDismiss: { Task { await load() } }) { PlaidLinkSheet() }
            .sheet(isPresented: $showCar, onDismiss: { Task { await load() } }) { AddCarSheet { Task { await load() } } }
            .sheet(item: $summary) { kind in
                Group {
                    switch kind {
                    case .netWorth: NetWorthSummarySheet(assets: assets, liabilities: liabilities)
                    case .assets: AssetsSummarySheet(accounts: visible, netWorth: netWorth)
                    case .liabilities: LiabilitiesSummarySheet(accounts: visible, assetsTotal: assets)
                    }
                }
                .zoomed(from: kind, in: zoom)
            }
            .sheet(item: $detail) { t in
                TransactionDetailView(transaction: t, all: monthTxns) { Task { await load() } }
                    .zoomed(from: t.id, in: zoom)
            }
            .navigationDestination(item: $opened) { o in
                Group {
                    switch o {
                    case .month: SpendingView(embedded: true, initial: monthTxns).navigationTitle("Spending")
                    case .health: PlanView(embedded: true, initial: insights).navigationTitle("Money health")
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .zoomed(from: o, in: zoom)
            }
        }
        .task { await load() }
    }

    // MARK: Hero

    private var hero: some View {
        let delta: Double? = points.count >= 2 ? (points.last!.value - points.first!.value) : nil
        return VStack(alignment: .leading, spacing: 6) {
            Text("Net worth").font(.subheadline.weight(.semibold)).opacity(0.85)
            CountUpText(value: netWorth)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .sensitive()
            if let delta {
                Label("\(signedMoney(delta)) \(range.label)", systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .opacity(0.95)
                    .sensitive()
            }
            HStack(spacing: 18) {
                CountingText("Assets \(money(assets))")
                CountingText("Liabilities \(money(liabilities))")
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
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            CountingText(money(shown.value))
                                .font(.title2.bold()).monospacedDigit()
                                .contentTransition(.numericText())
                                .sensitive()
                            Text(shown.date.formatted(.dateTime.month(.wide).day().year()))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        PeriodChangeBadge(first: points.first?.value ?? 0, last: points.last?.value ?? 0)
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
                            AxisValueLabel { if let x = v.as(Double.self) { CountingText(folioCompact(x)) } }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: axisDates(points.map(\.date))) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day(), anchor: .top)
                        }
                    }
                    .frame(height: 180)
                    .animation(.smooth(duration: 0.35), value: range)
                    .chartReveal(id: allPoints.count)
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
        return TileButton { opened = .month } content: {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(Date().formatted(.dateTime.month(.wide))).font(.headline)
                        Spacer()
                        CountingText(net >= 0 ? "\(money(net)) ahead" : "\(money(-net)) over")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(net >= 0 ? Color.up : Color.down)
                            .sensitive()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    monthBar("Income", earnedThisMonth, top, .up)
                    monthBar("Spent", spentThisMonth, top, Color(hex: 0x5E5CE6))
                    if !budgets.isEmpty {
                        Divider()
                        budgetGlance
                    }
                    if let left = leftAfterBills {
                        Divider()
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(left >= 0 ? "Left after bills still due" : "Short after bills still due").font(.subheadline)
                                Text("Usual income, minus what you've spent and the bills coming before month end").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            CountingText(money(abs(left))).font(.headline).foregroundStyle(left >= 0 ? Color.primary : Color.down).monospacedDigit().sensitive()
                        }
                    }
                }
            }
        }
    }

    private func monthBar(_ label: String, _ value: Double, _ top: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                CountingText(money(value)).font(.subheadline.weight(.semibold)).monospacedDigit().sensitive()
            }
            ProgressBar(fraction: value / top, color: color)
        }
    }

    /// What's left of the month's income once what you've spent and the bills still to come are taken out.
    private var leftAfterBills: Double? {
        guard let r = recurring, usualIncome > 0 || earnedThisMonth > 0 else { return nil }
        return max(usualIncome, earnedThisMonth) - spentThisMonth - r.dueThisMonth
    }

    // MARK: Bank health

    private func bankAttention(_ b: PlaidItem) -> some View {
        TileButton {
            UserDefaults.standard.set(MoneyView.Segment.accounts.rawValue, forKey: "moneySegment")
            router.selected = .money
        } content: {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(b.institutionName ?? "A bank") needs you to sign in again").font(.subheadline.weight(.semibold))
                    Text("Numbers from it are out of date until you do. Tap to fix it.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: Coming up

    private func comingUpCard(_ r: Recurring) -> some View {
        let next = r.upcoming.prefix(3)
        return NavigationLink { BillsView() } label: {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Coming up").font(.headline)
                        Spacer()
                        CountingText("\(money(r.dueNext30)) in 30 days").font(.subheadline.weight(.semibold)).monospacedDigit().sensitive()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    ForEach(Array(next), id: \.uid) { u in
                        HStack(spacing: 12) {
                            DateChip(date: u.date)
                            Text(u.name).font(.subheadline).lineLimit(1)
                            Spacer(minLength: 8)
                            CountingText((u.estimated ? "~" : "") + money(u.amount, cents: true)).font(.subheadline).monospacedDigit().sensitive()
                        }
                    }
                    if r.subscriptionsMonthly > 0 {
                        Divider()
                        CountingText("Subscriptions cost you \(money(r.subscriptionsMonthly * 12)) a year. See them all").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Budget glance

    /// Budget left, inside the month card (it used to be its own card that repeated the same month).
    /// Only categories close to or over their limit are named; the full list is one tap away on Spending.
    private var budgetGlance: some View {
        #if PERSONAL
        let budgets = self.budgets   // the Mac's figures, which leave out reimbursed work purchases
        #else
        let budgets = BudgetLine.measured(self.budgets, against: counted.filter(\.isDebit))   // matches the Spending tab
        #endif
        let total = budgets.reduce(0) { $0 + $1.monthlyAmount }
        let spent = budgets.reduce(0) { $0 + $1.spent }
        let tight = budgets.filter { $0.monthlyAmount > 0 && $0.spent / $0.monthlyAmount > 0.85 }
            .sorted { $0.spent / $0.monthlyAmount > $1.spent / $1.monthlyAmount }.prefix(3)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Budget").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                CountingText(spent > total ? "\(money(spent - total)) over" : "\(money(total - spent)) left of \(money(total))")
                    .font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7).monospacedDigit()
                    .foregroundStyle(spent > total ? Color.down : .primary)
                    .sensitive()
            }
            ProgressBar(fraction: total > 0 ? spent / total : 0, color: spent > total ? .red : spent / max(total, 1) > 0.85 ? .orange : .green)
            ForEach(Array(tight)) { b in
                HStack(spacing: 6) {
                    Circle().fill(b.spent > b.monthlyAmount ? Color.red : .orange).frame(width: 6, height: 6)
                    Text(b.category).font(.caption)
                    Spacer()
                    CountingText("\(money(b.spent)) of \(money(b.monthlyAmount))")
                        .font(.caption).foregroundStyle(b.spent > b.monthlyAmount ? Color.down : .secondary).monospacedDigit().sensitive()
                }
            }
        }
    }

    // MARK: Money health

    /// The four health scores at a glance; tap for income, usual spending and how each score is worked out.
    private func healthCard(_ h: Insights.Health) -> some View {
        let items: [(HealthMetric, Double?)] = HealthMetric.allCases.map { ($0, $0.value(h)) }
        return TileButton { opened = .health } content: {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Money health").font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                        ForEach(items, id: \.0) { item in
                            let m = item.0, v = item.1
                            HStack(spacing: 8) {
                                Circle().fill(v.map { m.ladder[m.level($0)].color } ?? .gray).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    CountingText(v.map { m.format($0) } ?? "—").font(.subheadline.weight(.semibold)).monospacedDigit().sensitive()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
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
                            Button { Haptic.tap(); detail = t } label: {
                                TransactionRow(transaction: t)
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableRowStyle())
                            .zoomSource(t.id, in: zoom)
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
        if let c: NetWorthHistoryResponse = try? await auth.withFreshToken(.netWorthHistory(days: Span.year.days)) {
            allPoints = Self.makePoints(c)
        }
        let now = Date()
        let start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now)) ?? now
        if let t: TransactionsResponse = try? await auth.withFreshToken(.transactions(from: dayString(start), to: dayString(now), limit: 500)) {
            monthTxns = t.transactions
        }
        if let b: BudgetsResponse = try? await auth.withFreshToken(.budgets) {
            budgets = b.budgets
        }
        if let r: Recurring = try? await auth.withFreshToken(.recurring) { recurring = r }
        if let i: Insights = try? await auth.withFreshToken(.insights) { usualIncome = i.income.monthly; insights = i }
        if !auth.isDemo, let p: PlaidItemsResponse = try? await auth.withFreshToken(.plaidItems) { banks = p.items }
        isLoading = false
        loaded = true
        #if !PERSONAL
        publishWidgetSnapshot()
        #endif
        // Pull anything new from connected banks in the background; reload only if something changed.
        if let r = await BankSync.run(auth), r.synced > 0 { await load() }
    }

    #if !PERSONAL
    /// Leaves a summary where the home-screen widgets can read it (Folio Desktop's widgets read the Mac's feed instead).
    private func publishWidgetSnapshot() {
        guard !visible.isEmpty else { return }
        let series = points.map(\.value)
        let spendByCategory = Dictionary(grouping: counted.filter(\.isDebit), by: \.category).mapValues { $0.reduce(0) { $0 + $1.doubleAmount } }
        var snap = WidgetSnapshot(
            netWorth: netWorth,
            change: (series.last ?? 0) - (series.first ?? 0),
            changeLabel: range.label.replacingOccurrences(of: "so far ", with: ""),
            series: Array(allPoints.suffix(30).map(\.value)),
            spent: spentThisMonth, income: earnedThisMonth,
            budgetTotal: budgets.reduce(0) { $0 + $1.monthlyAmount },
            budgetSpent: budgets.reduce(0) { $0 + $1.spent },
            hideAmounts: UserDefaults.standard.bool(forKey: "hideAmounts"),
            updated: Date()
        )
        snap.monthLabel = Date().formatted(.dateTime.month(.wide))
        snap.netCash = total(.cash) + total(.savings) - total(.credit)
        snap.invested = total(.investments)
        snap.budgetItems = budgets.map { b in WidgetSnapshot.BudgetLine(name: b.category, limit: b.monthlyAmount, spent: b.spent, color: Categories.style(b.category).color.hexString) }
        snap.categories = spendByCategory.map { WidgetSnapshot.Category(name: $0.key, total: $0.value, mine: $0.value, color: Categories.style($0.key).color.hexString) }
        snap.recent = monthTxns.filter { $0.isDebit && !$0.category.lowercased().contains("transfer") }.sorted { ($0.date, $0.id) > ($1.date, $1.id) }.prefix(8)
            .map { WidgetSnapshot.Purchase(id: $0.id, name: $0.displayName, amount: $0.doubleAmount, color: Categories.style($0.category).color.hexString, excluded: $0.isExcluded) }
        let invAccounts = accounts(in: .investments)
        snap.investments = WidgetSnapshot.Investments(
            total: total(.investments), dayChange: nil, ytd: nil, sp: nil, series: nil,
            accounts: invAccounts.map { WidgetSnapshot.Investments.Account(name: $0.name, balance: NSDecimalNumber(decimal: $0.currentBalance).doubleValue, ytd: nil) })
        snap.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
    #endif

    private static func makePoints(_ r: NetWorthHistoryResponse) -> [Pt] {
        r.snapshots
            .compactMap { s in parseDay(s.date).map { (d: $0, v: NSDecimalNumber(decimal: s.netWorthDecimal).doubleValue) } }
            .sorted { $0.d < $1.d }
            // Keyed by day so the line keeps its shape when the range changes.
            .map { Pt(id: Int($0.d.timeIntervalSince1970), date: $0.d, value: $0.v) }
    }
}

// MARK: - Press feedback

struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .brightness(configuration.isPressed ? -0.025 : 0)
            // Quick to press, a little spring on release.
            .animation(configuration.isPressed ? Motion.press : Motion.bouncy, value: configuration.isPressed)
    }
}

// MARK: - Composition card (stacked bar + legend; the whole card is one tile)

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
                    CountingText(money(total)).font(.title3.bold()).monospacedDigit().sensitive()
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
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

                VStack(spacing: 12) {
                    ForEach(active, id: \.0.id) { g, v in
                        HStack(spacing: 10) {
                            IconBadge(symbol: g.symbol, color: g.color, size: 28)
                            Text(g.rawValue).font(.subheadline)
                            Spacer()
                            Text("\(Int((v / max(total, 1) * 100).rounded()))%")
                                .font(.caption).foregroundStyle(.secondary)
                            CountingText(money(v)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                .frame(minWidth: 84, alignment: .trailing)
                                .sensitive()
                        }
                    }
                }
            }
        }
    }
}
