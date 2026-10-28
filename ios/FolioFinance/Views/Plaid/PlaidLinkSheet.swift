import SwiftUI
import LinkKit

// Real Plaid Link (LinkKit 7). Flow: POST /plaid/link/token -> present PlaidLinkView ->
// review the accounts the user picked -> POST /plaid/exchange with the chosen account ids
// (the backend imports accounts + transactions before replying) -> show what was added.
// Reconnect mode signs back in to a bank that stopped syncing, then refreshes it.
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

    var group: AccountGroup { AccountGroup.from(type: type, subtype: subtype) }
    var balance: Double { Double(balanceCurrent ?? "") ?? 0 }
}

/// An account Plaid says the user picked, before anything is saved.
struct ReviewAccount: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mask: String?
    let group: AccountGroup
}

/// What Plaid handed back, held while the user chooses which accounts to add.
struct LinkReview: Equatable, Sendable {
    let publicToken: String
    let institutionId: String?
    let institutionName: String?
    let accounts: [ReviewAccount]
}

extension AccountGroup {
    static func from(type: String, subtype: String?) -> AccountGroup {
        switch type.lowercased() {
        case "credit": return .credit
        case "loan": return .loans
        case "investment", "brokerage": return .investments
        case "depository":
            let s = (subtype ?? "").lowercased()
            return (s.contains("sav") || s == "cd" || s.contains("money market")) ? .savings : .cash
        default: return .other
        }
    }

    fileprivate static func from(_ subtype: AccountSubtype) -> AccountGroup {
        switch subtype {
        case .credit: return .credit
        case .loan: return .loans
        case .investment: return .investments
        case .depository(let d): return from(type: "depository", subtype: d.description)
        case .unknown(let type, let sub): return from(type: type, subtype: sub)
        case .other: return .other
        @unknown default: return .other
        }
    }
}

private struct PlaidExchangeResult: Decodable, Sendable {
    let id: String
    let institutionName: String?
    let synced: Bool?
    let accounts: [ImportedAccount]?
}

/// A bank the customer signed in to but hasn't finished adding. Kept for a short while so a closed sheet, an app switch
/// or a dropped connection never costs them the login. Plaid's one-time token is good for 30 minutes.
struct PendingLink: Codable {
    let publicToken: String
    let institutionId: String?
    let institutionName: String?
    let accounts: [PendingAccount]
    let savedAt: Date

    struct PendingAccount: Codable { let id: String; let name: String; let mask: String? ; let group: String }

    private static let key = "pendingPlaidLink"
    private static let lifetime: TimeInterval = 25 * 60

