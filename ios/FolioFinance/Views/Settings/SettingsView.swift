import SwiftUI

/// Account info and every preference in one place, opened from the profile menu.
struct SettingsView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var router: TabRouter
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hideAmounts") private var hide = false
    @ObservedObject private var ask = AskState.shared

    @State private var accountCount = 0
    @State private var banks: [PlaidItem] = []
    @State private var confirmSignOut = false
    @State private var showSetup = false
    @State private var showDelete = false
    @State private var deletePassword = ""
    @State private var deleteError: String?

    private var initial: String {
        String((auth.currentEmail ?? "F").first ?? "F").uppercased()
    }

    private var lastSync: Date? { banks.compactMap(\.lastSyncedAt).max() }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Text(initial)
                            .font(.title2.bold()).foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(LinearGradient(colors: [Color.heroTop, Color.accentColor], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(auth.isDemo ? "Sample data" : (auth.currentEmail ?? "Your account")).font(.headline).lineLimit(1)
                            Text(auth.isDemo ? "Changes aren't saved in demo mode" : "Signed in").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    infoRow("Accounts", "\(accountCount)", symbol: "creditcard")
                    infoRow("Connected banks", "\(banks.count)", symbol: "building.columns")
                    if let lastSync {
                        infoRow("Last bank sync", lastSync.formatted(.relative(presentation: .named)), symbol: "arrow.triangle.2.circlepath")
                    }
                }

                Section("Banks and accounts") {
                    Button {
                        UserDefaults.standard.set(MoneyView.Segment.accounts.rawValue, forKey: "moneySegment")
                        router.selected = .money
                        dismiss()
                    } label: { Label("Manage accounts and banks", systemImage: "link") }
                    if !auth.isDemo {
                        Button { showSetup = true } label: { Label("Run setup again", systemImage: "wand.and.stars") }
                    }
                }

                Section {
                    Toggle(isOn: $hide) { Label("Hide amounts", systemImage: "eye.slash") }
                    Toggle(isOn: Binding(get: { ask.enabled }, set: { on in Task { _ = await ask.set(on, auth: auth) } })) {
                        Label("Ask Folio", systemImage: "text.bubble")
                    }
                } header: { Text("Preferences") } footer: {
                    Text("Ask Folio sends your questions and the figures it needs to answer them to an AI service. Turn it off any time.")
                }

                Section("About") {
                    Link(destination: AppLinks.privacy) { Label("Privacy Policy", systemImage: "hand.raised") }
                    Link(destination: AppLinks.support) { Label("Contact Support", systemImage: "envelope") }
                    infoRow("Version", version, symbol: "info.circle")
                }

                Section {
                    Button(role: .destructive) { confirmSignOut = true } label: {
                        Label(auth.isDemo ? "Exit demo" : "Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    if !auth.isDemo {
                        Button(role: .destructive) { deleteError = nil; deletePassword = ""; showDelete = true } label: {
                            Label("Delete Account", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(isPresented: $showSetup) { OnboardingFlow { showSetup = false } }
            .alert("Delete your account?", isPresented: $showDelete) {
                SecureField("Password", text: $deletePassword)
                Button("Delete Everything", role: .destructive) {
                    Task { if let message = await auth.deleteAccount(password: deletePassword) { deleteError = message } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes your accounts, transactions, budgets and settings, and disconnects your banks. It can't be undone. Enter your password to confirm.")
            }
            .alert("Couldn't delete account", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(deleteError ?? "") }
            .confirmationDialog(auth.isDemo ? "Exit the demo?" : "Sign out of Folio?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button(auth.isDemo ? "Exit demo" : "Sign out", role: .destructive) { auth.logout() }
            }
            .task { await load() }
        }
        .presentationDetents([.large])
    }

    private func infoRow(_ title: String, _ value: String, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        if let r: AccountsResponse = try? await auth.withFreshToken(.accounts) { accountCount = r.accounts.count }
        if !auth.isDemo, let r: PlaidItemsResponse = try? await auth.withFreshToken(.plaidItems) { banks = r.items }
    }
}
