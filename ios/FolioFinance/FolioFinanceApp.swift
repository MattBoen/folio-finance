import SwiftUI

@main
struct FolioFinanceApp: App {
    @StateObject private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isAuthenticated {
                    MainTabView()
                        .transition(.opacity)
                } else {
                    LoginView()
                        .transition(.opacity)
                }
            }
            .animation(.smooth, value: authManager.isAuthenticated)
            .environmentObject(authManager)
        }
    }
}
