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
            Group {
                switch segment {
                case .spending: SpendingView(embedded: true)
                case .budget: PlanView(embedded: true)
                }
            }
            .id(segment)
            .transition(.opacity)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: Binding(get: { segment }, set: { v in withAnimation(.smooth(duration: 0.3)) { segmentRaw = v.rawValue } })) {
                        ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 230)
                }
                ToolbarItem(placement: .topBarTrailing) { ProfileMenu() }
            }
            .navigationTitle("Spending")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.selection, trigger: segmentRaw)
        }
    }
}
