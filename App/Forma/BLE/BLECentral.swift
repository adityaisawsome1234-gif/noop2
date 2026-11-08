import Foundation
import CoreBluetooth
import FormaCore
import FormaProtocol
import FormaSync
import FormaFeatures

/// Owns the app's single `CBCentralManager`.
///
/// - Created with a constant restoration identifier (iOS 27 scene-based apps get no launch options, so the
///   identifier is never derived from them). A connection iOS restores is set up with `defaultProfile` at
///   once: on a relaunch for a Bluetooth event the app model may ask for it late, or not at all.
/// - Keeps a pending `connect()` outstanding while collection is on (pending connects never time out). A
///   failed attempt, or a connection that drops before it stayed up for a while, backs off before the next
///   attempt. The backoff wait holds a process assertion, and when iOS ends it early the connect is issued
///   at once, so Forma is never suspended with nothing pending that could wake it again.
/// - Notifications that arrive while a connection is being set up are kept, in order, and handed to its
///   link right after `.ready`.
/// - Scans only when the user is choosing a band: filtered by service UUIDs, time-boxed to 30 s (and
///   stopped before Forma is suspended). Unfiltered scanning is offered only explicitly, in the foreground.
///   A scan iOS restored after terminating Forma is stopped.
/// - All Core Bluetooth calls happen on `queue`, the same serial queue that receives delegate callbacks.
final class BLECentral: NSObject, BandCentral, @unchecked Sendable {
    static let restoreIdentifier = "com.forma.central.v1"
    private static let selectedPeripheralKey = "forma.selectedPeripheralID"
    /// A connection that stays up this long resets the failure count; one that drops sooner counts as a
    /// failed attempt (so a band that accepts and then drops the link at once is retried with backoff).
    private static let stableConnectionSeconds: TimeInterval = 30
    /// Notifications kept while a connection is set up (a pairing prompt can hold setup up for a while).
    private static let setupEventLimit = 4_096
    private static let scanSeconds: Double = 30

    let queue = DispatchQueue(label: "com.forma.ble", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var central: CBCentralManager!
    private let handlerLock = NSLock()
    private var handler: (@Sendable (CentralEvent) -> Void)?
    /// Events raised before the app model installs its handler (e.g. state restoration at launch),
    /// delivered in order when it does.
    private var pendingEvents: [CentralEvent] = []

    // State below is only touched on `queue`.
    private var target: CBPeripheral?
    private var targetProfile: GATTProfile?
    private var wantConnected = false
    private var consecutiveFailures = 0
    private let reconnectPolicy = ReconnectPolicy()
    private var pendingReconnect: ProtectedDelay?
    private var reconnectGeneration: UInt64 = 0
    private var encryptionProblemReported = false

    // The connection to `target` this central knows about (from its own connect, or adopted after restoration).
    private var connectedPeripheralID: UUID?
    private var setupInProgress = false
    private var linkUpSince: Date?
    /// The connection was cancelled because it could not be used: its disconnect counts as a failed attempt.
    private var failNextDisconnect = false
    private var link: CoreBluetoothLink?
    private var writeChannel: GATTWriteChannel?
    private var setupEvents: [LinkEvent] = []
    private var characteristicsByUUID: [String: CBCharacteristic] = [:]
    private var pendingCharacteristicDiscoveries: Set<ObjectIdentifier> = []
    private var pendingNotifyConfirmations: Set<ObjectIdentifier> = []

    // Scanning and restoration.
    private var discoveredForScan: [UUID: CBPeripheral] = [:]
    private var scanTimeBox: ProtectedDelay?
    private var scanGeneration: UInt64 = 0
    private var stopRestoredScan = false
    private var unwantedRestoredPeripherals: [CBPeripheral] = []

    /// Profiles the app knows how to drive. Used for scan filters and to label scan results.
    let knownProfiles: [GATTProfile]
    /// Used for a connection the app model has not asked for (yet): one restored by iOS.
    let defaultProfile: GATTProfile

    init(knownProfiles: [GATTProfile], defaultProfile: GATTProfile) {
        self.knownProfiles = knownProfiles
        self.defaultProfile = defaultProfile
        super.init()
        queue.setSpecific(key: queueKey, value: true)
        // Created on `queue`: every delegate callback runs there too, so none can find `central` unset.
        queue.sync {
            central = CBCentralManager(delegate: self, queue: queue, options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
                // Forma explains a switched-off Bluetooth itself, instead of a system alert on every launch.
                CBCentralManagerOptionShowPowerAlertKey: false,
            ])
        }
    }

