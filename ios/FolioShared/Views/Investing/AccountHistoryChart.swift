import SwiftUI
import Charts

/// The graph shown when you tap an investment account: its value over time, with the same range switch and touch-to-inspect as the main Investing chart.
struct AccountHistoryChart: View {
    let account: Account
    @EnvironmentObject private var auth: AuthManager
    @State private var all: [InvestingView.Pt] = []
    @State private var range: InvestingView.Span = .ytd
    @State private var loaded = false
    @State private var selectedDate: Date?

    private var points: [InvestingView.Pt] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -range.days, to: Date()) ?? .distantPast
        return all.filter { $0.date >= cutoff }
    }

    private var shown: InvestingView.Pt? {
        guard let last = points.last else { return nil }
        guard let d = selectedDate else { return last }
        return points.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) } ?? last
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Range", selection: $range) {
                    ForEach(InvestingView.Span.allCases.filter { $0 != .threeYears }) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                } else if points.count >= 2, let shown {
                    let lo = points.map(\.value).min() ?? 0, hi = points.map(\.value).max() ?? 1
                    let pad = max(1, (hi - lo) * 0.18)
                    let change = (points.last?.value ?? 0) - (points.first?.value ?? 0)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            CountingText(money(shown.value, cents: false)).font(.title2.bold()).monospacedDigit().contentTransition(.numericText()).sensitive()
                            CountingText(selectedDate != nil
                                         ? shown.date.formatted(.dateTime.month(.wide).day().year())
                                         : "\(change >= 0 ? "Up" : "Down") \(money(abs(change))) over this period")
                                .font(.caption).foregroundStyle(.secondary).sensitive()
                        }
                        Spacer(minLength: 8)
                        PeriodChangeBadge(first: points.first?.value ?? 0, last: points.last?.value ?? 0)
                    }
                    Chart {
                        ForEach(points) { p in
                            AreaMark(x: .value("Date", p.date), yStart: .value("Base", lo - pad), yEnd: .value("Value", p.value))
                                .foregroundStyle(LinearGradient(colors: [Color.purple.opacity(0.30), Color.purple.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Date", p.date), y: .value("Value", p.value))
                                .foregroundStyle(Color.purple)
                                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                                .interpolationMethod(.monotone)
                        }
                        if selectedDate != nil {
                            RuleMark(x: .value("Date", shown.date)).foregroundStyle(.secondary.opacity(0.5))
                            PointMark(x: .value("Date", shown.date), y: .value("Value", shown.value)).foregroundStyle(Color.purple).symbolSize(70)
                        }
                    }
                    .chartXSelection(value: $selectedDate)
                    .chartYScale(domain: (lo - pad)...(hi + pad))
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine()
                            AxisValueLabel { if let x = v.as(Double.self) { Text(folioCompact(x)) } }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: axisDates(points.map(\.date))) { _ in
                            AxisValueLabel(format: range == .year ? .dateTime.month(.abbreviated).year(.twoDigits) : .dateTime.month(.abbreviated).day(), anchor: .top)
                        }
                    }
                    .frame(height: 180)
                    .animation(.smooth(duration: 0.35), value: range)
                    .sensitive()
                } else {
                    Label("This account's history isn't available yet.", systemImage: "clock")
                        .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: range)
        .task { await load() }
    }

    private func load() async {
        if let r: AccountHistoryResponse = try? await auth.withFreshToken(.accountHistory(id: account.id, days: 365)) {
            all = r.snapshots
                .compactMap { s in parseDay(s.date).map { (d: $0, v: s.doubleValue) } }
                .sorted { $0.d < $1.d }
                .map { InvestingView.Pt(id: Int($0.d.timeIntervalSince1970), date: $0.d, value: $0.v) }
        }
        loaded = true
    }
}
