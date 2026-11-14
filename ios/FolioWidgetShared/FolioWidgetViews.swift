import SwiftUI
import WidgetKit
import Charts

// The home-screen widgets for Folio and Folio Desktop. One file draws them for both apps, so they always look the same:
// each app only says where its WidgetSnapshot comes from (WidgetDataSource) and lists the widgets in its own bundle.

// MARK: - Data source and timeline

protocol WidgetDataSource { static func current() -> WidgetSnapshot? }

struct SnapshotEntry: TimelineEntry { let date: Date; let snapshot: WidgetSnapshot? }

struct SnapshotProvider<Source: WidgetDataSource>: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: .now, snapshot: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? .sample : Source.current()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [SnapshotEntry(date: .now, snapshot: Source.current())], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

enum WidgetKinds {
    #if PERSONAL
    static let spending = "Spending", netWorth = "NetWorth", investments = "Investments"
    #else
    static let spending = "FolioSpending", netWorth = "FolioNetWorth", investments = "FolioInvestments"
    #endif
}

// MARK: - Formatting (widgets are separate processes, so they carry their own)

enum WF {
    static func money(_ v: Double, cents: Bool = false) -> String {
        (v < 0 ? "−" : "") + abs(v).formatted(.currency(code: "USD").precision(.fractionLength(cents ? 2 : 0)))
    }
    static func signed(_ v: Double) -> String { (v >= 0 ? "+" : "−") + money(abs(v)) }
    static func compact(_ v: Double) -> String {
        let a = abs(v), sign = v < 0 ? "−" : ""
        if a >= 1_000_000 { return sign + "$" + String(format: "%.1fM", a / 1_000_000) }
        if a >= 1_000 { return sign + "$" + String(format: "%.0fk", a / 1_000) }
        return sign + "$" + String(format: "%.0f", a)
    }
    static func pct(_ r: Double?) -> String {
        guard let r else { return "—" }
        return (r >= 0 ? "+" : "−") + String(format: "%.1f%%", abs(r * 100))
    }
    static func hidden(_ s: String, _ hide: Bool) -> String { hide ? "$•••••" : s }
}