    func setEventHandler(_ handler: @escaping @Sendable (CentralEvent) -> Void) {
        // On `queue`, where every event is raised: the backlog is delivered before any newer event.
        queue.async {
            let backlog: [CentralEvent] = self.handlerLock.withLock {
                self.handler = handler
                defer { self.pendingEvents.removeAll() }
                return self.pendingEvents
            }
            for e in backlog { handler(e) }
        }
    }

    private func onEvent(_ event: CentralEvent) {
        let h: (@Sendable (CentralEvent) -> Void)? = handlerLock.withLock {
            if handler == nil, pendingEvents.count < 500 { pendingEvents.append(event) }
            return handler
        }
        h?(event)
    }

    /// Runs `work` on `queue` and waits for it (directly when already there).
    private func runOnQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { work() } else { queue.sync(execute: work) }
    }

    var savedPeripheralID: String? { Self.savedPeripheralUUID?.uuidString }

    // MARK: Persistence of the selected band

    static var savedPeripheralUUID: UUID? {
        guard let s = UserDefaults.standard.string(forKey: selectedPeripheralKey) else { return nil }
        return UUID(uuidString: s)
    }

    /// Forgets the saved band without a central (nothing to cancel when none was ever created).
    static func forgetSavedPeripheral() {
        savePeripheralID(nil)
    }

    private static func savePeripheralID(_ id: UUID?) {
        if let id { UserDefaults.standard.set(id.uuidString, forKey: selectedPeripheralKey) }
        else { UserDefaults.standard.removeObject(forKey: selectedPeripheralKey) }
    }

    // MARK: Public API (thread-safe; hops to `queue`)

    /// Start keeping the selected band connected (collection on). This also resumes reconnecting after it
    /// backed off or paused: the failure count starts again.
    func connectSelected(profile: GATTProfile) {
        queue.async {
            self.targetProfile = profile
            self.wantConnected = true
            self.consecutiveFailures = 0
            self.encryptionProblemReported = false
            self.cancelPendingReconnect()
            self.establishConnection()
        }
    }

    /// Stop collection: cancel the pending/active connection. (Other apps may keep their own link.)
    func disconnect() {
        queue.async {
            self.wantConnected = false
            self.cancelPendingReconnect()
            if let p = self.target, self.central.state == .poweredOn { self.central.cancelPeripheralConnection(p) }
        }
    }

    func select(peripheralID: String, profile: GATTProfile) {
        guard let peripheralID = UUID(uuidString: peripheralID) else { return }
        queue.async {
            Self.savePeripheralID(peripheralID)
            self.targetProfile = profile
            if let current = self.target, current.identifier != peripheralID {
                self.release(current, reason: "another band was selected")
            }
            if self.target == nil {
                self.target = self.discoveredForScan[peripheralID]
                    ?? (self.central.state == .poweredOn ? self.central.retrievePeripherals(withIdentifiers: [peripheralID]).first : nil)
            }
        }
    }

    func forgetSelected() {
        queue.async {
            self.wantConnected = false
            if let p = self.target { self.release(p, reason: "band forgotten") }
            Self.savePeripheralID(nil)
        }
    }

    func startScan(includeUnfiltered: Bool) {
        queue.async { self.startScanOnQueue(includeUnfiltered: includeUnfiltered) }
    }

    func stopScan() {
        queue.async { self.stopScanOnQueue() }
    }

    // MARK: Scanning (on queue)

    private func startScanOnQueue(includeUnfiltered: Bool) {
        guard central.state == .poweredOn else {
            onEvent(.bluetoothProblem(Self.describe(central.state)))
            // No scan started: the picker must not keep waiting for one.
            onEvent(.scanStopped)
            return
        }
        stopRestoredScan = false
        central.stopScan()
        discoveredForScan.removeAll()
        reportConnectedBands()
        let filter: [CBUUID]? = includeUnfiltered ? nil
            : Array(Set(knownProfiles.flatMap { $0.scanServiceFilter } + [UUIDs.heartRateService])).map { CBUUID(string: $0) }
        central.scanForPeripherals(withServices: filter, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        onEvent(.connectionEvent(ConnectionEvent(deviceID: nil, timestamp: EpochMillis(date: Date()), kind: .scanStarted,
                                                 detail: includeUnfiltered ? "unfiltered (foreground)" : "filtered")))
        // The time-box holds a process assertion: if Forma leaves the foreground with the picker open, the
        // scan stops before iOS suspends Forma instead of running on unattended.
        cancelScanTimeBox()
        let generation = scanGeneration
        scanTimeBox = ProtectedDelay(seconds: Self.scanSeconds, reason: "forma.scan") { [weak self] in
            self?.runOnQueue { self?.scanTimeBoxEnded(generation) }
        }
    }

    /// Bands already connected to this iPhone (e.g. by another app) do not need to advertise. One query per
    /// service, so each band is labelled with the service it was found by.
    private func reportConnectedBands() {
        var found: [UUID: (peripheral: CBPeripheral, services: [String])] = [:]
        let services = Array(Set(knownProfiles.compactMap(\.vendorService) + [UUIDs.heartRateService]))
        for service in services {
            for p in central.retrieveConnectedPeripherals(withServices: [CBUUID(string: service)]) {
                found[p.identifier, default: (peripheral: p, services: [])].services.append(service)
            }
        }
        for entry in found.values {
            let p = entry.peripheral
            discoveredForScan[p.identifier] = p
            let device = DiscoveredDevice(id: p.identifier.uuidString, name: p.name, rssi: nil, family: family(name: p.name, services: entry.services),
                                          advertisedServiceUUIDs: [], manufacturerDataHex: nil, connectedToThisPhone: true,
                                          lastSeen: EpochMillis(date: Date()))
            onEvent(.discovered(device, advertisement: [:]))
        }
    }

    private func stopScanOnQueue() {
        cancelScanTimeBox()
        if central.isScanning {
            central.stopScan()
            onEvent(.connectionEvent(ConnectionEvent(deviceID: nil, timestamp: EpochMillis(date: Date()), kind: .scanStopped)))
        }
        onEvent(.scanStopped)
    }

    private func scanTimeBoxEnded(_ generation: UInt64) {
        guard generation == scanGeneration else { return } // the scan was stopped or restarted meanwhile
        stopScanOnQueue()
    }

    private func cancelScanTimeBox() {
        scanGeneration &+= 1
        scanTimeBox?.cancel()
        scanTimeBox = nil
    }

    // MARK: Connection management (on queue)

    private func establishConnection() {
        guard wantConnected, central.state == .poweredOn else { return }
        if target == nil, let id = Self.savedPeripheralUUID {
            target = central.retrievePeripherals(withIdentifiers: [id]).first
        }
        guard let p = target else {
            onEvent(.stateChanged(.noDeviceSelected))
            return
        }
        p.delegate = self
        switch p.state {
        case .connected:
            // Connected before this process knew about it (state restoration): adopt the connection.
            if connectedPeripheralID != p.identifier { beginConnection(p) }
            if link != nil {
                onEvent(.stateChanged(.connected)) // already set up: a repeated request only re-reports the state
            } else if setupInProgress {
                onEvent(.stateChanged(.connecting))
            } else {
                setUp(p)
            }
        case .connecting:
            onEvent(.stateChanged(.searching)) // a pending connect is already outstanding
        default:
            onEvent(.stateChanged(.searching))
            central.connect(p, options: nil) // pending connect: completes whenever the band is in range
            onEvent(.connectionEvent(ConnectionEvent(deviceID: p.identifier.uuidString, timestamp: EpochMillis(date: Date()), kind: .connecting)))
        }
    }

    /// Starts tracking a connection to `p`; nothing from an earlier connection carries over.
    private func beginConnection(_ p: CBPeripheral) {
        endConnection(reason: "replaced by a new connection")
        connectedPeripheralID = p.identifier
        writeChannel = GATTWriteChannel(peripheral: p, queue: queue)
        failNextDisconnect = false
    }

    /// Forgets the current connection: closes its link, fails its writes and drops what setup collected.
    private func endConnection(reason: String) {
        link?.close(reason: reason, at: EpochMillis(date: Date()))
        link = nil
        writeChannel?.failAll()
        writeChannel = nil
        connectedPeripheralID = nil
        setupInProgress = false
        linkUpSince = nil
        setupEvents.removeAll()
        characteristicsByUUID.removeAll()
        pendingCharacteristicDiscoveries.removeAll()
        pendingNotifyConfirmations.removeAll()
    }

    /// Stops using `p`: cancels its connection and any pending reconnect, and closes its link. Callbacks that
    /// still arrive for it are ignored.
    private func release(_ p: CBPeripheral, reason: String) {
        cancelPendingReconnect()
        if central.state == .poweredOn { central.cancelPeripheralConnection(p) }
        endConnection(reason: reason)
        failNextDisconnect = false
        target = nil
    }

    /// Gives up on a connection that cannot be used. Its disconnect counts as a failed attempt, so a band that
    /// keeps failing this way is retried with backoff instead of in a tight loop.
    private func abandon(_ p: CBPeripheral, reason: String) {
        onEvent(.connectionEvent(ConnectionEvent(deviceID: p.identifier.uuidString, timestamp: EpochMillis(date: Date()),
                                                 kind: .connectFailed, detail: reason)))
        setupInProgress = false
        setupEvents.removeAll()
        failNextDisconnect = true
        central.cancelPeripheralConnection(p)
    }

    private func isSettingUp(_ p: CBPeripheral) -> Bool {
        setupInProgress && connectedPeripheralID == p.identifier
    }

    /// Discovers services and characteristics (reusing what the connection already knows, e.g. after state
    /// restoration), enables notifications and reads device information, then hands over a link.
    private func setUp(_ p: CBPeripheral) {
        setupInProgress = true
        characteristicsByUUID.removeAll()
        pendingCharacteristicDiscoveries.removeAll()
        pendingNotifyConfirmations.removeAll()
        onEvent(.stateChanged(.connecting))
        if let services = p.services, !services.isEmpty {
            for s in services {
                if let chars = s.characteristics, !chars.isEmpty {
                    register(chars)
                } else {
                    pendingCharacteristicDiscoveries.insert(ObjectIdentifier(s))
                    p.discoverCharacteristics(nil, for: s)
                }
            }
            if pendingCharacteristicDiscoveries.isEmpty { subscribe(p) }
            return
        }
        let profile = targetProfile ?? defaultProfile
        // An empty list means "discover everything" (used when the band's family is not known yet).
        p.discoverServices(profile.discoverServices.isEmpty ? nil : profile.discoverServices.map { CBUUID(string: $0) })
    }

    private func register(_ characteristics: [CBCharacteristic]) {
        for c in characteristics {
            characteristicsByUUID[UUIDs.normalize(c.uuid.uuidString)] = c
        }
    }

    private func subscribe(_ p: CBPeripheral) {
        let profile = targetProfile ?? defaultProfile
        for uuid in profile.subscribeCharacteristics {
            guard let c = characteristicsByUUID[uuid], c.properties.contains(.notify) || c.properties.contains(.indicate) else { continue }
            if c.isNotifying { continue }
            pendingNotifyConfirmations.insert(ObjectIdentifier(c))
            p.setNotifyValue(true, for: c)
        }
        // One-shot reads: device information and battery level (decoded by the adapter like notifications).
        for uuid in [UUIDs.firmwareRevision, UUIDs.hardwareRevision, UUIDs.modelNumber, UUIDs.manufacturerName, UUIDs.batteryLevel] {
            if let c = characteristicsByUUID[uuid], c.properties.contains(.read) { p.readValue(for: c) }
        }
        if pendingNotifyConfirmations.isEmpty { finishSetup(p) }
    }

    private func finishSetup(_ p: CBPeripheral) {
        setupInProgress = false
        // Collection was turned off while setting up: the connection is being cancelled, so no link.
        guard wantConnected else {
            setupEvents.removeAll()
            return
        }
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
        let channel = writeChannel ?? GATTWriteChannel(peripheral: p, queue: queue)
        writeChannel = channel
        link?.close(reason: "replaced by a new link", at: EpochMillis(date: Date()))
        let newLink = CoreBluetoothLink(peripheral: p, queue: queue, characteristics: characteristicsByUUID, writes: channel,
                                        onConsumerGone: { [weak self] gone in self?.linkConsumerGone(gone) },
                                        onOverflow: { [weak self] full in self?.linkOverflowed(full) })
        link = newLink
        if linkUpSince == nil { linkUpSince = Date() }
        newLink.emit(.ready(services: services))
        // Notifications and reads that arrived during setup, in arrival order and with their own receive times.
        let early = setupEvents
        setupEvents.removeAll()
        for e in early { newLink.emit(e) }
        onEvent(.stateChanged(.connected))
        onEvent(.connectionEvent(ConnectionEvent(deviceID: p.identifier.uuidString, timestamp: EpochMillis(date: Date()), kind: .servicesDiscovered,
                                                 detail: "\(services.count) services")))
        onEvent(.linkReady(newLink, services: summaries))
    }

    /// The app model stopped reading `gone` (its sync engine was stopped). While collection stays on, the
    /// connection gets a fresh link, so an engine the model starts next always has one to read — also when the
    /// model's request to connect was handled before the old reader went away.
    private func linkConsumerGone(_ gone: CoreBluetoothLink) {
        guard gone === link else { return }
        link = nil
        // One hop later: the model usually stops its engine right before selecting another band, forgetting
        // this one or turning collection off, and those requests (already queued) are honoured first.
        queue.async { [weak self] in self?.setUpAgainIfWanted() }
    }

    private func setUpAgainIfWanted() {
        guard wantConnected, link == nil, !setupInProgress, let p = target, p.identifier == connectedPeripheralID,
              p.state == .connected else { return }
        setUp(p)
    }

    /// The app model fell so far behind that the link could not keep every notification, so the link ended.
    /// Restart the connection rather than continue across the hole; the band keeps whatever history was not
    /// acknowledged.
    private func linkOverflowed(_ full: CoreBluetoothLink) {
        guard full === link, let p = target, p.identifier == connectedPeripheralID else { return }
        link = nil
        abandon(p, reason: "notifications arrived faster than they could be stored; reconnecting")
    }

    // MARK: Reconnecting (on queue)

    /// After a disconnect or a failed attempt. A disconnect after a connection that stayed up re-issues the
    /// pending connect at once; failures back off.
    private func scheduleReconnect(failure: Bool) {
        cancelPendingReconnect()
        guard wantConnected else { return }
        consecutiveFailures = failure ? consecutiveFailures + 1 : 0
        let delay = reconnectPolicy.delay(afterFailures: consecutiveFailures, jitterUnit: Double.random(in: 0..<1))
        guard delay > 0 else {
            establishConnection()
            return
        }
        let now = EpochMillis(date: Date())
        onEvent(.stateChanged(.disconnected(since: now)))
        onEvent(.connectionEvent(ConnectionEvent(deviceID: target?.identifier.uuidString, timestamp: now, kind: .reconnectScheduled,
                                                 detail: "in \(Int(delay.rounded())) s, after \(consecutiveFailures) failed attempt(s)")))
        // The wait holds a process assertion. If iOS refuses it, or ends it before the delay is over (Forma is
        // about to be suspended), the connect is issued at once: a timer cannot fire in a suspended app, and
        // without a pending connect nothing would wake Forma again.
        let generation = reconnectGeneration
        pendingReconnect = ProtectedDelay(seconds: delay, reason: "forma.reconnect") { [weak self] in
            self?.runOnQueue { self?.reconnectDelayEnded(generation) }
        }
    }

    private func reconnectDelayEnded(_ generation: UInt64) {
        guard generation == reconnectGeneration else { return } // cancelled or replaced meanwhile
        pendingReconnect = nil
        establishConnection()
    }

    private func cancelPendingReconnect() {
        reconnectGeneration &+= 1
        pendingReconnect?.cancel()
        pendingReconnect = nil
    }

    /// The band dropped its pairing with this iPhone. Every attempt would fail the same way until the user
    /// forgets the band in iOS Settings, so reconnecting pauses until the app model asks again (selecting the
    /// band, or reopening Forma).
    private func pauseForLostPairing() {
        wantConnected = false
        cancelPendingReconnect()
        onEvent(.stateChanged(.disconnected(since: EpochMillis(date: Date()))))
        onEvent(.pairingProblem("The band no longer recognizes this iPhone's pairing. Forget the band in iOS Settings → Bluetooth, then select it again in Forma. Forma stops reconnecting until you reopen it or select the band."))
    }

    private func reportEncryptionProblemIfNeeded(_ error: Error?) {
        guard !encryptionProblemReported, Self.isCBError(error, .encryptionTimedOut) else { return }
        encryptionProblemReported = true
        onEvent(.pairingProblem("Securing the connection to the band timed out. If iOS shows a Bluetooth pairing request, accept it; Forma does not bypass pairing."))
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

    /// A Core Bluetooth error (`CBErrorDomain`) with this code; other domains reuse the same numbers.
    static func isCBError(_ error: Error?, _ code: CBError.Code) -> Bool {
        guard let error = error as NSError?, error.domain == CBErrorDomain else { return false }
        return error.code == code.rawValue
    }
}

// MARK: - CBCentralManagerDelegate

extension BLECentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        onEvent(.bluetoothProblem(Self.describe(state)))
        if let unavailable = Self.linkState(for: state) {
            onEvent(.stateChanged(unavailable))
            onEvent(.connectionEvent(ConnectionEvent(deviceID: target?.identifier.uuidString, timestamp: EpochMillis(date: Date()),
                                                     kind: state == .unauthorized ? .unauthorized : .bluetoothOff,
                                                     detail: Self.describe(state))))
            cancelPendingReconnect()
            endConnection(reason: "Bluetooth unavailable")
            failNextDisconnect = false
            if scanTimeBox != nil {
                cancelScanTimeBox()
                onEvent(.scanStopped)
            }
            if state != .poweredOff {
                // Below "powered off" every CBPeripheral of this manager is invalid; the band is retrieved again
                // by its saved identifier once Bluetooth is back.
                target = nil
                discoveredForScan.removeAll()
                unwantedRestoredPeripherals.removeAll()
            }
            return
        }
        onEvent(.connectionEvent(ConnectionEvent(deviceID: target?.identifier.uuidString, timestamp: EpochMillis(date: Date()), kind: .bluetoothOn)))
        // Restored state Forma does not want: a scan whose picker is gone, and peripherals other than the band.
        if stopRestoredScan {
            stopRestoredScan = false
            stopScanOnQueue()
        }
        for p in unwantedRestoredPeripherals { central.cancelPeripheralConnection(p) }
        unwantedRestoredPeripherals.removeAll()
        establishConnection()
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        let saved = Self.savedPeripheralUUID
        // Only the selected band is adopted; setup finishes with `defaultProfile` once Bluetooth is on
        // (centralManagerDidUpdateState → establishConnection), without waiting for the app model.
        if let saved, let p = restored.first(where: { $0.identifier == saved }) {
            target = p
            p.delegate = self
            wantConnected = true
        }
        unwantedRestoredPeripherals = restored.filter { $0.identifier != saved }
        stopRestoredScan = dict[CBCentralManagerRestoredStateScanServicesKey] != nil
        onEvent(.connectionEvent(ConnectionEvent(deviceID: target?.identifier.uuidString, timestamp: EpochMillis(date: Date()),
                                                 kind: .restoredByOS,
                                                 detail: "\(restored.count) peripheral(s)" + (stopRestoredScan ? ", scan (stopped)" : ""))))
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
        guard peripheral.identifier == target?.identifier, wantConnected else {
            // No longer wanted: another band was selected, or collection was turned off meanwhile.
            central.cancelPeripheralConnection(peripheral)
            return
        }
        onEvent(.connectionEvent(ConnectionEvent(deviceID: peripheral.identifier.uuidString, timestamp: EpochMillis(date: Date()), kind: .connected)))
        peripheral.delegate = self
        cancelPendingReconnect()
        // Already adopted (restoration set it up before this callback arrived): nothing to redo.
        if connectedPeripheralID == peripheral.identifier, link != nil || setupInProgress { return }
        beginConnection(peripheral)
        setUp(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == target?.identifier else { return }
        onEvent(.connectionEvent(ConnectionEvent(deviceID: peripheral.identifier.uuidString, timestamp: EpochMillis(date: Date()),
                                                 kind: .connectFailed, detail: error?.localizedDescription)))
        endConnection(reason: "connection failed")
        failNextDisconnect = false
        // Bluetooth went away meanwhile: its state is what the app shows, and `.poweredOn` reconnects.
        guard central.state == .poweredOn else { return }
        if Self.isCBError(error, .peerRemovedPairingInformation) {
            pauseForLostPairing()
            return
        }
        reportEncryptionProblemIfNeeded(error)
        guard wantConnected else {
            onEvent(.stateChanged(.disconnected(since: EpochMillis(date: Date()))))
            return
        }
        scheduleReconnect(failure: true)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // A band that is no longer selected was released (and its link closed) when it was replaced.
        guard peripheral.identifier == target?.identifier else { return }
        let now = EpochMillis(date: Date())
        let stayedUp = linkUpSince.map { Date().timeIntervalSince($0) >= Self.stableConnectionSeconds } ?? false
        let failure = failNextDisconnect || !stayedUp
        failNextDisconnect = false
        endConnection(reason: error?.localizedDescription ?? "disconnected")
        onEvent(.connectionEvent(ConnectionEvent(deviceID: peripheral.identifier.uuidString, timestamp: now, kind: .disconnected,
                                                 detail: error?.localizedDescription)))
        // Bluetooth went away meanwhile: its state is what the app shows, and `.poweredOn` reconnects.
        guard central.state == .poweredOn else { return }
        if Self.isCBError(error, .peerRemovedPairingInformation) {
            pauseForLostPairing()
            return
        }
        reportEncryptionProblemIfNeeded(error)
        guard wantConnected else {
            onEvent(.stateChanged(.disconnected(since: now)))
            return
        }
        scheduleReconnect(failure: failure) // reports "searching" (pending connect) or "disconnected" (backing off)
    }
}

