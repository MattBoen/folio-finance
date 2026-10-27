import Foundation

struct Transaction: Identifiable, Codable, Sendable {
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

    var displayName: String { userName ?? merchantName ?? name }

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
