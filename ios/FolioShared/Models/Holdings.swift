import Foundation

/// What you own in your investment accounts (GET /insights/holdings).
struct HoldingsSummary: Decodable, Sendable {
    let holdings: [Holding]
    let total: Double
    let gain: Double?
    let gainPercent: Double?
    /// Value of the positions where the bank reports what was paid; the gain only covers these.
    let coveredValue: Double
    let byKind: [Kind]

    struct Holding: Decodable, Identifiable, Sendable {
        let accountId: String
        let ticker: String?
        let name: String
        let kind: String
        let quantity: Double
        let price: Double
        let value: Double
        let gain: Double?
        let gainPercent: Double?
        let weight: Double
        var id: String { accountId + (ticker ?? name) }
    }
    struct Kind: Decodable, Identifiable, Sendable {
        let kind: String
        let value: Double
        let percent: Double
        var id: String { kind }
    }
}
