import Foundation

struct Account: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let officialName: String?
    let type: AccountType
    let subtype: String?
    let balanceCurrent: String?
    let balanceAvailable: String?
    let balanceLimit: String?
    let currency: String
    let mask: String?
    let isHidden: Bool
    let institutionName: String?
    let plaidItemId: String?

    enum AccountType: String, Codable, Sendable {
        case depository
        case credit
        case loan
        case investment
        case other
    }

    var currentBalance: Decimal {
        Decimal(string: balanceCurrent ?? "0") ?? 0
    }

    var displayBalance: String {
        currentBalance.formatted(.currency(code: currency))
    }

    var isAsset: Bool {
        type == .depository || type == .investment
    }

    var isLiability: Bool {
        type == .credit || type == .loan
    }

    var typeLabel: String {
        switch type {
        case .depository: return subtype?.capitalized ?? "Checking"
        case .credit:     return "Credit Card"
        case .loan:       return subtype?.capitalized ?? "Loan"
        case .investment: return "Investment"
        case .other:      return "Account"
        }
    }
}

struct AccountsResponse: Decodable, Sendable {
    let accounts: [Account]
}
