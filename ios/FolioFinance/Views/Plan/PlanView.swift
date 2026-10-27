import SwiftUI

struct PlanView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var insights: Insights?
    @State private var budgets: [BudgetLine] = []
    @State private var loaded = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var showIncome = false
    @State private var showBudget = false
    @State private var showAge = false
    @State private var creating = false

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .plan)
                ScrollView {
                    VStack(spacing: 14) {
                        if let error { ErrorBanner(message: error) { Task { await load() } } }
                        if let insights {
                            if insights.dataQuality.transactionCount == 0 && insights.income.source == "none" {
                                EmptyStateCard(
                                    symbol: "wand.and.stars",
                                    title: "Your plan builds as you go",
                                    message: "Connect an account or add a few transactions and Folio will work out your income, your usual spending, and a budget to match."
                                )
                            }
                            incomeCard(insights)
                            budgetCard(insights)
                            healthCard(insights.health)
                            investingCard(insights.investing)
                            Text("General information based on your own data, not financial advice.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                }
                .refreshable { await load() }
                .overlay { if isLoading && !loaded { ProgressView().controlSize(.large) } }
            }
            .navigationTitle("Plan")
            .sheet(isPresented: $showIncome) {
                IncomeSheet(current: insights?.income.monthly ?? 0, isManual: insights?.income.source == "manual") { Task { await load() } }
            }
            .sheet(isPresented: $showBudget) {
                EditBudgetSheet(lines: budgets, suggestions: insights?.budget.items ?? []) { Task { await load() } }
            }
            .sheet(isPresented: $showAge) { AgeSheet { Task { await load() } } }
        }
        .task { await load() }
    }

    // MARK: Income + outflow

    private func incomeCard(_ i: Insights) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Monthly income").font(.subheadline).foregroundStyle(.secondary)
                        Text(i.income.monthly > 0 ? money(i.income.monthly) : "Not found yet")
                            .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit().sensitive()
                    }
                    Spacer()
                    Button("Edit") { showIncome = true }.font(.subheadline.weight(.semibold))
                }
                Text(incomeCaption(i.income)).font(.footnote).foregroundStyle(.secondary)

                if !i.income.sources.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(i.income.sources) { s in
                            HStack {
                                Text(s.name).font(.subheadline).lineLimit(1)
                                Text(s.frequency.capitalized).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(money(s.monthly)).font(.subheadline.weight(.semibold)).monospacedDigit().sensitive()
                            }
                        }
                    }
                }

                if i.outflow.monthlyAverage > 0 {
                    Divider()
                    HStack(alignment: .top) {
                        stat("Usual spending", money(i.outflow.monthlyAverage), "per month")
                        stat("Bills & fixed", money(i.outflow.fixed), "recurring")
                        stat("Flexible", money(i.outflow.variable), "day to day")
                    }
                }
            }
        }
    }

    private func incomeCaption(_ inc: Insights.Income) -> String {
        switch inc.source {
        case "manual": return "Set by you. Tap Edit to go back to detected income."
        case "detected": return "Found from your deposits · \(inc.confidence) confidence"
        default: return "We'll look for regular deposits once there's some activity. You can also enter it yourself."
        }
    }

    private func stat(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().sensitive()
            Text(sub).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Budget

    @ViewBuilder private func budgetCard(_ i: Insights) -> some View {
        let total = budgets.reduce(0) { $0 + $1.monthlyAmount }
        let spent = budgets.reduce(0) { $0 + $1.spent }
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(Date().formatted(.dateTime.month(.wide)) + " budget").font(.headline)
                    Spacer()
                    if !budgets.isEmpty { Button("Edit") { showBudget = true }.font(.subheadline.weight(.semibold)) }
                }
                if budgets.isEmpty {
                    Text(i.budget.items.isEmpty
                         ? "Once you have a few weeks of activity, Folio drafts a budget from what you actually spend."
                         : "Folio drafted \(money(i.budget.total)) a month from your recent spending. Review it, change anything, and you're set.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !i.budget.items.isEmpty {
                        Button { Task { await createBudget() } } label: {
                            Group { if creating { ProgressView() } else { Text("Create my budget").font(.headline) } }
                                .frame(maxWidth: .infinity).frame(height: 30)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(creating)
                    }
                    Button("Start from scratch") { showBudget = true }.font(.subheadline)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(money(max(total - spent, 0))).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit().sensitive()
                            Text(spent > total ? "over budget" : "left of \(money(total))").font(.subheadline).foregroundStyle(.secondary)
                        }
                        ProgressBar(fraction: total > 0 ? spent / total : 0, color: barColor(spent, total))
                    }
                    VStack(spacing: 12) {
                        ForEach(budgets) { b in
                            let style = Categories.style(b.category)
                            HStack(spacing: 12) {
                                IconBadge(symbol: style.symbol, color: style.color, size: 32)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(b.category).font(.subheadline)
                                        Spacer()
                                        Text("\(money(b.spent)) of \(money(b.monthlyAmount))")
                                            .font(.caption).foregroundStyle(.secondary).monospacedDigit().sensitive()
                                    }
                                    ProgressBar(fraction: b.monthlyAmount > 0 ? b.spent / b.monthlyAmount : 0, color: barColor(b.spent, b.monthlyAmount))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func barColor(_ spent: Double, _ total: Double) -> Color {
        guard total > 0 else { return .gray }
        let f = spent / total
        return f > 1 ? .red : f > 0.85 ? .orange : .green
    }

    // MARK: Health

    private func healthCard(_ h: Insights.Health) -> some View {
        VStack(spacing: 8) {
            SectionTitle("Money health")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                tile("Savings rate", h.savingsRate.map { "\(Int(($0 * 100).rounded()))%" }, "of income kept", status: h.savingsRate.map { $0 >= 0.15 ? .good : $0 >= 0.05 ? .ok : .attention }, hint: "Many people aim for 15% or more")
                tile("Emergency fund", h.emergencyFundMonths.map { String(format: "%.1f mo", $0) }, "of spending in cash", status: h.emergencyFundMonths.map { $0 >= 3 ? .good : $0 >= 1 ? .ok : .attention }, hint: "3 to 6 months is a common goal")
                tile("Credit use", h.creditUtilization.map { "\(Int(($0 * 100).rounded()))%" }, "of card limits", status: h.creditUtilization.map { $0 <= 0.10 ? .good : $0 <= 0.30 ? .ok : .attention }, hint: "Under 30% helps your credit score")
                tile("Debt payments", h.debtPaymentRatio.map { "\(Int(($0 * 100).rounded()))%" }, "of income", status: h.debtPaymentRatio.map { $0 <= 0.20 ? .good : $0 <= 0.36 ? .ok : .attention }, hint: "Lenders like to see under 36%")
            }
        }
    }

    private enum Status { case good, ok, attention
        var color: Color { switch self { case .good: .green; case .ok: .orange; case .attention: .red } }
        var label: String { switch self { case .good: "Strong"; case .ok: "Okay"; case .attention: "Needs care" } }
    }

    private func tile(_ title: String, _ value: String?, _ sub: String, status: Status?, hint: String) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(status?.color ?? .gray).frame(width: 8, height: 8)
                    Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(value ?? "—").font(.title2.bold()).monospacedDigit().sensitive()
                Text(value == nil ? "Not enough data yet" : sub).font(.caption).foregroundStyle(.secondary)
                Text(hint).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
    }

    // MARK: Investing

    private func investingCard(_ inv: Insights.Investing) -> some View {
        VStack(spacing: 8) {
            SectionTitle("Investing ideas")
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    if !inv.allocation.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Where your money sits").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
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
                                    Text(money(s.amount)).font(.subheadline.weight(.semibold)).monospacedDigit().frame(minWidth: 80, alignment: .trailing).sensitive()
                                }
                            }
                        }
                    }
                    ForEach(inv.notes) { n in
                        HStack(alignment: .top, spacing: 12) {
                            IconBadge(symbol: n.tone == "good" ? "checkmark" : n.tone == "attention" ? "exclamationmark" : "lightbulb.fill",
                                      color: n.tone == "good" ? .green : n.tone == "attention" ? .orange : .blue, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.title).font(.subheadline.weight(.semibold))
                                Text(n.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Button { showAge = true } label: { Label("Add your age for tailored ideas", systemImage: "person.crop.circle.badge.plus") }
                        .font(.subheadline)
                }
            }
        }
    }

    private func sliceColor(_ i: Int) -> Color {
        [AccountGroup.cash.color, AccountGroup.savings.color, AccountGroup.investments.color, AccountGroup.other.color][i % 4]
    }

    // MARK: Data

    private func load() async {
        isLoading = true
        error = nil
        do {
            async let ins: Insights = auth.withFreshToken(.insights)
            async let bud: BudgetsResponse = auth.withFreshToken(.budgets)
            let (i, b) = try await (ins, bud)
            insights = i
            budgets = b.budgets
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
        loaded = true
    }

    private func createBudget() async {
        creating = true
        do {
            let r: BudgetsResponse = try await auth.withFreshToken(.generateBudget)
            withAnimation(.smooth) { budgets = r.budgets }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        creating = false
    }
}

struct ProgressBar: View {
    var fraction: Double
    var color: Color
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(color.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
                }
        }
        .frame(height: 7)
    }
}

