import SwiftUI

struct BillingStatus: Decodable, Sendable {
    let enforced: Bool
    let configured: Bool
    let entitled: Bool
    let status: String
    let interval: String?
    let currentPeriodEnd: Date?
    let trialEnd: Date?
    let cancelAtPeriodEnd: Bool
    let trialDays: Int
    let monthlyPrice: Double
    let yearlyPrice: Double
}

private struct CheckoutURL: Decodable, Sendable { let url: String }

extension Endpoint {
    static var billingStatus: Endpoint { .get("/billing/status") }

    static func billingCheckout(interval: String) -> Endpoint {
        struct Body: Encodable { let interval: String }
        return .post("/billing/checkout", body: Body(interval: interval))
    }

    static var billingPortal: Endpoint { .post("/billing/portal", body: EmptyBody()) }
}

/// Where the customer stands with their subscription. Payment itself happens on the web (Stripe), so the app only asks the server.
@MainActor
final class BillingManager: ObservableObject {
    @Published private(set) var status: BillingStatus?

    /// True when billing is switched on and this customer hasn't subscribed.
    var locked: Bool { status.map { $0.enforced && !$0.entitled } ?? false }

    func refresh(_ auth: AuthManager) async {
        guard auth.isAuthenticated, !auth.isDemo else { status = nil; return }
        if let s: BillingStatus = try? await auth.withFreshToken(.billingStatus) { withAnimation(Motion.spring) { status = s } }
    }

    /// The Stripe checkout page for a plan. Opens in the browser.
    func checkoutURL(interval: String, auth: AuthManager) async throws -> URL {
        let r: CheckoutURL = try await auth.withFreshToken(.billingCheckout(interval: interval))
        guard let url = URL(string: r.url) else { throw APIError.invalidResponse }
        return url
    }

    /// Stripe's page for changing card, switching plan or cancelling.
    func portalURL(auth: AuthManager) async throws -> URL {
        let r: CheckoutURL = try await auth.withFreshToken(.billingPortal)
        guard let url = URL(string: r.url) else { throw APIError.invalidResponse }
        return url
    }
}
