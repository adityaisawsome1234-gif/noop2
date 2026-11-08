import Foundation
import CoreBluetooth
import FormaCore
import FormaProtocol
import FormaSync
import FormaFeatures

/// Events from the central to the app model (delivered on the main actor).
enum CentralEvent: Sendable {
    case stateChanged(LinkState)
    case bluetoothProblem(String?)
    case discovered(DiscoveredDevice, advertisement: [String: String])
    case scanStopped
    case linkReady(CoreBluetoothLink, services: [GATTServiceSummary])
    case connectionEvent(ConnectionEvent)
    case pairingProblem(String)
}

/// Owns the app's single `CBCentralManager`.
///
/// - Created once at process start with a constant restoration identifier (iOS 27 scene-based apps get
///   no launch options, so the identifier is never derived from them).
/// - Reconnects by keeping a pending `connect()` outstanding (pending connects never time out); applies
///   backoff only after connection *failures*.
/// - Scans only when the user is choosing a band: filtered by service UUIDs, time-boxed to 30 s.
///   Unfiltered scanning is offered only explicitly, in the foreground.
/// - All Core Bluetooth calls happen on `queue`, the same serial queue that receives delegate callbacks.
final class BLECentral: NSObject, @unchecked Sendable {
    static let restoreIdentifier = "com.forma.central.v1"
    private static let selectedPeripheralKey = "forma.selectedPeripheralID"

    let queue = DispatchQueue(label: "com.forma.ble", qos: .userInitiated)
    private var central: CBCentralManager!
    private let onEvent: @Sendable (CentralEvent) -> Void

    // State below is only touched on `queue`.
    private var target: CBPeripheral?
    private var targetProfile: GATTProfile?
    private var wantConnected = false
    private var consecutiveFailures = 0
    private let reconnectPolicy = ReconnectPolicy()
    private var link: CoreBluetoothLink?
    private var pendingNotifyConfirmations: Set<CBUUID> = []
    private var discoveredForScan: [UUID: CBPeripheral] = [:]
    private var scanStopWork: DispatchWorkItem?
    private var characteristicsByUUID: [String: CBCharacteristic] = [:]
    private var pendingServiceDiscoveries = 0

    /// Profiles the app knows how to drive. Used for scan filters and post-discovery adapter selection.
    let knownProfiles: [GATTProfile]

