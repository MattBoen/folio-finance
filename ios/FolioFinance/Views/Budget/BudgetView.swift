import SwiftUI

struct BudgetView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 52))
                    .foregroundStyle(Color.folioAmber)
                VStack(spacing: 8) {
                    Text("Budgets")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.folioSlate)
                    Text("Set monthly spending targets for each category and track your progress in real time.")
                        .font(.subheadline)
                        .foregroundStyle(Color.folioSlate.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                Text("Coming soon")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.folioAmber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.folioAmber.opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.folioCream)
            .navigationTitle("Budget")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
