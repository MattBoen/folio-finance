import Foundation

/// Bills and subscriptions the server found in the last year of transactions (GET /insights/recurring).
struct Recurring: Decodable, Sendable {
    let items: [RecurringItem]
    let monthlyTotal: Double
    let yearlyTotal: Double
    let subscriptionsMonthly: Double
    let upcoming: [UpcomingBill]
    let dueNext30: Double
    /// What is still due between today and the end of this month.
    let dueThisMonth: Double
}

struct RecurringItem: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let amount: Double
    let frequency: String        // weekly | biweekly | semimonthly | monthly | yearly
    let monthly: Double
    let yearly: Double
    let lastDate: String
    let nextDate: String
    let category: String
    let isSubscription: Bool
    let estimated: Bool
    let priceChange: PriceChange?
    let count: Int

    struct PriceChange: Decodable, Sendable { let from: Double; let to: Double }

    var frequencyLabel: String {
        switch frequency {
        case "weekly": "Weekly"
        case "biweekly": "Every 2 weeks"
        case "semimonthly": "Twice a month"
        case "yearly": "Yearly"
        default: "Monthly"
        }
    }
}

struct UpcomingBill: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let amount: Double
    let date: String
    let estimated: Bool
    var uid: String { id + date }
}
