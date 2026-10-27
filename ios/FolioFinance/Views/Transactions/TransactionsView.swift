import SwiftUI

struct TransactionsView: View {
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
        NavigationStack {
            Group {
                if isLoading && transactions.isEmpty {
                    ProgressView().tint(Color.folioAmber)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if transactions.isEmpty && error == nil {
                    emptyState
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
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button {
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            } label: {
                                                Label("Exclude", systemImage: "eye.slash")
                                            }
                                            .tint(Color.folioSlate)
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Transactions")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search transactions")
            .refreshable { await load() }
        }
        .task { await load() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "creditcard")
                .font(.system(size: 48))
                .foregroundStyle(Color.folioAmber)
            Text("No transactions yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.folioSlate)
            Text("Connect an account to see your transactions here.")
                .font(.subheadline)
                .foregroundStyle(Color.folioSlate.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        isLoading = true
        error = nil
        let cal = Calendar.current
        let to = Date()
        let from = cal.date(byAdding: .month, value: -1, to: to)!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        do {
            let response: TransactionsResponse = try await auth.withFreshToken(
                .transactions(from: fmt.string(from: from), to: fmt.string(from: to))
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

struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: transaction.isDebit ? "arrow.up" : "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(transaction.isDebit ? Color.primary : .green)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if let cat = transaction.categoryName {
                    Text(cat)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(transaction.displayAmount)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(transaction.isDebit ? Color.primary : .green)
                if transaction.isPending {
                    Text("Pending")
                        .font(.caption2)
                        .foregroundStyle(Color.folioAmber)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
