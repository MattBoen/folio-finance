import SwiftUI

/// Which breakdown the Budget tab is showing.
enum PlanSheetKind: Identifiable {
    case income
    case spending
    case budget
    case category(BudgetLine)
    case health(HealthMetric)

    var id: String {
        switch self {
        case .income: "income"
        case .spending: "spending"
        case .budget: "budget"
        case .category(let l): "category-\(l.id)"
        case .health(let m): "health-\(m.rawValue)"
        }
    }
}

enum HealthMetric: String, CaseIterable {
    case savings, emergency, credit, debt

    var title: String {
        switch self {
        case .savings: "Savings rate"
        case .emergency: "Emergency fund"
        case .credit: "Credit use"
        case .debt: "Debt payments"
        }
    }

    var symbol: String {
        switch self {
        case .savings: "banknote.fill"
        case .emergency: "lifepreserver.fill"
        case .credit: "creditcard.fill"
        case .debt: "building.columns.fill"
        }
    }

    /// Fractions (0.15 = 15%) or months for the emergency fund.
    func value(_ h: Insights.Health) -> Double? {
        switch self {
        case .savings: h.savingsRate
        case .emergency: h.emergencyFundMonths
        case .credit: h.creditUtilization
        case .debt: h.debtPaymentRatio
        }
    }

    func format(_ v: Double) -> String {
        self == .emergency ? String(format: "%.1f months", v) : "\(Int((v * 100).rounded()))%"
    }

    /// Strong / Okay / Needs care boundaries, matching the tiles on the Budget tab.
    var ladder: [(label: String, range: String, color: Color)] {
        switch self {
        case .savings: [("Strong", "15% or more", .green), ("Okay", "5% to 15%", .orange), ("Needs care", "Under 5%", .red)]
        case .emergency: [("Strong", "3 months or more", .green), ("Okay", "1 to 3 months", .orange), ("Needs care", "Under 1 month", .red)]
        case .credit: [("Strong", "10% or less", .green), ("Okay", "10% to 30%", .orange), ("Needs care", "Over 30%", .red)]
        case .debt: [("Strong", "20% or less", .green), ("Okay", "20% to 36%", .orange), ("Needs care", "Over 36%", .red)]
        }
    }

    /// Index into `ladder` for a value (0 strong, 1 okay, 2 needs care).
    func level(_ v: Double) -> Int {
        switch self {
        case .savings: v >= 0.15 ? 0 : v >= 0.05 ? 1 : 2
        case .emergency: v >= 3 ? 0 : v >= 1 ? 1 : 2
        case .credit: v <= 0.10 ? 0 : v <= 0.30 ? 1 : 2
        case .debt: v <= 0.20 ? 0 : v <= 0.36 ? 1 : 2
        }
    }
}

private func barTone(_ spent: Double, _ limit: Double) -> Color {
    guard limit > 0 else { return .gray }
    let f = spent / limit
    return f > 1 ? .red : f > 0.85 ? .orange : .green
}

// MARK: - Action row shared by sheets

private struct SheetAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.headline).frame(maxWidth: .infinity).frame(height: 30)
        }
        .buttonStyle(.bordered).controlSize(.large)
    }
}

// MARK: - Income

struct IncomeBreakdown: View {
    let insights: Insights
    var onEdit: () -> Void

