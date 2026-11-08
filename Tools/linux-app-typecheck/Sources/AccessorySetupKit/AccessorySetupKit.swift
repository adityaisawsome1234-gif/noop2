import Foundation
import CoreBluetooth
import UIKit
/// A 16-bit Bluetooth company identifier. Modelled as the struct a typed extensible enum over `uint16_t` imports
/// as; the app only calls `ASBluetoothCompanyIdentifier(_:)` with a `UInt16`, which compiles for that struct and
/// for a plain `UInt16` typealias alike (the SDK's exact import shape is unconfirmed here).
public struct ASBluetoothCompanyIdentifier: Hashable, RawRepresentable, Sendable {
    public var rawValue: UInt16
    public init(_ rawValue: UInt16) { self.rawValue = rawValue }
    public init(rawValue: UInt16) { self.rawValue = rawValue }
}
open class ASDiscoveryDescriptor: NSObject, @unchecked Sendable {
    open var bluetoothCompanyIdentifier: ASBluetoothCompanyIdentifier = ASBluetoothCompanyIdentifier(0)
    open var bluetoothServiceUUID: CBUUID?
    open var bluetoothNameSubstring: String?
    public override init() {}
}
open class ASPickerDisplayItem: NSObject, @unchecked Sendable {
    public init(name: String, productImage: UIImage, descriptor: ASDiscoveryDescriptor) {}
}
open class ASAccessory: NSObject, @unchecked Sendable {
    open var bluetoothIdentifier: UUID? { nil }
    open var displayName: String { "" }
}
public enum ASAccessoryEventType: Int { case unknown = 0, activated, invalidated, migrationComplete, accessoryAdded, accessoryRemoved, accessoryChanged, pickerDidPresent, pickerDidDismiss }
open class ASAccessoryEvent: NSObject, @unchecked Sendable {
    open var eventType: ASAccessoryEventType { .unknown }
    open var accessory: ASAccessory? { nil }
}
open class ASAccessorySession: NSObject, @unchecked Sendable {
    public override init() {}
    open func activate(on queue: DispatchQueue, eventHandler: @escaping (ASAccessoryEvent) -> Void) {}
    open func showPicker(for displayItems: [ASPickerDisplayItem], completionHandler: @escaping (Error?) -> Void) {}
    open func invalidate() {}
}
