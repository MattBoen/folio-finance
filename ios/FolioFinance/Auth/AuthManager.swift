import Foundation

@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

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
        isAuthenticated = accessToken != nil
    }

    func login(email: String, password: String) async {
        await perform {
            let response: AuthResponse = try await self.api.request(
                .login(email: email, password: password)
            )
            self.store(response)
        }
    }

    func register(email: String, password: String) async {
        await perform {
            let response: AuthResponse = try await self.api.request(
                .register(email: email, password: password)
            )
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
        isAuthenticated = false
        error = nil
    }

    func clearError() { error = nil }

    /// Makes an authenticated API request. On 401, refreshes the access token once and retries.
    func withFreshToken<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
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
