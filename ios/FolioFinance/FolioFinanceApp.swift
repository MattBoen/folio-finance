import SwiftUI

@main
struct FolioFinanceApp: App {
    @StateObject private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isAuthenticated {
                    MainTabView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(authManager)
            .preferredColorScheme(.light)
        }
    }
}
