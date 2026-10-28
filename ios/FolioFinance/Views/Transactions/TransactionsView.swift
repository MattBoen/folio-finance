import SwiftUI
import MapKit

struct TransactionsView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case list = "List", map = "Map"
        var id: String { rawValue }
    }

    @EnvironmentObject private var auth: AuthManager
    @State private var transactions: [Transaction] = []
    @State private var isLoading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var searchText = ""
    @State private var showAdd = false
    @State private var mode: Mode = .list
    @State private var detail: Transaction?

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
        NavigationStack {
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
                } else if mode == .list {
                    listView.transition(.opacity)
                } else {
                    ActivityMapView(transactions: filtered) { detail = $0 }.transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: mode)
            .sensoryFeedback(.selection, trigger: mode)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !transactions.isEmpty {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
            .navigationTitle("Activity")
            .searchable(text: $searchText, prompt: "Search transactions")
            .refreshable { await load() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddTransactionSheet { Task { await load() } } }
            .sheet(item: $detail) { t in
                TransactionDetailView(transaction: t, all: transactions) { Task { await load() } }
            }
        }
        .task { await load() }
    }

    private var listView: some View {
        List {
            if let error {
                ErrorBanner(message: error) { Task { await load() } }
                    .listRowBackground(Color.clear).listRowInsets(.init()).listRowSeparator(.hidden)
            }
            ForEach(grouped, id: \.key) { date, txns in
                Section {
                    ForEach(txns) { txn in
                        Button { detail = txn } label: {
                            TransactionRow(transaction: txn)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Rectangle().fill(.regularMaterial))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { Task { await delete(txn) } } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { Task { await setExcluded(txn, !txn.isExcluded) } } label: {
                                Label(txn.isExcluded ? "Include" : "Exclude",
                                      systemImage: txn.isExcluded ? "eye" : "eye.slash")
                            }
                            .tint(.gray)
                        }
                    }
                } header: {
                    Text(dayHeader(date))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .overlay { if isLoading && !loaded { ProgressView().controlSize(.large) } }
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

// MARK: - Map mode

/// Every place you've spent in the last 90 days, one marker per merchant.
private struct ActivityMapView: View {
    let transactions: [Transaction]
    var onSelect: (Transaction) -> Void

    @State private var coords: [String: CLLocationCoordinate2D] = [:]   // by merchant
    @State private var camera: MapCameraPosition = .automatic
    @State private var selection: String?
    @State private var locating = false
    @State private var finished = false

    private struct Pin: Identifiable {
        let latest: Transaction
        let coordinate: CLLocationCoordinate2D
        let visits: Int
        var id: String { latest.id }
    }

    private var pins: [Pin] {
        Dictionary(grouping: transactions, by: \.merchantKey).compactMap { key, rows in
            guard let c = coords[key], let latest = rows.max(by: { $0.date < $1.date }) else { return nil }
            return Pin(latest: latest, coordinate: c, visits: rows.count)
        }
    }

    var body: some View {
        let list = pins
        Map(position: $camera, selection: $selection) {
            ForEach(list) { pin in
                Marker(pin.visits > 1 ? "\(pin.latest.displayName) (\(pin.visits))" : pin.latest.displayName,
                       systemImage: Categories.style(pin.latest.category).symbol, coordinate: pin.coordinate)
                    .tint(pin.latest.tint)
                    .tag(pin.latest.id)
            }
        }
        .mapControls { MapCompass(); MapScaleView() }
        .overlay(alignment: .bottom) { status(count: list.count) }
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: selection) { _, id in
            guard let id, let t = transactions.first(where: { $0.id == id }) else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSelect(t)
            selection = nil
        }
        .task(id: transactions.map(\.id)) { await locateAll() }
    }

    @ViewBuilder private func status(count: Int) -> some View {
        Group {
            if locating {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(count == 0 ? "Finding your places…" : "\(count) places · finding more…") }
            } else if count == 0 && finished {
                Text("Nothing here has a location yet.")
            } else if count > 0 {
                Text("\(count) place\(count == 1 ? "" : "s") · last 90 days")
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 96)
        .animation(.smooth, value: locating)
        .opacity(locating || count > 0 || finished ? 1 : 0)
    }

    private func locateAll() async {
        let locator = PlaceLocator.shared
        finished = false

        // 1. Coordinates we already have (server pins, earlier lookups).
        var known: [String: CLLocationCoordinate2D] = [:]
        for t in transactions { if let c = locator.cachedCoordinate(for: t) { known[t.merchantKey] = c } }
        withAnimation(.smooth) { coords = known }
        if let region = Self.region(for: Array(known.values)) { locator.bias = region }
        if !known.isEmpty { withAnimation(.smooth(duration: 0.6)) { camera = Self.fit(Array(known.values)) } }

        // 2. Look up the rest by name, newest merchants first, one at a time.
        var seen = Set(known.keys)
        let pending = transactions.sorted { $0.date > $1.date }.filter { t in
            guard PlaceLocator.canLocate(t), !seen.contains(t.merchantKey) else { return false }
            seen.insert(t.merchantKey); return true
        }.prefix(40)
        locating = !pending.isEmpty
        for t in pending {
            if Task.isCancelled { return }
            if let c = await locator.coordinate(for: t) {
                withAnimation(.smooth) { coords[t.merchantKey] = c }
            }
        }
        locating = false
        finished = true
        if !coords.isEmpty { withAnimation(.smooth(duration: 0.6)) { camera = Self.fit(Array(coords.values)) } }
    }

    private static func region(for points: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !points.isEmpty else { return nil }
        let lat = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let lon = points.map(\.longitude).reduce(0, +) / Double(points.count)
        return MKCoordinateRegion(center: .init(latitude: lat, longitude: lon), span: .init(latitudeDelta: 0.5, longitudeDelta: 0.5))
    }

    private static func fit(_ points: [CLLocationCoordinate2D]) -> MapCameraPosition {
        guard let first = points.first else { return .automatic }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for p in points {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.5, 0.02), longitudeDelta: max((maxLon - minLon) * 1.5, 0.02))
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}

// MARK: - Row

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
        .padding(.vertical, 2)
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
