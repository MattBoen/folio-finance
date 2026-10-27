import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("Overview", systemImage: "square.grid.2x2.fill") }

            SpendingView()
                .tabItem { Label("Spending", systemImage: "chart.pie.fill") }

            PlanView()
                .tabItem { Label("Budget", systemImage: "dollarsign.circle.fill") }

            TransactionsView()
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle.fill") }

            AccountsView()
                .tabItem { Label("Accounts", systemImage: "building.columns.fill") }
        }
    }
}

/// Shows setup the first time a signed-in user has no accounts.
struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @AppStorage("setupSeenV2") private var setupSeen = false
    @EnvironmentObject private var lock: AppLock
    @State private var showSetup = false
    @State private var askFaceID = false

    var body: some View {
        MainTabView()
            .fullScreenCover(isPresented: $showSetup, onDismiss: { maybeAskFaceID() }) {
                OnboardingFlow {
                    setupSeen = true
                    showSetup = false
                }
            }
            .alert("Open Folio with \(lock.biometryName)?", isPresented: $askFaceID) {
                Button("Turn On") { Task { _ = await lock.enable() } }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("You're signed in. Next time, \(lock.biometryName) can open Folio instead of your password. You can change this in the profile menu.")
            }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-showOnboarding") { showSetup = true; return }
                #endif
                guard !auth.isDemo else { return }
                if !setupSeen {
                    showSetup = true
                    return
                }
                maybeAskFaceID()
            }
    }

    private func maybeAskFaceID() {
        guard !auth.isDemo, lock.isAvailable, !lock.hasAsked, !lock.isEnabled else { return }
        lock.hasAsked = true
        Task { try? await Task.sleep(for: .milliseconds(600)); askFaceID = true }
    }
}
