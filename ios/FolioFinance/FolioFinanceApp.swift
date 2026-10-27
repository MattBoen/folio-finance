import SwiftUI

@main
struct FolioFinanceApp: App {
    @StateObject private var authManager = AuthManager()
    @StateObject private var lock = AppLock()
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

                // Hides balances in the app switcher and behind Face ID.
                if scenePhase != .active || lock.isLocked {
                    if lock.isLocked && authManager.isAuthenticated { LockView().transition(.opacity) }
                    else if scenePhase != .active && authManager.isAuthenticated { PrivacyCover() }
                }
            }
            .environmentObject(authManager)
            .environmentObject(lock)
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-showOnboarding") { authManager.startDemo() }
                #endif
                await APIClient.shared.warmUp()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: lock.didEnterBackground()
                case .active: lock.didBecomeActive(authenticated: authManager.isAuthenticated && !authManager.isDemo)
                default: break
                }
            }
            .onChange(of: authManager.isAuthenticated) { _, signedIn in
                if !signedIn { lock.clear() }
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
