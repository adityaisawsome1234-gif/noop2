import Foundation
import FormaProtocol
import FormaFeatures

extension AppModel {
    /// Composition root for the iOS app: the Core Bluetooth central and iOS platform services.
    @MainActor
    static func makeForIOS() -> AppModel {
        let central = BLECentral(knownProfiles: AdapterRegistry.all.map(\.gatt))
        return AppModel(central: central, platform: IOSPlatformServices())
    }
}
