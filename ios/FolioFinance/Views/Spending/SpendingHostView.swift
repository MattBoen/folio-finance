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
                    .allowsHitTesting(segment == .spending)
                PlanView(embedded: true)
                    .opacity(segment == .budget ? 1 : 0)
                    .allowsHitTesting(segment == .budget)
            }
            .animation(.smooth(duration: 0.25), value: segment)
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Show", selection: Binding(get: { segment }, set: { segmentRaw = $0.rawValue })) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ProfileMenu() } }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.selection, trigger: segmentRaw)
        }
    }
}
