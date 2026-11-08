import Foundation
import FormaCore
import FormaProtocol
import FormaSync
import FormaStore

/// Writes through the platform's protected-execution helper so a write that starts during a short
/// background wake can finish before suspension.
final class ProtectedSink: IngestSink, @unchecked Sendable {
    let store: FormaStore
    let platform: any PlatformServices

    init(store: FormaStore, platform: any PlatformServices) {
        self.store = store
        self.platform = platform
    }

    func ingest(_ batch: IngestBatch) throws -> IngestResult { try platform.runProtected("forma.ingest") { try store.ingest(batch) } }
    func syncCursor(deviceID: String) throws -> SyncCursor? { try store.syncCursor(deviceID: deviceID) }
    func upsertDevice(_ device: DeviceRecord) throws { try platform.runProtected("forma.device") { try store.upsertDevice(device) } }
    func recordConnectionEvent(_ event: ConnectionEvent) throws { try platform.runProtected("forma.event") { try store.recordConnectionEvent(event) } }
    func recordRawFrame(_ frame: RawFrameRecord) throws { try platform.runProtected("forma.raw") { try store.recordRawFrame(frame) } }
    func beginSyncRun(_ run: SyncRunRecord) throws -> Int64 { try platform.runProtected("forma.run") { try store.beginSyncRun(run) } }
    func finishSyncRun(_ run: SyncRunRecord) throws { try platform.runProtected("forma.run") { try store.finishSyncRun(run) } }
}

extension AppModel {
    // MARK: Central events

