import SwiftUI

struct AccountsView: View {
    /// True when hosted inside the Money tab, which supplies the navigation stack and title.
    var embedded = false
    /// False while a host keeps this screen alive but hidden, so its toolbar button steps aside.
    var active = true

    @EnvironmentObject private var auth: AuthManager
    @State private var accounts: [Account] = []
    @State private var isLoading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var showAdd = false
    @State private var showConnect = false
    @State private var showCar = false
    @State private var editing: Account?
    @State private var deleting: Account?
    @State private var summaryGroup: AccountGroup?
    @State private var banks: [PlaidItem] = []
    @State private var reconnecting: PlaidItem?
    @State private var disconnecting: PlaidItem?
    @State private var refreshingBank: String?

    private var visible: [Account] { accounts.filter { !$0.isHidden } }
    private var hidden: [Account] { accounts.filter(\.isHidden) }

    var body: some View {
        Group {
            if embedded { core } else { NavigationStack { core } }
        }
        .task { await load() }
    }

    private var core: some View {
            ZStack {
                Wash(tone: .accounts)
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if let error { ErrorBanner(message: error) { Task { await load() } } }

                        if loaded && accounts.isEmpty {
                            EmptyStateCard(
                                symbol: "building.columns.fill",
                                title: "No accounts yet",
                                message: "Connect your bank to bring in balances and activity automatically, or add an account by hand."
                            )
                        }
                        ForEach(banks.filter { $0.status != .active }) { b in
                            attentionBanner(b)
                        }

                        ForEach(Array(AccountGroup.allCases.enumerated()), id: \.element) { i, g in
                            let rows = visible.filter { $0.group == g }
                            if !rows.isEmpty {
                                AccountGroupCard(group: g, accounts: rows, actions: actions, groupTotal: groupTotal(g)) { summaryGroup = g }
                                    .flowIn(i)
                            }
                        }

                        if loaded { addMoreCard.flowIn() }

                        if !banks.isEmpty { banksCard.flowIn() }

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
                .scrollIndicators(.hidden)
                .folioRefresh {
                    async let banks: Void = BankSync.refreshForPull(auth)
                    await load()
                    await banks
                    await load()
                }
                .overlay { if isLoading && !loaded { ProgressView().controlSize(.large) } }
            }
            .titledUnlessEmbedded("Accounts", embedded: embedded)
            .toolbar {
                if active { ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showAdd = true } label: { Label("Add account", systemImage: "plus") }
                        Button { showConnect = true } label: { Label("Connect a bank", systemImage: "link") }
                        Button { showCar = true } label: { Label("Add a car", systemImage: "car.fill") }
                    } label: {
                        Image(systemName: "plus")
                    }
                } }
            }
            .sheet(isPresented: $showAdd) { AddAccountSheet { Task { await load() } } }
            .sheet(isPresented: $showConnect, onDismiss: { Task { await load() } }) { PlaidLinkSheet() }
            .sheet(item: $reconnecting, onDismiss: { Task { await load() } }) { b in
                PlaidLinkSheet(reconnectItemId: b.id, reconnectName: b.institutionName)
            }
            .confirmationDialog(
                "Disconnect \(disconnecting?.institutionName ?? "this bank")?",
                isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    if let b = disconnecting { Task { await disconnect(b) } }
                }
            } message: {
                Text("Its accounts and their history are removed from Folio, and Folio stops receiving data from this bank.")
            }
            .sheet(isPresented: $showCar, onDismiss: { Task { await load() } }) { AddCarSheet { Task { await load() } } }
            .sheet(item: $editing) { a in AccountEditSheet(account: a) { Task { await load() } } }
            .onReceive(NotificationCenter.default.publisher(for: .accountsChanged)) { _ in Task { await load() } }
            .sheet(item: $summaryGroup) { g in groupSheet(g) }
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

    private func groupTotal(_ g: AccountGroup) -> Double {
        visible.filter { $0.group == g }.reduce(0) { $0 + NSDecimalNumber(decimal: $1.currentBalance).doubleValue }
    }

    private func groupSheet(_ g: AccountGroup) -> some View {
        let rows = visible.filter { $0.group == g }.sorted { $0.currentBalance > $1.currentBalance }
        let total = max(groupTotal(g), 1)
        let sameSide = AccountGroup.allCases.filter { $0.isLiability == g.isLiability }.reduce(0.0) { $0 + groupTotal($1) }
        return BreakdownSheet(
            title: g.rawValue, headline: (g.isLiability ? "−" : "") + money(groupTotal(g)),
            caption: "\(rows.count) account\(rows.count == 1 ? "" : "s") · \(Int((groupTotal(g) / max(sameSide, 1) * 100).rounded()))% of your \(g.isLiability ? "liabilities" : "assets")",
            tone: .accounts,
            sections: [BreakdownSection(title: "Accounts", rows: rows.map { a in
                let v = NSDecimalNumber(decimal: a.currentBalance).doubleValue
                return BreakdownRow(symbol: g.symbol, color: g.color, title: a.name,
                                    subtitle: [a.institutionName, a.mask.map { "•••• \($0)" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? a.typeLabel,
                                    value: (g.isLiability ? "−" : "") + money(a.currentBalance, cents: true), fraction: v / total)
            })]
        )
    }

    private var actions: AccountActions {
        AccountActions(
            edit: { editing = $0 },
            toggleHidden: { a in Task { await setHidden(a, !a.isHidden) } },
            delete: { deleting = $0 }
        )
    }

    @ViewBuilder private func menu(for a: Account) -> some View {
        Button { editing = a } label: { Label(a.isManual ? "Edit" : "Rename", systemImage: "pencil") }
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
            withAnimation(Motion.spring) { accounts = r.accounts }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        if !auth.isDemo, let r: PlaidItemsResponse = try? await auth.withFreshToken(.plaidItems) {
            withAnimation(Motion.spring) { banks = r.items }
        }
        isLoading = false
        loaded = true
        // Pull anything new from the banks in the background, then show it.
        if let r = await BankSync.run(auth), r.synced > 0 || r.needsAttention > 0 {
            if let a: AccountsResponse = try? await auth.withFreshToken(.accounts) { withAnimation(Motion.spring) { accounts = a.accounts } }
            if let b: PlaidItemsResponse = try? await auth.withFreshToken(.plaidItems) { withAnimation(Motion.spring) { banks = b.items } }
        }
    }

    private func refreshBank(_ b: PlaidItem) async {
        refreshingBank = b.id
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.refreshPlaidItem(id: b.id))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        refreshingBank = nil
        await load()
    }

    private func disconnect(_ b: PlaidItem) async {
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.removePlaidItem(id: b.id))
            disconnecting = nil
            await load()
        } catch {
            disconnecting = nil
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Banks

    private var addMoreCard: some View {
        HStack(spacing: 10) {
            Button { showConnect = true } label: {
                Label("Connect a bank", systemImage: "link")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 28)
            }
            .buttonStyle(.borderedProminent)
            Button { showAdd = true } label: {
                Label("Add by hand", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 28)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    private func attentionBanner(_ b: PlaidItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(b.institutionName ?? "A bank") stopped syncing").font(.subheadline.weight(.semibold))
                Text("Sign in again to keep balances up to date.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Reconnect") { reconnecting = b }.font(.subheadline.weight(.semibold)).buttonStyle(.bordered)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var banksCard: some View {
        VStack(spacing: 8) {
            SectionTitle("Connected banks", trailing: "Through Plaid")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(banks) { b in
                        HStack(spacing: 12) {
                            IconBadge(symbol: "building.columns.fill", color: b.status == .active ? .blue : .orange, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.institutionName ?? "Bank").font(.body).lineLimit(1)
                                Text(bankDetail(b)).font(.caption).foregroundStyle(b.status == .active ? Color.secondary : Color.orange)
                            }
                            Spacer(minLength: 8)
                            if refreshingBank == b.id {
                                ProgressView()
                            } else {
                                Menu {
                                    if b.status != .active {
                                        Button { reconnecting = b } label: { Label("Reconnect", systemImage: "arrow.triangle.2.circlepath") }
                                    }
                                    Button { Task { await refreshBank(b) } } label: { Label("Refresh now", systemImage: "arrow.clockwise") }
                                    Button(role: .destructive) { disconnecting = b } label: { Label("Disconnect", systemImage: "xmark.circle") }
                                } label: {
                                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
                                        .frame(width: 36, height: 36).contentShape(Rectangle())
                                }
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        if b.id != banks.last?.id { Divider().padding(.leading, 64) }
                    }
                }
            }
        }
    }

    private func bankDetail(_ b: PlaidItem) -> String {
        if b.status != .active { return "Needs you to sign in again" }
        let n = b.accountCount ?? 0
        let accounts = "\(n) account\(n == 1 ? "" : "s")"
        guard let t = b.lastSyncedAt else { return accounts }
        return accounts + " · Updated " + t.formatted(.relative(presentation: .named))
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
    var groupTotal: Double = 0
    var onSummary: () -> Void = {}

    private var subtotal: Decimal { accounts.reduce(0) { $0 + $1.currentBalance } }

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                TileButton(action: onSummary) {
                    HStack(spacing: 8) {
                        Circle().fill(group.color).frame(width: 9, height: 9)
                        Text(group.rawValue).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text((group.isLiability ? "−" : "") + money(subtotal))
                            .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit().sensitive()
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }

                ForEach(accounts) { a in
                    Divider().padding(.leading, 62)
                    NavigationLink(value: a) { AccountRow(account: a) }
                        .buttonStyle(PressableRowStyle())
                        .contextMenu {
                            Button { actions.edit(a) } label: { Label(a.isManual ? "Edit" : "Rename", systemImage: "pencil") }
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

extension String {
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
    @State private var showEdit = false
    @State private var detail: Transaction?
    @State private var title = ""
    @State private var live: Account?
    @Environment(\.dismiss) private var dismissDetail
    private var shown: Account { live ?? account }

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
                            Text(title.isEmpty ? account.name : title).font(.headline).lineLimit(1)
                            Text((shown.isLiability ? "−" : "") + money(shown.currentBalance, cents: true))
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
                        ForEach(txns) { t in
                            Button { detail = t } label: { TransactionRow(transaction: t).contentShape(Rectangle()) }
                                .buttonStyle(.plain)
                                .listRowBackground(Rectangle().fill(.regularMaterial))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay { if isLoading && !loaded { ProgressView().controlSize(.large) } }
        }
        .navigationTitle(title.isEmpty ? account.name : title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(account.isManual ? "Edit" : "Rename") { showEdit = true } } }
        .onReceive(NotificationCenter.default.publisher(for: .accountRemoved)) { n in
            if n.userInfo?["id"] as? String == account.id { dismissDetail() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountRenamed)) { n in
            if n.userInfo?["id"] as? String == account.id, let name = n.userInfo?["name"] as? String { title = name }
        }
        .sheet(isPresented: $showEdit) {
            AccountEditSheet(account: account) { Task { await rename() } }
        }
        .sheet(item: $detail) { t in
            TransactionDetailView(transaction: t, all: transactions) { Task { await load() } }
        }
        .searchable(text: $searchText, prompt: "Search")
        .folioRefresh { await load() }
        .task { await load() }
    }

    /// Shows the new name right away after an edit.
    private func rename() async {
        if let r: AccountsResponse = try? await auth.withFreshToken(.accounts), let a = r.accounts.first(where: { $0.id == account.id }) {
            title = a.name
            withAnimation(Motion.spring) { live = a }
        }
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
    @State private var showPlaid = false
    @State private var linkedViaPlaid = false

    private var balance: Double? { Double(balanceText.replacingOccurrences(of: ",", with: "")) }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && (balance ?? -1) >= 0 && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showPlaid = true } label: {
                        HStack(spacing: 12) {
                            IconBadge(symbol: "link", color: .blue, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connect a bank, card or brokerage").font(.headline).foregroundStyle(.primary)
                                Text("Secure and read-only, through Plaid. Balances and activity update on their own.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Or enter an account by hand below.")
                }
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
                    Text("Accounts you enter by hand keep the balance you give them. Connect a bank above to have it update on its own.")
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
        .sheet(isPresented: $showPlaid, onDismiss: { if linkedViaPlaid { dismiss() } }) {
            PlaidLinkSheet(onLinked: { _ in linkedViaPlaid = true; onSaved() })
        }
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
    @State private var confirmRemove = false

    init(account: Account, onSaved: @escaping () -> Void) {
        self.account = account
        self.onSaved = onSaved
        _name = State(initialValue: account.name)
        _institution = State(initialValue: account.institutionName ?? "")
        _balanceText = State(initialValue: NSDecimalNumber(decimal: account.currentBalance).stringValue)
    }

    private var balance: Double? { Double(balanceText.replacingOccurrences(of: ",", with: "")) }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && (!account.isManual || (balance ?? -1) >= 0) && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    if account.isManual { TextField("Bank or institution (optional)", text: $institution) }
                } footer: {
                    if !account.isManual { Text("Your bank keeps the balance up to date. Renaming only changes how it looks in Folio.") }
                }
                if account.isManual {
                    Section(account.isLiability ? "Amount owed" : "Current balance") {
                        HStack {
                            Text("$").foregroundStyle(.secondary)
                            TextField("0.00", text: $balanceText).keyboardType(.decimalPad)
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                Section {
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Text(account.isManual ? "Delete Account" : "Hide Account")
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 30)
                    }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                } footer: {
                    Text(account.isManual ? "Removes it from your net worth and history. This can't be undone." : "Connected accounts can't be deleted, because your bank keeps sending them. Hiding removes it from your net worth and totals, and you can show it again from Accounts.")
                }
            }
            .confirmationDialog(account.isManual ? "Delete \(account.name)?" : "Hide \(account.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button(account.isManual ? "Delete" : "Hide", role: .destructive) { Task { await remove() } }
            }
            .navigationTitle(account.isManual ? "Edit Account" : "Rename Account")
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

    private func remove() async {
        saving = true
        error = nil
        do {
            if account.isManual {
                let _: AnyDecodable = try await auth.withFreshToken(.deleteAccount(id: account.id))
            } else {
                let _: AnyDecodable = try await auth.withFreshToken(.setAccountHidden(id: account.id, hidden: true))
            }
            NotificationCenter.default.post(name: .accountRemoved, object: nil, userInfo: ["id": account.id])
            NotificationCenter.default.post(name: .accountsChanged, object: nil)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onSaved()
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        saving = false
    }

    private func save() async {
        saving = true
        error = nil
        do {
            if !account.isManual {
                let newName = name.trimmingCharacters(in: .whitespaces)
                let _: AccountResponse = try await auth.withFreshToken(.renameAccount(id: account.id, name: newName))
                NotificationCenter.default.post(name: .accountRenamed, object: nil, userInfo: ["id": account.id, "name": newName])
                NotificationCenter.default.post(name: .accountsChanged, object: nil)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onSaved(); dismiss(); saving = false
                return
            }
            guard let balance else { saving = false; return }
            let _: AccountResponse = try await auth.withFreshToken(.updateAccount(
                id: account.id, name: name.trimmingCharacters(in: .whitespaces), balance: balance,
                institutionName: institution.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ))
            NotificationCenter.default.post(name: .accountRenamed, object: nil, userInfo: ["id": account.id, "name": name.trimmingCharacters(in: .whitespaces)])
            NotificationCenter.default.post(name: .accountsChanged, object: nil)
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

extension Notification.Name {
    /// Posted after any change to accounts, so every screen showing them reloads.
    static let accountsChanged = Notification.Name("accountsChanged")
    static let accountRemoved = Notification.Name("accountRemoved")
    static let accountRenamed = Notification.Name("accountRenamed")
}
