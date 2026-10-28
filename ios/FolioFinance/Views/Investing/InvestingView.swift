import SwiftUI
import Charts

struct InvestingView: View {
    @EnvironmentObject private var auth: AuthManager
    @AppStorage("ageEntered") private var ageEntered = 0
    @State private var accounts: [Account] = []
    @State private var insights: Insights?
    @State private var loaded = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var sheet: InvestingSheet?
    @State private var showAdd = false
    @State private var showConnect = false
    @State private var showAge = false
    @State private var range: Span = .ytd
    @State private var points: [Pt] = []
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

    enum InvestingSheet: Identifiable {
        case hero, allocation, account(Account), note(Insights.Note), idea(Idea)
        var id: String {
            switch self {
            case .hero: "hero"
            case .allocation: "allocation"
            case .account(let a): "account-\(a.id)"
            case .note(let n): "note-\(n.id)"
            case .idea(let i): "idea-\(i.id)"
            }
        }
    }

    struct Idea: Identifiable {
        let id: String
        let symbol: String
        let color: Color
        let title: String
        let summary: String
        let headline: String
        let points: [String]
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

    private var ideas: [Idea] {
        let age = ageEntered
        let stocks = max(0, min(100, 110 - age))
        return [
            Idea(id: "age", symbol: "percent", color: .purple, title: "Stocks by age",
                 summary: age > 0 ? "A common rule of thumb points to about \(stocks)% in stocks." : "A popular idea is 110 minus your age.",
                 headline: age > 0 ? "\(stocks)%" : "110 − age",
                 points: ["Some people hold roughly 110 minus their age in stocks, and the rest in bonds and cash.",
                          age > 0 ? "At \(age), that rule gives about \(stocks)% in stocks and \(100 - stocks)% in bonds and cash." : "Add your age to see your own number.",
                          "It's a starting point for learning, not a target for you. Your goals and comfort with ups and downs matter more."]),
            Idea(id: "retire", symbol: "calendar.badge.clock", color: .indigo, title: "Retirement saving",
                 summary: "Many people aim to save about 15% of income.",
                 headline: "15%",
                 points: ["A widely quoted guide is saving about 15% of your income for retirement, including any employer match.",
                          "Starting earlier matters more than starting big, because growth builds on itself over time.",
                          "If 15% feels out of reach, a smaller regular amount that increases over time is a common approach."]),
            Idea(id: "match", symbol: "gift.fill", color: .pink, title: "Employer match",
                 summary: "Getting the full match is often a good first step.",
                 headline: "Full match",
                 points: ["If your employer matches contributions to a retirement plan, that match is extra pay for saving.",
                          "Many people contribute at least enough to receive the full match before saving elsewhere.",
                          "Check your plan's details for the match rate and how long you need to stay for it to fully belong to you."]),
            Idea(id: "fees", symbol: "scissors", color: .teal, title: "Fees",
                 summary: "Lower-fee funds keep more of your returns.",
                 headline: "Under 0.5%",
                 points: ["Funds charge a yearly fee, called an expense ratio. Over many years small differences add up.",
                          "Index funds often charge well under about 0.5% a year.",
                          "Your fund's fee is shown on its fact sheet or in your brokerage's details for that fund."]),
        ]
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .plan)
                ScrollView {
                    VStack(spacing: 14) {
                        if let error { ErrorBanner(message: error) { Task { await load() } } }
                        if loaded && invested.isEmpty {
                            emptyState
                        } else if !invested.isEmpty {
                            heroCard.flowIn(0)
                            chartCard.flowIn(1)
                            if let inv = insights?.investing, !inv.allocation.isEmpty { allocationCard(inv).flowIn(2) }
                            accountsCard.flowIn(3)
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
                .overlay { if isLoading && !loaded { ProgressView().controlSize(.large) } }
            }
            .navigationTitle("Investing")
            .onReceive(NotificationCenter.default.publisher(for: .accountsChanged)) { _ in Task { await load() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showAdd = true } label: { Label("Add account", systemImage: "plus") }
                        Button { showConnect = true } label: { Label("Connect a bank or brokerage", systemImage: "link") }
                    } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) { ProfileMenu() }
            }
            .sheet(item: $sheet) { kind in sheetContent(kind) }
            .sheet(isPresented: $showAdd) { AddAccountSheet { Task { await load() } } }
            .sheet(isPresented: $showConnect, onDismiss: { Task { await load() } }) { PlaidLinkSheet() }
            .sheet(isPresented: $showAge) { AgeSheet { Task { await load() } } }
        }
        .task { await load() }
        .onChange(of: range) { _, _ in Task { await loadChart() } }
    }

    private func loadChart() async {
        guard let r: NetWorthHistoryResponse = try? await auth.withFreshToken(.netWorthHistory(days: range.days)) else { return }
        let pts = r.snapshots
            .compactMap { s -> (Date, Double)? in
                guard let inv = s.invested, let v = Double(inv), let d = parseDay(s.date) else { return nil }
                return (d, v)
            }
            .sorted { $0.0 < $1.0 }
            .enumerated().map { Pt(id: $0.offset, date: $0.element.0, value: $0.element.1) }
        withAnimation(Motion.spring) { points = pts }
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
                            Text(money(shown.value))
                                .font(.title2.bold()).monospacedDigit()
                                .contentTransition(.numericText())
                                .sensitive()
                            Text(selectedDate != nil
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
                            AxisValueLabel { if let x = v.as(Double.self) { Text(compactMoney(x)) } }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                            AxisValueLabel(format: range == .threeYears || range == .year
                                           ? .dateTime.month(.abbreviated).year(.twoDigits)
                                           : .dateTime.month(.abbreviated).day())
                        }
                    }
                    .frame(height: 180)
                    .chartReveal(id: "\(range.rawValue)-\(points.count)")
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
        TileButton { sheet = .hero } content: {
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
        TileButton { sheet = .allocation } content: {
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
                                Text(money(s.amount)).font(.subheadline.weight(.semibold)).monospacedDigit()
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
                        TileButton { sheet = .account(a) } content: {
                            HStack(spacing: 12) {
                                IconBadge(symbol: AccountGroup.investments.symbol, color: AccountGroup.investments.color, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name).font(.body).lineLimit(1)
                                    Text([a.institutionName, share(a)].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(money(dbl(a), cents: true)).font(.body.weight(.semibold)).monospacedDigit().sensitive()
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

    private var ideasSection: some View {
        VStack(spacing: 8) {
            SectionTitle("Ideas")
            AskFolioButton(title: "Ask Folio how I'm doing vs the S&P 500", question: "How have my investments done compared with the S&P 500 this year?")
                .frame(maxWidth: .infinity, alignment: .leading)
            if let notes = insights?.investing.notes, !notes.isEmpty {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(notes) { n in
                            TileButton { sheet = .note(n) } content: {
                                HStack(alignment: .top, spacing: 12) {
                                    IconBadge(symbol: n.tone == "good" ? "checkmark" : n.tone == "attention" ? "exclamationmark" : "lightbulb.fill",
                                              color: n.tone == "good" ? .green : n.tone == "attention" ? .orange : .blue, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(n.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                                        Text(n.detail).font(.footnote).foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading).lineLimit(3)
                                    }
                                    Spacer(minLength: 0)
                                    chevron()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            if n.id != notes.last?.id { Divider().padding(.leading, 60) }
                        }
                    }
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(ideas) { idea in
                        TileButton { sheet = .idea(idea) } content: {
                            HStack(spacing: 12) {
                                IconBadge(symbol: idea.symbol, color: idea.color, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(idea.title).font(.subheadline.weight(.semibold))
                                    Text(idea.summary).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                chevron()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        if idea.id != ideas.last?.id { Divider().padding(.leading, 62) }
                    }
                }
            }
            if ageEntered == 0 {
                Button { showAge = true } label: { Label("Add your age for tailored ideas", systemImage: "person.crop.circle.badge.plus") }
                    .font(.subheadline).padding(.top, 2)
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
                footnote: "Balances only. Folio doesn't track returns for individual holdings."
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
            )
        case .note(let n):
            BreakdownSheet(
                title: n.title,
                headline: n.tone == "good" ? "Looks good" : n.tone == "attention" ? "Worth a look" : "An idea",
                caption: n.detail,
                tone: .plan,
                footnote: "General information based on your own data, not advice to buy or sell anything."
            )
        case .idea(let idea):
            BreakdownSheet(
                title: idea.title,
                headline: idea.headline,
                caption: idea.summary,
                tone: .plan,
                sections: [BreakdownSection(rows: idea.points.map { BreakdownRow(title: $0, value: "") })],
                footnote: "A rule of thumb for learning, not advice."
            ) {
                if ageEntered == 0 && idea.id == "age" {
                    Button { sheet = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showAge = true } } label: {
                        Label("Add your age", systemImage: "person.crop.circle.badge.plus").font(.headline).frame(maxWidth: .infinity).frame(height: 30)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
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
        await loadChart()
        isLoading = false
        loaded = true
    }
}
