import SwiftUI
import WidgetKit
import Charts

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: .now, snapshot: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? .sample : WidgetSnapshot.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(60 * 60))))
    }
}

// MARK: - Formatting

private func money(_ v: Double, hide: Bool) -> String {
    hide ? "$•••••" : v.formatted(.currency(code: "USD").precision(.fractionLength(0)))
}

private let brand = LinearGradient(colors: [Color(red: 0.25, green: 0.52, blue: 1.0), Color(red: 0.40, green: 0.36, blue: 0.90)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)

private struct EmptyWidget: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder.fill.badge.plus").font(.title2)
            Text("Open Folio to set up").font(.footnote.weight(.medium)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Net worth

struct NetWorthView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let s = entry.snapshot {
            switch family {
            case .accessoryRectangular: rectangular(s)
            case .accessoryInline: Text("Net worth \(money(s.netWorth, hide: s.hideAmounts))")
            default: card(s)
            }
        } else {
            EmptyWidget()
        }
    }

    private func card(_ s: WidgetSnapshot) -> some View {
        let up = s.change >= 0
        return VStack(alignment: .leading, spacing: 6) {
            Text("Net worth").font(.caption.weight(.semibold)).opacity(0.85)
            Text(money(s.netWorth, hide: s.hideAmounts))
                .font(.system(size: family == .systemSmall ? 28 : 34, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6).lineLimit(1)
            Label {
                Text(s.hideAmounts ? "•••• \(s.changeLabel)" : "\(money(abs(s.change), hide: false)) \(s.changeLabel)")
            } icon: {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
            }
            .font(.caption.weight(.medium)).opacity(0.9).lineLimit(1).minimumScaleFactor(0.7)
            if family != .systemSmall, !s.hideAmounts, s.series.count > 2 {
                Chart(Array(s.series.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("i", i), y: .value("v", v)).interpolationMethod(.monotone)
                        .foregroundStyle(.white)
                    AreaMark(x: .value("i", i), yStart: .value("min", s.series.min() ?? 0), yEnd: .value("v", v))
                        .foregroundStyle(.white.opacity(0.18))
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: (s.series.min() ?? 0)...(s.series.max() ?? 1))
                .padding(.top, 4)
            } else {
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(brand, for: .widget)
    }

    private func rectangular(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Net worth").font(.caption2).foregroundStyle(.secondary)
            Text(money(s.netWorth, hide: s.hideAmounts)).font(.headline)
            Text(s.hideAmounts ? "" : "\(s.change >= 0 ? "+" : "−")\(money(abs(s.change), hide: false)) \(s.changeLabel)").font(.caption2)
        }
        .containerBackground(.clear, for: .widget)
    }
}

struct NetWorthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FolioNetWorth", provider: SnapshotProvider()) { NetWorthView(entry: $0) }
            .configurationDisplayName("Net worth")
            .description("Your total and how it has moved.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Spending

struct SpendingView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let s = entry.snapshot {
            if family == .accessoryCircular { gauge(s) } else { card(s) }
        } else {
            EmptyWidget()
        }
    }

    private func left(_ s: WidgetSnapshot) -> Double { s.budgetTotal - s.budgetSpent }
    private func fraction(_ s: WidgetSnapshot) -> Double {
        s.budgetTotal > 0 ? min(1, s.budgetSpent / s.budgetTotal) : 0
    }

    private func card(_ s: WidgetSnapshot) -> some View {
        let over = left(s) < 0
        return VStack(alignment: .leading, spacing: 8) {
            Text(Date().formatted(.dateTime.month(.wide))).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(money(s.spent, hide: s.hideAmounts))
                .font(.system(size: family == .systemSmall ? 28 : 34, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6).lineLimit(1)
            Text("spent").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if s.budgetTotal > 0 {
                ProgressView(value: fraction(s)).tint(over ? .red : (fraction(s) > 0.85 ? .orange : .green))
                Text(s.hideAmounts ? "Budget" : over ? "\(money(-left(s), hide: false)) over budget" : "\(money(left(s), hide: false)) left of \(money(s.budgetTotal, hide: false))")
                    .font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text(s.hideAmounts ? "" : "of \(money(s.income, hide: false)) earned").font(.caption.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.background, for: .widget)
    }

    private func gauge(_ s: WidgetSnapshot) -> some View {
        Gauge(value: fraction(s)) {
            Image(systemName: "creditcard.fill")
        } currentValueLabel: {
            Text(s.hideAmounts ? "•" : compact(left(s)))
        }
        .gaugeStyle(.accessoryCircular)
        .containerBackground(.clear, for: .widget)
    }

    private func compact(_ v: Double) -> String {
        let a = abs(v)
        let t = a >= 1000 ? String(format: "%.1fk", a / 1000) : String(Int(a))
        return (v < 0 ? "−" : "") + t
    }
}

struct SpendingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FolioSpending", provider: SnapshotProvider()) { SpendingView(entry: $0) }
            .configurationDisplayName("Spending this month")
            .description("What you've spent and how much budget is left.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

@main
struct FolioWidgetBundle: WidgetBundle {
    var body: some Widget {
        NetWorthWidget()
        SpendingWidget()
    }
}