    var body: some View {
        let inc = insights.income
        let how: String = {
            switch inc.source {
            case "manual": return "Entered by you"
            case "detected": return "Found from your deposits"
            default: return "Not found yet"
            }
        }()
        BreakdownSheet(
            title: "Income",
            headline: inc.monthly > 0 ? money(inc.monthly) : "Not found yet",
            caption: inc.monthly > 0 ? "per month · \(money(inc.monthly * 12)) a year" : "Add some activity or enter it yourself",
            tone: .plan,
            sections: [
                BreakdownSection(title: "How we got this", rows: [
                    BreakdownRow(symbol: inc.source == "manual" ? "pencil" : "wand.and.stars", color: .blue, title: how,
                                 subtitle: inc.source == "detected" ? "\(inc.confidence.capitalized) confidence · regular deposits over your recent history" : nil, value: "")
                ]),
                BreakdownSection(title: "Sources", rows: inc.sources.isEmpty
                    ? [BreakdownRow(title: "No regular deposits found yet", value: "")]
                    : inc.sources.map { s in
                        BreakdownRow(symbol: "arrow.down.circle.fill", color: .green, title: s.name,
                                     subtitle: "Paid \(s.frequency)", value: money(s.monthly) + " / mo",
                                     fraction: inc.monthly > 0 ? s.monthly / inc.monthly : nil)
                    }),
            ] + depositsSection(inc),
            footnote: "Only regular deposits into checking and savings count, from the last 6 months. Transfers between your own accounts and card payments are left out. Deposits are counted after taxes."
        ) {
            SheetAction(title: inc.source == "manual" ? "Edit or reset income" : "Edit income", symbol: "pencil", action: onEdit)
        }
    }

    private func depositsSection(_ inc: Insights.Income) -> [BreakdownSection] {
        guard let deposits = inc.deposits, !deposits.isEmpty else { return [] }
        return [BreakdownSection(title: "Deposits we counted", rows: deposits.map { d in
            BreakdownRow(symbol: "arrow.down.left", color: .green, title: d.name,
                         subtitle: [shortDate(d.date), d.source == d.name ? nil : d.source].compactMap { $0 }.joined(separator: " · "),
                         value: "+" + money(d.amount, cents: true), valueColor: .green)
        })]
    }
}

/// "Oct 23" from "2026-10-23".
func shortDate(_ day: String) -> String {
    parseDay(day)?.formatted(.dateTime.month(.abbreviated).day()) ?? day
}

// MARK: - Spending pattern

struct SpendingPatternBreakdown: View {
    let insights: Insights

    var body: some View {
        let o = insights.outflow
        let total = max(o.monthlyAverage, 1)
        let cats = o.byCategory.sorted { $0.monthlyAverage > $1.monthlyAverage }
        BreakdownSheet(
            title: "Spending pattern",
            headline: money(o.monthlyAverage),
            caption: o.window.map { "per month · averaged over \(shortDate($0.from)) – \(shortDate($0.to))" } ?? "usual spending per month",
            tone: .plan,
            sections: [
                BreakdownSection(title: "Fixed vs flexible", rows: [
                    BreakdownRow(symbol: "lock.fill", color: .indigo, title: "Bills & fixed", subtitle: "Rent, loans, subscriptions and other recurring costs",
                                 value: money(o.fixed), fraction: o.fixed / total),
                    BreakdownRow(symbol: "cart.fill", color: .teal, title: "Flexible", subtitle: "Day-to-day spending that changes month to month",
                                 value: money(o.variable), fraction: o.variable / total),
                ]),
                BreakdownSection(title: "By category", rows: cats.isEmpty
                    ? [BreakdownRow(title: "No spending yet", value: "")]
                    : cats.map { c in
                        let style = Categories.style(c.category)
                        return BreakdownRow(symbol: style.symbol, color: style.color, title: c.category,
                                            subtitle: c.isFixed ? "Fixed" : "Flexible", value: money(c.monthlyAverage),
                                            fraction: c.monthlyAverage / total)
                    }),
            ],
            footnote: o.window.map { "Total spending from \(shortDate($0.from)) to \(shortDate($0.to)) divided by \(String(format: "%.1f", $0.months)) months. Transfers, card payments and anything you excluded aren't counted. Refunds reduce the total." } ?? "Averages over your recent months. Transfers and card payments aren't counted twice."
        )
    }
}

// MARK: - Budget

struct BudgetBreakdown: View {
    let budgets: [BudgetLine]
    var onEdit: () -> Void

