import SwiftUI
import Charts

struct InvestingView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var router: TabRouter
    @State private var accounts: [Account] = []
    @State private var insights: Insights?
    @State private var loaded = false
    @State private var holdings: HoldingsSummary?
    @State private var isLoading = false
    @State private var error: String?
    @State private var sheet: InvestingSheet?
    @Namespace private var zoom
    @State private var showAdd = false
    @State private var showConnect = false
    @State private var showAge = false
    @State private var range: Span = .ytd
    /// All three years, loaded once; switching ranges just trims it, so it's instant.
    @State private var allPoints: [Pt] = []
    @State private var selectedDate: Date?

    /// Daily snapshots, so the shortest range is a month; a day view would have nothing to draw.
    enum Span: String, CaseIterable, Identifiable {
        case month = "1M", threeMonths = "3M", ytd = "YTD", year = "1Y", threeYears = "3Y"
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .month: 30
            case .threeMonths: 90
            case .year: 365
            case .threeYears: 1095
            case .ytd: min(365, max(7, Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 90))
            }
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

    enum InvestingSheet: Identifiable {
        case hero, allocation, account(Account)
        var id: String {
            switch self {
            case .hero: "hero"
            case .allocation: "allocation"
            case .account(let a): "account-\(a.id)"
            }
        }
    }


    // MARK: Derived

    private func dbl(_ a: Account) -> Double { NSDecimalNumber(decimal: a.currentBalance).doubleValue }
    private var visible: [Account] { accounts.filter { !$0.isHidden } }
    private var invested: [Account] { visible.filter { $0.group == .investments }.sorted { dbl($0) > dbl($1) } }
    private var totalInvested: Double { invested.reduce(0) { $0 + dbl($1) } }
    private var netWorth: Double {
        visible.reduce(0) { $0 + ($1.isLiability ? -dbl($1) : dbl($1)) }
    }
    private var shareOfNetWorth: Double? { netWorth > 0 ? totalInvested / netWorth : nil }


    // MARK: Body

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .plan)
                ScrollView {
                    VStack(spacing: 14) {
                        if let error { ErrorBanner(message: error) { Task { await load() } } }
                        if !loaded && invested.isEmpty {
                            ForEach(0..<3, id: \.self) { _ in Card { Color.clear.frame(height: 150) }.redacted(reason: .placeholder).shimmer() }
                        } else if loaded && invested.isEmpty {
                            emptyState
                        } else if !invested.isEmpty {
                            heroCard.flowIn(0)
                            chartCard.flowIn(1)
                            if let inv = insights?.investing, !inv.allocation.isEmpty { allocationCard(inv).flowIn(2) }
                            accountsCard.flowIn(3)
                            if let hs = holdings, !hs.holdings.isEmpty { HoldingsCard(summary: hs, accounts: accounts).flowIn(3) }
                        }
                        if loaded { ideasSection.flowIn(4) }
                        if loaded {
                            Text("General information, not financial advice.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .folioRefresh { await load() }
            }
            .navigationTitle("Investing")
            .onReceive(NotificationCenter.default.publisher(for: .accountsChanged)) { _ in Task { await load() } }
            .toolbar {
                #if !PERSONAL
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showAdd = true } label: { Label("Add account", systemImage: "plus") }
                        Button { showConnect = true } label: { Label("Connect a bank or brokerage", systemImage: "link") }
                    } label: { Image(systemName: "plus") }.accessibilityLabel("Add")
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) { ProfileMenu() }
            }
            .environment(\.zoomNamespace, zoom)
            .sheet(item: $sheet) { kind in sheetContent(kind).zoomed(from: kind.id, in: zoom) }
            .sheet(isPresented: $showAdd) { AddAccountSheet { Task { await load() } } }
            .sheet(isPresented: $showConnect, onDismiss: { Task { await load() } }) { PlaidLinkSheet() }
            .sheet(isPresented: $showAge) { AgeSheet { Task { await load() } } }
        }
        .task { await load() }
    }

    private func loadChart() async {
        guard let r: NetWorthHistoryResponse = try? await auth.withFreshToken(.netWorthHistory(days: Span.threeYears.days)) else { return }
        let pts = r.snapshots
            .compactMap { s -> (Date, Double)? in
                guard let inv = s.invested, let v = Double(inv), let d = parseDay(s.date) else { return nil }
                return (d, v)
            }
            .sorted { $0.0 < $1.0 }
            // Keyed by day so the line keeps its shape when the range changes.
            .map { Pt(id: Int($0.0.timeIntervalSince1970), date: $0.0, value: $0.1) }
        withAnimation(Motion.spring) { allPoints = pts }
    }

    // MARK: Cards

    private var shown: Pt? {
        guard let last = points.last else { return nil }
        guard let d = selectedDate else { return last }
        return points.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) } ?? last
    }

    private var chartCard: some View {
        let lo = points.map(\.value).min() ?? 0
        let hi = points.map(\.value).max() ?? 1
        let pad = max(1, (hi - lo) * 0.18)
        let change = (points.last?.value ?? 0) - (points.first?.value ?? 0)
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
                            CountingText(selectedDate != nil
                                 ? shown.date.formatted(.dateTime.month(.wide).day().year())
                                 : "\(change >= 0 ? "Up" : "Down") \(money(abs(change))) over this period")
                                .font(.caption).foregroundStyle(.secondary).sensitive()
                        }
                        Spacer(minLength: 8)
                        PeriodChangeBadge(first: points.first?.value ?? 0, last: points.last?.value ?? 0)
                    }
                    Chart {
                        ForEach(points) { p in
                            AreaMark(x: .value("Date", p.date), yStart: .value("Base", lo - pad), yEnd: .value("Invested", p.value))
                                .foregroundStyle(LinearGradient(colors: [Color.purple.opacity(0.30), Color.purple.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Date", p.date), y: .value("Invested", p.value))
                                .foregroundStyle(Color.purple)
                                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                                .interpolationMethod(.monotone)
                        }
                        if selectedDate != nil {
                            RuleMark(x: .value("Date", shown.date)).foregroundStyle(.secondary.opacity(0.5))
                            PointMark(x: .value("Date", shown.date), y: .value("Invested", shown.value))
                                .foregroundStyle(Color.purple).symbolSize(70)
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
                            AxisValueLabel(format: range == .threeYears || range == .year
                                           ? .dateTime.month(.abbreviated).year(.twoDigits)
                                           : .dateTime.month(.abbreviated).day(),
                                           anchor: .top)
                        }
                    }
                    .frame(height: 180)
                    .animation(.smooth(duration: 0.35), value: range)
                    .chartReveal(id: allPoints.count)
                    .sensitive()
                } else {
                    Label("History builds up daily. Check back soon for your trend line.", systemImage: "clock")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: range)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            EmptyStateCard(
                symbol: "chart.line.uptrend.xyaxis",
                title: "Nothing invested yet",
                message: "Add a brokerage or retirement account to see it here."
            )
            HStack(spacing: 10) {
                Button { showAdd = true } label: {
                    Label("Add account", systemImage: "plus").font(.headline).frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button { showConnect = true } label: {
                    Label("Connect", systemImage: "link").font(.headline).frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
        }
    }

    private var heroCard: some View {
        TileButton(zoom: InvestingSheet.hero.id) { sheet = .hero } content: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Invested").font(.subheadline.weight(.semibold)).opacity(0.85)
                    Spacer()
                    chevron(.white.opacity(0.8))
                }
                CountUpText(value: totalInvested)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                    .contentTransition(.numericText())
                    .sensitive()
                HStack(spacing: 14) {
                    Text("\(invested.count) account\(invested.count == 1 ? "" : "s")")
                    if let s = shareOfNetWorth { Text("\(Int((s * 100).rounded()))% of your net worth") }
                }
                .font(.footnote).opacity(0.9)
            }
            .foregroundStyle(.white)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Color(hex: 0x6A5AD0), Color(hex: 0x3B8BFF)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .shadow(color: Color(hex: 0x6A5AD0).opacity(0.3), radius: 16, y: 8)
        }
    }

    private func sliceColor(_ i: Int) -> Color {
        [AccountGroup.cash.color, AccountGroup.savings.color, AccountGroup.investments.color, AccountGroup.other.color][i % 4]
    }

    private func allocationCard(_ inv: Insights.Investing) -> some View {
        TileButton(zoom: InvestingSheet.allocation.id) { sheet = .allocation } content: {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Where your money sits").font(.headline)
                        Spacer()
                        chevron()
                    }
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(Array(inv.allocation.enumerated()), id: \.offset) { idx, s in
                                RoundedRectangle(cornerRadius: 3).fill(sliceColor(idx))
                                    .frame(width: max(4, (geo.size.width - CGFloat(inv.allocation.count - 1) * 2) * s.percent / 100))
                            }
                        }
                    }
                    .frame(height: 12).clipShape(Capsule())
                    VStack(spacing: 8) {
                        ForEach(Array(inv.allocation.enumerated()), id: \.offset) { idx, s in
                            HStack(spacing: 8) {
                                Circle().fill(sliceColor(idx)).frame(width: 9, height: 9)
                                Text(s.label).font(.subheadline)
                                Spacer()
                                Text("\(Int(s.percent.rounded()))%").font(.caption).foregroundStyle(.secondary)
                                CountingText(money(s.amount)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                    .frame(minWidth: 80, alignment: .trailing).sensitive()
                            }
                        }
                    }
                }
            }
        }
    }

    private var accountsCard: some View {
        VStack(spacing: 8) {
            SectionTitle("Your investment accounts")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(invested) { a in
                        TileButton(zoom: InvestingSheet.account(a).id) { sheet = .account(a) } content: {
                            HStack(spacing: 12) {
                                IconBadge(symbol: AccountGroup.investments.symbol, color: AccountGroup.investments.color, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name).font(.body).lineLimit(1)
                                    Text([a.institutionName, share(a)].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                CountingText(money(dbl(a), cents: true)).font(.body.weight(.semibold)).monospacedDigit().sensitive()
                                chevron()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        if a.id != invested.last?.id { Divider().padding(.leading, 62) }
                    }
                }
            }
        }
    }

    private func share(_ a: Account) -> String? {
        totalInvested > 0 ? "\(Int((dbl(a) / totalInvested * 100).rounded()))%" : nil
    }

    /// Things Folio noticed about your own numbers. A note that has somewhere useful to go is a button that goes there;
    /// one that is just information is plain text, so nothing on screen looks tappable and does nothing.
    private enum NoteAction { case accounts, spending, age }
    private func action(for n: Insights.Note) -> (label: String, run: NoteAction)? {
        switch n.id {
        case "emergency-fund", "cash-drag", "card-utilization": ("See your accounts", .accounts)
        case "savings-rate": ("See your spending", .spending)
        case "add-age": ("Add your age", .age)
        default: nil
        }
    }
    private func perform(_ a: NoteAction) {
        switch a {
        case .accounts:
            UserDefaults.standard.set(MoneyView.Segment.accounts.rawValue, forKey: "moneySegment"); router.selected = .money
        case .spending:
            router.selected = .spending
        case .age: showAge = true
        }
    }

    private var ideasSection: some View {
        let notes = insights?.investing.notes ?? []
        return VStack(spacing: 8) {
            SectionTitle("Worth knowing")
            AskFolioButton(title: "Ask Folio how I'm doing vs the S&P 500", question: "How have my investments done compared with the S&P 500 this year?")
                .frame(maxWidth: .infinity, alignment: .leading)
            if !notes.isEmpty {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(notes) { n in
                            let act = action(for: n)
                            let row = HStack(alignment: .top, spacing: 12) {
                                IconBadge(symbol: n.tone == "good" ? "checkmark" : n.tone == "attention" ? "exclamationmark" : "lightbulb.fill",
                                          color: n.tone == "good" ? .green : n.tone == "attention" ? .orange : .blue, size: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(n.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                                    Text(n.detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    if let act { Text(act.label).font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor).padding(.top, 2) }
                                }
                                Spacer(minLength: 0)
                                if act != nil { chevron() }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            if let act { TileButton { perform(act.run) } content: { row } } else { row }
                            if n.id != notes.last?.id { Divider().padding(.leading, 60) }
                        }
                    }
                }
            }
        }
    }

    private func chevron(_ color: Color = Color(UIColor.tertiaryLabel)) -> some View {
        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(color).allowsHitTesting(false)
    }

    // MARK: Sheets

    @ViewBuilder private func sheetContent(_ kind: InvestingSheet) -> some View {
        switch kind {
        case .hero:
            BreakdownSheet(
                title: "Invested",
                headline: money(totalInvested),
                caption: shareOfNetWorth.map { "\(Int(($0 * 100).rounded()))% of your net worth" },
                tone: .plan,
                sections: [BreakdownSection(title: "By account", rows: invested.map { a in
                    BreakdownRow(symbol: AccountGroup.investments.symbol, color: AccountGroup.investments.color, title: a.name,
                                 subtitle: a.institutionName, value: money(dbl(a), cents: true),
                                 fraction: totalInvested > 0 ? dbl(a) / totalInvested : nil)
                })],
                footnote: "Tap an account to see its share, or open What you own for individual holdings."
            )
        case .allocation:
            let alloc = insights?.investing.allocation ?? []
            BreakdownSheet(
                title: "Where your money sits",
                headline: money(alloc.reduce(0) { $0 + $1.amount }),
                caption: "across your asset types",
                tone: .plan,
                sections: [BreakdownSection(rows: alloc.enumerated().map { i, s in
                    BreakdownRow(color: sliceColor(i), title: s.label, subtitle: "\(Int(s.percent.rounded()))% of your assets",
                                 value: money(s.amount), fraction: s.percent / 100)
                })]
            )
        case .account(let a):
            BreakdownSheet(
                title: a.name,
                headline: money(dbl(a), cents: true),
                caption: a.institutionName,
                tone: .plan,
                sections: [BreakdownSection(rows: [
                    BreakdownRow(title: "Type", value: a.typeLabel),
                    BreakdownRow(title: "Share of invested", value: share(a) ?? "n/a", fraction: totalInvested > 0 ? dbl(a) / totalInvested : nil),
                    BreakdownRow(title: "Source", value: a.isManual ? "Entered by you" : "Connected"),
                ] + (a.mask.map { [BreakdownRow(title: "Account", value: "•••• \($0)")] } ?? []))],
                footnote: a.isManual ? "Update this balance any time from Money, then Accounts." : "This balance updates automatically."
            ) {
                AccountHistoryChart(account: a)
            }
        }
    }

    // MARK: Data

    private func load() async {
        isLoading = true
        error = nil
        do {
            let a: AccountsResponse = try await auth.withFreshToken(.accounts)
            accounts = a.accounts
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        if let i: Insights = try? await auth.withFreshToken(.insights) { insights = i }
        if let hs: HoldingsSummary = try? await auth.withFreshToken(.holdings) { holdings = hs }
        await loadChart()
        isLoading = false
        loaded = true
    }
}
