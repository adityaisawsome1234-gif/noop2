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
/// The session is activated when the picker is first requested, the picker is shown once the session
/// reports `.activated`, and the session is invalidated when this controller goes away.
///
/// Forma never calls `removeAccessory`: removal unpairs the accessory system-wide (including from the
/// official app). "Forget band" in Forma only stops Forma from connecting.
@MainActor
@Observable
final class AccessorySetupController {
    static var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSAccessorySetupKitSupports") != nil
    }

    @ObservationIgnored private var session: ASAccessorySession?
    @ObservationIgnored private var activated = false
    /// Requested before the session reported `.activated`; shown as soon as it has.
    @ObservationIgnored private var pendingPicker: ASPickerDisplayItem?
    @ObservationIgnored private var onSelected: ((_ bluetoothIdentifier: String, _ name: String) -> Void)?
    private(set) var lastError: String?

    isolated deinit {
        session?.invalidate()
    }

    /// Shows the system accessory picker with a descriptor built from the Info.plist ASK keys.
    func showPicker(onSelected: @escaping (_ bluetoothIdentifier: String, _ name: String) -> Void) {
        guard Self.isConfigured, let descriptor = makeDescriptor() else { return }
        lastError = nil
        self.onSelected = onSelected
        let image = UIImage(systemName: "sensor.tag.radiowaves.forward") ?? UIImage()
        let item = ASPickerDisplayItem(name: "Your band", productImage: image, descriptor: descriptor)
        if activated {
            present(item)
        } else {
            pendingPicker = item
            activateIfNeeded()
        }
    }

    /// ASK requires a Bluetooth service UUID or company identifier, plus an accessory identifier; Forma uses
    /// a name substring (Apple's pages disagree on whether it is optional, so it is always required here).
    /// Every value comes from Info.plist, which ASK checks the descriptor against.
    private func makeDescriptor() -> ASDiscoveryDescriptor? {
        let info = Bundle.main
        let service = (info.object(forInfoDictionaryKey: "NSAccessorySetupBluetoothServices") as? [String])?.first
        let company = Self.companyIdentifiers(info.object(forInfoDictionaryKey: "NSAccessorySetupBluetoothCompanyIdentifiers")).first
        let name = (info.object(forInfoDictionaryKey: "NSAccessorySetupBluetoothNames") as? [String])?.first
        guard service != nil || company != nil, let name, !name.isEmpty else {
            lastError = "This build's AccessorySetupKit settings are incomplete. Info.plist needs NSAccessorySetupBluetoothServices or NSAccessorySetupBluetoothCompanyIdentifiers, and NSAccessorySetupBluetoothNames (docs/BUILD_AND_INSTALL.md §6)."
            return nil
        }
        let descriptor = ASDiscoveryDescriptor()
        if let service { descriptor.bluetoothServiceUUID = CBUUID(string: service) }
        if let company { descriptor.bluetoothCompanyIdentifier = ASBluetoothCompanyIdentifier(company) }
        descriptor.bluetoothNameSubstring = name
        return descriptor
    }

    /// `NSAccessorySetupBluetoothCompanyIdentifiers` entries: numbers, or strings in hex with or without a
    /// "0x" prefix (company identifiers are written in hex, as Forma's Diagnostics shows them).
    nonisolated static func companyIdentifiers(_ value: Any?) -> [UInt16] {
        guard let entries = value as? [Any] else { return [] }
        return entries.compactMap { entry -> UInt16? in
            if let number = entry as? Int { return UInt16(exactly: number) }
            guard let text = entry as? String else { return nil }
            var hex = text.trimmingCharacters(in: .whitespaces)
            if hex.lowercased().hasPrefix("0x") { hex.removeFirst(2) }
            return UInt16(hex, radix: 16)
        }
    }

    private func activateIfNeeded() {
        guard session == nil else { return }
        let session = ASAccessorySession()
        self.session = session
        session.activate(on: DispatchQueue.main) { [weak self] event in
            // Delivered on the main queue passed above.
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func present(_ item: ASPickerDisplayItem) {
        session?.showPicker(for: [item]) { [weak self] error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in self?.lastError = message }
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            activated = true
            if let item = pendingPicker {
                pendingPicker = nil
                present(item)
            }
        case .accessoryAdded, .accessoryChanged:
            // One selection per picker (an added accessory can also report a change right after).
            guard let accessory = event.accessory, let id = accessory.bluetoothIdentifier, let onSelected else { return }
            self.onSelected = nil
            onSelected(id.uuidString, accessory.displayName)
        case .invalidated:
            activated = false
            session = nil
        default:
            break
        }
    }
}