    init(knownProfiles: [GATTProfile], onEvent: @escaping @Sendable (CentralEvent) -> Void) {
        self.knownProfiles = knownProfiles
        self.onEvent = onEvent
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    // MARK: Persistence of the selected band

    static var savedPeripheralID: UUID? {
        guard let s = UserDefaults.standard.string(forKey: selectedPeripheralKey) else { return nil }
        return UUID(uuidString: s)
    }

    private static func savePeripheralID(_ id: UUID?) {
        if let id { UserDefaults.standard.set(id.uuidString, forKey: selectedPeripheralKey) }
        else { UserDefaults.standard.removeObject(forKey: selectedPeripheralKey) }
    }

    // MARK: Public API (thread-safe; hops to `queue`)

    /// Start keeping the selected band connected (collection on).
    func connectSelected(profile: GATTProfile) {
        queue.async {
            self.targetProfile = profile
            self.wantConnected = true
            self.consecutiveFailures = 0
            self.establishConnection()
        }
    }

    /// Stop collection: cancel the pending/active connection. (Other apps may keep their own link.)
    func disconnect() {
        queue.async {
            self.wantConnected = false
            if let p = self.target { self.central.cancelPeripheralConnection(p) }
        }
    }

    func select(peripheralID: UUID, profile: GATTProfile) {
        queue.async {
            Self.savePeripheralID(peripheralID)
            if let current = self.target, current.identifier != peripheralID {
                self.central.cancelPeripheralConnection(current)
                self.target = nil
            }
            self.target = self.discoveredForScan[peripheralID]
                ?? self.central.retrievePeripherals(withIdentifiers: [peripheralID]).first
            self.targetProfile = profile
        }
    }

    func forgetSelected() {
        queue.async {
            self.wantConnected = false
            if let p = self.target { self.central.cancelPeripheralConnection(p) }
            self.target = nil
            Self.savePeripheralID(nil)
        }
    }

    func startScan(includeUnfiltered: Bool) {
        queue.async {
            guard self.central.state == .poweredOn else {
                self.onEvent(.bluetoothProblem(Self.describe(self.central.state)))
                return
            }
            self.central.stopScan()
            self.discoveredForScan.removeAll()
            // Bands already connected to this iPhone (e.g. by another app) do not need to advertise.
            let connectedServices = self.knownProfiles.flatMap { [$0.vendorService].compactMap { $0 } } + [UUIDs.heartRateService]
            let connected = self.central.retrieveConnectedPeripherals(withServices: connectedServices.map { CBUUID(string: $0) })
            for p in connected {
                self.discoveredForScan[p.identifier] = p
                let device = DiscoveredDevice(id: p.identifier.uuidString, name: p.name, rssi: nil, family: self.family(name: p.name, services: []),
                                              advertisedServiceUUIDs: [], manufacturerDataHex: nil, connectedToThisPhone: true,
                                              lastSeen: EpochMillis(date: Date()))
                self.onEvent(.discovered(device, advertisement: [:]))
            }
            let filter: [CBUUID]? = includeUnfiltered ? nil
                : Array(Set(self.knownProfiles.flatMap { $0.scanServiceFilter } + [UUIDs.heartRateService])).map { CBUUID(string: $0) }
            self.central.scanForPeripherals(withServices: filter, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            self.onEvent(.connectionEvent(ConnectionEvent(deviceID: nil, timestamp: EpochMillis(date: Date()), kind: .scanStarted,
                                                          detail: includeUnfiltered ? "unfiltered (foreground)" : "filtered")))
            self.scanStopWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.stopScanOnQueue() }
            self.scanStopWork = work
            self.queue.asyncAfter(deadline: .now() + 30, execute: work)
        }
    }

    func stopScan() {
        queue.async { self.stopScanOnQueue() }
    }

    private func stopScanOnQueue() {
        scanStopWork?.cancel()
        scanStopWork = nil
        if central.isScanning {
            central.stopScan()
            onEvent(.connectionEvent(ConnectionEvent(deviceID: nil, timestamp: EpochMillis(date: Date()), kind: .scanStopped)))
        }
        onEvent(.scanStopped)
    }

    // MARK: Connection management (on queue)

    private func establishConnection() {
        guard wantConnected, central.state == .poweredOn else { return }
        if target == nil, let id = Self.savedPeripheralID {
            target = central.retrievePeripherals(withIdentifiers: [id]).first
        }
        guard let p = target else {
            onEvent(.stateChanged(.noDeviceSelected))
            return
        }
        p.delegate = self
        switch p.state {
        case .connected:
            discover(p)
        case .connecting:
            onEvent(.stateChanged(.connecting))
        default:
            onEvent(.stateChanged(.searching))
            central.connect(p, options: nil) // pending connect: completes whenever the band is in range
            onEvent(.connectionEvent(ConnectionEvent(deviceID: p.identifier.uuidString, timestamp: EpochMillis(date: Date()), kind: .connecting)))
        }
    }

    private func discover(_ p: CBPeripheral) {
        guard let profile = targetProfile else { return }
        characteristicsByUUID.removeAll()
        pendingNotifyConfirmations.removeAll()
        onEvent(.stateChanged(.connecting))
        // Reuse already-discovered services (e.g. after state restoration).
        if let services = p.services, !services.isEmpty {
            pendingServiceDiscoveries = services.count
            for s in services {
                if let chars = s.characteristics, !chars.isEmpty {
                    register(chars, on: p)
                    pendingServiceDiscoveries -= 1
                } else {
                    p.discoverCharacteristics(nil, for: s)
                }
            }
            if pendingServiceDiscoveries == 0 { subscribe(p) }
            return
        }
        p.discoverServices(profile.discoverServices.map { CBUUID(string: $0) })
    }

    private func register(_ characteristics: [CBCharacteristic], on p: CBPeripheral) {
        for c in characteristics {
            characteristicsByUUID[UUIDs.normalize(c.uuid.uuidString)] = c
        }
    }

    private func subscribe(_ p: CBPeripheral) {
        guard let profile = targetProfile else { return }
        for uuid in profile.subscribeCharacteristics {
            guard let c = characteristicsByUUID[uuid], c.properties.contains(.notify) || c.properties.contains(.indicate) else { continue }
            if c.isNotifying { continue }
            pendingNotifyConfirmations.insert(c.uuid)
            p.setNotifyValue(true, for: c)
        }
        // One-shot reads: device information and battery level (decoded by the adapter like notifications).
        for uuid in [UUIDs.firmwareRevision, UUIDs.hardwareRevision, UUIDs.modelNumber, UUIDs.manufacturerName, UUIDs.batteryLevel] {
            if let c = characteristicsByUUID[uuid], c.properties.contains(.read) { p.readValue(for: c) }
        }
        if pendingNotifyConfirmations.isEmpty { finishSetup(p) }
    }

    private func finishSetup(_ p: CBPeripheral) {
        var services: [String: [String]] = [:]
        var summaries: [GATTServiceSummary] = []
        for s in p.services ?? [] {
            let sid = UUIDs.normalize(s.uuid.uuidString)
            let chars = s.characteristics ?? []
            services[sid] = chars.map { UUIDs.normalize($0.uuid.uuidString) }
            summaries.append(GATTServiceSummary(uuid: sid, name: Self.name(for: sid), characteristics: chars.map {
                GATTCharacteristicSummary(uuid: UUIDs.normalize($0.uuid.uuidString), name: Self.name(for: UUIDs.normalize($0.uuid.uuidString)),
                                          properties: Self.describe($0.properties), notifying: $0.isNotifying)
            }))
        }
        let newLink = CoreBluetoothLink(peripheral: p, queue: queue, characteristics: characteristicsByUUID)
        link?.close(reason: "replaced by new connection", at: EpochMillis(date: Date()))
        link = newLink
        newLink.emit(.ready(services: services))
        consecutiveFailures = 0
        onEvent(.stateChanged(.connected))
        onEvent(.connectionEvent(ConnectionEvent(deviceID: p.identifier.uuidString, timestamp: EpochMillis(date: Date()), kind: .servicesDiscovered,
                                                 detail: "\(services.count) services")))
        onEvent(.linkReady(newLink, services: summaries))
    }

    private func scheduleReconnect(after failure: Bool) {
        guard wantConnected else { return }
        if failure { consecutiveFailures += 1 }
        let delay = reconnectPolicy.delay(afterFailures: failure ? consecutiveFailures : 0, jitterUnit: Double.random(in: 0..<1))
        if delay > 0 {
            onEvent(.connectionEvent(ConnectionEvent(deviceID: target?.identifier.uuidString, timestamp: EpochMillis(date: Date()),
                                                     kind: .reconnectScheduled, detail: "in \(Int(delay)) s")))
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.establishConnection() }
    }

    // MARK: Helpers

    func family(name: String?, services: [String]) -> DeviceFamily {
        let normalized = services.map(UUIDs.normalize)
        for profile in knownProfiles {
            if let vendor = profile.vendorService, normalized.contains(vendor) {
                return vendor.hasPrefix("FD4B0001") ? .whoop5 : (vendor.hasPrefix("61080001") ? .whoop4 : .unknown)
            }
        }
        if normalized.contains(UUIDs.heartRateService) { return .standardHeartRate }
        return .unknown
    }

    static func describe(_ state: CBManagerState) -> String? {
        switch state {
        case .poweredOn: return nil
        case .poweredOff: return "Bluetooth is off. Turn it on in Control Center or Settings."
        case .unauthorized: return "Forma is not allowed to use Bluetooth. Enable it in Settings → Privacy & Security → Bluetooth."
        case .unsupported: return "This device does not support Bluetooth Low Energy."
        case .resetting: return "Bluetooth is restarting…"
        case .unknown: return "Bluetooth state is not known yet."
        @unknown default: return "Bluetooth is unavailable."
        }
    }

    static func linkState(for state: CBManagerState) -> LinkState? {
        switch state {
        case .poweredOn: return nil
        case .poweredOff: return .bluetoothUnavailable(.poweredOff)
        case .unauthorized: return .bluetoothUnavailable(.unauthorized)
        case .unsupported: return .bluetoothUnavailable(.unsupported)
        case .resetting: return .bluetoothUnavailable(.resetting)
        case .unknown: return .bluetoothUnavailable(.unknown)
        @unknown default: return .bluetoothUnavailable(.unknown)
        }
    }

    static func describe(_ p: CBCharacteristicProperties) -> [String] {
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("writeNoResponse") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out
    }

    static func name(for uuid: String) -> String {
        switch uuid {
        case UUIDs.heartRateService: return "Heart Rate"
        case UUIDs.heartRateMeasurement: return "Heart Rate Measurement"
        case UUIDs.bodySensorLocation: return "Body Sensor Location"
        case UUIDs.batteryService: return "Battery"
        case UUIDs.batteryLevel: return "Battery Level"
        case UUIDs.deviceInformationService: return "Device Information"
        case UUIDs.firmwareRevision: return "Firmware Revision"
        case UUIDs.hardwareRevision: return "Hardware Revision"
        case UUIDs.modelNumber: return "Model Number"
        case UUIDs.manufacturerName: return "Manufacturer Name"
        default: return uuid.hasPrefix("FD4B") || uuid.hasPrefix("6108") ? "Vendor" : "Other"
        }
    }

    static func isPairingError(_ error: Error?) -> Bool {
        guard let error = error as NSError?, error.domain == CBATTErrorDomain else { return false }
        return error.code == CBATTError.Code.insufficientAuthentication.rawValue
            || error.code == CBATTError.Code.insufficientEncryption.rawValue
            || error.code == CBATTError.Code.insufficientEncryptionKeySize.rawValue
    }
}

// MARK: - CBCentralManagerDelegate

extension BLECentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onEvent(.bluetoothProblem(Self.describe(central.state)))
        if let unavailable = Self.linkState(for: central.state) {
            onEvent(.stateChanged(unavailable))
            onEvent(.connectionEvent(ConnectionEvent(deviceID: target?.identifier.uuidString, timestamp: EpochMillis(date: Date()),
                                                     kind: central.state == .poweredOff ? .bluetoothOff : .unauthorized,
                                                     detail: Self.describe(central.state))))
            link?.close(reason: "Bluetooth unavailable", at: EpochMillis(date: Date()))
            link = nil
            return
        }
        onEvent(.connectionEvent(ConnectionEvent(deviceID: target?.identifier.uuidString, timestamp: EpochMillis(date: Date()), kind: .bluetoothOn)))
        establishConnection()
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        let saved = Self.savedPeripheralID
        if let p = restored.first(where: { $0.identifier == saved }) ?? restored.first {
            target = p
            p.delegate = self
            wantConnected = true
        }
        onEvent(.connectionEvent(ConnectionEvent(deviceID: target?.identifier.uuidString, timestamp: EpochMillis(date: Date()),
                                                 kind: .restoredByOS, detail: "\(restored.count) peripheral(s)")))
        // Remaining work happens in centralManagerDidUpdateState(.poweredOn) → establishConnection().
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discoveredForScan[peripheral.identifier] = peripheral
        let services = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).map { UUIDs.normalize($0.uuidString) }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { $0.map { String(format: "%02x", $0) }.joined() }
        var adv: [String: String] = [:]
        adv["name"] = name ?? ""
        adv["services"] = services.joined(separator: ", ")
        if let mfg {
            adv["manufacturerData"] = mfg
            if mfg.count >= 4 {
                // Company identifier = first two bytes, little-endian.
                let chars = Array(mfg)
                adv["companyID"] = "0x" + String(chars[2...3]) + String(chars[0...1])
            }
        }
        if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber {
            adv["connectable"] = connectable.boolValue ? "yes" : "no"
        }
        let device = DiscoveredDevice(id: peripheral.identifier.uuidString, name: name, rssi: RSSI.intValue,
                                      family: family(name: name, services: services), advertisedServiceUUIDs: services,
                                      manufacturerDataHex: mfg, connectedToThisPhone: false, lastSeen: EpochMillis(date: Date()))
        onEvent(.discovered(device, advertisement: adv))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onEvent(.connectionEvent(ConnectionEvent(deviceID: peripheral.identifier.uuidString, timestamp: EpochMillis(date: Date()), kind: .connected)))
        peripheral.delegate = self
        discover(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onEvent(.connectionEvent(ConnectionEvent(deviceID: peripheral.identifier.uuidString, timestamp: EpochMillis(date: Date()),
                                                 kind: .connectFailed, detail: error?.localizedDescription)))
        onEvent(.stateChanged(.disconnected(since: EpochMillis(date: Date()))))
        scheduleReconnect(after: true)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let now = EpochMillis(date: Date())
        link?.close(reason: error?.localizedDescription ?? "disconnected", at: now)
        link = nil
        onEvent(.connectionEvent(ConnectionEvent(deviceID: peripheral.identifier.uuidString, timestamp: now, kind: .disconnected,
                                                 detail: error?.localizedDescription)))
        onEvent(.stateChanged(wantConnected ? .searching : .disconnected(since: now)))
        if (error as NSError?)?.code == CBError.Code.peerRemovedPairingInformation.rawValue {
            onEvent(.pairingProblem("The band no longer recognizes this iPhone's pairing. Forget the band in iOS Settings → Bluetooth, then select it again in Forma."))
        }
        scheduleReconnect(after: false) // re-issue a pending connect immediately
    }
}

