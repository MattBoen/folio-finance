import SwiftUI

extension View {
    /// Sets a navigation title unless the view is hosted by another screen that owns the title.
    @ViewBuilder func titledUnlessEmbedded(_ title: String, embedded: Bool) -> some View {
        if embedded { self } else { navigationTitle(title) }
    }
}

/// Transactions and accounts together: one tab, one switch at the top.
struct MoneyView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case transactions = "Transactions", accounts = "Accounts"
        var id: String { rawValue }
    }

    @AppStorage("moneySegment") private var segmentRaw = Segment.transactions.rawValue
    private var segment: Segment { Segment(rawValue: segmentRaw) ?? .transactions }

    var body: some View {
        NavigationStack {
            Group {
                switch segment {
                case .transactions: TransactionsView(embedded: true)
                case .accounts: AccountsView(embedded: true)
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
            .navigationTitle("Money")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.selection, trigger: segmentRaw)
        }
    }
}
