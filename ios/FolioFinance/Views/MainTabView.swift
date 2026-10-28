import SwiftUI

struct MainTabView: View {
    @StateObject private var router = TabRouter()

    var body: some View {
        TabView(selection: $router.selected) {
            OverviewView()
                .tabItem { Label("Overview", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.overview)

            SpendingView()
                .tabItem { Label("Spending", systemImage: "chart.pie.fill") }
                .tag(AppTab.spending)

            PlanView()
                .tabItem { Label("Budget", systemImage: "dollarsign.circle.fill") }
                .tag(AppTab.budget)

            MoneyView()
                .tabItem { Label("Money", systemImage: "creditcard.fill") }
                .tag(AppTab.money)

            AskView()
                .tabItem { Label("Ask Folio", systemImage: "text.bubble.fill") }
                .tag(AppTab.ask)
        }
        .environmentObject(router)
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
