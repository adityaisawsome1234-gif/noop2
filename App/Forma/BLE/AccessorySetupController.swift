import Foundation
import UIKit
import CoreBluetooth
import AccessorySetupKit
import Observation

/// Optional AccessorySetupKit (ASK) integration.
///
/// Active only when Info.plist declares `NSAccessorySetupKitSupports` (see docs/BUILD_AND_INSTALL.md §6).
/// With ASK, the system picker grants Forma access to exactly the chosen accessory and — on iOS 26 and
/// later — lets iOS relaunch Forma for Bluetooth events even after a user force-quit (TN3115 note 5).
/// In ASK mode Core Bluetooth only sees accessories chosen in this picker.
///
/// Forma never calls `removeAccessory`: removal unpairs the accessory system-wide (including from the
/// official app). "Forget band" in Forma only stops Forma from connecting.
@MainActor
@Observable
final class AccessorySetupController {
    static var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSAccessorySetupKitSupports") != nil
    }

    @ObservationIgnored private let session = ASAccessorySession()
    @ObservationIgnored private var activated = false
    @ObservationIgnored private var onSelected: ((_ bluetoothIdentifier: String, _ name: String) -> Void)?
    private(set) var lastError: String?

    func activateIfNeeded() {
        guard Self.isConfigured, !activated else { return }
        activated = true
        session.activate(on: DispatchQueue.main) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    /// Shows the system accessory picker with a descriptor built from the Info.plist ASK keys.
    func showPicker(onSelected: @escaping (_ bluetoothIdentifier: String, _ name: String) -> Void) {
        activateIfNeeded()
        self.onSelected = onSelected
        let descriptor = ASDiscoveryDescriptor()
        if let services = Bundle.main.object(forInfoDictionaryKey: "NSAccessorySetupBluetoothServices") as? [String],
           let first = services.first {
            descriptor.bluetoothServiceUUID = CBUUID(string: first)
        }
        if let names = Bundle.main.object(forInfoDictionaryKey: "NSAccessorySetupBluetoothNames") as? [String],
           let first = names.first {
            descriptor.bluetoothNameSubstring = first
        }
        let image = UIImage(systemName: "sensor.tag.radiowaves.forward") ?? UIImage()
        let item = ASPickerDisplayItem(name: "Your band", productImage: image, descriptor: descriptor)
        session.showPicker(for: [item]) { [weak self] error in
            if let error {
                Task { @MainActor in self?.lastError = error.localizedDescription }
            }
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .accessoryAdded, .accessoryChanged:
            guard let accessory = event.accessory, let id = accessory.bluetoothIdentifier else { return }
            onSelected?(id.uuidString, accessory.displayName)
        default:
            break
        }
    }
}