    static func save(_ r: LinkReview) {
        let p = PendingLink(publicToken: r.publicToken, institutionId: r.institutionId, institutionName: r.institutionName,
                            accounts: r.accounts.map { .init(id: $0.id, name: $0.name, mask: $0.mask, group: $0.group.rawValue) }, savedAt: Date())
        if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    static func load() -> PendingLink? {
        guard let data = UserDefaults.standard.data(forKey: key), let p = try? JSONDecoder().decode(PendingLink.self, from: data) else { return nil }
        if Date().timeIntervalSince(p.savedAt) > lifetime { clear(); return nil }
        return p
    }

    var review: LinkReview {
        LinkReview(publicToken: publicToken, institutionId: institutionId, institutionName: institutionName,
                   accounts: accounts.map { ReviewAccount(id: $0.id, name: $0.name, mask: $0.mask, group: AccountGroup(rawValue: $0.group) ?? .other) })
    }
}

@MainActor
final class PlaidLinker: ObservableObject {
    enum Phase: Equatable {
        case idle
        case demo
        case preparing
        case readyToPresent(token: String)
        case review(LinkReview)
        case saving(institution: String?)
        case done(institution: String?, accounts: [ImportedAccount], synced: Bool)
        case reconnected(institution: String?)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    func prepare(auth: AuthManager, reconnectItemId: String?) async {
        if auth.isDemo { phase = .demo; return }
        // A bank signed in to earlier but never finished: pick up right where it stopped.
        if reconnectItemId == nil, let pending = PendingLink.load() { phase = .review(pending.review); return }
        phase = .preparing
        do {
            let endpoint: Endpoint = reconnectItemId.map { .reconnectLinkToken(itemId: $0) } ?? .linkToken
            let r: LinkTokenResponse = try await auth.withFreshToken(endpoint)
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

    func review(_ r: LinkReview) { PendingLink.save(r); phase = .review(r) }

    /// Drop the saved login and start a fresh connection (for "use a different bank").
    func discardPending(auth: AuthManager) async {
        PendingLink.clear()
        await prepare(auth: auth, reconnectItemId: nil)
    }

    func add(_ r: LinkReview, accountIds: [String], auth: AuthManager) async {
        phase = .saving(institution: r.institutionName)
        do {
            let result: PlaidExchangeResult = try await auth.withFreshToken(.exchangeToken(
                publicToken: r.publicToken, institutionId: r.institutionId, institutionName: r.institutionName,
                accountIds: accountIds.isEmpty ? nil : accountIds
            ))
            PendingLink.clear()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            phase = .done(institution: result.institutionName ?? r.institutionName, accounts: result.accounts ?? [], synced: result.synced ?? true)
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    func finishReconnect(itemId: String, institution: String?, auth: AuthManager) async {
        phase = .saving(institution: institution)
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.refreshPlaidItem(id: itemId))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            phase = .reconnected(institution: institution)
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    func fail(_ message: String) { phase = .failed(message) }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Launches Plaid Link, lets the user review accounts before they're added, and shows the result.
struct PlaidLinkSheet: View {
    /// Set to sign back in to a bank that needs attention instead of adding a new one.
    var reconnectItemId: String? = nil
    var reconnectName: String? = nil
    var onLinked: (String?) -> Void = { _ in }
    var onExit: (String?) -> Void = { _ in }

    @SwiftUI.Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager
    @StateObject private var linker = PlaidLinker()
    @State private var session: LinkSession?
    @State private var selected: Set<String> = []

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
                    .animation(Motion.spring, value: linker.phase)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    switch linker.phase {
                    case .done, .reconnected, .saving: EmptyView()
                    default: Button("Cancel") { onExit(nil); dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .task { await linker.prepare(auth: auth, reconnectItemId: reconnectItemId) }
        .onChange(of: linker.phase) { _, new in
            switch new {
            case .readyToPresent(let t): session = LinkSession(token: t)
            case .review(let r): selected = Set(r.accounts.map(\.id))
            case .done(let name, _, _), .reconnected(let name): onLinked(name)
            default: break
            }
        }
        .fullScreenCover(item: $session) { current in
            PlaidLinkView(token: current.token) { success in
                let institution = success.metadata.institution
                session = nil
                if let itemId = reconnectItemId {
                    Task { await linker.finishReconnect(itemId: itemId, institution: institution.name, auth: auth) }
                } else {
                    linker.review(LinkReview(
                        publicToken: success.publicToken,
                        institutionId: institution.id,
                        institutionName: institution.name,
                        accounts: success.metadata.accounts.map {
                            ReviewAccount(id: $0.id, name: $0.name, mask: $0.mask, group: .from($0.subtype))
                        }
                    ))
                }
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
        case .preparing, .saving, .review: true
        default: false
        }
    }

    @ViewBuilder private var content: some View {
        switch linker.phase {
        case .idle, .preparing, .readyToPresent:
            progress(reconnectItemId == nil ? "Getting a secure connection…" : "Reconnecting \(reconnectName ?? "your bank")…", detail: nil)
        case .review(let r):
            reviewView(r)
        case .saving(let name):
            progress("Connecting \(name ?? "your bank")…", detail: "Importing your accounts and recent activity. This can take up to a minute.")
        case .done(let name, let imported, let synced):
            doneView(name: name, accounts: imported, synced: synced)
        case .reconnected(let name):
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Color.up)
                Text("\(name ?? "Your bank") is syncing again").font(.title2.bold()).multilineTextAlignment(.center)
                Text("Your latest balances and activity are in.").font(.subheadline).foregroundStyle(.secondary)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
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
                Button("Try again") { Task { await linker.prepare(auth: auth, reconnectItemId: reconnectItemId) } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }

    // MARK: Review (before anything is saved)

    private func reviewView(_ r: LinkReview) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Add these accounts?").font(.title2.bold())
                Text("From \(r.institutionName ?? "your bank"). Untick any you don't want in Folio.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if r.accounts.isEmpty {
                Text("Plaid didn't list the accounts. Folio will add every account you shared and you can hide any later.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                ScrollView {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(r.accounts.enumerated()), id: \.element.id) { i, a in
                                let on = selected.contains(a.id)
                                Button {
                                    if on { selected.remove(a.id) } else { selected.insert(a.id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        IconBadge(symbol: a.group.symbol, color: a.group.color, size: 36)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(a.name).font(.body).foregroundStyle(.primary).lineLimit(1)
                                            Text([a.group.rawValue, a.mask.map { "•••• \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                            .font(.title3).foregroundStyle(on ? Color.accentColor : Color.secondary)
                                            .contentTransition(.symbolEffect(.replace))
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 11)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PressableRowStyle())
                                .sensoryFeedback(.selection, trigger: on)
                                .entrance(i)
                                if i < r.accounts.count - 1 { Divider().padding(.leading, 64) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .scrollIndicators(.hidden)
            }
            let count = r.accounts.isEmpty ? 0 : selected.count
            Button {
                Task { await linker.add(r, accountIds: r.accounts.isEmpty ? [] : Array(selected), auth: auth) }
            } label: {
                Text(r.accounts.isEmpty ? "Add accounts" : "Add \(count) account\(count == 1 ? "" : "s")")
                    .font(.headline).frame(maxWidth: .infinity).frame(height: 30)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!r.accounts.isEmpty && selected.isEmpty)
            Button("Start over with a different bank") { Task { await linker.discardPending(auth: auth) } }
                .font(.footnote)
        }
    }

    // MARK: Done

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

// MARK: - Background sync

struct BankSyncResult: Decodable, Sendable {
    let synced: Int
    let needsAttention: Int
}

/// Asks the server to pull new balances and transactions from connected banks.
/// The server skips banks synced in the last few minutes, and this also throttles on the device.
@MainActor
enum BankSync {
    private static var last: Date?

    @discardableResult
    static func run(_ auth: AuthManager, force: Bool = false) async -> BankSyncResult? {
        guard !auth.isDemo else { return nil }
        if !force, let last, Date().timeIntervalSince(last) < 120 { return nil }
        last = Date()
        return try? await auth.withFreshToken(.syncBanks(force: force))
    }
}
