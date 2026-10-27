import SwiftUI
import LinkKit

// Real Plaid Link (LinkKit 7). Flow: POST /plaid/link/token -> present PlaidLinkView ->
// POST /plaid/exchange with the public token (the backend imports accounts + transactions
// before replying) -> onLinked(institutionName).
//
// Note: LinkKit also exports types named `Account`, `Environment`, `Institution`, and its own
// `PlaidLinkSheet`. This file avoids the first two; the app's PlaidLinkSheet below shadows LinkKit's.

private struct PlaidExchangeResult: Decodable, Sendable {
    let id: String
    let institutionName: String?
}

@MainActor
final class PlaidLinker: ObservableObject {
    enum Phase: Equatable {
        case idle
        case demo
        case preparing
        case readyToPresent(token: String)
        case saving(institution: String?)
        case done(institution: String?)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    func prepare(auth: AuthManager) async {
        if auth.isDemo { phase = .demo; return }
        phase = .preparing
        do {
            let r: LinkTokenResponse = try await auth.withFreshToken(.linkToken)
            phase = .readyToPresent(token: r.linkToken)
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
            phase = .done(institution: r.institutionName ?? institutionName)
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
    @State private var presenting = false
    @State private var token = ""

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
            if case .readyToPresent(let t) = new { token = t; presenting = true }
            if case .done(let name) = new { onLinked(name) }
        }
        .fullScreenCover(isPresented: $presenting) {
            PlaidLinkView(token: token) { success in
                let id = success.metadata.institution.id
                let name = success.metadata.institution.name
                let publicToken = success.publicToken
                presenting = false
                Task { await linker.complete(publicToken: publicToken, institutionId: id, institutionName: name, auth: auth) }
            } onExit: { exit in
                presenting = false
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
                    Button("Close") { presenting = false; linker.fail(error.localizedDescription) }
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
        case .done(let name):
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Color.up)
                Text("\(name ?? "Your bank") is connected").font(.title2.bold()).multilineTextAlignment(.center)
                Text("Your balances and activity are on their way in.").font(.subheadline).foregroundStyle(.secondary)
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
                Button("Try again") { Task { await linker.prepare(auth: auth) } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
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
