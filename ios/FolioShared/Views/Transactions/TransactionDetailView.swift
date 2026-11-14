import SwiftUI
import MapKit
import Charts

// MARK: - Place lookup (shared cache, one search at a time)

/// One quick look at where the phone is, used only to keep merchant searches in the right town. Never sent anywhere.
@MainActor
private final class DeviceLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    func current() async -> CLLocationCoordinate2D? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: manager.requestLocation()
        }
        return await withCheckedContinuation { waiting = $0 }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            case .denied, .restricted: finish(nil)
            default: break
            }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let c = locations.last?.coordinate
        Task { @MainActor in finish(c) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in finish(nil) }
    }
    private func finish(_ c: CLLocationCoordinate2D?) { waiting?.resume(returning: c); waiting = nil }
}

/// Finds where a purchase happened. In order of trust: the pin the bank sent, the street address the server
/// has (from the bank, the statement line, or a one-time merchant lookup), then an Apple Maps search for the
/// merchant in the town the bank reported. A search result only counts when its name matches the merchant,
/// so a different business nearby never gets the pin. Online purchases get no map.
@MainActor
final class PlaceLocator {
    static let shared = PlaceLocator()

    /// Roughly where the customer lives and shops, learned from purchases the bank placed on a map.
    private(set) var anchor: CLLocationCoordinate2D? = {
        let d = UserDefaults.standard
        guard d.object(forKey: "placeAnchorLat") != nil else { return nil }
        return CLLocationCoordinate2D(latitude: d.double(forKey: "placeAnchorLat"), longitude: d.double(forKey: "placeAnchorLon"))
    }()

    private let device = DeviceLocation()
    private var deviceAnchor: CLLocationCoordinate2D?
    private var triedDevice = false
    private var cache: [String: CLLocationCoordinate2D] = [:]
    private var towns: [String: CLLocationCoordinate2D?] = [:]
    private var missing = Set<String>()
    private var tail: Task<Void, Never> = Task {}

    private static let categoriesWithoutPlace: Set<String> = ["Income", "Subscriptions", "Bills & Utilities", "Transfer", "Home", "Fees"]
    private static let onlineMerchants = ["uber", "lyft", "netflix", "spotify", "amazon", "amzn", "apple.com", "itunes", "google", "paypal", "venmo", "doordash", "grubhub", "payroll", "rent", "transfer", "payment", "interest", "hulu", "openai", "steam"]
    /// Card-processor prefixes and filler that say nothing about the business.
    private static let noise: Set<String> = ["the", "and", "of", "inc", "llc", "co", "corp", "store", "sq", "tst", "fsp", "pp", "pos", "debit", "purchase", "card", "visa", "checkcard", "dbt", "ach", "www", "com"]

    static func canLocate(_ t: Transaction) -> Bool {
        if t.paymentChannel == "online" { return false }
        let key = (t.merchantName ?? t.name).lowercased()
        if onlineMerchants.contains(where: { key.contains($0) }) { return false }
        if t.hasCoordinate || (t.place?.isEmpty == false) { return true }
        return !categoriesWithoutPlace.contains(t.category)
    }

