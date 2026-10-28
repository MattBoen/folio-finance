import SwiftUI

struct TransactionsView: View {
    /// True when hosted inside the Money tab, which supplies the navigation stack and title.
    var embedded = false
    /// False while a host keeps this screen alive but hidden, so its search and toolbar step aside.
    var active = true

    @EnvironmentObject private var auth: AuthManager
    @State private var transactions: [Transaction] = []
    @State private var isLoading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var searchText = ""
    @State private var showAdd = false
    @State private var detail: Transaction?
    @State private var editing: Transaction?
    @State private var deleting: Transaction?

    private var filtered: [Transaction] {
        guard !searchText.isEmpty else { return transactions }
        let q = searchText.lowercased()
        return transactions.filter {
            $0.displayName.lowercased().contains(q) || $0.category.lowercased().contains(q)
                || ($0.accountName?.lowercased().contains(q) ?? false)
        }
    }

    private var grouped: [(key: String, value: [Transaction])] {
        Dictionary(grouping: filtered, by: \.date).sorted { $0.key > $1.key }
    }

    var body: some View {
        Group {
            if embedded { core } else { NavigationStack { core } }
        }
        .task { await load() }
    }

    private var core: some View {
            ZStack {
                Wash(tone: .activity)
                if loaded && transactions.isEmpty && error == nil {
                    ContentUnavailableView {
                        Label("No activity yet", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("Add a purchase or paycheck to start tracking where your money goes.")
                    } actions: {
                        Button("Add transaction") { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    listView
                }
            }
            .titledUnlessEmbedded("Activity", embedded: embedded)
            .modifier(OptionalSearch(enabled: !embedded, text: $searchText))
            .refreshable { await load() }
            .toolbar {
                if active {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showAdd = true } label: { Image(systemName: "plus") }
                    }
                }
            }
            .sheet(isPresented: $showAdd) { AddTransactionSheet { Task { await load() } } }
            .sheet(item: $detail) { t in
                TransactionDetailView(transaction: t, all: transactions) { Task { await load() } }
            }
            .sheet(item: $editing) { t in
                EditTransactionSheet(transaction: t) { Task { await load() } }
            }
            .confirmationDialog("Delete this transaction?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let t = deleting { Task { await delete(t) } } }
            } message: { Text("Connected accounts re-import their own transactions. To hide one from your spending instead, use Exclude.") }
    }

    /// Inline search, used when a host's pinned switch sits under the nav bar where the system field would go.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search transactions", text: $searchText)
                .submitLabel(.search).autocorrectionDisabled()
            if !searchText.isEmpty {
                Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if embedded { searchField }
                if let error { ErrorBanner(message: error) { Task { await load() } } }
                if !searchText.isEmpty && filtered.isEmpty {
                    EmptyStateCard(symbol: "magnifyingglass", title: "No matches", message: "Try a different merchant, category or account.")
                }
                ForEach(grouped, id: \.key) { date, txns in
                    VStack(spacing: 8) {
                        SectionTitle(dayHeader(date), trailing: dayTotal(txns))
                        Card(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(txns) { txn in
                                    Button { detail = txn } label: {
                                        TransactionRow(transaction: txn)
                                            .padding(.horizontal, 16).padding(.vertical, 10)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PressableRowStyle())
                                    .contextMenu {
                                        Button { Task { await setExcluded(txn, !txn.isExcluded) } } label: {
                                            Label(txn.isExcluded ? "Include in spending" : "Exclude from spending",
                                                  systemImage: txn.isExcluded ? "eye" : "eye.slash")
                                        }
                                        Button { editing = txn } label: { Label("Edit", systemImage: "pencil") }
                                        Button(role: .destructive) { deleting = txn } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    if txn.id != txns.last?.id { Divider().padding(.leading, 66) }
                                }
                            }
                        }
                    }
                    .flowIn()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .overlay { if isLoading && !loaded { ProgressView().controlSize(.large) } }
    }

    /// Net of the day's counted transactions, shown quietly beside the day header.
    private func dayTotal(_ rows: [Transaction]) -> String? {
        let net = rows.filter { !$0.isExcluded }.reduce(0.0) { $0 - $1.doubleAmount }
        guard net != 0 else { return nil }
        return (net > 0 ? "+" : "−") + money(abs(net))
    }

    private func load() async {
        isLoading = true
        error = nil
        let to = Date()
        let from = Calendar.current.date(byAdding: .day, value: -90, to: to) ?? to
        do {
            let r: TransactionsResponse = try await auth.withFreshToken(
                .transactions(from: dayString(from), to: dayString(to), limit: 500)
            )
            withAnimation(.smooth) { transactions = r.transactions }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
        loaded = true
    }

    private func setExcluded(_ t: Transaction, _ excluded: Bool) async {
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.setTransactionExcluded(id: t.id, excluded: excluded))
            await load()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func delete(_ t: Transaction) async {
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.deleteTransaction(id: t.id))
            await load()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Search field that can be switched off while the screen is hidden behind a sibling.
private struct OptionalSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    func body(content: Content) -> some View {
        if enabled { content.searchable(text: $text, prompt: "Search transactions") } else { content }
    }
}

// MARK: - Row

/// A subtle press highlight for rows inside a card.
struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.06) : .clear)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(configuration.isPressed ? Motion.press : Motion.bouncy, value: configuration.isPressed)
    }
}

struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        let style = Categories.style(transaction.category)
        let amount = abs(transaction.doubleAmount)
        HStack(spacing: 12) {
            IconBadge(symbol: style.symbol, color: style.color, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.displayName).font(.body).lineLimit(1)
                HStack(spacing: 6) {
                    Text([transaction.category, transaction.accountName].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                    if transaction.isPending { Text("Pending").foregroundStyle(.orange) }
                    if transaction.isExcluded { Text("Excluded").foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text((transaction.isDebit ? "−" : "+") + money(amount, cents: true))
                .font(.body.weight(.semibold)).monospacedDigit()
                .foregroundStyle(transaction.isDebit ? Color.primary : Color.up)
                .sensitive()
        }
        .opacity(transaction.isExcluded ? 0.5 : 1)
    }
}

// MARK: - Add transaction

struct AddTransactionSheet: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager

    @State private var accounts: [Account] = []
    @State private var accountId = ""
    @State private var isIncome = false
    @State private var amountText = ""
    @State private var name = ""
    @State private var category = "Groceries"
    @State private var date = Date()
    @State private var saving = false
    @State private var loadedAccounts = false
    @State private var error: String?

    private var amount: Double? { Double(amountText.replacingOccurrences(of: ",", with: "")) }
    private var canSave: Bool {
        (amount ?? 0) > 0 && !name.trimmingCharacters(in: .whitespaces).isEmpty && !accountId.isEmpty && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $isIncome) {
                        Text("Expense").tag(false)
                        Text("Income").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(.init())
                }
                Section {
                    HStack {
                        Text("$").foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText).keyboardType(.decimalPad)
                    }
                    TextField(isIncome ? "Source (e.g. Paycheck)" : "Merchant (e.g. Trader Joe's)", text: $name)
                    if !isIncome {
                        Picker("Category", selection: $category) {
                            ForEach(Categories.choices.filter { $0 != "Income" }, id: \.self) { c in
                                Label(c, systemImage: Categories.style(c).symbol).tag(c)
                            }
                        }
                    }
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                }
                Section {
                    if accounts.isEmpty && loadedAccounts {
                        Text("Add an account first from the Accounts tab.").foregroundStyle(.secondary)
                    } else {
                        Picker("Account", selection: $accountId) {
                            ForEach(accounts) { Text($0.name).tag($0.id) }
                        }
                    }
                } footer: {
                    Text("Manual accounts update their balance automatically.")
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("New Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(!canSave)
                }
            }
            .task { await loadAccounts() }
        }
        .presentationDetents([.large])
    }

    private func loadAccounts() async {
        if let r: AccountsResponse = try? await auth.withFreshToken(.accounts) {
            accounts = r.accounts.filter { !$0.isHidden }
            if accountId.isEmpty { accountId = accounts.first?.id ?? "" }
        }
        loadedAccounts = true
    }

    private func save() async {
        guard let amount else { return }
        saving = true
        error = nil
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.createTransaction(
                accountId: accountId, amount: amount, kind: isIncome ? "income" : "expense",
                date: dayString(date), name: name.trimmingCharacters(in: .whitespaces),
                category: isIncome ? "Income" : category
            ))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onSaved()
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        saving = false
    }
}