    var body: some View {
        let total = budgets.reduce(0) { $0 + $1.monthlyAmount }
        let spent = budgets.reduce(0) { $0 + $1.spent }
        let left = total - spent
        let cal = Calendar.current
        let now = Date()
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let daysLeft = max(1, daysInMonth - cal.component(.day, from: now) + 1)
        let ordered = budgets.sorted { a, b in
            let ao = a.spent > a.monthlyAmount, bo = b.spent > b.monthlyAmount
            if ao != bo { return ao }
            return (a.monthlyAmount > 0 ? a.spent / a.monthlyAmount : 0) > (b.monthlyAmount > 0 ? b.spent / b.monthlyAmount : 0)
        }
        let pace: String = left > 0
            ? "You can spend about \(money(left / Double(daysLeft))) a day for the rest of the month (\(daysLeft) day\(daysLeft == 1 ? "" : "s") left)."
            : "You're \(money(-left)) over for the month with \(daysLeft) day\(daysLeft == 1 ? "" : "s") left."
        BreakdownSheet(
            title: now.formatted(.dateTime.month(.wide)) + " budget",
            headline: left >= 0 ? money(left) : "−" + money(-left),
            caption: left >= 0 ? "left of \(money(total))" : "over a \(money(total)) budget",
            tone: .plan,
            sections: [
                BreakdownSection(title: "The month so far", rows: [
                    BreakdownRow(symbol: "target", color: .blue, title: "Budgeted", value: money(total)),
                    BreakdownRow(symbol: "cart.fill", color: barTone(spent, total), title: "Spent", value: money(spent),
                                 fraction: total > 0 ? spent / total : 0),
                    BreakdownRow(symbol: "calendar", color: .teal, title: "Pace", subtitle: pace, value: ""),
                ]),
                BreakdownSection(title: "By category", rows: ordered.map { b in
                    let style = Categories.style(b.category)
                    let over = b.spent > b.monthlyAmount
                    return BreakdownRow(
                        symbol: style.symbol, color: over ? .red : style.color, title: b.category,
                        subtitle: "\(money(b.spent)) of \(money(b.monthlyAmount)) · \(b.monthlyAmount > 0 ? Int((b.spent / b.monthlyAmount * 100).rounded()) : 0)%",
                        value: over ? "−" + money(b.spent - b.monthlyAmount) : money(b.monthlyAmount - b.spent),
                        fraction: b.monthlyAmount > 0 ? b.spent / b.monthlyAmount : 0,
                        valueColor: over ? .red : nil)
                }),
            ]
        ) {
            SheetAction(title: "Edit budget", symbol: "slider.horizontal.3", action: onEdit)
        }
    }
}

struct CategoryBudgetBreakdown: View {
    let line: BudgetLine

    var body: some View {
        let style = Categories.style(line.category)
        let left = line.monthlyAmount - line.spent
        let pct = line.monthlyAmount > 0 ? line.spent / line.monthlyAmount : 0
        BreakdownSheet(
            title: line.category,
            headline: left >= 0 ? money(left) : "−" + money(-left),
            caption: left >= 0 ? "left this month" : "over this month",
            tone: .plan,
            sections: [
                BreakdownSection(rows: [
                    BreakdownRow(symbol: style.symbol, color: style.color, title: "Monthly limit", value: money(line.monthlyAmount)),
                    BreakdownRow(symbol: "cart.fill", color: barTone(line.spent, line.monthlyAmount), title: "Spent so far", value: money(line.spent), fraction: pct),
                    BreakdownRow(symbol: "percent", color: .indigo, title: "Used", value: "\(Int((pct * 100).rounded()))%"),
                ])
            ],
            footnote: "Open the Spending tab to see every \(line.category.lowercased()) transaction."
        )
    }
}

// MARK: - Money health

struct HealthBreakdown: View {
    let metric: HealthMetric
    let insights: Insights
    var hasAge: Bool = false

