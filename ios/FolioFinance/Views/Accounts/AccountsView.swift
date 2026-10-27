import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var accounts: [Account] = []
    @State private var isLoading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var showAdd = false
    @State private var showConnect = false
    @State private var editing: Account?
    @State private var deleting: Account?

    private var visible: [Account] { accounts.filter { !$0.isHidden } }
    private var hidden: [Account] { accounts.filter(\.isHidden) }

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .accounts)
                ScrollView {
                    VStack(spacing: 14) {
                        if let error { ErrorBanner(message: error) { Task { await load() } } }

                        if loaded && accounts.isEmpty {
                            EmptyStateCard(
                                symbol: "building.columns.fill",
                                title: "No accounts yet",
                                message: "Add the accounts you want to track. You can enter balances by hand today and connect your bank later."
                            )
                            Button { showAdd = true } label: {
                                Label("Add account", systemImage: "plus")
                                    .font(.headline).frame(maxWidth: .infinity).frame(height: 30)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        }

                        ForEach(AccountGroup.allCases) { g in
                            let rows = visible.filter { $0.group == g }
                            if !rows.isEmpty {
                                AccountGroupCard(group: g, accounts: rows, actions: actions)
                                    .flowIn()
                            }
                        }

                        if !hidden.isEmpty {
                            VStack(spacing: 8) {
                                SectionTitle("Hidden", trailing: "Not counted in net worth")
                                Card(padding: 0) {
                                    VStack(spacing: 0) {
                                        ForEach(hidden) { a in
                                            AccountRow(account: a, dimmed: true)
                                                .contextMenu { menu(for: a) }
                                            if a.id != hidden.last?.id { Divider().padding(.leading, 62) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .refreshable { await load() }
                .overlay { if isLoading && !loaded { ProgressView().controlSize(.large) } }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showAdd = true } label: { Label("Add account", systemImage: "plus") }
                        Button { showConnect = true } label: { Label("Connect a bank", systemImage: "link") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) { AddAccountSheet { Task { await load() } } }
            .sheet(isPresented: $showConnect) { PlaidLinkSheet() }
            .sheet(item: $editing) { a in EditAccountSheet(account: a) { Task { await load() } } }
            .confirmationDialog(
                "Delete \(deleting?.name ?? "account")?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let a = deleting { Task { await delete(a) } }
                }
            } message: {
                Text("It will be removed from your net worth.")
            }
            .navigationDestination(for: Account.self) { AccountTransactionsView(account: $0) }
        }
        .task { await load() }
    }

    private var actions: AccountActions {
        AccountActions(
            edit: { editing = $0 },
            toggleHidden: { a in Task { await setHidden(a, !a.isHidden) } },
            delete: { deleting = $0 }
        )
    }

    @ViewBuilder private func menu(for a: Account) -> some View {
        if a.isManual { Button { editing = a } label: { Label("Edit balance", systemImage: "pencil") } }
        Button { Task { await setHidden(a, !a.isHidden) } } label: {
            Label(a.isHidden ? "Show in net worth" : "Hide", systemImage: a.isHidden ? "eye" : "eye.slash")
        }
        if a.isManual {
            Button(role: .destructive) { deleting = a } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            let r: AccountsResponse = try await auth.withFreshToken(.accounts)
            accounts = r.accounts
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
        loaded = true
    }

    private func setHidden(_ a: Account, _ hidden: Bool) async {
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.setAccountHidden(id: a.id, hidden: hidden))
            await load()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func delete(_ a: Account) async {
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.deleteAccount(id: a.id))
            deleting = nil
            await load()
        } catch {
            deleting = nil
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

extension Account: Hashable {
    static func == (l: Account, r: Account) -> Bool { l.id == r.id && l.balanceCurrent == r.balanceCurrent }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct AccountActions {
    var edit: (Account) -> Void
    var toggleHidden: (Account) -> Void
    var delete: (Account) -> Void
}

// MARK: - Group card

struct AccountGroupCard: View {
    let group: AccountGroup
    let accounts: [Account]
    let actions: AccountActions

    private var subtotal: Decimal { accounts.reduce(0) { $0 + $1.currentBalance } }

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Circle().fill(group.color).frame(width: 9, height: 9)
                    Text(group.rawValue).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text((group.isLiability ? "−" : "") + money(subtotal))
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit().sensitive()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                ForEach(accounts) { a in
                    Divider().padding(.leading, 62)
                    NavigationLink(value: a) { AccountRow(account: a) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if a.isManual { Button { actions.edit(a) } label: { Label("Edit balance", systemImage: "pencil") } }
                            Button { actions.toggleHidden(a) } label: { Label("Hide", systemImage: "eye.slash") }
                            if a.isManual {
                                Button(role: .destructive) { actions.delete(a) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                }
            }
        }
    }
}

struct AccountRow: View {
    let account: Account
    var dimmed = false

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: account.group.symbol, color: account.group.color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.body).lineLimit(1)
                Text([account.institutionName, account.mask.map { "•••• \($0)" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? account.typeLabel)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text((account.isLiability ? "−" : "") + money(account.currentBalance, cents: true))
                .font(.body.weight(.semibold)).monospacedDigit().sensitive()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Account detail

struct AccountTransactionsView: View {
    let account: Account
    @EnvironmentObject private var auth: AuthManager
    @State private var transactions: [Transaction] = []
    @State private var isLoading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var searchText = ""

    private var filtered: [Transaction] {
        guard !searchText.isEmpty else { return transactions }
        let q = searchText.lowercased()
        return transactions.filter { $0.displayName.lowercased().contains(q) || $0.category.lowercased().contains(q) }
    }

    private var grouped: [(key: String, value: [Transaction])] {
        Dictionary(grouping: filtered, by: \.date).sorted { $0.key > $1.key }
    }

    var body: some View {
        ZStack {
            Wash(tone: .accounts)
            List {
                Section {
                    HStack(spacing: 12) {
                        IconBadge(symbol: account.group.symbol, color: account.group.color, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((account.isLiability ? "−" : "") + money(account.currentBalance, cents: true))
                                .font(.title2.bold()).monospacedDigit().sensitive()
                            Text(account.isLiability ? "Amount owed" : "Current balance")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Rectangle().fill(.regularMaterial))
                }
                if let error {
                    ErrorBanner(message: error) { Task { await load() } }
                        .listRowBackground(Color.clear).listRowInsets(.init())
                }
                if loaded && transactions.isEmpty && error == nil {
                    Section {
                        Text(account.isManual ? "No transactions yet. Add one from the Activity tab." : "No transactions in the last 90 days.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .listRowBackground(Rectangle().fill(.regularMaterial))
                    }
                }
                ForEach(grouped, id: \.key) { date, txns in
                    Section(dayHeader(date)) {
                        ForEach(txns) { TransactionRow(transaction: $0).listRowBackground(Rectangle().fill(.regularMaterial)) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay { if isLoading && !loaded { ProgressView().controlSize(.large) } }
        }
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        let to = Date()
        let from = Calendar.current.date(byAdding: .day, value: -90, to: to) ?? to
        do {
            let r: TransactionsResponse = try await auth.withFreshToken(
                .transactions(from: dayString(from), to: dayString(to), accountId: account.id, limit: 500)
            )
            transactions = r.transactions
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
        loaded = true
    }
}

// MARK: - Add / edit account

struct AddAccountSheet: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager

    enum Kind: String, CaseIterable, Identifiable {
        case checking = "Checking", savings = "Savings", investment = "Investment"
        case credit = "Credit card", loan = "Loan", other = "Other asset"
        var id: String { rawValue }
        var apiType: String {
            switch self {
            case .checking, .savings: "depository"
            case .investment: "investment"
            case .credit: "credit"
            case .loan: "loan"
            case .other: "other"
            }
        }
        var subtype: String? { self == .checking ? "checking" : self == .savings ? "savings" : nil }
        var isLiability: Bool { self == .credit || self == .loan }
        var example: String {
            switch self {
            case .checking: "Everyday Checking"
            case .savings: "Emergency Fund"
            case .investment: "Brokerage"
            case .credit: "Rewards Card"
            case .loan: "Car Loan"
            case .other: "Vehicle"
            }
        }
    }

    @State private var kind: Kind = .checking
    @State private var name = ""
    @State private var institution = ""
    @State private var balanceText = ""
    @State private var saving = false
    @State private var error: String?

    private var balance: Double? { Double(balanceText.replacingOccurrences(of: ",", with: "")) }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && (balance ?? -1) >= 0 && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Name (e.g. \(kind.example))", text: $name)
                    TextField("Bank or institution (optional)", text: $institution)
                }
                Section {
                    HStack {
                        Text("$").foregroundStyle(.secondary)
                        TextField("0.00", text: $balanceText).keyboardType(.decimalPad)
                    }
                } header: {
                    Text(kind.isLiability ? "Amount owed" : "Current balance")
                } footer: {
                    Text("You can update this any time. Connected banks will sync automatically in a future update.")
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("New Account")
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
        }
        .presentationDetents([.large])
    }

    private func save() async {
        guard let balance else { return }
        saving = true
        error = nil
        do {
            let _: AccountResponse = try await auth.withFreshToken(.createManualAccount(
                name: name.trimmingCharacters(in: .whitespaces), type: kind.apiType, subtype: kind.subtype,
                balance: balance, institutionName: institution.trimmingCharacters(in: .whitespaces).nilIfEmpty
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

struct EditAccountSheet: View {
    let account: Account
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager

    @State private var name: String
    @State private var institution: String
    @State private var balanceText: String
    @State private var saving = false
    @State private var error: String?

    init(account: Account, onSaved: @escaping () -> Void) {
        self.account = account
        self.onSaved = onSaved
        _name = State(initialValue: account.name)
        _institution = State(initialValue: account.institutionName ?? "")
        _balanceText = State(initialValue: NSDecimalNumber(decimal: account.currentBalance).stringValue)
    }

    private var balance: Double? { Double(balanceText.replacingOccurrences(of: ",", with: "")) }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && (balance ?? -1) >= 0 && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Bank or institution (optional)", text: $institution)
                }
                Section(account.isLiability ? "Amount owed" : "Current balance") {
                    HStack {
                        Text("$").foregroundStyle(.secondary)
                        TextField("0.00", text: $balanceText).keyboardType(.decimalPad)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Edit Account")
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
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        guard let balance else { return }
        saving = true
        error = nil
        do {
            let _: AccountResponse = try await auth.withFreshToken(.updateAccount(
                id: account.id, name: name.trimmingCharacters(in: .whitespaces), balance: balance,
                institutionName: institution.trimmingCharacters(in: .whitespaces).nilIfEmpty
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

// Catch-all decodable for endpoints whose response body we ignore
struct AnyDecodable: Decodable, Sendable {}
