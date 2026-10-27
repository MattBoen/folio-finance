import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0

    init() {
        // Native opaque tab bar — matches Wallet, Health, Stocks style
        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = UIColor.systemBackground
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar

        // Large-title nav bar with cream tint for non-slate screens
        let navBar = UINavigationBarAppearance()
        navBar.configureWithDefaultBackground()
        UINavigationBar.appearance().standardAppearance = navBar
        UINavigationBar.appearance().scrollEdgeAppearance = navBar
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            OverviewView()
                .tabItem { Label("Overview", systemImage: "house.fill") }
                .tag(0)

            AccountsView()
                .tabItem { Label("Accounts", systemImage: "creditcard.fill") }
                .tag(1)

            TransactionsView()
                .tabItem { Label("Transactions", systemImage: "list.bullet.rectangle.fill") }
                .tag(2)

            BudgetView()
                .tabItem { Label("Budget", systemImage: "chart.bar.xaxis") }
                .tag(3)
        }
        .tint(Color.folioAmber)
    }
}
