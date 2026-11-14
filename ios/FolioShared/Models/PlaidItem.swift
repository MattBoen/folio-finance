import Foundation

struct PlaidItem: Identifiable, Codable, Sendable {
    let id: String
    let institutionName: String?
    let status: ItemStatus
    let createdAt: Date
    let lastSyncedAt: Date?
    let accountCount: Int?

    enum ItemStatus: String, Codable, Sendable {
        case active
        case loginRequired = "login_required"
        case error
    }
}

struct PlaidItemsResponse: Decodable {
    let items: [PlaidItem]
}

struct LinkTokenResponse: Decodable, Sendable {
    let linkToken: String
    let expiration: String
}

struct NetWorthSnapshot: Decodable, Sendable {
    let date: String
    let netWorth: String
    let totalAssets: String
    let totalLiabilities: String
    /// Investment-account total that day; absent on older snapshots.
    let invested: String?

    var netWorthDecimal: Decimal { Decimal(string: netWorth) ?? 0 }
    var assetsDecimal: Decimal   { Decimal(string: totalAssets) ?? 0 }
    var liabilitiesDecimal: Decimal { Decimal(string: totalLiabilities) ?? 0 }
}

struct NetWorthHistoryResponse: Decodable, Sendable {
    let snapshots: [NetWorthSnapshot]
}
