import SwiftUI

// Real Plaid Link activates once the paid Apple Developer account and Plaid
// production access are in place. Until then this explains what's coming.

struct PlaidLinkSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Wash(tone: .balance)
                VStack(spacing: 22) {
                    Spacer()
                    BrandMark(size: 76)
                    VStack(spacing: 8) {
                        Text("Bank connections are coming soon")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text("Soon you'll be able to link your banks, cards and investments so balances and transactions stay up to date on their own.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Until then, add accounts by hand", systemImage: "square.and.pencil")
                            Label("Your net worth history builds daily", systemImage: "chart.line.uptrend.xyaxis")
                            Label("Everything carries over when you connect", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .font(.subheadline)
                    }
                    Spacer()
                    Button("Got it") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .padding(24)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