// MARK: - CBPeripheralDelegate

extension BLECentral: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isSettingUp(peripheral) else { return }
        let services = peripheral.services ?? []
        guard error == nil, !services.isEmpty else {
            abandon(peripheral, reason: "service discovery failed: \(error?.localizedDescription ?? "no services")")
            return
        }
        pendingCharacteristicDiscoveries = Set(services.map { ObjectIdentifier($0) })
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Each service answers once; anything else (a repeat, or a reply from an earlier setup) is ignored.
        guard isSettingUp(peripheral), pendingCharacteristicDiscoveries.remove(ObjectIdentifier(service)) != nil else { return }
        if let chars = service.characteristics { register(chars) }
        if pendingCharacteristicDiscoveries.isEmpty { subscribe(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == target?.identifier else { return }
        if Self.isPairingError(error) {
            onEvent(.pairingProblem("The band requires a paired (encrypted) connection for \(Self.name(for: UUIDs.normalize(characteristic.uuid.uuidString))). Accept the iOS pairing prompt, or the data path stays unavailable. Forma does not bypass pairing."))
        }
        guard isSettingUp(peripheral), pendingNotifyConfirmations.remove(ObjectIdentifier(characteristic)) != nil else { return }
        if pendingNotifyConfirmations.isEmpty { finishSetup(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == target?.identifier else { return }
        guard error == nil, let value = characteristic.value else {
            if Self.isPairingError(error) {
                onEvent(.pairingProblem("Reading \(Self.name(for: UUIDs.normalize(characteristic.uuid.uuidString))) requires pairing."))
            }
            return
        }
        let event = LinkEvent.notification(characteristic: UUIDs.normalize(characteristic.uuid.uuidString), bytes: [UInt8](value),
                                           receivedAt: EpochMillis(date: Date()))
        if let link {
            link.emit(event)
        } else if isSettingUp(peripheral) {
            // Kept for the link this setup is about to hand over (e.g. the notification that relaunched Forma).
            guard setupEvents.count < Self.setupEventLimit else {
                abandon(peripheral, reason: "setup did not finish while notifications kept arriving")
                return
            }
            setupEvents.append(event)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == connectedPeripheralID else { return }
        writeChannel?.didWrite(key: UUIDs.normalize(characteristic.uuid.uuidString), error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral.identifier == connectedPeripheralID else { return }
        writeChannel?.pump()
    }
}

// MARK: - Protected delay

/// Waits `seconds` while holding a process assertion (`performExpiringActivity`), then runs `action` once.
/// If iOS refuses the assertion, or ends it before the time is up because Forma is about to be suspended,
/// `action` runs at once instead: the work is done before suspension rather than by a timer that cannot fire
/// in a suspended app. `cancel()` stops it (and releases the assertion) without running `action`.
private final class ProtectedDelay: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let wake = DispatchSemaphore(value: 0)
    private let action: @Sendable () -> Void

    init(seconds: Double, reason: String, action: @escaping @Sendable () -> Void) {
        self.action = action
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { [self] expired in
            if !expired { _ = wake.wait(timeout: .now() + seconds) }
            fire()
            wake.signal() // releases a first invocation still waiting after an early expiry
        }
    }

    func cancel() {
        let wasFinished: Bool = lock.withLock {
            defer { finished = true }
            return finished
        }
        if !wasFinished { wake.signal() }
    }

    private func fire() {
        let run: Bool = lock.withLock {
            if finished { return false }
            finished = true
            return true
        }
        if run { action() }
    }
}
