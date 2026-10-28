import Foundation

struct Transaction: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let accountId: String
    let accountName: String?
    let amount: String
    let date: String        // YYYY-MM-DD
    let name: String
    let userName: String?
    let merchantName: String?
    let categoryName: String?
    let note: String?
    let isPending: Bool
    let isExcluded: Bool
    let lat: Double?
    let lon: Double?

    private enum CodingKeys: String, CodingKey {
        case id, accountId, accountName, amount, date, name, userName, merchantName
        case categoryName, note, isPending, isExcluded, lat, lon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountId = try c.decode(String.self, forKey: .accountId)
        accountName = try c.decodeIfPresent(String.self, forKey: .accountName)
        amount = try c.decode(String.self, forKey: .amount)
        date = try c.decode(String.self, forKey: .date)
        name = try c.decode(String.self, forKey: .name)
        userName = try c.decodeIfPresent(String.self, forKey: .userName)
        merchantName = try c.decodeIfPresent(String.self, forKey: .merchantName)
        categoryName = try c.decodeIfPresent(String.self, forKey: .categoryName)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        isPending = try c.decodeIfPresent(Bool.self, forKey: .isPending) ?? false
        isExcluded = try c.decodeIfPresent(Bool.self, forKey: .isExcluded) ?? false
        lat = Self.flexibleDouble(c, .lat)
        lon = Self.flexibleDouble(c, .lon)
    }

    /// The server sends coordinates as numeric strings (Postgres numeric) or numbers, or null.
    private static func flexibleDouble(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }

    var decimalAmount: Decimal {
        Decimal(string: amount) ?? 0
    }

    // Plaid: positive = debit (money out), negative = credit (money in)
    var displayAmount: String {
        let abs = Swift.abs(decimalAmount)
        let formatted = abs.formatted(.currency(code: "USD"))
        return decimalAmount > 0 ? "-\(formatted)" : "+\(formatted)"
    }

    var isDebit: Bool { decimalAmount > 0 }

    var doubleAmount: Double { NSDecimalNumber(decimal: decimalAmount).doubleValue }

    var category: String { categoryName ?? (isDebit ? "Other" : "Income") }

    var displayName: String { userName?.nilIfEmpty ?? merchantName ?? name }

    /// Stable key for "this merchant" across transactions.
    var merchantKey: String { displayName.trimmingCharacters(in: .whitespaces).lowercased() }

    var hasCoordinate: Bool { lat != nil && lon != nil }

    var displayDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let d = formatter.date(from: date) else { return date }
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: d)
    }
}

struct TransactionsResponse: Decodable, Sendable {
    let transactions: [Transaction]
    let total: Int
}
