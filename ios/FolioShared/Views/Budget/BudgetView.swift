import SwiftUI
import Charts

/// One page for a month of money going out: what you spent, your budget for it, and every category with its target.
/// The budget lives here (not on a separate screen) so each category shows up once, with its spending and its limit together.
struct SpendingView: View {
    var embedded = false
    /// False while a host keeps this screen alive but hidden, so its toolbar button steps aside.
    var active = true
    /// This month's transactions when the opener already has them, so the page arrives full instead of loading.
    var initial: [Transaction]? = nil
    @EnvironmentObject private var auth: AuthManager
    @State private var donutIn = false
    @State private var donutLeftAt: Date?
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
    @Namespace private var zoom
    @State private var showAllIn: Set<String> = []
    @State private var budgets: [BudgetLine] = []
    @State private var budgetsLoaded = false
    @State private var suggestions: [Insights.BudgetItem] = []
    @State private var budgetDraft: BudgetDraft?

    enum SpendSheet: String, Identifiable { case spent, income, saved, budget; var id: String { rawValue } }

    /// The lines the budget editor opens with.
    struct BudgetDraft: Identifiable {
        let id = UUID()
        let lines: [BudgetLine]
    }

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
    /// Out-of-pocket purchases the customer excluded: still shown, crossed out, and left out of every total.
    private var excludedRows: [Transaction] {
        transactions.filter { $0.isDebit && $0.isExcluded && !$0.category.lowercased().contains("transfer") }.sorted { $0.date > $1.date }
    }

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

    /// Every category with spending, then any budgeted category with nothing spent yet, so each target is visible.
    /// A budgeted "Other" shows everything that counts toward it, so its amount matches its bar.
    private var categoryRows: [Slice] {
        var list = slices
        let have = Set(list.map(\.id))
        for b in budgetLines where !have.contains(b.category) {
            let s = Categories.style(b.category)
            list.append(Slice(id: b.category, value: 0, color: s.color, symbol: s.symbol))
        }
        guard otherCatchAll else { return list }
        return list.map { s in
            s.id == "Other" ? Slice(id: s.id, value: rows(in: s.id).reduce(0) { $0 + $1.doubleAmount }, color: s.color, symbol: s.symbol) : s
        }
    }

    /// True when the budget has an "Other" line, which covers every category without its own target.
    private var otherCatchAll: Bool { budgetNames.contains("Other") }

    /// The month's purchases in a category row (a budgeted "Other" also takes everything without its own target).
    private func rows(in category: String) -> [Transaction] {
        if category == "Other" && otherCatchAll {
            return expenses.filter { $0.category == "Other" || !budgetNames.contains($0.category) }
        }
        return expenses.filter { $0.category == category }
    }

    // MARK: Budget

    private var hasBudget: Bool { !budgets.isEmpty }
    private var budgetNames: Set<String> { Set(budgets.map(\.category)) }

    /// Each target with what was spent against it in the month on screen, worked out from the same purchases listed
    /// below, so a bar never disagrees with the amount beside it.
    private var budgetLines: [BudgetLine] {
        #if PERSONAL
        // The Mac's own figures for this month, which leave out reimbursed work purchases.
        if isCurrentMonth { return budgets }
        #endif
        return BudgetLine.measured(budgets, against: expenses)
    }

    private func line(for category: String) -> BudgetLine? { budgetLines.first { $0.category == category } }

    private static func barColor(_ spent: Double, _ total: Double) -> Color {
        guard total > 0 else { return .gray }
        let f = spent / total
        return f > 1 ? .red : f > 0.85 ? .orange : .green
    }

    private var daysLeft: Int {
        let cal = Calendar.current
        let days = cal.range(of: .day, in: .month, for: Date())?.count ?? 30
        return max(1, days - cal.component(.day, from: Date()) + 1)
    }

    /// Opens the budget editor. With no budget yet it starts filled in with Folio's draft, so you only review and save.
    private func editBudget() {
        if hasBudget { budgetDraft = BudgetDraft(lines: budgets); return }
        budgetDraft = BudgetDraft(lines: suggestions.map {
            BudgetLine(id: $0.category, category: $0.category, monthlyAmount: $0.amount.rounded(), spent: 0)
        })
    }

    // MARK: Body

    var body: some View {
        Group {
            if embedded { core } else { NavigationStack { core } }
        }
        .onAppear {
            if transactions.isEmpty, let initial, !initial.isEmpty { transactions = initial; loaded = true }
        }
        .task(id: month) { await load() }
        .task { await loadBudget() }
        .onReceive(NotificationCenter.default.publisher(for: .budgetsChanged)) { _ in Task { await loadBudget() } }
    }

