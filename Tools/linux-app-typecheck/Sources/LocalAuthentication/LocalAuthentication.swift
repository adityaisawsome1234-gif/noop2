import Foundation
public enum LAPolicy: Int { case deviceOwnerAuthenticationWithBiometrics = 1, deviceOwnerAuthentication = 2 }
open class LAContext: NSObject {
    public override init() {}
    open func canEvaluatePolicy(_ policy: LAPolicy, error: UnsafeMutablePointer<NSError?>?) -> Bool { true }
    open func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool { true }
}
