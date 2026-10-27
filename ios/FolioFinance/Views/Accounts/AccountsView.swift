import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var accounts: [Account] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showLinkSheet = false

    private var grouped: [(key: String, value: [Account])] {
        Dictionary(grouping: accounts, by: { $0.institutionName ?? "Other" })
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && accounts.isEmpty {
                    ProgressView().tint(Color.folioAmber)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if accounts.isEmpty && error == nil {
                    EmptyAccountsCard().padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if let error {
                            ErrorBanner(message: error) { Task { await load() } }
                                .listRowInsets(.init())
                                .listRowBackground(Color.clear)
                        }
                        ForEach(grouped, id: \.key) { institution, accts in
                            Section(institution) {
                                ForEach(accts) { account in
                                    NavigationLink(destination: AccountTransactionsView(account: account)) {
                                        AccountDetailRow(account: account)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                            Task { await toggleHide(account) }
                                        } label: {
                                            Label("Hide", systemImage: "eye.slash")
                                        }
                                    }
                                    .contextMenu {
                                        Button {
                                            Task { await refreshAccount(account) }
                                        } label: {
                                            Label("Refresh data", systemImage: "arrow.clockwise")
                                        }
                                        Button(role: .destructive) {
                                            Task { await toggleHide(account) }
                                        } label: {
                                            Label("Hide account", systemImage: "eye.slash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showLinkSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.folioAmber)
                    }
                }
            }
            .refreshable { await load() }
            .sheet(isPresented: $showLinkSheet) {
                PlaidLinkSheet { publicToken, institutionId, institutionName in
                    await linkAccount(
                        publicToken: publicToken,
                        institutionId: institutionId,
                        institutionName: institutionName
                    )
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            let response: AccountsResponse = try await auth.withFreshToken(.accounts)
            accounts = response.accounts
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private func linkAccount(
        publicToken: String,
        institutionId: String?,
        institutionName: String?
    ) async {
        do {
            let _: AnyDecodable = try await auth.withFreshToken(
                .exchangeToken(
                    publicToken: publicToken,
                    institutionId: institutionId,
                    institutionName: institutionName
                )
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func toggleHide(_ account: Account) async {
        struct HiddenBody: Encodable { let hidden: Bool }
        do {
            let _: AnyDecodable = try await auth.withFreshToken(
                .patch("/accounts/\(account.id)/hidden", body: HiddenBody(hidden: !account.isHidden))
            )
            await load()
        } catch {}
    }

    private func refreshAccount(_ account: Account) async {
        guard let itemId = account.plaidItemId else { return }
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.refreshPlaidItem(id: itemId))
            try? await Task.sleep(for: .seconds(2))
            await load()
        } catch {}
    }
}

private struct AccountDetailRow: View {
    let account: Account

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.primary)
                HStack(spacing: 6) {
                    Text(account.typeLabel)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                    if let mask = account.mask {
                        Text("•••• \(mask)")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
            Spacer()
            Text(account.displayBalance)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(account.isLiability ? Color.folioAmber : Color.primary)
        }
        .padding(.vertical, 4)
    }
}

// ── Account transaction drill-through ────────────────────────────────────────

private struct AccountTransactionsView: View {
    let account: Account
    @EnvironmentObject private var auth: AuthManager
    @State private var transactions: [Transaction] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var searchText = ""

    private var filtered: [Transaction] {
        guard !searchText.isEmpty else { return transactions }
        let q = searchText.lowercased()
        return transactions.filter {
            $0.displayName.lowercased().contains(q) ||
            ($0.categoryName?.lowercased().contains(q) ?? false)
        }
    }

    private var grouped: [(key: String, value: [Transaction])] {
        Dictionary(grouping: filtered, by: \.date).sorted { $0.key > $1.key }
    }

    var body: some View {
        Group {
            if isLoading && transactions.isEmpty {
                ProgressView().tint(Color.folioAmber)
            } else if transactions.isEmpty && error == nil {
                VStack(spacing: 12) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.folioAmber)
                    Text("No transactions")
                        .font(.headline)
                        .foregroundStyle(Color.folioSlate)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let error {
                        ErrorBanner(message: error) { Task { await load() } }
                            .listRowInsets(.init())
                            .listRowBackground(Color.clear)
                    }
                    ForEach(grouped, id: \.key) { date, txns in
                        Section(formatDate(date)) {
                            ForEach(txns) { txn in
                                TransactionRow(transaction: txn)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        let cal = Calendar.current
        let to = Date()
        let from = cal.date(byAdding: .month, value: -3, to: to)!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        do {
            let response: TransactionsResponse = try await auth.withFreshToken(
                .transactions(
                    from: fmt.string(from: from),
                    to: fmt.string(from: to),
                    accountId: account.id
                )
            )
            transactions = response.transactions
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private func formatDate(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let d = parser.date(from: iso) else { return iso }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        return fmt.string(from: d)
    }
}

// Catch-all decodable for fire-and-forget endpoints
struct AnyDecodable: Decodable, Sendable {}
