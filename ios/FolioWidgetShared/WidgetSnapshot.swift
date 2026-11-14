import Foundation

/// Everything the home-screen widgets show, in one small read-only summary. No tokens or account details.
/// Folio's app writes one after each refresh; Folio Desktop builds one from the Mac's feed. Both draw it with the same widget views.
struct WidgetSnapshot: Codable, Equatable {
    var netWorth: Double
    /// Change over the range the app last showed (year to date by default).
    var change: Double
    var changeLabel: String
    var series: [Double]
    var spent: Double
    var income: Double
    var budgetTotal: Double
    var budgetSpent: Double
    var hideAmounts: Bool
    var updated: Date

    // Newer fields are optional so a snapshot saved by an older build still loads.
    var monthLabel: String? = nil
    var dayChange: Double? = nil
    var netCash: Double? = nil
    var invested: Double? = nil
    var budgetItems: [BudgetLine]? = nil
    var categories: [Category]? = nil
    var recent: [Purchase]? = nil
    var investments: Investments? = nil

    struct BudgetLine: Codable, Equatable { var name: String; var limit: Double; var spent: Double; var color: String }
    struct Category: Codable, Equatable { var name: String; var total: Double; var mine: Double; var color: String }
    struct Purchase: Codable, Equatable, Identifiable { var id: String; var name: String; var amount: Double; var color: String; var excluded: Bool }
    struct Investments: Codable, Equatable {
        var total: Double
        var dayChange: Double?
        /// Year-to-date return and the S&P 500's, as fractions (0.067 = 6.7%). Nil when the source can't say.
        var ytd: Double?
        var sp: Double?
        var series: [Double]?
        var accounts: [Account]
        struct Account: Codable, Equatable, Identifiable { var name: String; var balance: Double; var ytd: Double?; var id: String { name } }
    }

    #if PERSONAL
    static let groupID = "group.com.mattboen.financialpicture"
    #else
    static let groupID = "group.com.mattboen.foliofinance"
    #endif
    private static let key = "widgetSnapshot"

    static var sample: WidgetSnapshot {
        WidgetSnapshot(netWorth: 129_127, change: 10_181, changeLabel: "this year",
                       series: (0..<30).map { (i: Int) -> Double in 119_000.0 + Double(i) * 340.0 + Double(i % 4) * 120.0 },
                       spent: 1_219, income: 3_150, budgetTotal: 3_360, budgetSpent: 1_219,
                       hideAmounts: false, updated: Date(), monthLabel: "November", dayChange: 312, netCash: 8_420, invested: 103_791,
                       budgetItems: [BudgetLine(name: "Groceries", limit: 760, spent: 410, color: "#1baf7a"), BudgetLine(name: "Dining", limit: 300, spent: 187, color: "#eb6834")],
                       categories: [Category(name: "Groceries", total: 410, mine: 410, color: "#1baf7a"), Category(name: "Dining", total: 187, mine: 187, color: "#eb6834"), Category(name: "Shopping", total: 96, mine: 96, color: "#e87ba4")],
                       recent: [Purchase(id: "1", name: "Whole Foods", amount: 86.2, color: "#1baf7a", excluded: false), Purchase(id: "2", name: "Chipotle", amount: 14.5, color: "#eb6834", excluded: false)],
                       investments: Investments(total: 103_791, dayChange: 312, ytd: 0.098, sp: 0.124, series: nil,
                                                accounts: [.init(name: "Brokerage", balance: 42_310, ytd: 0.11), .init(name: "401(k)", balance: 61_480, ytd: 0.09)]))
    }

    static func load() -> WidgetSnapshot? {
        guard let d = UserDefaults(suiteName: groupID)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: d)
    }

    func save() {
        guard let d = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.groupID)?.set(d, forKey: Self.key)
    }

    static func clear() {
        UserDefaults(suiteName: groupID)?.removeObject(forKey: key)
    }
}
