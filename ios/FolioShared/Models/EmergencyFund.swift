import Foundation

/// Which cash accounts make up your emergency fund and how many months they cover.
/// Folio sorts the accounts (Ask Folio's AI when it's on, simple rules otherwise); your own choices always win.
struct EmergencyFund: Decodable, Sendable {
    struct Account: Decodable, Identifiable, Sendable {
        let id: String
        let name: String
        let institution: String?
        let kind: String          // "checking" | "savings"
        let balance: Double
        var included: Bool
        var source: String        // "ai" | "rules" | "you"
        var reason: String
    }
    struct Monthly: Decodable, Sendable {
        let essentials: Double
        let usual: Double
        let budget: Double?
    }
    struct Essential: Decodable, Identifiable, Sendable {
        let category: String
        let monthly: Double
        var id: String { category }
    }
    struct Question: Decodable, Sendable {
        let accountId: String
        let text: String
    }

    var accounts: [Account]
    var basis: String             // "essentials" | "usual" | "budget"
    let monthly: Monthly
    let essentials: [Essential]
    let total: Double
    let months: Double?
    let question: Question?
    let sortedBy: String          // "ai" | "rules"
    let canSort: Bool
}

extension Endpoint {
    static var emergencyFund: Endpoint { .get("/insights/emergency-fund") }

    /// Your changes: which accounts count, what it's measured against, or `reset` to have Folio sort them again.
    static func saveEmergencyFund(included: [String: Bool]? = nil, basis: String? = nil, reset: Bool? = nil) -> Endpoint {
        struct Body: Encodable { let included: [String: Bool]?; let basis: String?; let reset: Bool? }
        return .put("/insights/emergency-fund", body: Body(included: included, basis: basis, reset: reset))
    }

    /// Asks Ask Folio's AI to sort the accounts. Does nothing (just returns the screen) when Ask Folio is off.
    static var sortEmergencyFund: Endpoint { .post("/ask/emergency-fund", body: EmptyBody()) }
}

extension Notification.Name {
    /// Something behind Money health changed (for example, which accounts are the emergency fund).
    static let healthChanged = Notification.Name("FolioHealthChanged")
}

/// Savings rate: income minus spending, as a share of income. Spending is measured the same way as the
/// emergency fund (essentials, usual spending or budget) unless you pick something else for it.
struct SavingsRate: Decodable, Sendable {
    let income: Double
    let incomeSource: String      // "detected" | "manual" | "none"
    var basis: String
    let followsFund: Bool
    let fundBasis: String
    let monthly: EmergencyFund.Monthly
    let spending: Double
    let leftOver: Double
    let rate: Double?
}

extension Endpoint {
    static var savingsRate: Endpoint { .get("/insights/savings-rate") }

    /// "essentials" | "usual" | "budget", or "match" to follow the emergency fund again.
    static func saveSavingsRate(basis: String) -> Endpoint {
        struct Body: Encodable { let basis: String }
        return .put("/insights/savings-rate", body: Body(basis: basis))
    }
}

/// Credit use: card balances ÷ card limits. The limit is the bank's, or one you typed in (yours wins).
struct CreditUse: Decodable, Sendable {
    struct Card: Decodable, Identifiable, Sendable {
        let id: String
        let name: String
        let institution: String?
        let balance: Double
        let limit: Double?
        let limitSource: String   // "bank" | "you" | "rules" | "none"
        let used: Double?
        /// A charge card with no preset limit: left out of credit use, like current credit scores do.
        let noLimit: Bool
    }
    let cards: [Card]
    let balance: Double
    let limit: Double
    let rate: Double?
    let missing: Int
}

extension Endpoint {
    static var creditUse: Endpoint { .get("/insights/credit-use") }

    enum CardLimit { case amount(Double), noLimit, bank }

    /// Your limit for a card, "no preset limit" (a charge card), or back to what the bank reports.
    static func saveCreditLimit(id: String, _ choice: CardLimit) -> Endpoint {
        struct Body: Encodable {
            let id: String; let choice: CardLimit
            enum K: String, CodingKey { case limits }
            struct Key: CodingKey { var stringValue: String; var intValue: Int? { nil }; init(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { nil } }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: K.self)
                var m = c.nestedContainer(keyedBy: Key.self, forKey: .limits)
                let k = Key(stringValue: id)
                switch choice {
                case .amount(let v): try m.encode(v, forKey: k)
                case .noLimit: try m.encode("none", forKey: k)
                case .bank: try m.encodeNil(forKey: k)
                }
            }
        }
        return .put("/insights/credit-use", body: Body(id: id, choice: choice))
    }
}
