import Foundation

public let CBCentralManagerOptionRestoreIdentifierKey = "kCBInitOptionRestoreIdentifier"
public let CBCentralManagerOptionShowPowerAlertKey = "kCBInitOptionShowPowerAlert"
public let CBCentralManagerScanOptionAllowDuplicatesKey = "kCBScanOptionAllowDuplicates"
public let CBCentralManagerRestoredStatePeripheralsKey = "kCBRestoredPeripherals"
public let CBAdvertisementDataServiceUUIDsKey = "kCBAdvDataServiceUUIDs"
public let CBAdvertisementDataLocalNameKey = "kCBAdvDataLocalName"
public let CBAdvertisementDataManufacturerDataKey = "kCBAdvDataManufacturerData"
public let CBAdvertisementDataIsConnectable = "kCBAdvDataIsConnectable"
public let CBATTErrorDomain = "CBATTErrorDomain"

public enum CBManagerState: Int { case unknown = 0, resetting, unsupported, unauthorized, poweredOff, poweredOn }
public enum CBPeripheralState: Int { case disconnected = 0, connecting, connected, disconnecting }
public enum CBCharacteristicWriteType: Int { case withResponse = 0, withoutResponse }

public struct CBCharacteristicProperties: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let broadcast = CBCharacteristicProperties(rawValue: 0x01)
    public static let read = CBCharacteristicProperties(rawValue: 0x02)
    public static let writeWithoutResponse = CBCharacteristicProperties(rawValue: 0x04)
    public static let write = CBCharacteristicProperties(rawValue: 0x08)
    public static let notify = CBCharacteristicProperties(rawValue: 0x10)
    public static let indicate = CBCharacteristicProperties(rawValue: 0x20)
}

public struct CBATTError: Error {
    public enum Code: Int { case success = 0, invalidHandle, readNotPermitted, writeNotPermitted, invalidPdu, insufficientAuthentication,
                            requestNotSupported, invalidOffset, insufficientAuthorization, prepareQueueFull, attributeNotFound,
                            attributeNotLong, insufficientEncryptionKeySize, invalidAttributeValueLength, unlikelyError,
                            insufficientEncryption, unsupportedGroupType, insufficientResources }
}
public struct CBError: Error {
    public enum Code: Int { case unknown = 0, invalidParameters, invalidHandle, notConnected, outOfSpace, operationCancelled,
                            connectionTimeout, peripheralDisconnected, uuidNotAllowed, alreadyAdvertising, connectionFailed,
                            connectionLimitReached, unkownDevice, operationNotSupported, peerRemovedPairingInformation,
                            encryptionTimedOut, tooManyLEPairedDevices }
}

open class CBUUID: NSObject, @unchecked Sendable {
    public let uuidString: String
    public init(string: String) { uuidString = string.uppercased() }
}

open class CBAttribute: NSObject { open var uuid: CBUUID { CBUUID(string: "0000") } }

open class CBCharacteristic: CBAttribute, @unchecked Sendable {
    open var properties: CBCharacteristicProperties { [] }
    open var isNotifying: Bool { false }
    open var value: Data? { nil }
}

open class CBService: CBAttribute, @unchecked Sendable {
    open var characteristics: [CBCharacteristic]? { nil }
}

public protocol CBPeripheralDelegate: AnyObject {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?)
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?)
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral)
}

open class CBPeer: NSObject { open var identifier: UUID { UUID() } }

open class CBPeripheral: CBPeer, @unchecked Sendable {
    open weak var delegate: CBPeripheralDelegate?
    open var name: String? { nil }
    open var state: CBPeripheralState { .disconnected }
    open var services: [CBService]? { nil }
    open var canSendWriteWithoutResponse: Bool { true }
    open func discoverServices(_ serviceUUIDs: [CBUUID]?) {}
    open func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) {}
    open func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {}
    open func readValue(for characteristic: CBCharacteristic) {}
    open func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}
    open func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { 180 }
}

public protocol CBCentralManagerDelegate: AnyObject {
    func centralManagerDidUpdateState(_ central: CBCentralManager)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any])
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber)
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?)
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?)
}

open class CBManager: NSObject { open var state: CBManagerState { .unknown } }

open class CBCentralManager: CBManager {
    open weak var delegate: CBCentralManagerDelegate?
    open var isScanning: Bool { false }
    public init(delegate: CBCentralManagerDelegate?, queue: DispatchQueue?, options: [String: Any]? = nil) { self.delegate = delegate }
    open func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]? = nil) {}
    open func stopScan() {}
    open func connect(_ peripheral: CBPeripheral, options: [String: Any]? = nil) {}
    open func cancelPeripheralConnection(_ peripheral: CBPeripheral) {}
    open func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral] { [] }
    open func retrieveConnectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [CBPeripheral] { [] }
}
