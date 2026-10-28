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
            ZStack {
                TransactionsView(embedded: true, active: segment == .transactions)
                    .opacity(segment == .transactions ? 1 : 0)
                    .scaleEffect(segment == .transactions ? 1 : 0.98)
                    .blur(radius: segment == .transactions ? 0 : 6)
                    .allowsHitTesting(segment == .transactions)
                AccountsView(embedded: true, active: segment == .accounts)
                    .opacity(segment == .accounts ? 1 : 0)
                    .scaleEffect(segment == .accounts ? 1 : 0.98)
                    .blur(radius: segment == .accounts ? 0 : 6)
                    .allowsHitTesting(segment == .accounts)
            }
            .animation(Motion.spring, value: segment)
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Show", selection: Binding(get: { segment }, set: { segmentRaw = $0.rawValue })) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
                .background {
                    // No bar: solid page colour behind the switch with a short fade below, so cards slide away under it.
                    Color(UIColor.systemGroupedBackground)
                        .ignoresSafeArea(edges: .top)
                        .overlay(alignment: .bottom) {
                            LinearGradient(colors: [Color(UIColor.systemGroupedBackground), Color(UIColor.systemGroupedBackground).opacity(0)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 14).offset(y: 14)
                        }
                }
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
