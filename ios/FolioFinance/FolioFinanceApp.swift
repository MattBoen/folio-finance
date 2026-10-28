import SwiftUI

@main
struct FolioFinanceApp: App {
    @StateObject private var authManager = AuthManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                Group {
                    if authManager.isAuthenticated {
                        RootView().transition(.opacity)
                    } else {
                        LoginView().transition(.opacity)
                    }
                }
                .animation(.smooth, value: authManager.isAuthenticated)

                // Hides balances in the app switcher.
                if scenePhase != .active && authManager.isAuthenticated { PrivacyCover() }
            }
            .environmentObject(authManager)
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-showOnboarding") { authManager.startDemo() }
                #endif
                await APIClient.shared.warmUp()
            }
        }
    }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Wash(tone: .balance)
            BrandMark(size: 84)
        }
    }
}
