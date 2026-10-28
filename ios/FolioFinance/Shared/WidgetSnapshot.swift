import Foundation

/// A small, read-only summary the app leaves for the widgets. No tokens or account details.
struct WidgetSnapshot: Codable, Equatable {
    var netWorth: Double
    /// Change over the chart range the app last showed (year to date by default).
    var change: Double
    var changeLabel: String
    var series: [Double]
    var spent: Double
    var income: Double
    var budgetTotal: Double
    var budgetSpent: Double
    var hideAmounts: Bool
    var updated: Date

    static let groupID = "group.com.mattboen.foliofinance"
    private static let key = "widgetSnapshot"

    static var sample: WidgetSnapshot {
        WidgetSnapshot(netWorth: 129_127, change: 10_181, changeLabel: "this year",
                       series: (0..<30).map { (i: Int) -> Double in 119_000.0 + Double(i) * 340.0 + Double(i % 4) * 120.0 },
                       spent: 3_770, income: 6_300, budgetTotal: 3_360, budgetSpent: 3_044,
                       hideAmounts: false, updated: Date())
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