    /// Meaningful words of a business name: "SQ *CHUB'S PUB #12" -> ["chubs", "pub"].
    static func words(_ name: String) -> [String] {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !noise.contains($0) && $0.rangeOfCharacter(from: .decimalDigits) == nil }
    }

    /// True when a map result is plausibly this merchant: its name contains the merchant's first real word.
    static func sameBusiness(merchant: String, result: String) -> Bool {
        guard let first = words(merchant).first else { return false }
        return words(result).joined().contains(first)
    }

    /// Remembers the middle of the purchases the bank placed, so searches stay in the customer's own area.
    func learn(from transactions: [Transaction]) async {
        let pins = transactions.compactMap { t -> (Double, Double)? in
            guard t.paymentChannel != "online", let la = t.lat, let lo = t.lon else { return nil }
            return (la, lo)
        }
        var center: CLLocationCoordinate2D?
        if pins.count >= 2 {
            center = CLLocationCoordinate2D(latitude: pins.map(\.0).sorted()[pins.count / 2], longitude: pins.map(\.1).sorted()[pins.count / 2])
        } else if anchor == nil {
            // No pins from the bank: use the town it reports most often.
            let counts = transactions.compactMap { t in t.city.map { [$0, t.region].compactMap { $0 }.joined(separator: ", ") } }
                .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            if let top = counts.max(by: { $0.value < $1.value })?.key { center = await town(top) }
        }
        guard let center else { return }
        anchor = center
        UserDefaults.standard.set(center.latitude, forKey: "placeAnchorLat")
        UserDefaults.standard.set(center.longitude, forKey: "placeAnchorLon")
    }

    func cachedCoordinate(for t: Transaction) -> CLLocationCoordinate2D? {
        guard Self.canLocate(t) else { return nil }
        if let lat = t.lat, let lon = t.lon { return CLLocationCoordinate2D(latitude: lat, longitude: lon) }
        return cache[t.id]
    }

    private func town(_ name: String) async -> CLLocationCoordinate2D? {
        if let known = towns[name] { return known }
        let found = try? await CLGeocoder().geocodeAddressString(name).first?.location?.coordinate
        towns[name] = found
        return found
    }

    func coordinate(for t: Transaction) async -> CLLocationCoordinate2D? {
        if let c = cachedCoordinate(for: t) { return c }
        guard Self.canLocate(t), !missing.contains(t.id) else { return nil }

        // A street address: ask for exactly that.
        if let place = t.place, !place.isEmpty,
           let found = try? await CLGeocoder().geocodeAddressString(place).first?.location?.coordinate {
            cache[t.id] = found
            return found
        }

        // Otherwise search by name in the town the bank reported, or else where this customer usually shops.
        var center: CLLocationCoordinate2D?
        var radius = 25_000.0
        if let city = t.city {
            center = await town([city, t.region].compactMap { $0 }.joined(separator: ", "))
        }
        if center == nil {
            if anchor == nil, deviceAnchor == nil, !triedDevice {
                triedDevice = true
                deviceAnchor = await device.current()
            }
            center = anchor ?? deviceAnchor
            radius = 40_000
        }
        guard let center else { missing.insert(t.id); return nil }

        let merchant = t.merchantName ?? t.name
        let query = Self.words(merchant).joined(separator: " ")
        guard !query.isEmpty else { missing.insert(t.id); return nil }
        let previous = tail
        let job = Task<CLLocationCoordinate2D?, Never> {
            await previous.value
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
            request.resultTypes = .pointOfInterest
            let response = try? await MKLocalSearch(request: request).start()
            let here = CLLocation(latitude: center.latitude, longitude: center.longitude)
            return response?.mapItems
                .filter { Self.sameBusiness(merchant: merchant, result: $0.name ?? "") }
                .map { $0.placemark.coordinate }
                .filter { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: here) <= radius }
                .min { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: here) < CLLocation(latitude: $1.latitude, longitude: $1.longitude).distance(from: here) }
        }
        tail = Task { _ = await job.value; try? await Task.sleep(for: .milliseconds(250)) }

        if let found = await job.value {
            cache[t.id] = found
            return found
        }
        missing.insert(t.id)
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
    @State private var editing = false
    @State private var incomeRows: [Transaction] = []

    private var isIncome: Bool { !transaction.isDebit }

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
                        if isIncome { incomeCard } else { mapCard }
                        detailsCard
                        if !isIncome { merchantCard }
                        actionsCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Edit") { editing = true } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $editing) {
                EditTransactionSheet(transaction: transaction) { onChanged(); dismiss() }
            }
            .confirmationDialog("Delete this transaction?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: { Text("Connected accounts re-import their own transactions, so this only removes ones you added.") }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            if isIncome { await loadIncomeHistory() } else { await locate() }
        }
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
                CountingText((transaction.isDebit ? "−" : "+") + money(amount, cents: true))
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
                // Wallet-style: the merchant and its address on one tappable row that opens Apple Maps.
                Button {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
                    item.name = transaction.displayName
                    item.openInMaps()
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transaction.displayName).foregroundStyle(.primary).lineLimit(1)
                            if let p = transaction.place, !p.isEmpty {
                                Text(p).font(.footnote).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

    /// The bank's own wording, only when it adds something: no trailing reference numbers, and not a street address
    /// (the map card already shows where it was).
    private var statementText: String? {
        let d = transaction.name
        if d.range(of: #"\d{5}(-?\d{4})?\s+[A-Z]{2}\s+USA\s*$"#, options: .regularExpression) != nil { return nil }
        let c = d.replacingOccurrences(of: #"\s+[0-9][0-9\-]{6,}\s*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return c.isEmpty || c.lowercased() == transaction.displayName.lowercased() ? nil : c
    }

    /// Category and status are already in the header, so this only carries what isn't: which card, online, the bank's wording, your note.
    @ViewBuilder private var detailsCard: some View {
        let rows: [(String, String)] = [
            transaction.accountName.map { ("Card", $0) },
            transaction.paymentChannel == "online" ? ("How", "Online") : nil,
            statementText.map { ("On the statement", $0) },
            (transaction.note?.isEmpty == false) ? ("Note", transaction.note ?? "") : nil,
        ].compactMap { $0 }
        if !rows.isEmpty {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        if i > 0 { Divider().padding(.leading, 16) }
                        row(r.0, r.1)
                    }
                }
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

    // MARK: Income overview

    private var sourceRows: [Transaction] {
        let source = incomeRows.isEmpty ? all : incomeRows
        let rows = source.filter { $0.merchantKey == transaction.merchantKey && !$0.isDebit }
        let merged = rows.contains(where: { $0.id == transaction.id }) ? rows : rows + [transaction]
        return merged.sorted { $0.date < $1.date }
    }

    private struct Cadence { let name: String; let gapDays: Double?; let perMonth: Double? }

    private func cadence(_ rows: [Transaction]) -> Cadence {
        let dates = rows.compactMap { parseDay($0.date) }.sorted()
        guard dates.count >= 2 else { return Cadence(name: "One deposit so far", gapDays: nil, perMonth: nil) }
        let gaps = zip(dates, dates.dropFirst()).map { $1.timeIntervalSince($0) / 86_400 }.sorted()
        let median = gaps[gaps.count / 2]
        switch median {
        case 5...9: return Cadence(name: "Weekly", gapDays: median, perMonth: 52.0 / 12)
        case 12...16: return Cadence(name: "Every two weeks", gapDays: median, perMonth: 26.0 / 12)
        case 28...33: return Cadence(name: "Monthly", gapDays: median, perMonth: 1)
        case 10..<12, 16..<20: return Cadence(name: "Twice a month", gapDays: median, perMonth: 2)
        default: return Cadence(name: "Irregular", gapDays: median, perMonth: nil)
        }
    }

    @ViewBuilder private var incomeCard: some View {
        let rows = sourceRows
        let cutoff = Calendar.current.date(byAdding: .month, value: -12, to: Date()) ?? Date()
        let last12 = rows.filter { (parseDay($0.date) ?? .distantPast) >= cutoff }
        let yearStart = Calendar.current.date(from: Calendar.current.dateComponents([.year], from: Date())) ?? Date()
        let ytd = rows.filter { (parseDay($0.date) ?? .distantPast) >= yearStart }
        let total12 = last12.reduce(0) { $0 + abs($1.doubleAmount) }
        let totalYTD = ytd.reduce(0) { $0 + abs($1.doubleAmount) }
        let avg = last12.isEmpty ? 0 : total12 / Double(last12.count)
        let cad = cadence(rows)
        let months = monthly(last12)
        let latest = rows.last
        VStack(spacing: 8) {
            SectionTitle("Income from \(transaction.displayName)")
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        bigStat("This year", money(totalYTD))
                        Divider().frame(height: 40)
                        bigStat("Last 12 months", money(total12))
                    }
                    if months.count > 1 {
                        Chart(months, id: \.key) { m in
                            BarMark(x: .value("Month", m.label), y: .value("Received", m.total))
                                .foregroundStyle(LinearGradient(colors: [Color.up, Color.up.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                                .cornerRadius(5)
                        }
                        .chartYAxis(.hidden)
                        .frame(height: 120)
                        .sensitive()
                    }
                    VStack(spacing: 10) {
                        stat("Deposits", "\(last12.count)")
                        stat("Average deposit", money(avg, cents: true))
                        if let latest { stat("Most recent", "\(money(abs(latest.doubleAmount), cents: true)) · \(shortDay(latest.date))") }
                        stat("How often", cad.name)
                        if let per = cad.perMonth, avg > 0 { stat("Estimated per month", money(avg * per)) }
                    }
                    if let gap = cad.gapDays, cad.perMonth != nil, let last = latest.flatMap({ parseDay($0.date) }),
                       let next = Calendar.current.date(byAdding: .day, value: Int(gap.rounded()), to: last) {
                        Label("Next deposit around \(next.formatted(.dateTime.month(.abbreviated).day()))", systemImage: "calendar")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.up)
                    }
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.suffix(6).reversed()), id: \.id) { t in
                        HStack {
                            Text(shortDay(t.date)).foregroundStyle(.secondary)
                            Spacer()
                            CountingText("+" + money(abs(t.doubleAmount), cents: true)).fontWeight(.semibold).monospacedDigit().foregroundStyle(Color.up).sensitive()
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        if t.id != rows.suffix(6).reversed().last?.id { Divider().padding(.leading, 16) }
                    }
                }
            }
        }
    }

    private func bigStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            CountingText(value).font(.title2.bold()).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1).sensitive()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortDay(_ s: String) -> String {
        parseDay(s)?.formatted(.dateTime.month(.abbreviated).day().year()) ?? s
    }

    private func loadIncomeHistory() async {
        let to = Date()
        let from = Calendar.current.date(byAdding: .month, value: -12, to: to) ?? to
        if let r: TransactionsResponse = try? await auth.withFreshToken(.transactions(from: dayString(from), to: dayString(to), limit: 500)) {
            withAnimation(.smooth) { incomeRows = r.transactions }
        }
    }

    // MARK: Merchant history

    @ViewBuilder private var merchantCard: some View {
        let visits = history
        if visits.count > 1 {
            let months = filledMonths(monthly(visits))
            let total = visits.reduce(0) { $0 + abs($1.doubleAmount) }
            let tint = transaction.tint, top = months.map(\.total).max() ?? 1, lastKey = months.last?.key
            // One headline number with secondary detail beside it, then a quiet chart: no gridlines, rounded bars,
            // the latest month emphasized, values labeled right on the bars.
            VStack(spacing: 8) {
                SectionTitle("At this merchant")
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Total spent").font(.footnote).foregroundStyle(.secondary)
                                CountingText(money(total, cents: true)).font(.title2.bold()).monospacedDigit().sensitive()
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(visits.count) visits").font(.subheadline.weight(.medium))
                                CountingText("\(money(total / Double(visits.count), cents: true)) avg").font(.footnote).foregroundStyle(.secondary).monospacedDigit().sensitive()
                            }
                        }
                        if months.count > 1 {
                            Chart(months, id: \.key) { m in
                                BarMark(x: .value("Month", m.label), y: .value("Spent", m.total), width: .ratio(0.6))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .foregroundStyle(m.key == lastKey ? tint : tint.opacity(0.35))
                                    .annotation(position: .top, spacing: 4) {
                                        CountingText(money(m.total)).font(.caption2.weight(.medium)).foregroundStyle(m.key == lastKey ? .primary : .secondary).monospacedDigit()
                                    }
                            }
                            .chartYScale(domain: 0...(top * 1.3))
                            .chartYAxis(.hidden)
                            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption).foregroundStyle(Color(.secondaryLabel)) } }
                            .frame(height: 130)
                            .sensitive()
                        }
                    }
                }
            }
        }
    }

    private static let monthKey: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// A month with no visits still gets its (empty) bar, so the chart reads as a true timeline. Last six months.
    private func filledMonths(_ m: [MonthTotal]) -> [MonthTotal] {
        guard let first = m.first, let last = m.last, var d = Self.monthKey.date(from: first.key), let end = Self.monthKey.date(from: last.key) else { return Array(m.suffix(6)) }
        let known = Dictionary(uniqueKeysWithValues: m.map { ($0.key, $0) })
        var out: [MonthTotal] = []
        while d <= end {
            let k = Self.monthKey.string(from: d)
            out.append(known[k] ?? MonthTotal(key: k, label: d.formatted(.dateTime.month(.abbreviated)), total: 0))
            guard let next = Calendar.current.date(byAdding: .month, value: 1, to: d) else { break }
            d = next
        }
        return Array(out.suffix(6))
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
            CountingText(value).fontWeight(.semibold).monospacedDigit().sensitive()
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
        await PlaceLocator.shared.learn(from: all + [transaction])
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


// MARK: - Edit sheet

/// Rename a transaction, move it to another category, or add a note. The bank's own details stay untouched.
struct EditTransactionSheet: View {
    let transaction: Transaction
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager
    @State private var name: String
    @State private var category: String
    @State private var note: String
    @State private var applyToSimilar = true
    @State private var saving = false
    @State private var error: String?

    init(transaction: Transaction, onSaved: @escaping () -> Void) {
        self.transaction = transaction
        self.onSaved = onSaved
        _name = State(initialValue: transaction.displayName)
        _category = State(initialValue: transaction.category)
        _note = State(initialValue: transaction.note ?? "")
    }

    private var choices: [String] {
        Categories.choices.contains(category) ? Categories.choices : [category] + Categories.choices
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section {
                    Picker("Category", selection: $category) {
                        ForEach(choices, id: \.self) { c in
                            Label(c, systemImage: Categories.style(c).symbol).tag(c)
                        }
                    }
                } footer: { Text("Budgets and spending charts use this category.") }
                if category != transaction.category {
                    Section {
                        Toggle("Every \(transaction.displayName) transaction", isOn: $applyToSimilar)
                    } footer: { Text(applyToSimilar ? "Past and future purchases from this merchant go to \(category), so you only fix it once." : "Only this transaction changes.") }
                }
                Section("Note") {
                    TextField("Add a note", text: $note, axis: .vertical).lineLimit(1...4)
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { if saving { ProgressView() } else { Text("Save").bold() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        saving = true
        error = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            let _: AnyDecodable = try await auth.withFreshToken(.updateTransaction(
                id: transaction.id,
                userName: trimmed == transaction.displayName ? nil : trimmed,
                note: note == (transaction.note ?? "") ? nil : note,
                category: category == transaction.category ? nil : category,
                applyToSimilar: category == transaction.category ? nil : applyToSimilar
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
