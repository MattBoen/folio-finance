import SwiftUI
import Charts

struct SpendingView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var month = SpendingView.startOfMonth(Date())
    @State private var transactions: [Transaction] = []
    @State private var previousSpent = 0.0
    @State private var isLoading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var selected: String?
    @State private var showAdd = false
    @State private var detail: Transaction?

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
        NavigationStack {
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
                            donutCard.flowIn()
                            statsCard.flowIn()
                            categoriesCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .refreshable { await load() }
                .overlay { if isLoading && !loaded { ProgressView().controlSize(.large) } }
            }
            .navigationTitle("Spending")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddTransactionSheet { Task { await load() } } }
            .sheet(item: $detail) { t in
                TransactionDetailView(transaction: t, all: transactions) { Task { await load() } }
            }
            .sensoryFeedback(.selection, trigger: month)
        }
        .task(id: month) { await load() }
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
                    SectorMark(angle: .value("Spent", s.value), innerRadius: .ratio(0.66), angularInset: 1.5)
                        .cornerRadius(6)
                        .foregroundStyle(s.color)
                        .opacity(selected == nil || selected == s.id ? 1 : 0.28)
                }
                .chartLegend(.hidden)
                .frame(height: 220)
                .overlay {
                    VStack(spacing: 2) {
                        Text(focus?.id ?? "Spent")
                            .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                        Text(money(focus?.value ?? spent))
                            .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
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

    private var statsCard: some View {
        Card {
            HStack(alignment: .top) {
                stat("Spent", spent, .primary)
                Divider().frame(height: 34)
                stat("Income", earned, Color.up)
                Divider().frame(height: 34)
                stat(earned - spent >= 0 ? "Saved" : "Overspent", abs(earned - spent), earned - spent >= 0 ? Color.up : Color.down)
            }
        }
    }

    private func stat(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(money(value)).font(.title3.bold()).monospacedDigit().foregroundStyle(color)
                .minimumScaleFactor(0.7).lineLimit(1).sensitive()
                .contentTransition(.numericText())
                .animation(.smooth, value: value)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var categoriesCard: some View {
        let list = slices
        let top = list.first?.value ?? 1
        return VStack(spacing: 8) {
            SectionTitle("Categories", trailing: "Tap to see transactions")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(list) { s in
                        categoryRow(s, top: top)
                        if selected == s.id { transactionList(for: s) }
                        if s.id != list.last?.id { Divider().padding(.leading, 64) }
                    }
                }
                .animation(.smooth, value: selected)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .sensoryFeedback(.selection, trigger: selected)
        }
        .flowIn()
    }

    private func categoryRow(_ s: Slice, top: Double) -> some View {
        let open = selected == s.id
        return Button {
            withAnimation(.smooth) { selected = open ? nil : s.id }
        } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: s.symbol, color: s.color, size: 36)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(s.id).font(.body)
                        Spacer()
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

    /// Every transaction in this category for the month, right under its row.
    private func transactionList(for s: Slice) -> some View {
        let rows = expenses.filter { $0.category == s.id }.sorted { $0.date > $1.date }
        return VStack(spacing: 0) {
            ForEach(rows) { t in
                Button { detail = t } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(parseDay(t.date)?.formatted(.dateTime.month(.abbreviated).day()) ?? t.date)
                                .font(.caption).foregroundStyle(.secondary)
                            if t.isPending { Text("Pending").font(.caption2).foregroundStyle(.orange) }
                        }
                        .frame(width: 52, alignment: .leading)
                        Text(t.displayName).font(.subheadline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(money(t.doubleAmount, cents: true)).font(.subheadline.weight(.medium)).monospacedDigit().sensitive()
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.quaternary)
                    }
                    .padding(.leading, 64).padding(.trailing, 16).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 64)
            }
            Text("\(rows.count) transaction\(rows.count == 1 ? "" : "s") in \(month.formatted(.dateTime.month(.wide)))")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 64).padding(.vertical, 9)
        }
        .background(s.color.opacity(0.05))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Data

    private func shift(_ delta: Int) {
        selected = nil
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
