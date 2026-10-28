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
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 12)
                .background {
                    // Frosted like a system bar, so content scrolling underneath is blurred behind the switch.
                    Rectangle().fill(.regularMaterial)
                        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
                        .ignoresSafeArea(edges: .top)
                }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ProfileMenu() } }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.selection, trigger: segmentRaw)
        }
    }
}
