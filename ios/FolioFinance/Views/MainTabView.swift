import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("Overview", systemImage: "square.grid.2x2.fill") }

            SpendingView()
                .tabItem { Label("Spending", systemImage: "chart.pie.fill") }

            TransactionsView()
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle.fill") }

            AccountsView()
                .tabItem { Label("Accounts", systemImage: "building.columns.fill") }
        }
    }
}