// MARK: - CBPeripheralDelegate

extension BLECentral: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard error == nil, !services.isEmpty else {
            onEvent(.connectionEvent(ConnectionEvent(deviceID: peripheral.identifier.uuidString, timestamp: EpochMillis(date: Date()),
                                                     kind: .connectFailed, detail: "service discovery failed: \(error?.localizedDescription ?? "no services")")))
            central.cancelPeripheralConnection(peripheral)
            return
        }
        pendingServiceDiscoveries = services.count
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let chars = service.characteristics { register(chars, on: peripheral) }
        pendingServiceDiscoveries -= 1
        if pendingServiceDiscoveries <= 0 { subscribe(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if Self.isPairingError(error) {
            onEvent(.pairingProblem("The band requires a paired (encrypted) connection for \(Self.name(for: UUIDs.normalize(characteristic.uuid.uuidString))). Accept the iOS pairing prompt, or the data path stays unavailable. Forma does not bypass pairing."))
        }
        pendingNotifyConfirmations.remove(characteristic.uuid)
        if pendingNotifyConfirmations.isEmpty, link == nil { finishSetup(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else {
            if Self.isPairingError(error) {
                onEvent(.pairingProblem("Reading \(Self.name(for: UUIDs.normalize(characteristic.uuid.uuidString))) requires pairing."))
            }
            return
        }
        link?.emit(.notification(characteristic: UUIDs.normalize(characteristic.uuid.uuidString), bytes: [UInt8](value),
                                 receivedAt: EpochMillis(date: Date())))
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        link?.completeWrite(characteristic: UUIDs.normalize(characteristic.uuid.uuidString), error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        link?.readyForWriteWithoutResponse()
    }
}
