import SwiftUI
import LinkKit

// Real Plaid Link (LinkKit 7). Flow: POST /plaid/link/token -> present PlaidLinkView ->
// POST /plaid/exchange with the public token (the backend imports accounts + transactions
// before replying) -> onLinked(institutionName).
//
// Note: LinkKit also exports types named `Account`, `Environment`, `Institution`, and its own
// `PlaidLinkSheet`. This file avoids the first two; the app's PlaidLinkSheet below shadows LinkKit's.

/// One account the server imported from the bank, shown back to the user after linking.
struct ImportedAccount: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let type: String
    let subtype: String?
    let mask: String?
    let balanceCurrent: String?

    var group: AccountGroup {
        switch type {
        case "credit": return .credit
        case "loan": return .loans
        case "investment": return .investments
        case "depository":
            let s = (subtype ?? "").lowercased()
            return (s.contains("sav") || s == "cd" || s.contains("money market")) ? .savings : .cash
        default: return .other
        }
    }

    var balance: Double { Double(balanceCurrent ?? "") ?? 0 }
}

private struct PlaidExchangeResult: Decodable, Sendable {
    let id: String
    let institutionName: String?
    let synced: Bool?
    let accounts: [ImportedAccount]?
}

@MainActor
final class PlaidLinker: ObservableObject {
    enum Phase: Equatable {
        case idle
        case demo
        case preparing
        case readyToPresent(token: String)
        case saving(institution: String?)
        case done(institution: String?, accounts: [ImportedAccount], synced: Bool)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    func prepare(auth: AuthManager) async {
        if auth.isDemo { phase = .demo; return }
        phase = .preparing
        do {
            let r: LinkTokenResponse = try await auth.withFreshToken(.linkToken)
            let token = r.linkToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.hasPrefix("link-") else {
                phase = .failed("The server didn't return a valid Plaid link token (got \(token.isEmpty ? "nothing" : "an unexpected value")). Check the Plaid keys on the server.")
                return
            }
            phase = .readyToPresent(token: token)
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    func complete(publicToken: String, institutionId: String?, institutionName: String?, auth: AuthManager) async {
        phase = .saving(institution: institutionName)
        do {
            let r: PlaidExchangeResult = try await auth.withFreshToken(
                .exchangeToken(publicToken: publicToken, institutionId: institutionId, institutionName: institutionName)
            )
            phase = .done(institution: r.institutionName ?? institutionName, accounts: r.accounts ?? [], synced: r.synced ?? true)
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    func fail(_ message: String) { phase = .failed(message) }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Launches Plaid Link immediately and shows progress, success, and errors.
struct PlaidLinkSheet: View {
    var onLinked: (String?) -> Void = { _ in }
    var onExit: (String?) -> Void = { _ in }

    @SwiftUI.Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager
    @StateObject private var linker = PlaidLinker()
    @State private var session: LinkSession?

    private struct LinkSession: Identifiable {
        let id = UUID()
        let token: String
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .balance)
                content
                    .padding(24)
                    .animation(.smooth, value: linker.phase)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .done = linker.phase {} else { Button("Cancel") { onExit(nil); dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .task { await linker.prepare(auth: auth) }
        .onChange(of: linker.phase) { _, new in
            if case .readyToPresent(let t) = new { session = LinkSession(token: t) }
            if case .done(let name, _, _) = new { onLinked(name) }
        }
        .fullScreenCover(item: $session) { current in
            PlaidLinkView(token: current.token) { success in
                let id = success.metadata.institution.id
                let name = success.metadata.institution.name
                let publicToken = success.publicToken
                session = nil
                Task { await linker.complete(publicToken: publicToken, institutionId: id, institutionName: name, auth: auth) }
            } onExit: { exit in
                session = nil
                if let error = exit.error {
                    linker.fail(error.displayMessage ?? error.errorMessage)
                } else {
                    onExit(nil)
                    dismiss()
                }
            } errorView: { error in
                VStack(spacing: 14) {
                    Text("Couldn't open your bank connection").font(.headline)
                    Text(error.localizedDescription).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Close") { session = nil; linker.fail(error.localizedDescription) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)
            }
        }
    }

    private var isBusy: Bool {
        switch linker.phase {
        case .preparing, .saving: true
        default: false
        }
    }

    @ViewBuilder private var content: some View {
        switch linker.phase {
        case .idle, .preparing, .readyToPresent:
            progress("Getting a secure connection…", detail: nil)
        case .saving(let name):
            progress("Connecting \(name ?? "your bank")…", detail: "Importing your accounts and recent activity. This can take up to a minute.")
        case .done(let name, let imported, let synced):
            doneView(name: name, accounts: imported, synced: synced)
        case .demo:
            VStack(spacing: 16) {
                BrandMark(size: 72)
                Text("Banks can't be connected in the demo").font(.title3.bold()).multilineTextAlignment(.center)
                Text("Create a free account to link your real banks, cards and investments.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Got it") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.orange)
                Text("That didn't work").font(.title3.bold())
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { Task { await linker.prepare(auth: auth) } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }

    /// What was added, listed account by account.
    private func doneView(name: String?, accounts: [ImportedAccount], synced: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Color.up)
                .symbolEffect(.bounce, value: accounts.count)
            Text("\(name ?? "Your bank") is connected").font(.title2.bold()).multilineTextAlignment(.center)
            if accounts.isEmpty {
                Text(synced
                     ? "No accounts came through from this bank. Try connecting again and make sure to select the accounts to share."
                     : "Your accounts are still importing. Pull down to refresh in a moment.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("Added \(accounts.count) account\(accounts.count == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(.secondary)
                ScrollView {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(accounts.enumerated()), id: \.element.id) { i, a in
                                HStack(spacing: 12) {
                                    IconBadge(symbol: a.group.symbol, color: a.group.color, size: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(a.name).font(.body).lineLimit(1)
                                        Text([a.group.rawValue, a.mask.map { "•••• \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text((a.group.isLiability ? "−" : "") + money(abs(a.balance), cents: true))
                                        .font(.body.weight(.semibold)).monospacedDigit().sensitive()
                                }
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .entrance(i)
                                if i < accounts.count - 1 { Divider().padding(.leading, 64) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
                .scrollIndicators(.hidden)
            }
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private func progress(_ title: String, detail: String?) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(title).font(.headline).multilineTextAlignment(.center)
            if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
    }
}

/// A button that opens the Plaid connection flow in a sheet.
struct PlaidConnectButton<Label: View>: View {
    var onLinked: (String?) -> Void = { _ in }
    @ViewBuilder var label: () -> Label
    @State private var show = false

    var body: some View {
        Button { show = true } label: { label() }
            .sheet(isPresented: $show) { PlaidLinkSheet(onLinked: onLinked) }
    }
}
