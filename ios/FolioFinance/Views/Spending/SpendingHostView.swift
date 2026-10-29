import SwiftUI

/// Spending and budget together: one tab, one switch at the top.
struct SpendingHostView: View {
    static let segmentKey = "spendingSegment"

    enum Segment: String, CaseIterable, Identifiable {
        case spending = "Spending", budget = "Budget"
        var id: String { rawValue }
    }

    @AppStorage(SpendingHostView.segmentKey) private var segmentRaw = Segment.spending.rawValue
    private var segment: Segment { Segment(rawValue: segmentRaw) ?? .spending }

    var body: some View {
        NavigationStack {
            ZStack {
                SpendingView(embedded: true, active: segment == .spending)
                    .opacity(segment == .spending ? 1 : 0)
                    .scaleEffect(segment == .spending ? 1 : 0.98)
                    .blur(radius: segment == .spending ? 0 : 6)
                    .allowsHitTesting(segment == .spending)
                PlanView(embedded: true)
                    .opacity(segment == .budget ? 1 : 0)
                    .scaleEffect(segment == .budget ? 1 : 0.98)
                    .blur(radius: segment == .budget ? 0 : 6)
                    .allowsHitTesting(segment == .budget)
            }
            .animation(Motion.spring, value: segment)
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Show", selection: Binding(get: { segment }, set: { segmentRaw = $0.rawValue })) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
                // No bar: the page's own colour sits behind the switch, so cards slide away under it.
                .background { PinnedBandBackground(tone: segment == .spending ? .spending : .plan) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ProfileMenu() }
            }
            .navigationTitle(segment.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.selection, trigger: segmentRaw)
        }
    }
}