    private var core: some View {
            ZStack {
                Wash(tone: .spending)
                ScrollView {
                    VStack(spacing: 14) {
                        monthPicker
                        if let error { ErrorBanner(message: error) { Task { await reloadAll() } } }
                        if loaded && expenses.isEmpty && error == nil {
                            // Early in a month there's no spending yet, but your budget still matters most.
                            if hasBudget { budgetCard.flowIn(0) }
                            EmptyStateCard(
                                symbol: "chart.pie",
                                title: isCurrentMonth ? "Nothing spent yet" : "No spending this month",
                                message: "Purchases from your accounts show up here, grouped by category."
                            )
                            #if !PERSONAL
                            Button { showAdd = true } label: {
                                Label("Add transaction", systemImage: "plus")
                                    .font(.headline).frame(maxWidth: .infinity).frame(height: 30)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            #endif
                            if !hasBudget && isCurrentMonth && budgetsLoaded { budgetSetupCard }
                        } else if !expenses.isEmpty {
                            TileButton(zoom: SpendSheet.spent.id) { sheet = .spent } content: { donutCard }.flowIn(0)
                            if hasBudget { budgetCard.flowIn(1) }
                            statsCard.flowIn(1)
                            categoriesCard
                            if !hasBudget && isCurrentMonth && budgetsLoaded { budgetSetupCard.flowIn() }
                            AskFolioButton(title: "Ask Folio where my money went", question: "Where is my money going this month compared with usual, and where could I realistically cut back?")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !excludedRows.isEmpty { excludedCard.flowIn() }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .folioRefresh { await reloadAll() }
                .overlay { if isLoading && !loaded { ProgressView().controlSize(.large) } }
            }
            .titledUnlessEmbedded("Spending", embedded: embedded)
            .toolbar {
                #if !PERSONAL
                if active {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAdd = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add")
                    }
                }
                #endif
                if !embedded || active { ToolbarItem(placement: .topBarTrailing) { ProfileMenu() } }
            }
            .sheet(isPresented: $showAdd) { AddTransactionSheet { Task { await reloadAll() } } }
            .environment(\.zoomNamespace, zoom)
            .sheet(item: $detail) { t in
                TransactionDetailView(transaction: t, all: transactions) { Task { await reloadAll() } }
                    .zoomed(from: t.id, in: zoom)
            }
            .sheet(item: $sheet) { kind in summarySheet(kind).zoomed(from: kind.id, in: zoom) }
            .sheet(item: $budgetDraft) { d in
                EditBudgetSheet(lines: d.lines, suggestions: suggestions) {
                    NotificationCenter.default.post(name: .budgetsChanged, object: nil)
                }
            }
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
                               innerRadius: .ratio(focus?.id == s.id ? 0.62 : 0.66),
                               outerRadius: .ratio(focus?.id == s.id ? 1.0 : 0.94),
                               angularInset: 1.5)
                        .cornerRadius(6)
                        .foregroundStyle(s.color)
                        .opacity(focus == nil || focus?.id == s.id ? 1 : 0.28)
                }
                .chartLegend(.hidden)
                // A new month (or a different set of categories) gets a fresh chart. Letting Charts morph one
                // set of slices into another divides by zero inside Apple's code and crashes the app.
                .id(chartKey(list))
                .frame(height: 220)
                .animation(Motion.bouncy, value: selected)
                .scaleEffect(donutIn ? 1 : 0.7)
                .rotationEffect(.degrees(donutIn ? 0 : -110))
                .opacity(donutIn ? 1 : 0)
                .onAppear {
                    guard active else { return }
                    if Replay.due(donutLeftAt) { Replay.restart(reset: { donutIn = false }, run: spinIn) }
                    else if !donutIn { spinIn() }
                }
                .onDisappear { donutLeftAt = Date() }
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
                        }
                    }
                    .animation(.snappy, value: selected)
                }
                if focus == nil, previousSpent > 0 {
                    let change = (spent - previousSpent) / previousSpent
                    let tint = change <= 0 ? Color.up : Color.down
                    Label("\(Int((abs(change) * 100).rounded()))% \(change <= 0 ? "less" : "more") than last month",
                          systemImage: change <= 0 ? "arrow.down.right" : "arrow.up.right")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(tint.opacity(0.14), in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }

    private func chartKey(_ list: [Slice]) -> String {
        "\(month.timeIntervalSince1970)|" + list.map(\.id).joined(separator: ",")
    }

    private func spinIn() {
        withAnimation(Motion.bouncy.delay(0.1)) { donutIn = true }
    }

    /// The one number people check most: how much is left this month, and what that means per day.
    private var budgetCard: some View {
        let lines = budgetLines
        let total = lines.reduce(0) { $0 + $1.monthlyAmount }
        let used = lines.reduce(0) { $0 + $1.spent }
        let left = total - used
        let over = lines.filter { $0.spent > $0.monthlyAmount }.count
        let pace: String = {
            let s: String
            if isCurrentMonth {
                s = left > 0
                    ? "About \(money(left / Double(daysLeft))) a day for the next \(daysLeft) day\(daysLeft == 1 ? "" : "s")"
                    : "\(daysLeft) day\(daysLeft == 1 ? "" : "s") left in the month"
            } else {
                s = "Spent \(money(used)) of \(money(total))"
            }
            return s
        }()
        return TileButton(zoom: SpendSheet.budget.id) { sheet = .budget } content: {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text(isCurrentMonth ? "Budget" : "\(month.formatted(.dateTime.month(.wide))) budget")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        CountingText(money(abs(left)))
                            .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(left < 0 ? Color.down : .primary)
                            .sensitive()
                        CountingText(left >= 0
                                     ? (isCurrentMonth ? "left of \(money(total))" : "under a \(money(total)) budget")
                                     : "over a \(money(total)) budget")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                            .sensitive()
                    }
                    ProgressBar(fraction: total > 0 ? used / total : 0, color: Self.barColor(used, total))
                    HStack(spacing: 0) {
                        CountingText(pace).foregroundStyle(.secondary)
                        if over > 0 { Text(" · \(over) categor\(over == 1 ? "y" : "ies") over").foregroundStyle(Color.down) }
                    }
                    .font(.caption).lineLimit(1).minimumScaleFactor(0.8).sensitive()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("Edit") { editBudget() }
                .font(.subheadline.weight(.semibold))
                .padding(.top, 14).padding(.trailing, 16)
        }
    }

    /// Shown when there's no budget yet: one tap opens the editor already filled in from your usual spending.
    private var budgetSetupCard: some View {
        let drafted = suggestions.reduce(0) { $0 + $1.amount }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Set a monthly budget", systemImage: "target").font(.headline)
                CountingText(suggestions.isEmpty
                     ? "Pick a target for each category, and every category here shows what's left as you spend."
                     : "Folio drafted \(money(drafted)) a month from what you usually spend. Review it, change anything, and save.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { editBudget() } label: {
                    Text(suggestions.isEmpty ? "Start a budget" : "Review my budget")
                        .font(.headline).frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                AskFolioButton(title: "Have Ask Folio build it", question: "Build me a complete monthly budget from my income and what I usually spend. Keep it realistic and leave room to save.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Income and what was left. "Spent" is already the big number in the chart, so it isn't repeated here.
    private var statsCard: some View {
        let net = earned - spent
        return Card {
            HStack(alignment: .top) {
                statButton("Income", earned, Color.up, .income)
                Divider().frame(height: 34)
                statButton(net >= 0 ? "Saved" : "Overspent", abs(net), net >= 0 ? Color.up : Color.down, .saved)
            }
        }
    }

    private func statButton(_ label: String, _ value: Double, _ color: Color, _ kind: SpendSheet) -> some View {
        TileButton(zoom: kind.id) { sheet = kind } content: {
            VStack(spacing: 3) {
                CountingText(money(value)).font(.title3.bold()).monospacedDigit().foregroundStyle(color)
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

    /// Closes a breakdown, then opens the budget editor once it has gone.
    private func handOffToEditor() {
        sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { editBudget() }
    }

    @ViewBuilder private func summarySheet(_ kind: SpendSheet) -> some View {
        let monthName = month.formatted(.dateTime.month(.wide))
        switch kind {
        case .budget:
            BudgetBreakdown(budgets: budgetLines, month: month) { handOffToEditor() }
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
                })],
                footnote: "Your usual monthly income, and how it's worked out, is under Money health on Overview."
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

    // MARK: Categories

    private var categoriesCard: some View {
        let list = categoryRows
        let top = list.first?.value ?? 1
        return VStack(spacing: 8) {
            HStack {
                Text("Categories").font(.title3.bold())
                Spacer()
                if hasBudget {
                    Button { editBudget() } label: {
                        Label("Edit budget", systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold))
                    }
                } else {
                    Text("Tap to see transactions").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
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

    private func budgetCaption(_ b: BudgetLine) -> String {
        let left = b.monthlyAmount - b.spent
        let base = left >= 0 ? "\(money(left)) left of \(money(b.monthlyAmount))" : "\(money(-left)) over \(money(b.monthlyAmount))"
        return b.category == "Other" ? base + " · covers the rest" : base
    }

    private func categoryRow(_ s: Slice, top: Double) -> some View {
        let open = selected == s.id
        let b = line(for: s.id)
        return Button {
            withAnimation(Motion.spring) { selected = open ? nil : s.id }
        } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: s.symbol, color: s.color, size: 36)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(s.id).font(.body).lineLimit(1)
                        Spacer(minLength: 8)
                        CountingText(money(s.value)).font(.body.weight(.semibold)).monospacedDigit().sensitive()
                    }
                    if let b {
                        // Budgeted: the bar is spending against its limit, green → orange → red.
                        ProgressBar(fraction: b.monthlyAmount > 0 ? b.spent / b.monthlyAmount : 0, color: Self.barColor(b.spent, b.monthlyAmount))
                        CountingText(budgetCaption(b))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(b.spent > b.monthlyAmount ? Color.down : .secondary)
                            .sensitive()
                    } else {
                        GeometryReader { geo in
                            Capsule().fill(s.color.opacity(0.18))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(s.color).frame(width: max(6, geo.size.width * s.value / max(top, 0.01)))
                                }
                        }
                        .frame(height: 6)
                        if hasBudget {
                            Text(otherCatchAll && s.id != "Other" ? "Counts toward Other" : "No budget")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
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
        let rows = self.rows(in: s.id).sorted { $0.date > $1.date }
        let expanded = showAllIn.contains(s.id)
        let shown = expanded ? rows : Array(rows.prefix(6))
        return VStack(spacing: 0) {
            HStack {
                Text(rows.isEmpty ? "Nothing spent here yet in \(month.formatted(.dateTime.month(.wide)))"
                                  : "\(rows.count) transaction\(rows.count == 1 ? "" : "s") in \(month.formatted(.dateTime.month(.wide)))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !rows.isEmpty {
                    CountingText(money(s.value, cents: true)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit().sensitive()
                }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, rows.isEmpty ? 12 : 6)

            ForEach(shown) { t in
                Divider().padding(.leading, 16)
                Button { Haptic.tap(); detail = t } label: {
                    HStack(spacing: 10) {
                        Text(parseDay(t.date)?.formatted(.dateTime.month(.abbreviated).day()) ?? t.date)
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.displayName).font(.subheadline).lineLimit(1).minimumScaleFactor(0.85)
                            if t.isPending { Text("Pending").font(.caption2).foregroundStyle(.orange) }
                        }
                        Spacer(minLength: 8)
                        CountingText(money(t.doubleAmount, cents: true))
                            .font(.subheadline.weight(.medium)).monospacedDigit().sensitive()
                            .frame(minWidth: 76, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.quaternary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .zoomSource(t.id, in: zoom)
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

    private var excludedCard: some View {
        VStack(spacing: 8) {
            SectionTitle("Excluded", trailing: "Not counted in spending")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(excludedRows) { t in
                        Button { Haptic.tap(); detail = t } label: {
                            TransactionRow(transaction: t)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableRowStyle())
                        .zoomSource(t.id, in: zoom)
                        if t.id != excludedRows.last?.id { Divider().padding(.leading, 66) }
                    }
                }
            }
        }
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

    private func reloadAll() async {
        async let a: Void = load()
        async let b: Void = loadBudget()
        _ = await (a, b)
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

    /// Targets, plus Folio's draft for when there isn't a budget yet. Neither failing blocks the page.
    private func loadBudget() async {
        async let bud: BudgetsResponse = auth.withFreshToken(.budgets)
        async let ins: Insights = auth.withFreshToken(.insights)
        if let b = try? await bud { withAnimation(.smooth) { budgets = b.budgets } }
        if let i = try? await ins { suggestions = i.budget.items }
        budgetsLoaded = true
    }
}

extension BudgetLine {
    /// Targets with "spent" worked out from the given purchases. A budgeted "Other" takes everything without its own target.
    static func measured(_ lines: [BudgetLine], against expenses: [Transaction]) -> [BudgetLine] {
        let names = Set(lines.map(\.category))
        return lines.map { b in
            let rows = b.category == "Other"
                ? expenses.filter { $0.category == "Other" || !names.contains($0.category) }
                : expenses.filter { $0.category == b.category }
            return BudgetLine(id: b.id, category: b.category, monthlyAmount: b.monthlyAmount, spent: rows.reduce(0) { $0 + $1.doubleAmount })
        }
    }
}
