import Foundation
import LocalAuthentication
import Observation

/// Optional Face ID / passcode lock for opening Forma. Off by default.
/// This is a privacy screen, not encryption: the data itself is protected by iOS file protection.
@MainActor
@Observable
final class AppLock {
    private(set) var isLocked: Bool
    private(set) var lastError: String?
    private(set) var isEnabled: Bool

    /// Explicit setter (property observers are avoided on @Observable stored properties).
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.key)
        if !enabled { isLocked = false }
    }

    private static let key = "forma.appLock.enabled"

    init() {
        let enabled = UserDefaults.standard.bool(forKey: Self.key)
        isEnabled = enabled
        isLocked = enabled
    }

    /// Lock again when the app moves to the background (called from scene phase changes).
    func lockIfEnabled() {
        if isEnabled { isLocked = true }
    }

    func unlock() async {
        guard isEnabled else { isLocked = false; return }
        let context = LAContext()
        var error: NSError?
        // deviceOwnerAuthentication falls back to the passcode when biometrics are unavailable.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = error?.localizedDescription ?? "Authentication is not available on this device."
            return
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Forma to view your health data.")
            if ok {
                isLocked = false
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
