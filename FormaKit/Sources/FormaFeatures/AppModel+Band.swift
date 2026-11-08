import Foundation
import FormaCore
import FormaProtocol
import FormaSync
import FormaStore

/// Writes through the platform's protected-execution helper so a write that starts during a short
/// background wake can finish before suspension. After records are stored, cached daily values of the
/// days they fall in are invalidated (history recovered for a past day reaches that day's values).
final class ProtectedSink: IngestSink, @unchecked Sendable {
    let store: FormaStore
    let platform: any PlatformServices
    let cacheGate: DerivedCacheGate?

    init(store: FormaStore, platform: any PlatformServices, cacheGate: DerivedCacheGate? = nil) {
        self.store = store
        self.platform = platform
        self.cacheGate = cacheGate
    }

    func ingest(_ batch: IngestBatch) throws -> IngestResult {
        try platform.runProtected("forma.ingest") {
            let result = try store.ingest(batch)
            if result.inserted > 0, let records = Self.recordRange(of: batch) {
                // The records are durably stored; failing to drop a cache row must not fail the ingest.
                let range = AppModel.affectedByRecords(in: records)
                if let cacheGate {
                    _ = try? cacheGate.invalidate(range) { try store.invalidateDerived(overlapping: range) }
                } else {
                    _ = try? store.invalidateDerived(overlapping: range)
                }
            }
            return result
        }
    }

    /// `[oldest, newest + 1 ms)` of the batch's record times, nil without records.
    static func recordRange(of batch: IngestBatch) -> TimeRange? {
        var lo = Int64.max
        var hi = Int64.min
        func note(_ t: EpochMillis) { lo = min(lo, t); hi = max(hi, t) }
        batch.heartRates.forEach { note($0.timestamp) }
        batch.beatIntervals.forEach { note($0.timestamp) }
        batch.motion.forEach { note($0.timestamp) }
        batch.aux.forEach { note($0.timestamp) }
        guard lo <= hi else { return nil }
        return TimeRange(start: lo, end: hi == Int64.max ? hi : hi + 1)
    }

    func syncCursor(deviceID: String) throws -> SyncCursor? { try store.syncCursor(deviceID: deviceID) }
    func upsertDevice(_ device: DeviceRecord) throws { try platform.runProtected("forma.device") { try store.upsertDevice(device) } }
    func recordConnectionEvent(_ event: ConnectionEvent) throws { try platform.runProtected("forma.event") { try store.recordConnectionEvent(event) } }
    func recordRawFrame(_ frame: RawFrameRecord) throws { try platform.runProtected("forma.raw") { try store.recordRawFrame(frame) } }
    func beginSyncRun(_ run: SyncRunRecord) throws -> Int64 { try platform.runProtected("forma.run") { try store.beginSyncRun(run) } }
    func finishSyncRun(_ run: SyncRunRecord) throws { try platform.runProtected("forma.run") { try store.finishSyncRun(run) } }
    /// Forwarded, never skipped: the engine acknowledges band history only after this returns.
    func ensureDurable() throws { try platform.runProtected("forma.durable") { try store.ensureDurable() } }
}

extension DiagnosticsCounters {
    /// These counters plus one engine's counters (each engine counts from zero).
    func adding(_ c: SyncCounters) -> DiagnosticsCounters {
        var out = self
        out.framesValid += c.framesValid
        out.framesMalformed += c.framesMalformed
        out.bytesDiscarded += c.bytesDiscarded
        out.unknownPackets += c.unknownPackets
        out.standardHRNotifications += c.standardHRNotifications
        out.standardHRWithRR += c.standardHRWithRR
        out.commandsSent += c.commandsSent
        out.historyRecords += c.historyRecords
        out.realtimeHRPackets += c.realtimeHRPackets
        out.lastRealtimeCandidateBPM = c.lastRealtimeCandidateBPM ?? out.lastRealtimeCandidateBPM
        out.historyRecordsUnmapped += c.historyRecordsUnmapped
        out.historyRecordsUndecoded += c.historyRecordsUndecoded
        out.historyRecordsUnsolicited += c.historyRecordsUnsolicited
        out.historyTimeCollisions += c.historyTimeCollisions
        out.historyChunksSaved += c.historyChunksSaved
        out.historyChunksAcknowledged += c.historyChunksAcknowledged
        out.acknowledgementsAccepted += c.acknowledgementsAccepted
        out.acknowledgementsRejected += c.acknowledgementsRejected
        out.responseSequenceMismatches += c.responseSequenceMismatches
        out.notificationGaps += c.notificationGaps
        out.historyRecordsSaved += c.historyRecordsSaved
        out.historyRecordsAlreadyStored += c.historyRecordsAlreadyStored
        out.historyChunksReceived += c.historyChunksReceived
        out.historyTransfersFinishedByBand += c.historyTransfersFinishedByBand
        out.historyAmbiguousDuplicates += c.historyAmbiguousDuplicates
        return out
    }
}

