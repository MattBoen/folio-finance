import SwiftUI

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

    var isAsset: Bool { !isLiability }

    var isLiability: Bool {
        type == .credit || type == .loan
    }

    var isManual: Bool { plaidItemId == nil }

    var group: AccountGroup {
        switch type {
        case .credit: return .credit
        case .loan: return .loans
        case .investment: return .investments
        case .other: return .other
        case .depository:
            let s = (subtype ?? "").lowercased()
            return (s.contains("sav") || s == "cd" || s.contains("money market")) ? .savings : .cash
        }
    }

    var typeLabel: String {
        switch type {
        case .depository: return subtype?.capitalized ?? "Checking"
        case .credit:     return "Credit Card"
        case .loan:       return subtype?.capitalized ?? "Loan"
        case .investment: return "Investment"
        case .other:      return "Other asset"
        }
    }
}

struct AccountsResponse: Decodable, Sendable {
    let accounts: [Account]
}

struct AccountResponse: Decodable, Sendable {
    let account: Account
}

/// The balance-sheet groups, in the same order and colors as the Mac app.
enum AccountGroup: String, CaseIterable, Identifiable, Sendable {
    case cash = "Cash"
    case savings = "Savings"
    case investments = "Investments"
    case other = "Physical Assets"
    case credit = "Credit Cards"
    case loans = "Loans"

    var id: String { rawValue }
    var isLiability: Bool { self == .credit || self == .loans }

    var color: Color {
        switch self {
        case .cash: Color(hex: 0x2A78D6)
        case .savings: Color(hex: 0x1BAF7A)
        case .investments: Color(hex: 0x6A5AD0)
        case .other: Color(hex: 0xE0A21A)
        case .credit: Color(hex: 0xE34948)
        case .loans: Color(hex: 0xC2569E)
        }
    }

    var symbol: String {
        switch self {
        case .cash: "banknote.fill"
        case .savings: "leaf.fill"
        case .investments: "chart.line.uptrend.xyaxis"
        case .other: "car.fill"
        case .credit: "creditcard.fill"
        case .loans: "building.columns.fill"
        }
    }
}
