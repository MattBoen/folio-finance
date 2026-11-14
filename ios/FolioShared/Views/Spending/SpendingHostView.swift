import SwiftUI

/// The Spending tab: one page with the month's spending, its budget, and every category with its target.
/// (It used to switch between Spending and Budget, which showed the same categories twice.)
struct SpendingHostView: View {
    var body: some View {
        NavigationStack {
            SpendingView(embedded: true)
                .navigationTitle("Spending")
        }
    }
}
