import Foundation
import Security

final class KeychainService: Sendable {
    static let shared = KeychainService()

    private let service = "com.mattboen.foliofinance"

    func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Face ID app lock

import LocalAuthentication
import SwiftUI

@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false

    private let enabledKey = "faceIDLockEnabled"
    private var backgroundedAt: Date?
    /// How long the app can sit in the background before it asks again.
    private let grace: TimeInterval = 30

    init() {
        let enabled = UserDefaults.standard.bool(forKey: "faceIDLockEnabled")
        let signedIn = KeychainService.shared.load(key: "access_token") != nil
        isLocked = enabled && signedIn && LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey); objectWillChange.send() }
    }

    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    /// True when this device has Face ID / Touch ID / a passcode that can unlock the app.
    var isAvailable: Bool { canAuthenticate }

    var hasAsked: Bool {
        get { UserDefaults.standard.bool(forKey: "faceIDAsked") }
        set { UserDefaults.standard.set(newValue, forKey: "faceIDAsked") }
    }

    /// Turns the lock on after the user proves it works (this also triggers the system permission prompt).
    func enable() async -> Bool {
        let ctx = LAContext()
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Turn on \(biometryName) for Folio")
            if ok { isEnabled = true }
            return ok
        } catch { return false }
    }

    private var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func lockOnLaunch(authenticated: Bool) {
        isLocked = authenticated && isEnabled && canAuthenticate
    }

    func didEnterBackground() { backgroundedAt = Date() }

    func didBecomeActive(authenticated: Bool) {
        defer { backgroundedAt = nil }
        guard authenticated, isEnabled, canAuthenticate, let at = backgroundedAt else { return }
        if Date().timeIntervalSince(at) > grace { isLocked = true }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your finances")
            if ok { isLocked = false }
        } catch {
            // stay locked; the user can tap to try again
        }
        isAuthenticating = false
    }

    func clear() { isLocked = false }
}

struct LockView: View {
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        ZStack {
            Wash(tone: .balance)
            VStack(spacing: 22) {
                Spacer()
                BrandMark(size: 84)
                Text("Folio is locked").font(.title2.bold())
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Unlock with \(lock.biometryName)", systemImage: lock.biometryName == "Passcode" ? "lock.open.fill" : "faceid")
                        .font(.headline).frame(height: 30).padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Spacer()
                Button("Sign out", role: .destructive) { auth.logout(); lock.clear() }
                    .font(.footnote)
                    .padding(.bottom, 24)
            }
        }
        .task { await lock.unlock() }
    }
}
