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