// MARK: - Edit sheets

struct IncomeSheet: View {
    let current: Double
    let isManual: Bool
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("$").foregroundStyle(.secondary)
                        TextField("0", text: $text).keyboardType(.decimalPad)
                    }
                } header: { Text("Monthly income after taxes") } footer: {
                    Text("Folio uses this for your savings rate and budget. Leave it to use what we detect from your deposits.")
                }
                if isManual {
                    Section { Button("Use detected income") { Task { await save(nil) } } }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Income")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save(Double(text.replacingOccurrences(of: ",", with: ""))) } } label: {
                        if saving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(Double(text.replacingOccurrences(of: ",", with: "")) == nil || saving)
                }
            }
            .onAppear { if current > 0 { text = String(Int(current.rounded())) } }
        }
        .presentationDetents([.medium])
    }

    private func save(_ value: Double?) async {
        saving = true
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.setIncome(monthly: value))
            onSaved(); dismiss()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        saving = false
    }
}

struct AgeSheet: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager
    @State private var age = 35
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Age: \(age)", value: $age, in: 18...90)
                } footer: { Text("Used only to tailor general investing ideas, like how much of a portfolio people your age often hold in stocks.") }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Your age")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { if saving { ProgressView() } else { Text("Save").bold() } }.disabled(saving)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        saving = true
        let year = Calendar.current.component(.year, from: Date()) - age
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.setBirthYear(year))
            onSaved(); dismiss()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        saving = false
    }
}