    var body: some View {
        let v = metric.value(insights.health)
        let level = v.map { metric.level($0) }
        let income = insights.income.monthly
        let spending = insights.outflow.monthlyAverage
        BreakdownSheet(
            title: metric.title,
            headline: v.map { metric.format($0) } ?? "—",
            caption: level.map { metric.ladder[$0].label } ?? "Not enough data yet",
            tone: .plan,
            sections: [
                BreakdownSection(title: "What this is", rows: [
                    BreakdownRow(symbol: metric.symbol, color: .blue, title: metric.title, subtitle: what, value: "")
                ]),
                BreakdownSection(title: "Where you land", rows: metric.ladder.enumerated().map { i, step in
                    BreakdownRow(symbol: i == 0 ? "checkmark" : i == 1 ? "minus" : "exclamationmark", color: step.color,
                                 title: step.label, subtitle: level == i ? "You're here" : nil, value: step.range,
                                 valueColor: level == i ? step.color : nil)
                }),
                BreakdownSection(title: "How it's worked out", rows: workings(income: income, spending: spending)),
                BreakdownSection(title: "A gentle thought", rows: [
                    BreakdownRow(symbol: "lightbulb.fill", color: .yellow, title: "Something to consider", subtitle: suggestion(level: level), value: "")
                ]),
            ],
            footnote: "General information based on your own data, not financial advice."
        )
    }

    private var what: String {
        switch metric {
        case .savings: "The share of your income you keep after spending."
        case .emergency: "How many months of usual spending your cash would cover."
        case .credit: "How much of your credit card limits you're using."
        case .debt: "How much of your income goes to loan and card payments."
        }
    }

    private func workings(income: Double, spending: Double) -> [BreakdownRow] {
        let h = insights.health
        switch metric {
        case .savings:
            guard income > 0 else { return [BreakdownRow(title: "Needs your income first", subtitle: "Add or confirm income on the Budget tab.", value: "")] }
            return [
                BreakdownRow(title: "Income", subtitle: insights.income.source == "manual" ? "The amount you entered" : "From your regular deposits, per month", value: money(income)),
                BreakdownRow(title: "Usual spending", subtitle: insights.outflow.window.map { "Average per month, \(shortDate($0.from)) to \(shortDate($0.to))" } ?? "Average per month", value: "−" + money(spending)),
                BreakdownRow(title: "Left over", subtitle: "Left over ÷ income", value: money(income - spending), valueColor: income - spending >= 0 ? .green : .red),
            ]
        case .emergency:
            guard let m = h.emergencyFundMonths else { return [BreakdownRow(title: "Needs some spending history", value: "")] }
            let cashRows = (h.inputs?.cashAccounts ?? []).map { a in
                BreakdownRow(symbol: a.kind == "savings" ? "leaf.fill" : "banknote.fill",
                             color: a.kind == "savings" ? AccountGroup.savings.color : AccountGroup.cash.color,
                             title: a.name, subtitle: a.kind == "savings" ? "Savings" : "Checking", value: money(a.balance))
            }
            return cashRows + [
                BreakdownRow(title: "Cash on hand", subtitle: "Checking and savings, not investments", value: money(h.inputs?.liquid ?? m * spending)),
                BreakdownRow(title: "Usual monthly spending", value: money(spending)),
                BreakdownRow(title: "Months covered", subtitle: "Cash ÷ monthly spending", value: String(format: "%.1f", m)),
            ]
        case .credit:
            let cards = (h.inputs?.cards ?? []).map { c in
                BreakdownRow(symbol: "creditcard.fill", color: AccountGroup.credit.color, title: c.name,
                             subtitle: c.limit.map { "Limit \(money($0))" } ?? "No limit reported, so not counted",
                             value: money(c.balance), fraction: c.limit.map { $0 > 0 ? c.balance / $0 : 0 })
            }
            return cards + [
                BreakdownRow(title: "Card balances ÷ card limits", subtitle: h.creditUtilization == nil
                    ? "Needs a card with a known limit. Connected cards usually include it." : "Using the limits your cards report.",
                             value: h.creditUtilization.map { metric.format($0) } ?? "—")
            ]
        case .debt:
            let payments = (h.inputs?.debtPayments ?? []).map { p in
                BreakdownRow(symbol: "building.columns.fill", color: AccountGroup.loans.color, title: p.name,
                             subtitle: shortDate(p.date), value: money(p.amount, cents: true))
            }
            return payments + [
                BreakdownRow(title: "Debt payments per month", subtitle: "Loan and mortgage payments over the last 90 days", value: money(h.inputs?.debtMonthly ?? 0)),
                BreakdownRow(title: "Monthly debt payments ÷ monthly income", subtitle: h.debtPaymentRatio == nil
                    ? "Needs loan payments plus your income." : "Using your income of \(money(income)).",
                             value: h.debtPaymentRatio.map { metric.format($0) } ?? "—")
            ]
        }
    }