    func handle(_ event: CentralEvent) {
        switch event {
        case .stateChanged(let state):
            connection.link = state
            if case .connected = state {} else { connection.liveStreaming = false }
        case .bluetoothProblem(let message):
            bluetoothProblemMessage = message
        case .discovered(let device, let advertisement):
            if let i = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                var merged = device
                merged.connectedToThisPhone = merged.connectedToThisPhone || discoveredDevices[i].connectedToThisPhone
                discoveredDevices[i] = merged
            } else {
                discoveredDevices.append(device)
            }
            if !advertisement.isEmpty { advertisements[device.id] = advertisement }
            discoveredDevices.sort(by: Self.discoveryOrder)
        case .scanStopped:
            isScanning = false
        case .linkReady(let link, let services):
            diagnostics.services = services
            startEngine(on: link, services: services)
        case .connectionEvent(let e):
            connectionEvents.insert(e, at: 0)
            if connectionEvents.count > 200 { connectionEvents.removeLast(connectionEvents.count - 200) }
            if !isDemo, let store = liveStore {
                _ = try? platform.runProtected("forma.event") { try store.recordConnectionEvent(e) }
            }
            if e.kind == .disconnected {
                connection.link = collectionEnabled ? .searching : .disconnected(since: e.timestamp)
            }
        case .pairingProblem(let message):
            alertMessage = message
        }
    }

    /// Known families first, then stronger signal.
    nonisolated static func discoveryOrder(_ a: DiscoveredDevice, _ b: DiscoveredDevice) -> Bool {
        let aKnown = a.family != .unknown
        let bKnown = b.family != .unknown
        if aKnown != bKnown { return aKnown }
        let aRSSI = a.rssi ?? -200
        let bRSSI = b.rssi ?? -200
        return aRSSI > bRSSI
    }

    // MARK: Scanning & selection

    public func startScan(includeUnfiltered: Bool) {
        discoveredDevices.removeAll()
        isScanning = true
        central.startScan(includeUnfiltered: includeUnfiltered)
    }

    public func stopScan() {
        central.stopScan()
        isScanning = false
    }

    public func selectDevice(_ device: DiscoveredDevice) async {
        stopScan()
        let record = DeviceRecord(id: device.id, family: device.family, name: device.displayName, firstSeen: timeSource.now())
        do { try liveStore?.upsertDevice(record) } catch { alertMessage = "Saving the band failed: \(error)" }
        selectedDevice = record
        connection = ConnectionSummary(deviceName: record.name, family: record.family, link: .searching, isDemo: isDemo)
        diagnostics = DiagnosticsState(advertisement: advertisements[device.id] ?? [:], captureEnabled: diagnostics.captureEnabled)
        central.select(peripheralID: device.id, profile: Self.connectionProfile)
        if collectionEnabled && !isDemo { central.connectSelected(profile: Self.connectionProfile) }
        await refreshNow()
    }

    public func forgetDevice() async {
        stopEngine()
        central.forgetSelected()
        selectedDevice = nil
        currentAdapter = nil
        connection = ConnectionSummary(isDemo: isDemo)
        await refreshNow()
    }

    public func setCollectionEnabled(_ on: Bool) async {
        collectionEnabled = on
        platform.setPreference(on ? "1" : "0", forKey: "collectionEnabled")
        if on, selectedDevice != nil, !isDemo {
            central.connectSelected(profile: Self.connectionProfile)
        } else {
            central.disconnect()
            stopEngine()
        }
    }

    public func setLiveHeartRate(_ on: Bool) async {
        liveHeartRateEnabled = on
        platform.setPreference(on ? "1" : "0", forKey: "liveHeartRate")
        await engine?.setOptions(syncOptions())
    }

    public func setHistorySyncMode(_ mode: HistorySyncMode) async {
        historySyncMode = mode
        setStoreSetting(mode.rawValue, "historySyncMode")
        await engine?.setOptions(syncOptions())
    }

    public func syncNow() async {
        guard historySyncMode != .off else { return }
        await engine?.requestHistorySync()
    }

    // MARK: Sync engine lifecycle

    func syncOptions() -> SyncOptions {
        let policy: HistoryPolicy
        switch historySyncMode {
        case .off: policy = .off
        case .manual: policy = .manual
        case .automatic: policy = .automatic
        }
        return SyncOptions(history: policy, liveHeartRate: liveHeartRateEnabled, rawCapture: diagnostics.captureEnabled)
    }

    func startEngine(on link: any PeripheralLink, services: [GATTServiceSummary]) {
        guard !isDemo, let store = liveStore else { return }
        stopEngine()
        let serviceIDs = services.map(\.uuid)
        guard let adapter = AdapterRegistry.adapter(forDiscoveredServices: serviceIDs) else {
            alertMessage = "This device does not expose a data service Forma supports."
            return
        }
        currentAdapter = adapter
        var device = selectedDevice ?? DeviceRecord(id: link.peripheralID, family: adapter.family, name: "Band", firstSeen: timeSource.now())
        if device.family != adapter.family {
            device.family = adapter.family
        }
        device.lastConnected = timeSource.now()
        selectedDevice = device
        connection.family = adapter.family
        diagnostics.adapterID = adapter.adapterID
        diagnostics.parserVersion = adapter.parserVersion
        let engine = SyncEngine(adapter: adapter, sink: ProtectedSink(store: store, platform: platform), device: device,
                                timeSource: timeSource, options: syncOptions(), recorder: recorder)
        self.engine = engine
        let updates = engine.updates
        engineTasks.append(Task { [weak self] in
            for await update in updates {
                await MainActor.run { self?.apply(update) }
            }
        })
        engineTasks.append(Task {
            await engine.run(link: link)
        })
    }

    func stopEngine() {
        for t in engineTasks { t.cancel() }
        engineTasks.removeAll()
        engine = nil
    }

    func apply(_ update: SyncUpdate) {
        switch update {
        case .linkReady:
            connection.link = .connected
            updateCheck("connect", .passed, "Connected directly over Bluetooth; no account or internet used.")
            let hasVendor = diagnostics.services.contains { $0.uuid == Whoop5Adapter.service }
            let hasHR = diagnostics.services.contains { $0.uuid == UUIDs.heartRateService }
            updateCheck("gatt", hasVendor || hasHR ? .passed : .failed,
                        "Vendor service \(hasVendor ? "present" : "absent"); standard heart-rate service \(hasHR ? "present" : "absent").")
            if !hasHR { updateCheck("standardHR", .notApplicable, "The band does not expose the standard heart-rate service on this connection.") }
        case .liveHeartRate(let bpm, let at, let source):
            connection.liveStreaming = true
            connection.lastDeviceSample = max(at, connection.lastDeviceSample ?? at)
            lastLiveSource = source
            if liveWorkoutStart != nil, let device = selectedDevice {
                liveWorkoutSamples.append(HeartRateSample(deviceID: device.id, timestamp: at, bpm: bpm, source: source, receivedAt: at))
                if liveWorkoutSamples.count > 20_000 { liveWorkoutSamples.removeFirst(liveWorkoutSamples.count - 20_000) }
            }
        case .historyStarted:
            connection.sync = .syncingHistory(recordsReceived: 0, newestRecord: nil)
        case .historyProgress(let records, let newest):
            connection.sync = .syncingHistory(recordsReceived: records, newestRecord: newest)
        case .historyChunkSaved:
            break
        case .historyComplete(let at):
            connection.sync = .idle
            connection.lastCompletedSync = at
            updateCheck("history", .passed, "History transferred, saved, then acknowledged.")
            scheduleRefresh()
        case .historyStopped(let reason, let at):
            connection.sync = .failed(message: reason, at: at)
            updateCheck("history", .failed, reason)
            scheduleRefresh()
        case .deviceInformation(let field, let value):
            if field == "firmware" {
                selectedDevice?.firmwareVersion = value
                diagnostics.firmware = value
            }
        case .battery:
            break
        case .clockOffset(let millis):
            updateCheck("clock", abs(millis) <= 2_000 ? .passed : .unverified,
                        "Band clock differs from this iPhone by \(DisplayFormat.number(Double(millis) / 1_000, digits: 1)) s.")
        case .pairingRequired:
            alertMessage = "The band asked for a paired connection. Accept the iOS pairing prompt; Forma never bypasses pairing."
        case .commandSent:
            break
        case .counters(let c):
            diagnostics.counters.framesValid = c.framesValid
            diagnostics.counters.framesMalformed = c.framesMalformed
            diagnostics.counters.bytesDiscarded = c.bytesDiscarded
            diagnostics.counters.unknownPackets = c.unknownPackets
            diagnostics.counters.standardHRNotifications = c.standardHRNotifications
            diagnostics.counters.standardHRWithRR = c.standardHRWithRR
            diagnostics.counters.commandsSent = c.commandsSent
            diagnostics.counters.historyRecords = c.historyRecords
            diagnostics.capturedEntries = recorder.snapshot(header: CaptureHeader(createdAt: 0, deviceFamily: .unknown)).entries.count
        case .frame(let entry):
            let line = FrameLogLine(id: (diagnostics.recentFrames.first?.id ?? 0) + 1, at: entry.at, direction: entry.direction,
                                    characteristic: String(entry.characteristic.prefix(8)), summary: entry.summary, hexPreview: entry.hexPreview)
            diagnostics.recentFrames.insert(line, at: 0)
            if diagnostics.recentFrames.count > 100 { diagnostics.recentFrames.removeLast(diagnostics.recentFrames.count - 100) }
        case .persistenceFailed(let message):
            let t = timeSource.now()
            if t - lastPersistenceAlert > 60_000 {
                lastPersistenceAlert = t
                alertMessage = message
            }
        case .disconnected(_, let at):
            connection.liveStreaming = false
            connection.link = collectionEnabled ? .searching : .disconnected(since: at)
            if case .syncingHistory = connection.sync { connection.sync = .idle }
            scheduleRefresh()
        }
    }

    func updateCheck(_ id: String, _ status: CheckStatus, _ detail: String) {
        guard let i = diagnostics.checks.firstIndex(where: { $0.id == id }) else { return }
        // Never downgrade a passed check during the same test with a weaker result.
        if diagnostics.checks[i].status == .passed && status == .unverified { return }
        diagnostics.checks[i].status = status
        diagnostics.checks[i].detail = detail
    }
}