extension Color {
    init(widgetHex hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0; Scanner(string: h).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

// MARK: - Look: the app's softly colored canvas, light or dark to match the iPhone

private func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(UIColor { t in
        let v = t.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    })
}
private let good = adaptive(light: 0x1E8E3E, dark: 0x5EE08A)
private let bad = adaptive(light: 0xD92D20, dark: 0xFF7A70)
private let ink = Color.primary
private let dim = Color.secondary
private let faint = Color.primary.opacity(0.12)

private struct WidgetCanvas: View {
    let glow: String, glow2: String
    // Colors resolve from the system's light/dark setting directly (not from a SwiftUI environment value),
    // so the widget background always matches the iPhone.
    private func dyn(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    private func glowColor(_ hex: String, light: CGFloat, dark: CGFloat) -> Color {
        let base = UIColor(Color(widgetHex: hex))
        return dyn(base.withAlphaComponent(light), base.withAlphaComponent(dark))
    }
    var body: some View {
        ZStack {
            dyn(UIColor(red: 0.957, green: 0.961, blue: 0.973, alpha: 1), UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1))
            RadialGradient(colors: [glowColor(glow, light: 0.26, dark: 0.34), .clear], center: .topTrailing, startRadius: 0, endRadius: 200)
            RadialGradient(colors: [glowColor(glow2, light: 0.18, dark: 0.22), .clear], center: .bottomLeading, startRadius: 0, endRadius: 190)
            RadialGradient(colors: [Color(widgetHex: glow).opacity(0.10), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 140)
        }
    }
}

private struct EmptyWidget: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.pie.fill").font(.title2)
            Text("Open the app once").font(.caption).multilineTextAlignment(.center)
        }.foregroundStyle(ink)
    }
}
private struct Cap: View {
    let t: String
    var body: some View { Text(t.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(dim) }
}
private struct Big: View {
    let t: String; var size: CGFloat = 30
    var body: some View { Text(t).font(.system(size: size, weight: .bold, design: .rounded)).foregroundStyle(ink).minimumScaleFactor(0.55).lineLimit(1).monospacedDigit() }
}
private extension WidgetFamily { var isAccessory: Bool { [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(self) } }
private func stamp(_ s: WidgetSnapshot) -> String { s.updated.formatted(date: .omitted, time: .shortened) }

// MARK: - Spending

struct SpendingWidget<Source: WidgetDataSource>: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.spending, provider: SnapshotProvider<Source>()) { entry in
            WidgetSpendingView(entry: entry).containerBackground(for: .widget) { WidgetCanvas(glow: "34c759", glow2: "30b0c7") }
        }
        .configurationDisplayName("Spending").description("This month's spending, your budget and the latest purchases.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct WidgetSpendingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry
    var body: some View {
        if let s = entry.snapshot { content(s).padding(family.isAccessory ? 0 : 16) } else { EmptyWidget() }
    }

    private func month(_ s: WidgetSnapshot) -> String { s.monthLabel.map { String($0.split(separator: " ").first ?? "") } ?? Date().formatted(.dateTime.month(.wide)) }
    private func left(_ s: WidgetSnapshot) -> (String, Color)? {
        guard s.budgetTotal > 0 else { return nil }
        let l = s.budgetTotal - s.budgetSpent
        return l >= 0 ? (WF.money(l) + " left", good) : (WF.money(-l) + " over", bad)
    }

    @ViewBuilder private func content(_ s: WidgetSnapshot) -> some View {
        let h = s.hideAmounts
        switch family {
        case .accessoryCircular:
            if s.budgetTotal > 0 {
                Gauge(value: min(1, s.budgetSpent / max(1, s.budgetTotal))) { Image(systemName: "creditcard") } currentValueLabel: { Text(h ? "•" : WF.compact(s.spent)).font(.system(size: 12, weight: .bold)) }.gaugeStyle(.accessoryCircular)
            } else {
                VStack(spacing: 0) { Image(systemName: "creditcard").font(.caption); Text(h ? "•" : WF.compact(s.spent)).font(.system(size: 13, weight: .bold)) }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("\(month(s)) spending").font(.caption2).foregroundStyle(.secondary)
                Text(WF.hidden(WF.money(s.spent), h)).font(.headline)
                if !h, let l = left(s) { Text(l.0).font(.caption2) }
            }
        case .accessoryInline:
            Text(h ? "Spending hidden" : "Spent \(WF.money(s.spent))" + (left(s).map { " · \($0.0)" } ?? ""))

        case .systemSmall:
            VStack(alignment: .leading, spacing: 0) {
                Cap(t: month(s))
                Big(t: WF.hidden(WF.money(s.spent), h), size: 32).padding(.top, 2)
                if !h, let l = left(s) { Text(l.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(l.1).padding(.top, 1) }
                Spacer(minLength: 4)
                HStack(alignment: .bottom) {
                    Text(stamp(s)).font(.system(size: 9)).foregroundStyle(dim)
                    Spacer()
                    donut(s, 54)
                }
            }
        case .systemMedium:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Cap(t: month(s))
                    Big(t: WF.hidden(WF.money(s.spent), h), size: 30).padding(.top, 2)
                    if !h, let l = left(s) { Text(l.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(l.1).padding(.top, 1) }
                    Spacer(minLength: 4)
                    donut(s, 58)
                }.frame(width: 112, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Cap(t: "Latest"); Spacer(); Text(stamp(s)).font(.system(size: 9)).foregroundStyle(dim) }
                    let rows = Array((s.recent ?? []).prefix(5))
                    VStack(spacing: 0) { ForEach(rows) { t in purchaseRow(t, hide: h) } }.padding(.top, 4)
                    Spacer(minLength: 0)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Cap(t: s.monthLabel ?? month(s)); Big(t: WF.hidden(WF.money(s.spent), h), size: 34).padding(.top, 2)
                        if !h, s.budgetTotal > 0, let l = left(s) { Text("\(l.0) of \(WF.money(s.budgetTotal))").font(.system(size: 12, weight: .semibold)).foregroundStyle(l.1) }
                    }
                    Spacer(); donut(s, 76)
                }
                if let items = s.budgetItems, !items.isEmpty {
                    VStack(spacing: 7) { ForEach(items.sorted { $0.limit > $1.limit }.prefix(4), id: \.name) { budgetBar($0, hide: h) } }
                }
                Rectangle().fill(faint).frame(height: 1)
                let n = (s.budgetItems ?? []).isEmpty ? 8 : 4
                VStack(spacing: 0) { ForEach(Array((s.recent ?? []).prefix(n))) { t in purchaseRow(t, hide: h) } }
                Spacer(minLength: 0)
            }
        }
    }

    private func donut(_ s: WidgetSnapshot, _ size: CGFloat) -> some View {
        let slices = (s.categories ?? []).filter { $0.total > 0 }.sorted { $0.total > $1.total }
            .map { SpendWheel.Slice(id: $0.name, total: $0.total, mine: max(0, $0.mine), color: Color(widgetHex: $0.color)) }
        return SpendWheel(slices: slices).frame(width: size, height: size)
    }
    private func purchaseRow(_ t: WidgetSnapshot.Purchase, hide: Bool) -> some View {
        HStack(spacing: 7) {
            Circle().fill(Color(widgetHex: t.color)).frame(width: 7, height: 7)
            Text(t.name).font(.system(size: 12, weight: .medium)).foregroundStyle(t.excluded ? dim : ink).lineLimit(1)
            Spacer(minLength: 4)
            Text(hide ? "••••" : WF.money(t.amount, cents: true)).font(.system(size: 12, weight: .semibold)).foregroundStyle(t.excluded ? dim : ink)
                .strikethrough(t.excluded, color: dim).monospacedDigit()
        }.frame(height: family == .systemMedium ? 20 : 22)
    }
    private func budgetBar(_ it: WidgetSnapshot.BudgetLine, hide: Bool) -> some View {
        let over = it.spent > it.limit
        return VStack(spacing: 3) {
            HStack {
                Text(it.name).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(ink); Spacer()
                Text(hide ? "•••• / ••••" : "\(WF.money(it.spent)) / \(WF.money(it.limit))").font(.system(size: 10)).foregroundStyle(over ? bad : dim).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(faint)
                    Capsule().fill(over ? bad : Color(widgetHex: it.color)).frame(width: max(5, g.size.width * min(1, it.spent / max(1, it.limit))))
                }
            }.frame(height: 5)
        }
    }
}