    private func suggestion(level: Int?) -> String {
        guard let level else { return "Once there's a bit more activity, this fills in on its own." }
        switch (metric, level) {
        case (.savings, 0): return "You're keeping a healthy share. Some people put the extra toward long-term goals."
        case (.savings, 1): return "A small, automatic transfer on payday is a common way to nudge this up."
        case (.savings, _): return "Looking at your biggest flexible category is a common first step."
        case (.emergency, 0): return "You're well covered. Cash beyond six months or so is sometimes put to other uses."
        case (.emergency, 1): return "Many people build toward three months of spending, one step at a time."
        case (.emergency, _): return "Even a month of spending set aside can take a lot of pressure off."
        case (.credit, 0): return "Low use is generally good for credit scores."
        case (.credit, 1): return "Paying a card down before its statement closes can lower the reported balance."
        case (.credit, _): return "Bringing balances under about 30% of limits is generally seen as helpful."
        case (.debt, 0): return "Payments are a comfortable share of your income."
        case (.debt, 1): return "This is workable. Extra payments on the highest-rate debt tend to save the most."
        default: return "A high share can strain a budget. Reviewing rates and terms is a common step."
        }
    }
}

// MARK: - Investing

struct InvestingBreakdown: View {
    let investing: Insights.Investing
    var hasAge: Bool
    var onAddAge: () -> Void

    private func color(_ i: Int) -> Color {
        [AccountGroup.cash.color, AccountGroup.savings.color, AccountGroup.investments.color, AccountGroup.other.color][i % 4]
    }

    var body: some View {
        BreakdownSheet(
            title: "Investing ideas",
            headline: money(investing.totalInvested),
            caption: "invested today",
            tone: .plan,
            sections: [
                BreakdownSection(title: "Where your money sits", rows: investing.allocation.isEmpty
                    ? [BreakdownRow(title: "Add an account to see this", value: "")]
                    : investing.allocation.enumerated().map { i, s in
                        BreakdownRow(symbol: nil, color: color(i), title: s.label, subtitle: "\(Int(s.percent.rounded()))% of your assets",
                                     value: money(s.amount), fraction: s.percent / 100)
                    }),
                BreakdownSection(title: "Notes for you", rows: investing.notes.isEmpty
                    ? [BreakdownRow(title: "Nothing to flag right now", value: "")]
                    : investing.notes.map { n in
                        BreakdownRow(symbol: n.tone == "good" ? "checkmark" : n.tone == "attention" ? "exclamationmark" : "lightbulb.fill",
                                     color: n.tone == "good" ? .green : n.tone == "attention" ? .orange : .blue,
                                     title: n.title, subtitle: n.detail, value: "")
                    }),
                BreakdownSection(title: "Common rules of thumb", rows: [
                    BreakdownRow(symbol: "percent", color: .purple, title: "Stocks by age",
                                 subtitle: hasAge ? "Some people hold roughly 110 minus their age in stocks, and the rest in bonds and cash."
                                                  : "A popular idea is 110 minus your age in stocks. Add your age to see yours.", value: ""),
                    BreakdownRow(symbol: "calendar.badge.clock", color: .indigo, title: "Retirement saving",
                                 subtitle: "Many people aim to save about 15% of income for retirement.", value: ""),
                    BreakdownRow(symbol: "gift.fill", color: .pink, title: "Employer match",
                                 subtitle: "If your employer matches contributions, getting the full match is often seen as a good first step.", value: ""),
                    BreakdownRow(symbol: "scissors", color: .teal, title: "Fees",
                                 subtitle: "Funds with lower fees keep more of your returns. Under about 0.5% a year is common for index funds.", value: ""),
                ]),
            ],
            footnote: "General ideas for learning, not advice to buy or sell anything."
        ) {
            if !hasAge { SheetAction(title: "Add your age for tailored ideas", symbol: "person.crop.circle.badge.plus", action: onAddAge) }
        }
    }
}
