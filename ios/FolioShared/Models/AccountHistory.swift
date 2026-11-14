import Foundation

/// A day-by-day value for one account (GET /accounts/:id/history).
struct AccountHistoryResponse: Decodable, Sendable {
    let snapshots: [Point]

    struct Point: Decodable, Sendable {
        let date: String
        let value: String
        var doubleValue: Double { Double(value) ?? 0 }
    }
}
