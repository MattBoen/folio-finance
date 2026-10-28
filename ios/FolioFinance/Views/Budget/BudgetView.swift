import SwiftUI
import Charts

struct SpendingView: View {
    var embedded = false
    /// False while a host keeps this screen alive but hidden, so its toolbar button steps aside.
    var active = true
    @EnvironmentObject private var auth: AuthManager
    @State private var donutIn = false
    @State private var month = SpendingView.startOfMonth(Date())
    @State private var transactions: [Transaction] = []
    @State private var previousSpent = 0.0
    @State private var isLoading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var selected: String?
    @State private var showAdd = false
    @State private var detail: Transaction?
    @State private var sheet: SpendSheet?
    @State private var showAllIn: Set<String> = []

    enum SpendSheet: String, Identifiable { case spent, income, saved; var id: String { rawValue } }

    struct Slice: Identifiable {
        let id: String
        let value: Double
        let color: Color
        let symbol: String
    }

    // MARK: Derived

    private static func startOfMonth(_ d: Date) -> Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: d)) ?? d
    }

    private var isCurrentMonth: Bool { Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month) }

    private static func countsAsSpending(_ t: Transaction) -> Bool {
        !t.isExcluded && !t.category.lowercased().contains("transfer")
    }

    private var expenses: [Transaction] { transactions.filter { $0.isDebit && Self.countsAsSpending($0) } }
    private var incomes: [Transaction] { transactions.filter { !$0.isDebit && Self.countsAsSpending($0) } }
    private var spent: Double { expenses.reduce(0) { $0 + $1.doubleAmount } }
    private var earned: Double { incomes.reduce(0) { $0 + abs($1.doubleAmount) } }

    private var slices: [Slice] {
        Dictionary(grouping: expenses, by: \.category)
            .map { name, rows in
                let s = Categories.style(name)
                return Slice(id: name, value: rows.reduce(0) { $0 + $1.doubleAmount }, color: s.color, symbol: s.symbol)
            }
            .sorted { $0.value > $1.value }
    }

    // MARK: Body

    var body: some View {
        Group {
            if embedded { core } else { NavigationStack { core } }
        }
        .task(id: month) { await load() }
    }

    private var core: some View {
            ZStack {
                Wash(tone: .spending)
                ScrollView {
                    VStack(spacing: 14) {
                        monthPicker
                        if let error { ErrorBanner(message: error) { Task { await load() } } }
                        if loaded && expenses.isEmpty && error == nil {
                            EmptyStateCard(
                                symbol: "chart.pie",
                                title: isCurrentMonth ? "Nothing spent yet" : "No spending this month",
                                message: "Expenses you add in Activity show up here, grouped by category."
                            )
                            Button { showAdd = true } label: {
                                Label("Add transaction", systemImage: "plus")
                                    .font(.headline).frame(maxWidth: .infinity).frame(height: 30)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        } else if !expenses.isEmpty {
                            TileButton { sheet = .spent } content: { donutCard }.flowIn(0)
                            statsCard.flowIn(1)
                            categoriesCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .refreshable { await load() }
                .overlay { if isLoading && !loaded { ProgressView().controlSize(.large) } }
            }
            .titledUnlessEmbedded("Spending", embedded: embedded)
            .toolbar {
                if active {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAdd = true } label: { Image(systemName: "plus") }
                    }
                }
                if !embedded { ToolbarItem(placement: .topBarTrailing) { ProfileMenu() } }
            }
            .sheet(isPresented: $showAdd) { AddTransactionSheet { Task { await load() } } }
            .sheet(item: $detail) { t in
                TransactionDetailView(transaction: t, all: transactions) { Task { await load() } }
            }
            .sheet(item: $sheet) { kind in summarySheet(kind) }
            .sensoryFeedback(.selection, trigger: month)
    }

    // MARK: Pieces

    private var monthPicker: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                .disabled(isCurrentMonth)
        }
        .padding(.horizontal, 4)
    }

    private var donutCard: some View {
        let list = slices
        let total = max(spent, 0.01)
        let focus = list.first { $0.id == selected }
        return Card {
            VStack(spacing: 14) {
                Chart(list) { s in
                    // The chosen slice steps out a little; the rest dim.
                    SectorMark(angle: .value("Spent", s.value),
                               innerRadius: .ratio(selected == s.id ? 0.62 : 0.66),
                               outerRadius: .ratio(selected == s.id ? 1.0 : 0.94),
                               angularInset: 1.5)
                        .cornerRadius(6)
                        .foregroundStyle(s.color)
                        .opacity(selected == nil || selected == s.id ? 1 : 0.28)
                }
                .chartLegend(.hidden)
                .frame(height: 220)
                .animation(Motion.bouncy, value: selected)
                .scaleEffect(donutIn ? 1 : 0.7)
                .rotationEffect(.degrees(donutIn ? 0 : -110))
                .opacity(donutIn ? 1 : 0)
                .onAppear { if active { spinIn() } }
                // Kept alive behind the Budget side, so spin in again each time it's shown.
                .onChange(of: active) { _, now in if now { donutIn = false; spinIn() } }
                .overlay {
                    VStack(spacing: 2) {
                        Text(focus?.id ?? "Spent")
                            .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                        CountUpText(value: focus?.value ?? spent)
                            .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                            .sensitive()
                        if let focus {
                            Text("\(Int((focus.value / total * 100).rounded()))% of spending")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if previousSpent > 0 {
                            let change = (spent - previousSpent) / previousSpent
                            Label("\(Int((abs(change) * 100).rounded()))% vs last month",
                                  systemImage: change <= 0 ? "arrow.down.right" : "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(change <= 0 ? Color.up : Color.down)
                        }
                    }
                    .animation(.snappy, value: selected)
                }
            }
        }
    }

    private func spinIn() {
        withAnimation(Motion.bouncy.delay(0.1)) { donutIn = true }
    }

    private var statsCard: some View {
        let net = earned - spent
        return Card {
            HStack(alignment: .top) {
                statButton("Spent", spent, .primary, .spent)
                Divider().frame(height: 34)
                statButton("Income", earned, Color.up, .income)
                Divider().frame(height: 34)
                statButton(net >= 0 ? "Saved" : "Overspent", abs(net), net >= 0 ? Color.up : Color.down, .saved)
            }
        }
    }

    private func statButton(_ label: String, _ value: Double, _ color: Color, _ kind: SpendSheet) -> some View {
        TileButton { sheet = kind } content: {
            VStack(spacing: 3) {
                Text(money(value)).font(.title3.bold()).monospacedDigit().foregroundStyle(color)
                    .minimumScaleFactor(0.7).lineLimit(1).sensitive()
                    .contentTransition(.numericText())
                    .animation(.smooth, value: value)
                HStack(spacing: 3) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
    }

    // MARK: Summary sheets

    @ViewBuilder private func summarySheet(_ kind: SpendSheet) -> some View {
        let monthName = month.formatted(.dateTime.month(.wide))
        switch kind {
        case .spent:
            let list = slices
            let change: String? = previousSpent > 0 ? {
                let c = (spent - previousSpent) / previousSpent
                return "\(Int((abs(c) * 100).rounded()))% \(c <= 0 ? "less" : "more") than last month"
            }() : nil
            BreakdownSheet(
                title: "Spent in \(monthName)", headline: money(spent), caption: change, tone: .spending,
                sections: [BreakdownSection(title: "By category", rows: list.map { s in
                    BreakdownRow(symbol: s.symbol, color: s.color, title: s.id,
                                 subtitle: "\(expenses.filter { $0.category == s.id }.count) transaction\(expenses.filter { $0.category == s.id }.count == 1 ? "" : "s") · \(Int((s.value / max(spent, 1) * 100).rounded()))% of spending",
                                 value: money(s.value), fraction: s.value / max(spent, 1))
                })],
                footnote: "Transfers and excluded transactions aren't counted."
            )
        case .income:
            let groups = Dictionary(grouping: incomes, by: \.displayName)
                .map { (name: $0.key, rows: $0.value, total: $0.value.reduce(0) { $0 + abs($1.doubleAmount) }) }
                .sorted { $0.total > $1.total }
            BreakdownSheet(
                title: "Income in \(monthName)", headline: money(earned),
                caption: "\(incomes.count) deposit\(incomes.count == 1 ? "" : "s")", tone: .spending,
                sections: [BreakdownSection(title: "By source", rows: groups.map { g in
                    BreakdownRow(symbol: "arrow.down.circle.fill", color: .green, title: g.name,
                                 subtitle: "\(g.rows.count) deposit\(g.rows.count == 1 ? "" : "s")",
                                 value: money(g.total), fraction: g.total / max(earned, 1))
                })]
            )
        case .saved:
            let net = earned - spent
            let rate = earned > 0 ? Int((net / earned * 100).rounded()) : nil
            BreakdownSheet(
                title: net >= 0 ? "Saved in \(monthName)" : "Overspent in \(monthName)", headline: money(abs(net)),
                caption: rate.map { net >= 0 ? "\($0)% of your income" : "Spending is above income by \(abs($0))%" }, tone: .spending,
                sections: [BreakdownSection(rows: [
                    BreakdownRow(symbol: "arrow.down.circle.fill", color: .green, title: "Income", value: money(earned), fraction: earned / max(earned, spent, 1)),
                    BreakdownRow(symbol: "creditcard.fill", color: Color(hex: 0x5E5CE6), title: "Spent", value: money(spent), fraction: spent / max(earned, spent, 1)),
                    BreakdownRow(symbol: net >= 0 ? "leaf.fill" : "exclamationmark.triangle.fill", color: net >= 0 ? .green : .orange,
                                 title: net >= 0 ? "Left over" : "Over by", value: money(abs(net)), valueColor: net >= 0 ? Color.up : Color.down),
                ])],
                footnote: "Savings rate is what's left after spending, as a share of income. Many people aim for 15% or more."
            )
        }
    }

    private var categoriesCard: some View {
        let list = slices
        let top = list.first?.value ?? 1
        return VStack(spacing: 8) {
            SectionTitle("Categories", trailing: "Tap to see transactions")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(list) { s in
                        VStack(spacing: 0) {
                            categoryRow(s, top: top)
                            if selected == s.id { transactionList(for: s) }
                        }
                        if s.id != list.last?.id { Divider().padding(.leading, 64) }
                    }
                }
                .compositingGroup()
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .sensoryFeedback(.selection, trigger: selected)
        }
        .flowIn()
    }

    private func categoryRow(_ s: Slice, top: Double) -> some View {
        let open = selected == s.id
        return Button {
            withAnimation(Motion.spring) { selected = open ? nil : s.id }
        } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: s.symbol, color: s.color, size: 36)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(s.id).font(.body).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(money(s.value)).font(.body.weight(.semibold)).monospacedDigit().sensitive()
                    }
                    GeometryReader { geo in
                        Capsule().fill(s.color.opacity(0.18))
                            .overlay(alignment: .leading) {
                                Capsule().fill(s.color).frame(width: max(6, geo.size.width * s.value / top))
                            }
                    }
                    .frame(height: 6)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(open ? s.color.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// This category's transactions for the month, kept inside the same tile: the first six, then "Show all".
    private func transactionList(for s: Slice) -> some View {
        let rows = expenses.filter { $0.category == s.id }.sorted { $0.date > $1.date }
        let expanded = showAllIn.contains(s.id)
        let shown = expanded ? rows : Array(rows.prefix(6))
        return VStack(spacing: 0) {
            HStack {
                Text("\(rows.count) transaction\(rows.count == 1 ? "" : "s") in \(month.formatted(.dateTime.month(.wide)))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(money(s.value, cents: true)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit().sensitive()
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)

            ForEach(shown) { t in
                Divider().padding(.leading, 16)
                Button { detail = t } label: {
                    HStack(spacing: 10) {
                        Text(parseDay(t.date)?.formatted(.dateTime.month(.abbreviated).day()) ?? t.date)
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.displayName).font(.subheadline).lineLimit(1).minimumScaleFactor(0.85)
                            if t.isPending { Text("Pending").font(.caption2).foregroundStyle(.orange) }
                        }
                        Spacer(minLength: 8)
                        Text(money(t.doubleAmount, cents: true))
                            .font(.subheadline.weight(.medium)).monospacedDigit().sensitive()
                            .frame(minWidth: 76, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.quaternary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if rows.count > 6 {
                Divider().padding(.leading, 16)
                Button {
                    withAnimation(Motion.spring) {
                        if expanded { showAllIn.remove(s.id) } else { showAllIn.insert(s.id) }
                    }
                } label: {
                    Text(expanded ? "Show less" : "Show all \(rows.count)")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: expanded)
            }
        }
        .background(s.color.opacity(0.05))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Data

    private func shift(_ delta: Int) {
        selected = nil
        showAllIn = []
        withAnimation(.smooth) {
            month = Calendar.current.date(byAdding: .month, value: delta, to: month) ?? month
        }
    }

    private func range(for start: Date) -> (String, String) {
        let end = Calendar.current.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? start
        return (dayString(start), dayString(end))
    }

    private func load() async {
        isLoading = true
        error = nil
        let (from, to) = range(for: month)
        let prevStart = Calendar.current.date(byAdding: .month, value: -1, to: month) ?? month
        let (pFrom, pTo) = range(for: prevStart)
        do {
            async let current: TransactionsResponse = auth.withFreshToken(.transactions(from: from, to: to, limit: 500))
            async let previous: TransactionsResponse = auth.withFreshToken(.transactions(from: pFrom, to: pTo, limit: 500))
            let (c, p) = try await (current, previous)
            withAnimation(.smooth) {
                transactions = c.transactions
                previousSpent = p.transactions
                    .filter { $0.isDebit && Self.countsAsSpending($0) }
                    .reduce(0) { $0 + $1.doubleAmount }
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
        loaded = true
    }
}
