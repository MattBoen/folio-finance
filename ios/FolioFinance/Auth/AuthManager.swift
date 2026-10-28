import Foundation

@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var isDemo = false
    /// Set when the email has no account yet; the sign-in screen asks before creating one.
    @Published var pendingNewAccount: String?

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

    /// One button for both: signs in when the email has an account, otherwise offers to create one.
    func continueWithEmail(email: String, password: String) async {
        let email = Self.normalized(email)
        await perform {
            struct Check: Decodable { let exists: Bool }
            let known: Bool? = (try? await self.api.request(.checkEmail(email)) as Check)?.exists

            if known == true {
                try await self.signIn(email: email, password: password)
                return
            }
            if known == false {
                guard password.count >= 8 else {
                    throw APIError.server(400, "New to Folio? Choose a password with at least 8 characters to create your account.")
                }
                self.pendingNewAccount = email
                return
            }
            // Older server without the check route: try signing in, then offer to create.
            do {
                try await self.signIn(email: email, password: password)
            } catch APIError.unauthorized {
                guard password.count >= 8 else { throw APIError.server(401, "That email and password don't match.") }
                self.pendingNewAccount = email
            }
        }
    }

    func createAccountAfterConfirm(email: String, password: String) async {
        pendingNewAccount = nil
        await register(email: email, password: password)
    }

    private func signIn(email: String, password: String) async throws {
        do {
            let response: AuthResponse = try await api.request(.login(email: email, password: password))
            UserDefaults.standard.set(email, forKey: "currentEmail")
            store(response)
        } catch APIError.unauthorized {
            throw APIError.server(401, "That email and password don't match.")
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
            Self.forgetSetupSeen(email)
            self.store(response)
        }
    }

    func refresh() async throws {
        guard let raw = refreshToken else { throw APIError.unauthorized }
        let response: AuthResponse = try await api.request(.refresh(token: raw))
        store(response)
    }

    func logout() {
        WidgetSnapshot.clear()
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
            if let email = UserDefaults.standard.string(forKey: "currentEmail") { Self.forgetSetupSeen(email) }
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

    /// A new account starts setup even if the same email used this phone before.
    static func forgetSetupSeen(_ email: String) {
        let seen = (UserDefaults.standard.stringArray(forKey: "setupSeenEmails") ?? []).filter { $0 != email }
        UserDefaults.standard.set(seen, forKey: "setupSeenEmails")
    }

    func markSetupSeen() {
        let email = UserDefaults.standard.string(forKey: "currentEmail") ?? ""
        var seen = UserDefaults.standard.stringArray(forKey: "setupSeenEmails") ?? []
        if !seen.contains(email) { seen.append(email) }
        UserDefaults.standard.set(seen, forKey: "setupSeenEmails")
    }

    var currentEmail: String? {
        if isDemo { return nil }
        return UserDefaults.standard.string(forKey: "currentEmail")
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
            let v: [String: Any] = ["vin": "1FMEE5DH2PLA12345", "year": 2023, "make": "Ford", "model": "Bronco",
                                    "trims": ["Base", "Big Bend", "Black Diamond", "Outer Banks", "Badlands", "Wildtrak", "Everglades"],
                                    "details": "4-door SUV · 2.3L 4-cyl · AWD", "miles": 41200, "annualMiles": 10800, "ageYears": 3.8,
                                    "estimatedValue": 38200, "lowValue": 34400, "highValue": 42000, "source": "estimate"]
            let data = try JSONSerialization.data(withJSONObject: v)
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        }
        if endpoint.path == "/vehicles/estimate" {
            let v: [String: Any] = ["estimatedValue": 40100, "lowValue": 36100, "highValue": 44100, "source": "estimate", "annualMiles": 10800, "ageYears": 3.8]
            let data = try JSONSerialization.data(withJSONObject: v)
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        }
        if endpoint.path.hasPrefix("/vehicles/"), endpoint.method == "GET", !endpoint.path.contains("trims") {
            return try decodeDemo(["year": 2023, "make": "Ford", "model": "Bronco", "trim": "Big Bend", "miles": 41200, "annualMiles": 10800, "averageAnnualMiles": 10800, "currentMiles": 41200, "valueIsManual": false] as [String: Any])
        }
        if endpoint.path == "/ask" {
            return try decodeDemo(askResponse(for: endpoint))
        }
        if endpoint.path == "/ask/confirm" {
            throw APIError.server(403, "Changes aren't saved in demo mode.")
        }
        if endpoint.path == "/ask/dismiss" {
            return try decodeDemo([String: Any]())
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
                   "sources": [["name": "Acme Corp Payroll", "monthly": 6300, "frequency": "biweekly"]],
                   "deposits": (0..<6).map { i in ["date": dayString(Date().addingTimeInterval(-Double(3 + i * 14) * 86_400)),
                                                   "name": "Acme Corp Payroll", "amount": 3150, "source": "Acme Corp Payroll"] }],
        "outflow": ["monthlyAverage": 3770, "fixed": 2310, "variable": 1460,
                    "window": ["from": dayString(Date().addingTimeInterval(-90 * 86_400)), "to": dayString(Date()), "days": 90, "months": 2.96],
                    "byCategory": [["category": "Home", "monthlyAverage": 1850, "isFixed": true],
                                   ["category": "Groceries", "monthlyAverage": 820, "isFixed": false]]],
        "budget": ["total": 3560, "items": [["category": "Home", "amount": 1850], ["category": "Groceries", "amount": 760],
                                           ["category": "Dining", "amount": 220], ["category": "Transport", "amount": 280],
                                           ["category": "Bills & Utilities", "amount": 200], ["category": "Shopping", "amount": 250]]],
        "health": ["savingsRate": 0.40, "emergencyFundMonths": 6.2, "creditUtilization": 0.12, "debtPaymentRatio": 0.09,
                   "inputs": ["cashAccounts": [["name": "Everyday Checking", "balance": 4820.44, "kind": "cash"],
                                               ["name": "High-Yield Savings", "balance": 18500, "kind": "savings"]],
                              "liquid": 23320.44,
                              "cards": [["name": "Rewards Card", "balance": 1284.10, "limit": 10700]],
                              "debtPayments": [["date": dayString(Date().addingTimeInterval(-12 * 86_400)), "name": "Auto Finance Payment", "amount": 565],
                                               ["date": dayString(Date().addingTimeInterval(-42 * 86_400)), "name": "Auto Finance Payment", "amount": 565]],
                              "debtMonthly": 565]],
        "investing": ["totalInvested": 103791,
                      "allocation": [["label": "Cash", "amount": 4820, "percent": 3.4], ["label": "Savings", "amount": 18500, "percent": 13.1],
                                     ["label": "Investments", "amount": 103791, "percent": 73.3], ["label": "Physical assets", "amount": 14500, "percent": 10.2]],
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

    private static func decodeDemo<T: Decodable>(_ object: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    /// Canned answers for the suggested questions, so Ask can be tried without a server.
    private static func askResponse(for endpoint: Endpoint) -> [String: Any] {
        var last = ""
        if let body = endpoint.body,
           let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let msgs = obj["messages"] as? [[String: Any]],
           let text = msgs.last?["content"] as? String { last = text.lowercased() }

        if last.contains("raise") || last.contains("increase") {
            return [
                "answer": "Groceries is $760 a month and you're at $610, so there's room, but you've been close to the limit in two of the last four months. Raising it to $850 would cover your usual pace with a little to spare.",
                "facts": [["label": "Groceries budget", "value": "$760"], ["label": "Spent this month", "value": "$610"], ["label": "Average, last 3 months", "value": "$812"]],
                "proposal": ["id": "demo-proposal", "kind": "budget", "title": "Raise your groceries budget",
                             "detail": "Based on what you've spent over the last three months.",
                             "category": "Groceries", "current_amount": 760, "new_amount": 850],
            ]
        }
        if last.contains("s&p") || last.contains("s & p") || last.contains("benchmark") {
            return [
                "answer": "A rough comparison: your investment accounts grew about 9.8% so far this year, and the S&P 500 is up about 12.4% over the same stretch. Part of your growth comes from contributions, so this isn't a precise performance number.",
                "facts": [["label": "Your investments, year to date", "value": "+9.8%"], ["label": "S&P 500, year to date", "value": "+12.4%"]],
            ]
        }
        if last.contains("saving") || last.contains("invest") {
            return [
                "answer": "You're keeping about 40% of your income this month, well above the 15% many people aim for. Most of the rest sits in investments and savings.",
                "facts": [["label": "Income this month", "value": "$6,300"], ["label": "Spent this month", "value": "$3,770"], ["label": "Savings rate", "value": "40%"]],
            ]
        }
        if last.contains("dining") || last.contains("restaurant") || last.contains("coffee") {
            return [
                "answer": "You've spent $187 on dining this month, about 85% of your $220 dining budget, with 4 days left.",
                "facts": [["label": "Dining this month", "value": "$187"], ["label": "Dining budget", "value": "$220"], ["label": "Left", "value": "$33"]],
            ]
        }
        if last.contains("budget") {
            return [
                "answer": "Your October budget is $3,560. You've spent $2,948 so far, which leaves $612 for the rest of the month. Transport is the only category over its limit.",
                "facts": [["label": "Budget", "value": "$3,560"], ["label": "Spent", "value": "$2,948"], ["label": "Left", "value": "$612"], ["label": "Over limit", "value": "Transport (+$21)"]],
            ]
        }
        return [
            "answer": "This is sample data, so I can answer a handful of questions here. Try one of the suggestions, or create an account to ask about your own numbers.",
            "facts": [],
        ]
    }

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
        acct("demo-car", "Vehicle", "other", "vehicle", 14500, "Estimated value"),
        acct("demo-card", "Rewards Card", "credit", nil, 1284.10, "Harbor Bank"),
        acct("demo-loan", "Auto Loan", "loan", "auto", 11200, "Lakeside Credit Union"),
    ]

    private static func history(days: Int) -> [[String: Any]] {
        let now = Date()
        return (0..<days).map { i in
            let date = Calendar.current.date(byAdding: .day, value: -i, to: now) ?? now
            let growth = max(0.5, 0.90 + 0.10 * (1 - Double(i) / 365))
            let invested = 103_791.0 * max(0.4, 0.55 + 0.45 * (1 - Double(i) / 1095)) + sin(Double(i) * 0.13) * 900
            let nw = 129_127.29 * growth + sin(Double(i) * 0.09) * 380 + sin(Double(i) * 0.61) * 140
            let liabilities = 12_484.10 + Double(i) * 8
            return [
                "date": dayString(date),
                "net_worth": String(format: "%.2f", nw),
                "total_assets": String(format: "%.2f", nw + liabilities),
                "total_liabilities": String(format: "%.2f", liabilities),
                "invested": String(format: "%.2f", invested),
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

    /// Made-up storefront locations for the sample data (online merchants have none).
    private static let places: [String: (Double, Double)] = [
        "Whole Foods": (37.7712, -122.4114), "Trader Joe's": (37.7842, -122.4392), "Blue Bottle Coffee": (37.7762, -122.4231),
        "Chipotle": (37.7899, -122.4034), "Shell": (37.7655, -122.4180), "AMC Theatres": (37.7849, -122.4066),
        "CVS Pharmacy": (37.7721, -122.4318), "Planet Fitness": (37.7788, -122.4195),
    ]

    private static let transactions: [[String: Any]] = {
        let now = Date()
        var rows: [[String: Any]] = []
        for i in 0..<380 {
            let date = Calendar.current.date(byAdding: .day, value: -i, to: now) ?? now
            for (k, t) in templates.enumerated() where i % t.every == t.offset {
                let r = Double((i * 31 + k * 17) % 100) / 100
                let amount = t.low + (t.high - t.low) * r
                var row: [String: Any] = [
                    "id": "demo-\(i)-\(k)", "account_id": t.account, "account_name": accountNames[t.account] ?? "",
                    "amount": String(format: "%.2f", t.income ? -amount : amount), "date": dayString(date),
                    "name": t.name, "merchant_name": t.name, "category_name": t.category,
                    "is_pending": i == 0 && k % 2 == 0, "is_excluded": false,
                ]
                // Like the server, send coordinates as numeric strings.
                if let p = places[t.name] { row["lat"] = String(p.0); row["lon"] = String(p.1) }
                rows.append(row)
            }
        }
        return rows
    }()
}
