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
    ///
    /// The lock turns on only when this iPhone can authenticate its owner (a device passcode is set);
    /// otherwise Forma would lock itself with no way back in, since the switch to turn it off is behind the
    /// lock. Returns whether the setting changed; when it did not, `lastError` says why.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            var error: NSError?
            guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                lastError = Self.isPasscodeNotSet(error)
                    ? "App Lock needs a device passcode. Set one in Settings → Face ID & Passcode, then turn App Lock on."
                    : "App Lock can't be turned on: \(error?.localizedDescription ?? "this iPhone can't authenticate its owner.")"
                return false
            }
        }
        isEnabled = enabled
        lastError = nil
        UserDefaults.standard.set(enabled, forKey: Self.key)
        if !enabled { isLocked = false }
        return true
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
            if Self.isPasscodeNotSet(error) {
                // The passcode was removed after App Lock was turned on. With nothing to authenticate against
                // the lock protects nothing, and keeping it closed would only lock the owner out. It applies
                // again once a passcode is set.
                isLocked = false
                lastError = nil
                return
            }
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
            // A prompt cancelled by the user, by iOS or because Forma left the foreground is not an error to
            // show: the Unlock button simply asks again.
            lastError = Self.isCancellation(error) ? nil : error.localizedDescription
        }
    }

    private static func isPasscodeNotSet(_ error: Error?) -> Bool {
        laErrorCode(error) == LAError.Code.passcodeNotSet.rawValue
    }

    private static func isCancellation(_ error: Error) -> Bool {
        guard let code = laErrorCode(error) else { return false }
        let cancellations: [LAError.Code] = [.userCancel, .systemCancel, .appCancel, .notInteractive]
        return cancellations.contains { $0.rawValue == code }
    }

    private static func laErrorCode(_ error: Error?) -> Int? {
        guard let error = error as NSError?, error.domain == LAErrorDomain else { return nil }
        return error.code
    }
}