struct EditBudgetSheet: View {
    struct Row: Identifiable { let id = UUID(); var category: String; var amount: String }

    let suggestions: [Insights.BudgetItem]
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager
    @State private var rows: [Row]
    @State private var saving = false
    @State private var error: String?

    init(lines: [BudgetLine], suggestions: [Insights.BudgetItem], onSaved: @escaping () -> Void) {
        self.suggestions = suggestions
        self.onSaved = onSaved
        _rows = State(initialValue: lines.map { Row(category: $0.category, amount: String(Int($0.monthlyAmount.rounded()))) })
    }

    private var available: [String] {
        Categories.choices.filter { c in c != "Income" && !rows.contains { $0.category == c } }
    }
    private var total: Double { rows.reduce(0) { $0 + (Double($1.amount) ?? 0) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($rows) { $row in
                        HStack(spacing: 12) {
                            IconBadge(symbol: Categories.style(row.category).symbol, color: Categories.style(row.category).color, size: 30)
                            Text(row.category)
                            Spacer()
                            Text("$").foregroundStyle(.secondary)
                            TextField("0", text: $row.amount).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                        }
                    }
                    .onDelete { rows.remove(atOffsets: $0) }
                } header: { Text("Monthly targets") } footer: { Text("Total \(money(total)) a month. Swipe to remove a category.") }

                if !available.isEmpty {
                    Section {
                        Menu {
                            ForEach(available, id: \.self) { c in
                                Button(c) {
                                    let hint = suggestions.first { $0.category == c }?.amount
                                    rows.append(Row(category: c, amount: hint.map { String(Int($0.rounded())) } ?? ""))
                                }
                            }
                        } label: { Label("Add a category", systemImage: "plus.circle.fill") }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { if saving { ProgressView() } else { Text("Save").bold() } }.disabled(saving)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func save() async {
        saving = true
        do {
            let items = rows.compactMap { r -> (category: String, amount: Double)? in
                guard let a = Double(r.amount), a > 0 else { return nil }
                return (r.category, a)
            }
            let _: BudgetsResponse = try await auth.withFreshToken(.saveBudget(items))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onSaved(); dismiss()
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        saving = false
    }
}
