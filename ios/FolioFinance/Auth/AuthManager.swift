import Foundation

@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var isDemo = false

    private let keychain = KeychainService.shared
    private let api = APIClient.shared

    private(set) var accessToken: String? {
        get { keychain.load(key: "access_token") }
        set {
            if let v = newValue { keychain.save(key: "access_token", value: v) }
            else { keychain.delete(key: "access_token") }
        }
    }

    private var refreshToken: String? {
        get { keychain.load(key: "refresh_token") }
        set {
            if let v = newValue { keychain.save(key: "refresh_token", value: v) }
            else { keychain.delete(key: "refresh_token") }
        }
    }

    init() {
        // The keychain survives deleting the app; UserDefaults doesn't. A fresh install starts signed out.
        if !UserDefaults.standard.bool(forKey: "installMarkerV2") {
            keychain.delete(key: "access_token")
            keychain.delete(key: "refresh_token")
            UserDefaults.standard.set(true, forKey: "installMarkerV2")
        }
        isAuthenticated = accessToken != nil
    }

    func login(email: String, password: String) async {
        let email = Self.normalized(email)
        await perform {
            do {
                let response: AuthResponse = try await self.api.request(.login(email: email, password: password))
                UserDefaults.standard.set(email, forKey: "currentEmail")
                self.store(response)
            } catch APIError.unauthorized {
                throw APIError.server(401, "That email and password don't match.")
            }
        }
    }

    private static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func register(email: String, password: String) async {
        let email = Self.normalized(email)
        await perform {
            let response: AuthResponse = try await self.api.request(
                .register(email: email, password: password)
            )
            UserDefaults.standard.set(email, forKey: "currentEmail")
            self.store(response)
        }
    }

    func refresh() async throws {
        guard let raw = refreshToken else { throw APIError.unauthorized }
        let response: AuthResponse = try await api.request(.refresh(token: raw))
        store(response)
    }

    func logout() {
        accessToken = nil
        refreshToken = nil
        isDemo = false
        isAuthenticated = false
        error = nil
    }

    /// Returns an error message, or nil after the account is gone and the session is cleared.
    func deleteAccount(password: String) async -> String? {
        do {
            let _: AnyDecodable = try await withFreshToken(.deleteMyAccount(password: password))
            logout()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Each account sees the introduction once per phone; "Set up Folio" in the profile menu replays it.
    var hasSeenSetup: Bool {
        let email = UserDefaults.standard.string(forKey: "currentEmail") ?? ""
        return (UserDefaults.standard.stringArray(forKey: "setupSeenEmails") ?? []).contains(email)
    }

    func markSetupSeen() {
        let email = UserDefaults.standard.string(forKey: "currentEmail") ?? ""
        var seen = UserDefaults.standard.stringArray(forKey: "setupSeenEmails") ?? []
        if !seen.contains(email) { seen.append(email) }
        UserDefaults.standard.set(seen, forKey: "setupSeenEmails")
    }

    func startDemo() {
        isDemo = true
        isAuthenticated = true
        error = nil
    }

    func clearError() { error = nil }

    /// Makes an authenticated API request. On 401, refreshes the access token once and retries.
    func withFreshToken<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        if isDemo { return try DemoData.respond(to: endpoint) }
        guard let token = accessToken else { throw APIError.unauthorized }
        do {
            return try await api.request(endpoint, token: token)
        } catch APIError.unauthorized {
            try await refresh()
            guard let newToken = accessToken else { throw APIError.unauthorized }
            return try await api.request(endpoint, token: newToken)
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func store(_ response: AuthResponse) {
        accessToken = response.accessToken
        refreshToken = response.refreshToken
        isAuthenticated = true
        error = nil
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        isLoading = true
        error = nil
        do {
            try await work()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

struct AuthResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
}

// MARK: - Demo mode (sample data, read-only)

@MainActor
enum DemoData {
    static func respond<T: Decodable>(to endpoint: Endpoint) throws -> T {
        if endpoint.path == "/vehicles/lookup" {
            let v: [String: Any] = ["vin": "1HGCV1F30MA000000", "year": 2021, "make": "Honda", "model": "Accord", "trim": "Sport", "miles": 41200,
                                    "estimatedValue": 22400, "lowValue": 20200, "highValue": 24600, "source": "estimate"]
            let data = try JSONSerialization.data(withJSONObject: v)
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        }
        guard endpoint.method == "GET" else {
            throw APIError.server(403, "Demo mode is read-only. Create a free account to save your own data.")
        }
        let path = endpoint.path
        let object: Any
        if path.hasPrefix("/accounts/net-worth/history") {
            object = ["snapshots": history(days: Int(query(path)["days"] ?? "") ?? 90)]
        } else if path == "/accounts" {
            object = ["accounts": accounts]
        } else if path == "/insights" {
            object = insights
        } else if path == "/budgets" {
            object = budgets
        } else if path.hasPrefix("/transactions") {
            let q = query(path)
            var rows = transactions
            if let from = q["from"] { rows = rows.filter { ($0["date"] as? String ?? "") >= from } }
            if let to = q["to"] { rows = rows.filter { ($0["date"] as? String ?? "") <= to } }
            if let acct = q["account_id"] { rows = rows.filter { ($0["account_id"] as? String) == acct } }
            object = ["transactions": rows, "total": rows.count]
        } else {
            throw APIError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private static let insights: [String: Any] = [
        "income": ["monthly": 6300, "source": "detected", "confidence": "high",
                   "sources": [["name": "Acme Corp Payroll", "monthly": 6300, "frequency": "biweekly"]]],
        "outflow": ["monthlyAverage": 3770, "fixed": 2310, "variable": 1460,
                    "byCategory": [["category": "Home", "monthlyAverage": 1850, "isFixed": true],
                                   ["category": "Groceries", "monthlyAverage": 820, "isFixed": false]]],
        "budget": ["total": 3560, "items": [["category": "Home", "amount": 1850], ["category": "Groceries", "amount": 760],
                                           ["category": "Dining", "amount": 220], ["category": "Transport", "amount": 280],
                                           ["category": "Bills & Utilities", "amount": 200], ["category": "Shopping", "amount": 250]]],
        "health": ["savingsRate": 0.40, "emergencyFundMonths": 6.2, "creditUtilization": 0.12, "debtPaymentRatio": 0.09],
        "investing": ["totalInvested": 103791,
                      "allocation": [["label": "Cash", "amount": 4820, "percent": 3.4], ["label": "Savings", "amount": 18500, "percent": 13.1],
                                     ["label": "Investments", "amount": 103791, "percent": 73.3], ["label": "Other assets", "amount": 14500, "percent": 10.2]],
                      "notes": [["id": "match", "title": "Retirement saving looks strong", "detail": "You're putting away well over the 15% of income many people aim for.", "tone": "good"],
                                ["id": "cash", "title": "A lot sits in savings", "detail": "Above six months of spending in cash can lag behind inflation. Some people move the extra into longer-term investments.", "tone": "info"]]],
        "dataQuality": ["monthsOfData": 4, "transactionCount": 214],
    ]

    private static let budgets: [String: Any] = [
        "month": String(dayString(Date()).prefix(7)),
        "budgets": [["id": "b1", "category": "Home", "monthlyAmount": 1850, "spent": 1850], ["id": "b2", "category": "Groceries", "monthlyAmount": 760, "spent": 610],
                    ["id": "b3", "category": "Dining", "monthlyAmount": 220, "spent": 187], ["id": "b4", "category": "Transport", "monthlyAmount": 280, "spent": 301],
                    ["id": "b5", "category": "Shopping", "monthlyAmount": 250, "spent": 96]],
    ]

    private static func query(_ path: String) -> [String: String] {
        guard let items = URLComponents(string: "https://demo.local" + path)?.queryItems else { return [:] }
        return Dictionary(items.compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    private static func acct(_ id: String, _ name: String, _ type: String, _ subtype: String?, _ bal: Double, _ inst: String) -> [String: Any] {
        var a: [String: Any] = [
            "id": id, "name": name, "type": type, "balance_current": String(format: "%.2f", bal),
            "currency": "USD", "is_hidden": false, "institution_name": inst,
        ]
        if let subtype { a["subtype"] = subtype }
        return a
    }

    private static let accounts: [[String: Any]] = [
        acct("demo-checking", "Everyday Checking", "depository", "checking", 4820.44, "Harbor Bank"),
        acct("demo-savings", "High-Yield Savings", "depository", "savings", 18500, "Harbor Bank"),
        acct("demo-brokerage", "Brokerage", "investment", nil, 42310.20, "Summit Invest"),
        acct("demo-401k", "401(k)", "investment", nil, 61480.75, "Summit Invest"),
        acct("demo-car", "Vehicle", "other", nil, 14500, "Estimated value"),
        acct("demo-card", "Rewards Card", "credit", nil, 1284.10, "Harbor Bank"),
        acct("demo-loan", "Auto Loan", "loan", "auto", 11200, "Lakeside Credit Union"),
    ]

    private static func history(days: Int) -> [[String: Any]] {
        let now = Date()
        return (0..<days).map { i in
            let date = Calendar.current.date(byAdding: .day, value: -i, to: now) ?? now
            let growth = 0.90 + 0.10 * (1 - Double(i) / 365)
            let nw = 129_127.29 * growth + sin(Double(i) * 0.09) * 380 + sin(Double(i) * 0.61) * 140
            let liabilities = 12_484.10 + Double(i) * 8
            return [
                "date": dayString(date),
                "net_worth": String(format: "%.2f", nw),
                "total_assets": String(format: "%.2f", nw + liabilities),
                "total_liabilities": String(format: "%.2f", liabilities),
            ]
        }
    }

    private struct Template {
        let name: String, category: String, low: Double, high: Double, every: Int, offset: Int, account: String
        var income = false
    }

    private static let templates: [Template] = [
        .init(name: "Whole Foods", category: "Groceries", low: 45, high: 120, every: 4, offset: 0, account: "demo-card"),
        .init(name: "Trader Joe's", category: "Groceries", low: 30, high: 80, every: 6, offset: 2, account: "demo-card"),
        .init(name: "Blue Bottle Coffee", category: "Dining", low: 5, high: 9, every: 2, offset: 1, account: "demo-card"),
        .init(name: "Chipotle", category: "Dining", low: 12, high: 18, every: 5, offset: 3, account: "demo-card"),
        .init(name: "Shell", category: "Transport", low: 35, high: 62, every: 9, offset: 4, account: "demo-checking"),
        .init(name: "Uber", category: "Transport", low: 12, high: 31, every: 7, offset: 5, account: "demo-card"),
        .init(name: "Amazon", category: "Shopping", low: 20, high: 150, every: 8, offset: 6, account: "demo-card"),
        .init(name: "AMC Theatres", category: "Entertainment", low: 14, high: 40, every: 13, offset: 7, account: "demo-card"),
        .init(name: "CVS Pharmacy", category: "Health", low: 10, high: 40, every: 17, offset: 8, account: "demo-checking"),
        .init(name: "Netflix", category: "Subscriptions", low: 15.49, high: 15.49, every: 30, offset: 3, account: "demo-card"),
        .init(name: "Spotify", category: "Subscriptions", low: 11.99, high: 11.99, every: 30, offset: 7, account: "demo-card"),
        .init(name: "Comcast", category: "Bills & Utilities", low: 79.99, high: 79.99, every: 30, offset: 12, account: "demo-checking"),
        .init(name: "City Utilities", category: "Bills & Utilities", low: 112.40, high: 112.40, every: 30, offset: 15, account: "demo-checking"),
        .init(name: "Rent", category: "Home", low: 1850, high: 1850, every: 30, offset: 1, account: "demo-checking"),
        .init(name: "Planet Fitness", category: "Health", low: 24.99, high: 24.99, every: 30, offset: 20, account: "demo-checking"),
        .init(name: "Acme Corp Payroll", category: "Income", low: 3150, high: 3150, every: 14, offset: 2, account: "demo-checking", income: true),
    ]

    private static let accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0["id"] as! String, $0["name"] as! String) })

    private static let transactions: [[String: Any]] = {
        let now = Date()
        var rows: [[String: Any]] = []
        for i in 0..<120 {
            let date = Calendar.current.date(byAdding: .day, value: -i, to: now) ?? now
            for (k, t) in templates.enumerated() where i % t.every == t.offset {
                let r = Double((i * 31 + k * 17) % 100) / 100
                let amount = t.low + (t.high - t.low) * r
                rows.append([
                    "id": "demo-\(i)-\(k)", "account_id": t.account, "account_name": accountNames[t.account] ?? "",
                    "amount": String(format: "%.2f", t.income ? -amount : amount), "date": dayString(date),
                    "name": t.name, "merchant_name": t.name, "category_name": t.category,
                    "is_pending": i == 0 && k % 2 == 0, "is_excluded": false,
                ])
            }
        }
        return rows
    }()
}
