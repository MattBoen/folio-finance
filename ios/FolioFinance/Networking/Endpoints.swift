import Foundation

struct Endpoint {
    let method: String
    let path: String
    let body: Data?

    static func get(_ path: String) -> Endpoint {
        Endpoint(method: "GET", path: path, body: nil)
    }

    static func post<B: Encodable>(_ path: String, body: B) -> Endpoint {
        Endpoint(method: "POST", path: path, body: try? JSONEncoder.snakeCase.encode(body))
    }

    static func patch<B: Encodable>(_ path: String, body: B) -> Endpoint {
        Endpoint(method: "PATCH", path: path, body: try? JSONEncoder.snakeCase.encode(body))
    }

    static func put<B: Encodable>(_ path: String, body: B) -> Endpoint {
        Endpoint(method: "PUT", path: path, body: try? JSONEncoder.snakeCase.encode(body))
    }

    static func delete(_ path: String) -> Endpoint {
        Endpoint(method: "DELETE", path: path, body: nil)
    }
}

extension JSONEncoder {
    static let snakeCase: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}

// ── Auth ──────────────────────────────────────────────────────────────────────

extension Endpoint {
    static func login(email: String, password: String) -> Endpoint {
        .post("/auth/login", body: ["email": email, "password": password])
    }

    static func register(email: String, password: String) -> Endpoint {
        .post("/auth/register", body: ["email": email, "password": password])
    }

    static func checkEmail(_ email: String) -> Endpoint {
        .post("/auth/check", body: ["email": email])
    }

    static func refresh(token: String) -> Endpoint {
        struct Body: Encodable { let refreshToken: String }
        return .post("/auth/refresh", body: Body(refreshToken: token))
    }

    static func appleSignIn(identityToken: String, fullName: String?) -> Endpoint {
        struct Body: Encodable { let identityToken: String; let fullName: String? }
        return .post("/auth/apple", body: Body(identityToken: identityToken, fullName: fullName))
    }

    static var me: Endpoint { .get("/auth/me") }
}

// ── Plaid ─────────────────────────────────────────────────────────────────────

extension Endpoint {
    static var linkToken: Endpoint {
        .post("/plaid/link/token", body: EmptyBody())
    }

    /// A link token for signing back in to a bank that stopped syncing (Plaid "update mode").
    static func reconnectLinkToken(itemId: String) -> Endpoint {
        struct Body: Encodable { let itemId: String }
        return .post("/plaid/link/token", body: Body(itemId: itemId))
    }

    static func exchangeToken(
        publicToken: String,
        institutionId: String?,
        institutionName: String?,
        accountIds: [String]? = nil
    ) -> Endpoint {
        struct Body: Encodable {
            let publicToken: String
            let institutionId: String?
            let institutionName: String?
            let accountIds: [String]?
        }
        return .post("/plaid/exchange", body: Body(
            publicToken: publicToken,
            institutionId: institutionId,
            institutionName: institutionName,
            accountIds: accountIds
        ))
    }

    /// Pulls new balances and transactions from every connected bank (skips ones synced in the last few minutes).
    static func syncBanks(force: Bool = false) -> Endpoint {
        .post(force ? "/plaid/sync?force=1" : "/plaid/sync", body: EmptyBody())
    }

    static var plaidItems: Endpoint { .get("/plaid/items") }

    static func removePlaidItem(id: String) -> Endpoint {
        .delete("/plaid/items/\(id)")
    }

    static func refreshPlaidItem(id: String) -> Endpoint {
        .post("/plaid/items/\(id)/refresh", body: EmptyBody())
    }
}

// ── Accounts ─────────────────────────────────────────────────────────────────

extension Endpoint {
    static var accounts: Endpoint { .get("/accounts") }

    static func createManualAccount(
        name: String, type: String, subtype: String?, balance: Double, institutionName: String?
    ) -> Endpoint {
        struct Body: Encodable {
            let name: String; let type: String; let subtype: String?
            let balance: Double; let institutionName: String?
        }
        return .post("/accounts/manual", body: Body(
            name: name, type: type, subtype: subtype, balance: balance, institutionName: institutionName
        ))
    }

    static func updateAccount(id: String, name: String, balance: Double, institutionName: String?) -> Endpoint {
        struct Body: Encodable { let name: String; let balance: Double; let institutionName: String? }
        return .patch("/accounts/\(id)", body: Body(name: name, balance: balance, institutionName: institutionName))
    }

    static func renameAccount(id: String, name: String) -> Endpoint {
        struct Body: Encodable { let name: String }
        return .patch("/accounts/\(id)", body: Body(name: name))
    }

    static func deleteAccount(id: String) -> Endpoint { .delete("/accounts/\(id)") }

    /// Permanently deletes the signed-in customer and all of their data.
    static func deleteMyAccount(password: String) -> Endpoint {
        struct Body: Encodable { let password: String }
        return Endpoint(method: "DELETE", path: "/account", body: try? JSONEncoder().encode(Body(password: password)))
    }

    static func setAccountHidden(id: String, hidden: Bool) -> Endpoint {
        struct Body: Encodable { let hidden: Bool }
        return .patch("/accounts/\(id)/hidden", body: Body(hidden: hidden))
    }
}

// ── Transactions ──────────────────────────────────────────────────────────────

extension Endpoint {
    static func transactions(from: String, to: String, accountId: String? = nil, limit: Int = 100) -> Endpoint {
        var path = "/transactions?from=\(from)&to=\(to)&limit=\(limit)"
        if let accountId { path += "&account_id=\(accountId)" }
        return .get(path)
    }