extension AppModel {
    // MARK: Central events

    func handle(_ event: CentralEvent) {
        switch event {
        case .stateChanged(let state):
            // Without a selected band there is no link to describe: keep "No band" (and its actions).
            guard selectedDevice != nil else { return }
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
            startEngine(on: link, services: services)
        case .connectionEvent(let e):
            connectionEvents.insert(e, at: 0)
            if connectionEvents.count > 200 { connectionEvents.removeLast(connectionEvents.count - 200) }
            if !isDemo, let store = liveStore {
                _ = try? platform.runProtected("forma.event") { try store.recordConnectionEvent(e) }
            }
            if e.kind == .disconnected, selectedDevice != nil, !isDemo {
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
        // Nothing from the previous band (its engine, adapter or screens) carries over to this one.
        stopEngine()
        currentAdapter = nil
        let record = DeviceRecord(id: device.id, family: device.family, name: device.displayName, firstSeen: timeSource.now())
        do { try liveStore?.upsertDevice(record) } catch { alertMessage = "Saving the band failed: \(error)" }
        // The stored record keeps what is already known about this band (e.g. its firmware).
        selectedDevice = (try? liveStore?.device(id: device.id)) ?? record
        beginNewDataContext()
        connection = ConnectionSummary(deviceName: record.name, family: record.family, link: idleLinkState(), isDemo: isDemo)
        diagnostics = DiagnosticsState(advertisement: advertisements[device.id] ?? [:], captureEnabled: diagnostics.captureEnabled)
        countersBase = DiagnosticsCounters()
        central.select(peripheralID: device.id, profile: Self.connectionProfile)
        if collectionEnabled && !isDemo { central.connectSelected(profile: Self.connectionProfile) }
        await refreshNow()
    }

    public func forgetDevice() async {
        stopEngine()
        central.forgetSelected()
        selectedDevice = nil
        currentAdapter = nil
        beginNewDataContext()
        connection = ConnectionSummary(isDemo: isDemo)
        await refreshNow()
    }

    public func setCollectionEnabled(_ on: Bool) async {
        collectionEnabled = on
        platform.setPreference(on ? "1" : "0", forKey: "collectionEnabled")
        if on, selectedDevice != nil, !isDemo {
            central.connectSelected(profile: Self.connectionProfile)
            if connection.link != .connected { connection.link = .searching }
        } else {
            central.disconnect()
            stopEngine()
            if selectedDevice != nil, !isDemo { connection.link = .disconnected(since: timeSource.now()) }
        }
    }

    public func setLiveHeartRate(_ on: Bool) async {
        liveHeartRateEnabled = on
        platform.setPreference(on ? "1" : "0", forKey: "liveHeartRate")
        await applyEngineOptions()
    }

    public func setHistorySyncMode(_ mode: HistorySyncMode) async {
        historySyncMode = mode
        setStoreSetting(mode.rawValue, SettingKey.historySyncMode)
        await applyEngineOptions()
    }

    /// Experimental: confirm intact, durably saved history chunks to the band. Off by default because
    /// the acknowledgement format is not verified on hardware and the band may then free that data.
    public func setHistoryAcknowledgement(_ on: Bool) async {
        historyAcknowledgementEnabled = on
        setStoreSetting(on ? "1" : "0", SettingKey.historyAcknowledgement)
        await applyEngineOptions()
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
        // The compatibility test never acknowledges: it promises read-only and stream on/off requests only.
        return SyncOptions(history: policy, acknowledgeHistory: historyAcknowledgementEnabled && !isRunningCompatibilityTest,
                           liveHeartRate: wantsRealtimeStream, rawCapture: diagnostics.captureEnabled)
    }

    /// The band's real-time stream is requested only while the setting "Request live heart-rate stream" is on
    /// and someone can see it — Forma in the foreground — or a workout is recording (it keeps the request
    /// while Forma is in the background). Otherwise it is switched off, so the band is never left streaming
    /// for nobody.
    var wantsRealtimeStream: Bool {
        liveHeartRateEnabled && (sceneActivity == .active || liveWorkoutStart != nil)
    }

    /// Re-applies the current options to a running engine (scene changes, workouts, settings).
    func applyEngineOptions() async {
        guard let engine else { return }
        let options = syncOptions()
        noteRealtimeRequest(options)
        await engine.setOptions(options)
    }

    /// Remembers (across launches) that Forma asked for the real-time stream, before the request goes out;
    /// cleared once the engine reports that it switched the stream off.
    func noteRealtimeRequest(_ options: SyncOptions) {
        if options.liveHeartRate { platform.setPreference("1", forKey: Self.realtimeStreamPreferenceKey) }
    }

    func startEngine(on link: any PeripheralLink, services: [GATTServiceSummary]) {
        guard let store = liveStore else {
            // Nothing could be saved (the database did not open): release the link instead of leaving it
            // unconsumed, which would only end in overflow and reconnect cycles.
            central.disconnect()
            return
        }
        // Own band only: a link to any other peripheral — or any link while no band is selected — is never
        // collected or labelled as the selected band's. (Not disconnected either: that would cancel the
        // pending connection to the band the user did select.)
        guard let selected = selectedDevice, selected.id == link.peripheralID else { return }
        guard !isDemo, collectionEnabled || isRunningCompatibilityTest else {
            // Demo mode, or "Collect from band" is off: nothing is recorded, and the link is released.
            central.disconnect()
            return
        }
        stopEngine()
        diagnostics.services = services
        let serviceIDs = services.map(\.uuid)
        guard let adapter = AdapterRegistry.adapter(forDiscoveredServices: serviceIDs) else {
            alertMessage = "This device does not expose a data service Forma supports."
            central.disconnect()
            return
        }
        currentAdapter = adapter
        var device = selected
        if device.family != adapter.family {
            device.family = adapter.family
        }
        device.lastConnected = timeSource.now()
        selectedDevice = device
        connection.family = adapter.family
        diagnostics.adapterID = adapter.adapterID
        diagnostics.parserVersion = adapter.parserVersion
        let options = syncOptions()
        noteRealtimeRequest(options)
        let engine = SyncEngine(adapter: adapter, sink: ProtectedSink(store: store, platform: platform, cacheGate: liveCacheGate),
                                device: device, timeSource: timeSource, options: options, recorder: recorder,
                                realtimeStreamMayBeOn: platform.preference(Self.realtimeStreamPreferenceKey) == "1")
        self.engine = engine
        engineGeneration &+= 1
        let generation = engineGeneration
        let updates = engine.updates
        engineTasks.append(Task { @MainActor [weak self] in
            for await update in updates {
                guard let self else { return }
                // Updates of an engine that was stopped or replaced meanwhile are dropped.
                guard self.engineGeneration == generation else { return }
                self.apply(update)
            }
        })
        engineTasks.append(Task {
            await engine.run(link: link)
        })
    }

    func stopEngine() {
        engineGeneration &+= 1
        for t in engineTasks { t.cancel() }
        engineTasks.removeAll()
        engine = nil
        countersBase = diagnostics.counters
        connection.liveStreaming = false
        // The stopped engine can no longer report how its transfer ended.
        if case .syncingHistory = connection.sync {
            connection.sync = .failed(message: "History transfer stopped before it finished; data that was not acknowledged stays on the band",
                                      at: timeSource.now())
        }
        invalidateHistoryRange()
    }

    /// Drops cached daily values of the days the current history transfer reported records for.
    func invalidateHistoryRange() {
        guard let range = historyRunRange else { return }
        historyRunRange = nil
        guard let store = liveStore else { return }
        invalidateDerived(in: store, overlapping: Self.affectedByRecords(in: range))
    }

    func apply(_ update: SyncUpdate) {
        switch update {
        case .linkReady:
            connection.link = .connected
            lastClockCheck = nil
            recordLinkChecks()
        case .liveHeartRate(let bpm, let at, let source):
            // Never present an implausible value as live (e.g. the 0 a strap sends without contact).
            guard HeartRateSample.plausibleRange.contains(bpm) else { return }
            let received = timeSource.now()
            lastLiveUpdateAt = received
            connection.liveStreaming = true
            let clamped = min(at, received)
            connection.lastDeviceSample = max(clamped, connection.lastDeviceSample ?? clamped)
            lastLiveSource = source
            if isRunningCompatibilityTest { testLiveReadingTimes.append(received) }
            if liveWorkoutStart != nil, let device = selectedDevice {
                liveWorkoutSamples.append(HeartRateSample(deviceID: device.id, timestamp: at, bpm: bpm, source: source, receivedAt: at))
                if liveWorkoutSamples.count > 20_000 { liveWorkoutSamples.removeFirst(liveWorkoutSamples.count - 20_000) }
            }
        case .historyStarted:
            connection.sync = .syncingHistory(recordsReceived: 0, newestRecord: nil)
            historyChunksAcknowledged = 0
        case .historyProgress(let records, let newest):
            connection.sync = .syncingHistory(recordsReceived: records, newestRecord: newest)
            if let newest {
                let r = historyRunRange ?? TimeRange(start: newest, end: newest + 1)
                historyRunRange = TimeRange(start: min(r.start, newest), end: max(r.end, newest + 1))
            }
        case .historyChunkSaved(_, _, let acknowledged):
            if acknowledged { historyChunksAcknowledged += 1 }
            invalidateHistoryRange()
        case .historyComplete(let at, let chunks, let acknowledged):
            connection.sync = .idle
            connection.lastCompletedSync = at
            if chunks == 0 {
                updateCheck("history", .unverified, "The band reported no stored history to transfer, so saving could not be checked.")
            } else if acknowledged == 0 {
                updateCheck("history", .passed, "History transferred and saved (\(chunks) chunk\(chunks == 1 ? "" : "s")). Not acknowledged, so the band is expected to keep its copy (checklist 5.2 verifies it).")
            } else {
                updateCheck("history", .passed, "History transferred and saved; \(acknowledged) of \(chunks) chunk\(chunks == 1 ? "" : "s") acknowledged after saving.")
            }
            invalidateHistoryRange()
            autoValidationPending = true
            scheduleRefresh()
        case .historyStopped(let reason, let at):
            connection.sync = .failed(message: reason, at: at)
            updateCheck("history", .failed, reason)
            invalidateHistoryRange()
            // What arrived before the stop was saved: it can be validated too.
            autoValidationPending = true
            scheduleRefresh()
        case .deviceInformation(let field, let value):
            if field == "firmware" {
                // Validation verdicts are per firmware: cached values pick up the change through their
                // fingerprint, and history heart rate is re-gated on the next refresh.
                selectedDevice?.firmwareVersion = value
                diagnostics.firmware = value
            }
        case .battery(let percent):
            diagnostics.batteryPercent = percent
        case .clockOffset(let millis):
            recordClockCheck(abs(millis) <= 2_000 ? .passed : .unverified,
                             "Band clock differs from this iPhone by \(DisplayFormat.number(Double(millis) / 1_000, digits: 1)) s.")
        case .clockImplausible(let offset):
            let days = DisplayFormat.number(Double(abs(offset)) / 86_400_000, digits: 1)
            recordClockCheck(.failed,
                             "The band's clock is off by about \(days) days. Forma never sets the band's clock, so band history can't be placed in time and is left on the band. Opening the official app once usually corrects the band's clock.")
        case .pairingRequired:
            alertMessage = "The band asked for a paired connection. Accept the iOS pairing prompt; Forma never bypasses pairing."
        case .commandSent(let name):
            if isRunningCompatibilityTest { testCommandNames.append(name) }
            if name == AllowedCommand.setRealtimeHeartRate(enabled: false).name {
                platform.setPreference(nil, forKey: Self.realtimeStreamPreferenceKey)
            }
        case .counters(let c):
            diagnostics.counters = countersBase.adding(c)
            diagnostics.capturedEntries = recorder.count
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
            lastClockCheck = nil
            if selectedDevice != nil, !isDemo {
                connection.link = collectionEnabled ? .searching : .disconnected(since: at)
            }
            if case .syncingHistory = connection.sync { connection.sync = .idle }
            invalidateHistoryRange()
            scheduleRefresh()
        }
    }

    /// Connect and service-layout checks from the link as it was set up.
    func recordLinkChecks() {
        updateCheck("connect", .passed, "Connected directly over Bluetooth; no account or internet used.")
        let hasVendor = diagnostics.services.contains { UUIDs.equal($0.uuid, Whoop5Adapter.service) }
        let hasHR = diagnostics.services.contains { UUIDs.equal($0.uuid, UUIDs.heartRateService) }
        updateCheck("gatt", hasVendor || hasHR ? .passed : .failed,
                    "Vendor service \(hasVendor ? "present" : "absent"); standard heart-rate service \(hasHR ? "present" : "absent").")
        if !hasHR { updateCheck("standardHR", .notApplicable, "The band does not expose the standard heart-rate service on this connection.") }
    }

    /// The clock check of this connection, kept for a compatibility test started while connected.
    func recordClockCheck(_ status: CheckStatus, _ detail: String) {
        lastClockCheck = (status, detail)
        updateCheck("clock", status, detail)
    }

    func updateCheck(_ id: String, _ status: CheckStatus, _ detail: String) {
        guard let i = diagnostics.checks.firstIndex(where: { $0.id == id }) else { return }
        // Never downgrade a passed check during the same test with a weaker result.
        if diagnostics.checks[i].status == .passed && status == .unverified { return }
        diagnostics.checks[i].status = status
        diagnostics.checks[i].detail = detail
    }

    func checkStatus(_ id: String) -> CheckStatus? {
        diagnostics.checks.first { $0.id == id }?.status
    }
}
