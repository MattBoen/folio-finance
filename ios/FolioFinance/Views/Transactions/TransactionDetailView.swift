import SwiftUI
import MapKit
import Charts

// MARK: - Place lookup (shared cache, one search at a time)

/// Finds where a purchase happened: the server's coordinates when there are some, otherwise Apple Maps by merchant name.
@MainActor
final class PlaceLocator {
    static let shared = PlaceLocator()

    /// Bias searches toward where the customer's located purchases cluster.
    var bias: MKCoordinateRegion?

    private var cache: [String: CLLocationCoordinate2D] = [:]
    private var missing = Set<String>()
    private var tail: Task<Void, Never> = Task {}

    private static let categoriesWithoutPlace: Set<String> = ["Income", "Subscriptions", "Bills & Utilities", "Transfer", "Home"]
    private static let onlineMerchants = ["uber", "lyft", "netflix", "spotify", "amazon", "apple", "google", "paypal", "venmo", "doordash", "payroll", "rent"]

    static func canLocate(_ t: Transaction) -> Bool {
        if t.hasCoordinate { return true }
        if categoriesWithoutPlace.contains(t.category) { return false }
        let key = t.merchantKey
        return !onlineMerchants.contains { key.contains($0) }
    }

    func cachedCoordinate(for t: Transaction) -> CLLocationCoordinate2D? {
        if let lat = t.lat, let lon = t.lon { return CLLocationCoordinate2D(latitude: lat, longitude: lon) }
        return cache[t.merchantKey]
    }

    func coordinate(for t: Transaction) async -> CLLocationCoordinate2D? {
        if let c = cachedCoordinate(for: t) { return c }
        guard Self.canLocate(t) else { return nil }
        let key = t.merchantKey
        if missing.contains(key) { return nil }

        let previous = tail
        let name = t.displayName
        let region = bias
        let job = Task<CLLocationCoordinate2D?, Never> {
            await previous.value
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = name
            if let region { request.region = region }
            let response = try? await MKLocalSearch(request: request).start()
            return response?.mapItems.first?.placemark.coordinate
        }
        tail = Task { _ = await job.value; try? await Task.sleep(for: .milliseconds(250)) }

        if let found = await job.value {
            cache[key] = found
            return found
        }
        missing.insert(key)
        return nil
    }
}

extension Transaction {
    var tint: Color { Categories.style(category).color }
}

// MARK: - Detail sheet

struct TransactionDetailView: View {
    let transaction: Transaction
    var all: [Transaction] = []
    var onChanged: () -> Void = {}

    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var coordinate: CLLocationCoordinate2D?
    @State private var locating = true
    @State private var isExcluded: Bool
    @State private var busy = false
    @State private var message: String?
    @State private var confirmDelete = false

    init(transaction: Transaction, all: [Transaction] = [], onChanged: @escaping () -> Void = {}) {
        self.transaction = transaction
        self.all = all
        self.onChanged = onChanged
        _isExcluded = State(initialValue: transaction.isExcluded)
        _coordinate = State(initialValue: nil)
    }

    private var style: (symbol: String, color: Color) { Categories.style(transaction.category) }
    private var amount: Double { abs(transaction.doubleAmount) }

    private var history: [Transaction] {
        let merchant = all.filter { $0.merchantKey == transaction.merchantKey && $0.isDebit == transaction.isDebit }
        return merchant.contains(where: { $0.id == transaction.id }) ? merchant : merchant + [transaction]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .activity)
                ScrollView {
                    VStack(spacing: 14) {
                        header
                        mapCard
                        detailsCard
                        merchantCard
                        actionsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete this transaction?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: { Text("Connected accounts re-import their own transactions, so this only removes ones you added.") }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await locate() }
    }

    // MARK: Header

