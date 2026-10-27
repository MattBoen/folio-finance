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

    static func delete(_ path: String) -> Endpoint {
        Endpoint(method: "DELETE", path: path, body: nil)
    }
}

private extension JSONEncoder {
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

    static func exchangeToken(
        publicToken: String,
        institutionId: String?,
        institutionName: String?
    ) -> Endpoint {
        struct Body: Encodable {
            let publicToken: String
            let institutionId: String?
            let institutionName: String?
        }
        return .post("/plaid/exchange", body: Body(
            publicToken: publicToken,
            institutionId: institutionId,
            institutionName: institutionName
        ))
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

    static func deleteAccount(id: String) -> Endpoint { .delete("/accounts/\(id)") }

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

    static func deleteTransaction(id: String) -> Endpoint { .delete("/transactions/\(id)") }

    static func spendingSummary(from: String, to: String) -> Endpoint {
        .get("/transactions/spending/summary?from=\(from)&to=\(to)")
    }

    static func netWorthHistory(days: Int = 90) -> Endpoint {
        .get("/accounts/net-worth/history?days=\(days)")
    }
}

private struct EmptyBody: Encodable {}
