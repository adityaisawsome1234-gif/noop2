import Foundation
public enum LAPolicy: Int { case deviceOwnerAuthenticationWithBiometrics = 1, deviceOwnerAuthentication = 2 }
public let LAErrorDomain = "com.apple.LocalAuthentication"
/// Bridged NSError of `LAErrorDomain` in the real SDK; only the codes the app checks are listed here.
public struct LAError: Error {
    public enum Code: Int {
        case authenticationFailed = -1, userCancel = -2, userFallback = -3, systemCancel = -4, passcodeNotSet = -5,
             biometryNotAvailable = -6, biometryNotEnrolled = -7, biometryLockout = -8, appCancel = -9, invalidContext = -10,
             notInteractive = -1004
    }
}
open class LAContext: NSObject {
    public override init() {}
    open func canEvaluatePolicy(_ policy: LAPolicy, error: UnsafeMutablePointer<NSError?>?) -> Bool { true }
    open func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool { true }
}