    private var header: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    IconBadge(symbol: style.symbol, color: style.color, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transaction.displayName).font(.title2.bold()).lineLimit(2)
                        Text(transaction.category).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text((transaction.isDebit ? "−" : "+") + money(amount, cents: true))
                    .font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(transaction.isDebit ? Color.primary : Color.up)
                    .contentTransition(.numericText())
                    .sensitive()
                HStack(spacing: 8) {
                    if let d = parseDay(transaction.date) {
                        Text(d.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    }
                    if transaction.isPending { badge("Pending", .orange) }
                    if isExcluded { badge("Excluded", .purple) }
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    // MARK: Map

    @ViewBuilder private var mapCard: some View {
        if let c = coordinate {
            VStack(spacing: 0) {
                Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 700, longitudinalMeters: 700))) {
                    Marker(transaction.displayName, systemImage: style.symbol, coordinate: c).tint(transaction.tint)
                }
                .frame(height: 190)
                .allowsHitTesting(false)
                Button {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
                    item.name = transaction.displayName
                    item.openInMaps()
                } label: {
                    Label("Open in Maps", systemImage: "map.fill").frame(maxWidth: .infinity)
                }
                .padding(12)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        } else if locating && PlaceLocator.canLocate(transaction) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .frame(height: 120)
                .overlay {
                    HStack(spacing: 8) { ProgressView(); Text("Finding it on the map…").font(.footnote).foregroundStyle(.secondary) }
                }
                .transition(.opacity)
        }
    }

    // MARK: Details

    private var detailsCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                row("Category", transaction.category)
                if let account = transaction.accountName { Divider().padding(.leading, 16); row("Account", account) }
                Divider().padding(.leading, 16)
                row("Status", transaction.isPending ? "Pending" : "Posted")
                if let note = transaction.note, !note.isEmpty { Divider().padding(.leading, 16); row("Note", note) }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Merchant history

    @ViewBuilder private var merchantCard: some View {
        let visits = history
        if visits.count > 1 {
            let months = monthly(visits)
            let total = visits.reduce(0) { $0 + abs($1.doubleAmount) }
            VStack(spacing: 8) {
                SectionTitle("At this merchant")
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        if months.count > 1 {
                            Chart(months, id: \.key) { m in
                                BarMark(x: .value("Month", m.label), y: .value("Spent", m.total))
                                    .foregroundStyle(transaction.tint.gradient)
                                    .cornerRadius(5)
                            }
                            .chartYAxis(.hidden)
                            .frame(height: 110)
                            .sensitive()
                        }
                        VStack(spacing: 10) {
                            stat("Visits", "\(visits.count)")
                            stat("Total", money(total, cents: true))
                            stat("Average", money(total / Double(visits.count), cents: true))
                        }
                    }
                }
            }
        }
    }

    private struct MonthTotal { let key: String; let label: String; let total: Double }

    private func monthly(_ rows: [Transaction]) -> [MonthTotal] {
        Dictionary(grouping: rows, by: { String($0.date.prefix(7)) })
            .map { key, items in
                let label = parseDay(items[0].date)?.formatted(.dateTime.month(.abbreviated)) ?? key
                return MonthTotal(key: key, label: label, total: items.reduce(0) { $0 + abs($1.doubleAmount) })
            }
            .sorted { $0.key < $1.key }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit().sensitive()
        }
        .font(.subheadline)
    }

    // MARK: Actions

    private var actionsCard: some View {
        VStack(spacing: 10) {
            if let message {
                Label(message, systemImage: "info.circle.fill")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                    .transition(.opacity)
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    Button { Task { await toggleExcluded() } } label: {
                        Label(isExcluded ? "Include in spending" : "Exclude from spending", systemImage: isExcluded ? "eye" : "eye.slash")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    Divider().padding(.leading, 16)
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete transaction", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
                .disabled(busy)
            }
        }
        .animation(.smooth, value: message)
    }

    // MARK: Data

    private func locate() async {
        let found = await PlaceLocator.shared.coordinate(for: transaction)
        withAnimation(.smooth) {
            coordinate = found
            locating = false
        }
    }

    private func toggleExcluded() async {
        busy = true
        message = nil
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.setTransactionExcluded(id: transaction.id, excluded: !isExcluded))
            withAnimation(.smooth) { isExcluded.toggle() }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onChanged()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        busy = false
    }

    private func delete() async {
        busy = true
        message = nil
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.deleteTransaction(id: transaction.id))
            onChanged()
            dismiss()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        busy = false
    }
}