    static func createTransaction(
        accountId: String, amount: Double, kind: String, date: String, name: String, category: String?
    ) -> Endpoint {
        struct Body: Encodable {
            let accountId: String; let amount: Double; let kind: String
            let date: String; let name: String; let category: String?
        }
        return .post("/transactions", body: Body(
            accountId: accountId, amount: amount, kind: kind, date: date, name: name, category: category
        ))
    }

    static func setTransactionExcluded(id: String, excluded: Bool) -> Endpoint {
        struct Body: Encodable { let isExcluded: Bool }
        return .patch("/transactions/\(id)", body: Body(isExcluded: excluded))
    }

    /// Only the fields that are passed change; an empty name or note clears it.
    static func updateTransaction(id: String, userName: String?, note: String?, category: String?) -> Endpoint {
        struct Body: Encodable { let userName: String?; let note: String?; let category: String? }
        return .patch("/transactions/\(id)", body: Body(userName: userName, note: note, category: category))
    }

    static func deleteTransaction(id: String) -> Endpoint { .delete("/transactions/\(id)") }

    static func spendingSummary(from: String, to: String) -> Endpoint {
        .get("/transactions/spending/summary?from=\(from)&to=\(to)")
    }

    static func netWorthHistory(days: Int = 90) -> Endpoint {
        .get("/accounts/net-worth/history?days=\(days)")
    }
}

private struct EmptyBody: Encodable {}

// ── Plan: insights, budgets, income, vehicles ─────────────────────────────────

extension Endpoint {
    static var insights: Endpoint { .get("/insights") }
    static var budgets: Endpoint { .get("/budgets") }
    static var generateBudget: Endpoint { .post("/budgets/generate", body: EmptyBody()) }

    static func saveBudget(_ items: [(category: String, amount: Double)]) -> Endpoint {
        struct Item: Encodable { let category: String; let amount: Double }
        struct Body: Encodable { let items: [Item] }
        return .put("/budgets", body: Body(items: items.map { Item(category: $0.category, amount: $0.amount) }))
    }

    /// Pass nil to go back to the detected income.
    static func setIncome(monthly: Double?) -> Endpoint {
        struct Body: Encodable { let monthly: Double? }
        return .put("/settings/income", body: Body(monthly: monthly))
    }

    static func setBirthYear(_ year: Int?) -> Endpoint {
        struct Body: Encodable { let birthYear: Int? }
        return .put("/settings/profile", body: Body(birthYear: year))
    }

    static func vehicleLookup(vin: String, miles: Int) -> Endpoint {
        struct Body: Encodable { let vin: String; let miles: Int }
        return .post("/vehicles/lookup", body: Body(vin: vin, miles: miles))
    }

    static func vehicleEstimate(year: Int, make: String, model: String, trim: String?, miles: Int, vin: String? = nil) -> Endpoint {
        struct Body: Encodable { let year: Int; let make: String; let model: String; let trim: String?; let miles: Int; let vin: String? }
        return .post("/vehicles/estimate", body: Body(year: year, make: make, model: model, trim: trim, miles: miles, vin: vin))
    }

    static func vehicleTrims(year: Int, make: String, model: String) -> Endpoint {
        func enc(_ v: String) -> String { v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v }
        return .get("/vehicles/trims?year=\(year)&make=\(enc(make))&model=\(enc(model))")
    }

    static func createVehicle(vin: String?, year: Int, make: String, model: String, trim: String?, miles: Int, value: Double, annualMiles: Int? = nil) -> Endpoint {
        struct Body: Encodable {
            let vin: String?; let year: Int; let make: String; let model: String
            let trim: String?; let miles: Int; let value: Double; let annualMiles: Int?
        }
        return .post("/vehicles", body: Body(vin: vin, year: year, make: make, model: model, trim: trim, miles: miles, value: value, annualMiles: annualMiles))
    }

    static func vehicleDetails(accountId: String) -> Endpoint { .get("/vehicles/\(accountId)") }

    /// Change any of the odometer, yearly miles or value. `reestimate` recomputes the value from the car's details.
    static func updateVehicle(accountId: String, miles: Int? = nil, annualMiles: Int? = nil, value: Double? = nil, reestimate: Bool? = nil) -> Endpoint {
        struct Body: Encodable { let miles: Int?; let annualMiles: Int?; let value: Double?; let reestimate: Bool? }
        return .patch("/vehicles/\(accountId)", body: Body(miles: miles, annualMiles: annualMiles, value: value, reestimate: reestimate))
    }
}

// ── Ask ───────────────────────────────────────────────────────────────────────

extension Endpoint {
    static var askSettings: Endpoint { .get("/settings/ask") }

    static func setAskEnabled(_ enabled: Bool) -> Endpoint {
        struct Body: Encodable { let enabled: Bool }
        return .put("/settings/ask", body: Body(enabled: enabled))
    }

    static func ask(messages: [(role: String, content: String)]) -> Endpoint {
        struct Msg: Encodable { let role: String; let content: String }
        struct Body: Encodable { let messages: [Msg] }
        return .post("/ask", body: Body(messages: messages.map { Msg(role: $0.role, content: $0.content) }))
    }

    static func confirmProposal(id: String) -> Endpoint {
        struct Body: Encodable { let proposalId: String }
        return .post("/ask/confirm", body: Body(proposalId: id))
    }

    static func dismissProposal(id: String) -> Endpoint {
        struct Body: Encodable { let proposalId: String }
        return .post("/ask/dismiss", body: Body(proposalId: id))
    }
}
