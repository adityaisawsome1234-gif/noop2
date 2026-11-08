import Foundation
import UIKit
import CoreBluetooth
import FormaProtocol
import FormaFeatures

extension AppModel {
    /// Composition root for the iOS app: the Core Bluetooth central and iOS platform services.
    ///
    /// Creating a `CBCentralManager` shows the system Bluetooth permission prompt while permission has not
    /// been decided. On a first run that would put the prompt over the privacy page, before onboarding has
    /// explained why Forma needs Bluetooth, so the central is then created on first use (onboarding's "Allow
    /// Bluetooth" step or a band scan). Once permission was decided either way — which includes every
    /// relaunch by iOS for a Bluetooth event — it is created at process start, as state restoration needs.
    ///
    /// The central gets the model's union connection profile up front, so a connection iOS restores is set up
    /// (and its notifications kept) without waiting for the model to ask for it.
    @MainActor
    static func makeForIOS() -> AppModel {
        let profiles = AdapterRegistry.all.map(\.gatt)
        let defaultProfile = AppModel.connectionProfile
        let central: any BandCentral
        if CBManager.authorization == .notDetermined {
            central = DeferredBandCentral { BLECentral(knownProfiles: profiles, defaultProfile: defaultProfile) }
        } else {
            central = BLECentral(knownProfiles: profiles, defaultProfile: defaultProfile)
        }
        let model = AppModel(central: central, platform: IOSPlatformServices())
        // A Bluetooth relaunch starts the process in the background, possibly with no UI scene at all.
        // Tell the model before its first refresh runs, so a background wake computes no screens.
        if UIApplication.shared.applicationState == .background {
            model.sceneEnteredBackground()
        }
        return model
    }
}

/// A `BandCentral` that creates the real `BLECentral` (and with it the `CBCentralManager`) the first
/// time Bluetooth is actually needed. Calls that only stop something that never started do not create it.
final class DeferredBandCentral: BandCentral, @unchecked Sendable {
    private let lock = NSLock()
    private let make: @Sendable () -> BLECentral
    private var central: BLECentral?
    private var handler: (@Sendable (CentralEvent) -> Void)?

    init(make: @escaping @Sendable () -> BLECentral) {
        self.make = make
    }

    /// The real central, created (and given the event handler) on first use.
    private func resolved() -> BLECentral {
        let (central, newHandler): (BLECentral, (@Sendable (CentralEvent) -> Void)?) = lock.withLock {
            if let existing = self.central { return (existing, nil) }
            let created = make()
            self.central = created
            return (created, self.handler)
        }
        if let newHandler { central.setEventHandler(newHandler) }
        return central
    }

    /// The real central if it exists already.
    private var existing: BLECentral? { lock.withLock { central } }

    func connectSelected(profile: GATTProfile) { resolved().connectSelected(profile: profile) }
    func disconnect() { existing?.disconnect() }
    func select(peripheralID: String, profile: GATTProfile) { resolved().select(peripheralID: peripheralID, profile: profile) }
    func forgetSelected() {
        // Without a central there is no connection to cancel; only the saved selection is cleared (creating
        // the central here would show the permission prompt for nothing).
        if let existing { existing.forgetSelected() } else { BLECentral.forgetSavedPeripheral() }
    }
    func startScan(includeUnfiltered: Bool) { resolved().startScan(includeUnfiltered: includeUnfiltered) }
    func stopScan() { existing?.stopScan() }

    var savedPeripheralID: String? { existing?.savedPeripheralID ?? BLECentral.savedPeripheralUUID?.uuidString }

    func setEventHandler(_ handler: @escaping @Sendable (CentralEvent) -> Void) {
        let current: BLECentral? = lock.withLock {
            self.handler = handler
            return central
        }
        current?.setEventHandler(handler)
    }
}
