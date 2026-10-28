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
    @State private var showSetup = false

    var body: some View {
        MainTabView()
            .fullScreenCover(isPresented: $showSetup) {
                OnboardingFlow {
                    auth.markSetupSeen()
                    showSetup = false
                }
            }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-showOnboarding") { showSetup = true; return }
                #endif
                guard !auth.isDemo else { return }
                if !auth.hasSeenSetup {
                    showSetup = true
                    return
                }
            }
    }

}
