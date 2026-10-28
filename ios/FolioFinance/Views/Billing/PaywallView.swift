import SwiftUI

/// The subscribe screen. Used full-screen when billing locks the app, and as a step at the end of setup.
struct PaywallContent: View {
    var onSignOut: (() -> Void)? = nil
    var onSkip: (() -> Void)? = nil
    var skipTitle = "Not now"

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var billing: BillingManager
    @Environment(\.openURL) private var openURL
    @State private var interval = "year"
    @State private var working = false
    @State private var error: String?
    @State private var opened = false

    private var s: BillingStatus? { billing.status }
    private var trial: Int { s?.trialDays ?? 7 }
    private var monthly: Double { s?.monthlyPrice ?? 10.49 }
    private var yearly: Double { s?.yearlyPrice ?? 74.99 }
    private var savePercent: Int { Int((1 - yearly / (monthly * 12)) * 100) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(trial > 0 ? "Start your free \(trial == 7 ? "week" : "\(trial) days")" : "Subscribe to Folio")
                            .font(.system(size: 30, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                        Text(trial > 0 ? "Try everything free. Cancel any time before it ends and you won't be charged." : "Everything in Folio, for one simple price.")
                            .font(.body).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        perk("link", .blue, "Every account in one place", "Banks, cards, investments, loans and your car.")
                        perk("chart.line.uptrend.xyaxis", .green, "Net worth and spending that update themselves", "No spreadsheets, no manual entry.")
                        perk("sparkles", .indigo, "Ask Folio", "Ask about your money, build a budget, and make changes in plain words.")
                    }

                    VStack(spacing: 10) {
                        plan("year", title: "Yearly", price: "$\(String(format: "%.2f", yearly)) a year", detail: "About \(money(yearly / 12, cents: true)) a month", badge: "Save \(savePercent)%")
                        plan("month", title: "Monthly", price: "$\(String(format: "%.2f", monthly)) a month", detail: "Switch or cancel any time", badge: nil)
                    }

                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
            }

            VStack(spacing: 10) {
                if s?.configured == false {
                    Text("Subscriptions open soon.").font(.subheadline).foregroundStyle(.secondary)
                }
                Button { Task { await subscribe() } } label: {
                    Group {
                        if working { ProgressView().tint(.white) }
                        else { Text(trial > 0 ? "Start free \(trial == 7 ? "week" : "trial")" : "Subscribe").font(.headline) }
                    }
                    .frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(working || s?.configured == false)

                if opened {
                    Button("I've subscribed, check again") { Task { await billing.refresh(auth) } }.font(.subheadline.weight(.semibold))
                }
                Text("Secure checkout by Stripe opens in your browser.\(trial > 0 ? " Then \(interval == "year" ? "$\(String(format: "%.2f", yearly)) a year" : "$\(String(format: "%.2f", monthly)) a month") after the trial." : "")")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 14) {
                    Link("Privacy Policy", destination: AppLinks.privacy)
                    Link("Terms", destination: AppLinks.terms)
                    if let onSkip { Button(skipTitle, action: onSkip) }
                    if let onSignOut { Button("Sign out", action: onSignOut) }
                }
                .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 24).padding(.bottom, 14).padding(.top, 8)
        }
    }

    private func perk(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(symbol: symbol, color: color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func plan(_ id: String, title: String, price: String, detail: String, badge: String?) -> some View {
        let selected = interval == id
        return Button {
            withAnimation(Motion.spring) { interval = id }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title).font(.headline)
                        if let badge {
                            Text(badge).font(.caption.weight(.bold)).foregroundStyle(Color.up)
                                .padding(.horizontal, 7).padding(.vertical, 2).background(Color.up.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(price).font(.subheadline.weight(.semibold)).multilineTextAlignment(.trailing)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: interval)
    }

    private func subscribe() async {
        working = true; error = nil
        do {
            let url = try await billing.checkoutURL(interval: interval, auth: auth)
            opened = true
            openURL(url)
        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        working = false
    }
}

/// Shown over the whole app when billing is on and the customer hasn't subscribed.
struct PaywallGate: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        ZStack {
            Wash(tone: .balance)
            PaywallContent(onSignOut: { auth.logout() })
        }
    }
}
