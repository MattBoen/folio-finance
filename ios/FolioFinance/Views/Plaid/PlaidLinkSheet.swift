import SwiftUI

// PlaidLinkSheet — real LinkKit integration activates once you have a paid
// Apple Developer account and register the bundle ID with Plaid's dashboard.
// For now, this shows setup instructions so the rest of the app can be tested.

struct PlaidLinkSheet: View {
    let onSuccess: (String, String?, String?) async -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "building.columns.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.folioAmber)

                VStack(spacing: 10) {
                    Text("Connect your bank")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.folioSlate)
                    Text("Bank connections require a paid Apple Developer account. Once enrolled, this screen will open Plaid Link to connect your accounts.")
                        .font(.subheadline)
                        .foregroundStyle(Color.folioSlate.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                VStack(alignment: .leading, spacing: 10) {
                    StepRow(number: 1, text: "Enroll in Apple Developer Program ($99/yr)")
                    StepRow(number: 2, text: "Add Sign In with Apple capability in Xcode")
                    StepRow(number: 3, text: "Rebuild — Plaid Link activates automatically")
                }
                .padding()
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.folioCream)
            .navigationTitle("Connect Bank")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.folioAmber)
                }
            }
        }
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.folioCream)
                .frame(width: 22, height: 22)
                .background(Color.folioAmber)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.folioSlate)
        }
    }
}