// MARK: - Net worth

struct NetWorthWidget<Source: WidgetDataSource>: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.netWorth, provider: SnapshotProvider<Source>()) { entry in
            WidgetNetWorthView(entry: entry).containerBackground(for: .widget) { WidgetCanvas(glow: "0a7aff", glow2: "5e5ce6") }
        }
        .configurationDisplayName("Net worth").description("Your net worth, how it has moved and a 30-day trend.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct WidgetNetWorthView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry
    var body: some View {
        if let s = entry.snapshot { content(s).padding(family.isAccessory ? 0 : 16) } else { EmptyWidget() }
    }

    /// Today's move when the source knows it, otherwise the move over the range the app last showed.
    private func move(_ s: WidgetSnapshot) -> (Double, String) { s.dayChange.map { ($0, "today") } ?? (s.change, s.changeLabel) }

    @ViewBuilder private func content(_ s: WidgetSnapshot) -> some View {
        let h = s.hideAmounts, m = move(s)
        let line = h ? "•••• \(m.1)" : "\(WF.signed(m.0)) \(m.1)"
        switch family {
        case .accessoryInline: Text(h ? "Net worth hidden" : "Net worth \(WF.compact(s.netWorth))")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("Net worth").font(.caption2).foregroundStyle(.secondary)
                Text(WF.hidden(WF.money(s.netWorth), h)).font(.headline)
                if !h { Text(line).font(.caption2) }
            }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 0) {
                Cap(t: "Net worth")
                Big(t: WF.hidden(WF.money(s.netWorth), h), size: 28).padding(.top, 2)
                Text(line).font(.system(size: 12, weight: .semibold)).foregroundStyle(m.0 >= 0 ? good : bad).padding(.top, 1).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if !h { spark(s.series).frame(height: 44) }
            }
        default:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Cap(t: "Net worth")
                    Big(t: WF.hidden(WF.money(s.netWorth), h), size: 32).padding(.top, 2)
                    Text(line).font(.system(size: 12, weight: .semibold)).foregroundStyle(m.0 >= 0 ? good : bad).padding(.top, 1).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    HStack(spacing: 14) {
                        if let c = s.netCash { mini("Net cash", WF.hidden(WF.money(c), h)) }
                        if let i = s.invested { mini("Invested", WF.hidden(WF.money(i), h)) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 4) {
                    if !h { spark(s.series).frame(maxHeight: .infinity) } else { Spacer() }
                    Text("30 days · \(stamp(s))").font(.system(size: 9)).foregroundStyle(dim)
                }.frame(maxWidth: .infinity)
            }
        }
    }

    private func mini(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) { Text(l).font(.system(size: 9.5)).foregroundStyle(dim); Text(v).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink).monospacedDigit() }
    }
    @ViewBuilder private func spark(_ series: [Double]) -> some View {
        if series.count > 2 {
            let lo = series.min() ?? 0, hi = series.max() ?? 1, pad = max(1, (hi - lo) * 0.25)
            Chart(Array(series.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("i", i), yStart: .value("b", lo - pad), yEnd: .value("v", v))
                    .foregroundStyle(LinearGradient(colors: [Color(widgetHex: "3b82f6").opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(Color(widgetHex: "2f6df0"))
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round)).interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: (lo - pad)...(hi + pad)).chartLegend(.hidden)
        } else { Color.clear }
    }
}

// MARK: - Investments

struct InvestmentsWidget<Source: WidgetDataSource>: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.investments, provider: SnapshotProvider<Source>()) { entry in
            WidgetInvestmentsView(entry: entry).containerBackground(for: .widget) { WidgetCanvas(glow: "af52de", glow2: "0a7aff") }
        }
        .configurationDisplayName("Investments").description("What you have invested, how it's doing against the S&P 500 and each account.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

struct WidgetInvestmentsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry
    var body: some View {
        if let s = entry.snapshot, let inv = s.investments { content(s, inv).padding(family.isAccessory ? 0 : 16) } else { EmptyWidget() }
    }

    @ViewBuilder private func content(_ s: WidgetSnapshot, _ inv: WidgetSnapshot.Investments) -> some View {
        let h = s.hideAmounts, day = inv.dayChange
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(inv.sp == nil ? "Invested" : "Invested · YTD vs S&P").font(.caption2).foregroundStyle(.secondary)
                Text(WF.hidden(WF.money(inv.total), h)).font(.headline)
                if !h, inv.ytd != nil { Text("\(WF.pct(inv.ytd))" + (inv.sp == nil ? " this year" : " vs \(WF.pct(inv.sp))")).font(.caption2) }
            }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 0) {
                Cap(t: "Invested")
                Big(t: WF.hidden(WF.money(inv.total), h), size: 28).padding(.top, 2)
                if !h, let day { Text(WF.signed(day) + " today").font(.system(size: 12, weight: .semibold)).foregroundStyle(day >= 0 ? good : bad).padding(.top, 1) }
                Spacer(minLength: 4)
                if !h, let y = inv.ytd {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text("YTD").font(.system(size: 10, weight: .bold)).foregroundStyle(dim); Text(WF.pct(y)).font(.system(size: 14, weight: .bold)).foregroundStyle(ink) }
                        if let sp = inv.sp { HStack(spacing: 6) { Text("S&P \(WF.pct(sp))").font(.system(size: 11)).foregroundStyle(dim); badge(y - sp) } }
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) { Cap(t: "Invested"); Big(t: WF.hidden(WF.money(inv.total), h), size: 28) }
                    Spacer()
                    if let sp = inv.sp {
                        VStack(alignment: .trailing, spacing: 2) { Cap(t: "S&P 500 YTD"); Text(WF.pct(sp)).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(ink) }
                    } else if let y = inv.ytd {
                        VStack(alignment: .trailing, spacing: 2) { Cap(t: "This year"); Text(h ? "••••" : WF.pct(y)).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(ink) }
                    }
                }
                Rectangle().fill(faint).frame(height: 1)
                VStack(spacing: 0) {
                    ForEach(inv.accounts.prefix(family == .systemLarge ? 6 : 3)) { a in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(a.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                                Text(WF.hidden(WF.money(a.balance), h)).font(.system(size: 10)).foregroundStyle(dim)
                            }
                            Spacer(minLength: 4)
                            if !h, a.ytd != nil {
                                Text(WF.pct(a.ytd)).font(.system(size: 13, weight: .bold)).foregroundStyle(ink).monospacedDigit()
                                if let r = a.ytd, let sp = inv.sp { badge(r - sp) } else { Color.clear.frame(width: 50) }
                            }
                        }.frame(height: family == .systemLarge ? 40 : 30)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func badge(_ d: Double) -> some View {
        Text("\(d >= 0 ? "▲" : "▼") \(String(format: "%.1f", abs(d * 100)))").font(.system(size: 10, weight: .bold)).foregroundStyle(d >= 0 ? good : bad)
            .padding(.horizontal, 6).padding(.vertical, 2.5).background((d >= 0 ? good : bad).opacity(0.16), in: Capsule()).frame(minWidth: 50)
    }
}
