import Foundation
import FormaCore
import FormaProtocol

/// Whether band history is requested/acknowledged (mirrors the user's explicit choice).
public enum HistoryPolicy: String, Sendable, Codable {
    case off, manual, automatic
}

public struct SyncOptions: Sendable, Equatable {
    public var history: HistoryPolicy
    /// Ask the band for its vendor real-time heart-rate stream while connected.
    public var liveHeartRate: Bool
    /// Record raw notifications/commands into the capture recorder.
    public var rawCapture: Bool
    /// Persist live samples at least this often (ms of receive time) — keeps transactions short.
    public var liveFlushIntervalMillis: Int64
    /// Persist history records in sub-batches of this size while a chunk is still arriving.
    public var historySubBatchSize: Int
    /// Abort a history transfer when no history packet arrives for this long (ms of receive time).
    public var historyIdleTimeoutMillis: Int64
    /// Send the read-only identify request after connecting (when the adapter supports it).
    public var identifyOnConnect: Bool

    public init(history: HistoryPolicy = .off, liveHeartRate: Bool = true, rawCapture: Bool = false,
                liveFlushIntervalMillis: Int64 = 10_000, historySubBatchSize: Int = 500,
                historyIdleTimeoutMillis: Int64 = 30_000, identifyOnConnect: Bool = true) {
        self.history = history
        self.liveHeartRate = liveHeartRate
        self.rawCapture = rawCapture
        self.liveFlushIntervalMillis = max(0, liveFlushIntervalMillis)
        self.historySubBatchSize = max(1, historySubBatchSize)
        self.historyIdleTimeoutMillis = max(1_000, historyIdleTimeoutMillis)
        self.identifyOnConnect = identifyOnConnect
    }
}

/// Diagnostic counters for one engine lifetime.
public struct SyncCounters: Hashable, Sendable, Codable {
    public var framesValid = 0
    public var framesMalformed = 0
    public var bytesDiscarded = 0
    public var unknownPackets = 0
    public var standardHRNotifications = 0
    public var standardHRWithRR = 0
    public var realtimeHRPackets = 0
    public var historyRecords = 0
    public var historyRecordsUnmapped = 0
    public var commandsSent = 0
    public var commandResponses = 0
    public var deviceEvents = 0
    public var persistedRecords = 0
    public var duplicateRecords = 0

    public init() {}
}

/// A line for the diagnostics frame log.
public struct FrameLogEntry: Hashable, Sendable {
    public var at: EpochMillis
    public var direction: String
    public var characteristic: String
    public var summary: String
    public var hexPreview: String
}

/// Progress/status the UI listens to.
public enum SyncUpdate: Sendable, Equatable {
    case linkReady(services: [String: [String]])
    case liveHeartRate(bpm: Int, at: EpochMillis, source: MeasurementSource)
    case historyStarted(at: EpochMillis)
    case historyProgress(records: Int, newestRecord: EpochMillis?)
    case historyChunkSaved(inserted: Int, duplicates: Int, acknowledged: Bool)
    case historyComplete(at: EpochMillis)
    case historyStopped(reason: String, at: EpochMillis)
    case deviceInformation(field: String, value: String)
    case battery(percent: Int)
    case clockOffset(millis: Int64)
    case pairingRequired
    case commandSent(name: String)
    case counters(SyncCounters)
    case frame(FrameLogEntry)
    case persistenceFailed(message: String)
    case disconnected(reason: String?, at: EpochMillis)
}

/// Drives one band connection: decode → normalize → persist → (only then) acknowledge.
///
/// The engine is transport-agnostic: the app hands it a Core Bluetooth link, tests and `forma-replay`
/// hand it a `ReplayLink`. Guarantees:
/// - History acknowledgements are sent only after every record of the chunk is durably persisted, and
///   never for a chunk that contained records whose timestamps could not be mapped (those stay on the band).
/// - A failed persistence aborts the transfer without acknowledging.
/// - Unknown/malformed input is counted and logged, never fatal.
/// - Only commands in `AllowedCommand` that the adapter supports are ever written.
public actor SyncEngine {
    public nonisolated let updates: AsyncStream<SyncUpdate>
    private let updateContinuation: AsyncStream<SyncUpdate>.Continuation

    private let adapter: any DeviceAdapter
    private let sink: any IngestSink
    private var device: DeviceRecord
    private let timeSource: any TimeSource
    private var options: SyncOptions
    private let recorder: CaptureRecorder?

    private var link: (any PeripheralLink)?
    private var decoder: (any DeviceDecoder)?
    private var sequence = SequenceCounter()
    private var clock = ClockMapper()
    private var discontinuity = DiscontinuityDetector()
    private var counters = SyncCounters()
    private var syncRunID: Int64?
    private var runRecord: SyncRunRecord?

    // Live buffer
    private var liveHR: [HeartRateSample] = []
    private var liveBeats: [BeatInterval] = []
    private var liveAux: [AuxMeasurement] = []
    private var lastLiveFlush: EpochMillis?

    // History transfer state
    private enum HistoryState: Equatable { case idle, requested, receiving, failed }
    private var historyState: HistoryState = .idle
    private var historyHR: [HeartRateSample] = []
    private var historyBeats: [BeatInterval] = []
    private var historyMotion: [MotionEpoch] = []
    private var chunkHasUnmappedRecords = false
    private var chunkPersistenceFailed = false
    private var chunkRecordCount = 0
    private var newestPersistedInRun: EpochMillis?
    private var lastHistoryActivity: EpochMillis?
    private var historyRecordsThisRun = 0

    public init(adapter: any DeviceAdapter, sink: any IngestSink, device: DeviceRecord, timeSource: any TimeSource,
                options: SyncOptions, recorder: CaptureRecorder? = nil) {
        self.adapter = adapter
        self.sink = sink
        self.device = device
        self.timeSource = timeSource
        self.options = options
        self.recorder = recorder
        var cont: AsyncStream<SyncUpdate>.Continuation!
        self.updates = AsyncStream(bufferingPolicy: .bufferingNewest(1_000)) { cont = $0 }
        self.updateContinuation = cont
    }

    deinit {
        updateContinuation.finish()
    }

    public var currentCounters: SyncCounters { counters }

    public func setOptions(_ newOptions: SyncOptions) async {
        let liveChanged = newOptions.liveHeartRate != options.liveHeartRate
        options = newOptions
        if liveChanged, link != nil {
            await sendIfSupported(.setRealtimeHeartRate(enabled: newOptions.liveHeartRate))
        }
    }

    /// Consumes the link's events until it disconnects. Returns the finished sync-run record.
    @discardableResult
    public func run(link: any PeripheralLink) async -> SyncRunRecord {
        self.link = link
        self.decoder = adapter.makeDecoder()
        let start = timeSource.now()
        var record = SyncRunRecord(deviceID: device.id, startedAt: start, status: .running)
        do {
            syncRunID = try sink.beginSyncRun(record)
            record.id = syncRunID
        } catch {
            emit(.persistenceFailed(message: "Could not record sync run: \(error)"))
        }
        runRecord = record
        try? sink.upsertDevice(device)

        for await event in link.events {
            switch event {
            case .ready(let services):
                await onReady(services: services)
            case .notification(let characteristic, let bytes, let receivedAt):
                await onNotification(characteristic: characteristic, bytes: bytes, receivedAt: receivedAt)
            case .disconnected(let reason, let at):
                await onDisconnect(reason: reason, at: at)
            }
        }
        // Stream ended without an explicit disconnect event.
        if self.link != nil { await onDisconnect(reason: "link closed", at: timeSource.now()) }
        return runRecord ?? record
    }

    /// User-initiated "Sync now" (ignored when history is off or a transfer is running).
    public func requestHistorySync() async {
        guard options.history != .off, link != nil, historyState == .idle || historyState == .failed else { return }
        await startHistory()
    }

    // MARK: - Event handling

    private func onReady(services: [String: [String]]) async {
        emit(.linkReady(services: services))
        recorder?.record(CaptureEntry(t: timeSource.now(), dir: .event, c: "", d: "", note: "ready: \(services.keys.sorted().joined(separator: ","))"))
        if options.identifyOnConnect { await sendIfSupported(.identify) }
        await sendIfSupported(.readClock)
        await sendIfSupported(.readBattery)
        if options.liveHeartRate { await sendIfSupported(.setRealtimeHeartRate(enabled: true)) }
        if options.history == .automatic { await startHistory() }
    }

    private func onNotification(characteristic: String, bytes: [UInt8], receivedAt: EpochMillis) async {
        if options.rawCapture {
            recorder?.record(CaptureEntry(t: receivedAt, dir: .rx, c: characteristic, d: Self.hex(bytes)))
        }
        guard let decoder else { return }
        let events = decoder.decode(characteristic: characteristic, bytes: bytes, receivedAt: receivedAt)
        for e in events { await handle(e, characteristic: characteristic) }
        await flushLiveIfDue(now: receivedAt)
        await checkHistoryIdle(now: receivedAt)
        emit(.counters(counters))
    }

    private func onDisconnect(reason: String?, at: EpochMillis) async {
        if let decoder {
            for e in decoder.reset(at: at) { await handle(e, characteristic: "") }
        }
        flushLive(force: true)
        if historyState == .requested || historyState == .receiving {
            // Persist what arrived (dedup-safe), but never acknowledge an incomplete chunk.
            _ = persistHistory(cursorToken: nil, final: false)
            historyState = .idle
            emit(.historyStopped(reason: "Disconnected during history transfer; unacknowledged data stays on the band", at: at))
        }
        recorder?.record(CaptureEntry(t: at, dir: .event, c: "", d: "", note: "disconnect: \(reason ?? "")"))
        if var record = runRecord {
            record.endedAt = at
            record.status = record.status == .running ? (historyRecordsThisRun > 0 ? .interrupted : .completed) : record.status
            record.recordsInserted = counters.persistedRecords
            record.duplicates = counters.duplicateRecords
            record.malformedFrames = counters.framesMalformed
            try? sink.finishSyncRun(record)
            runRecord = record
        }
        emit(.counters(counters))
        emit(.disconnected(reason: reason, at: at))
        link = nil
        decoder = nil
    }

    private func handle(_ event: DecodedEvent, characteristic: String) async {
        switch event {
        case .standardHeartRate(let bpm, let contact, let rr, _, let receivedAt):
            counters.standardHRNotifications += 1
            if !rr.isEmpty { counters.standardHRWithRR += 1 }
            ingestStandardHR(bpm: bpm, contact: contact, rr: rr, receivedAt: receivedAt)

        case .realtimeHeartRate(let bpm, let deviceSeconds, let status, let receivedAt):
            counters.realtimeHRPackets += 1
            counters.framesValid += 1
            var flags: QualityFlags = []
            var ts = receivedAt
            var offset: Int64?
            if let s = deviceSeconds {
                let mapped = clock.map(deviceSeconds: s, now: timeSource.now())
                if let t = mapped.timestamp {
                    ts = t
                    flags.formUnion(mapped.flags)
                    offset = mapped.appliedOffsetMillis
                } else {
                    flags.insert(.phoneReceiveTime)
                }
            } else {
                flags.insert(.phoneReceiveTime)
            }
            if status == .unvalidated { flags.insert(.unvalidatedField) }
            if !HeartRateSample.plausibleRange.contains(bpm) { flags.insert(.outOfRange) }
            liveHR.append(HeartRateSample(deviceID: device.id, timestamp: ts, bpm: bpm, source: .liveVendorStream,
                                          deviceTimeRaw: deviceSeconds.map(Int64.init), receivedAt: receivedAt,
                                          clockOffsetMillis: offset, quality: flags))
            emit(.liveHeartRate(bpm: bpm, at: ts, source: .liveVendorStream))

        case .historyRecord(let r):
            counters.framesValid += 1
            counters.historyRecords += 1
            historyRecordsThisRun += 1
            lastHistoryActivity = r.receivedAt
            if historyState == .requested || historyState == .idle { historyState = .receiving }
            ingestHistoryRecord(r)
            if historyHR.count + historyMotion.count + historyBeats.count >= options.historySubBatchSize {
                _ = persistHistory(cursorToken: nil, final: false)
            }

        case .historyMarker(let marker):
            counters.framesValid += 1
            lastHistoryActivity = marker.receivedAt
            await handleMarker(marker)

        case .commandResponse(let response):
            counters.framesValid += 1
            counters.commandResponses += 1
            log(.init(at: response.receivedAt, direction: "rx", characteristic: characteristic,
                      summary: "response to cmd \(response.command) result \(response.resultCode.map(String.init) ?? "?")",
                      hexPreview: Self.hex(Array(response.data.prefix(24)))))

        case .deviceEvent(let ev):
            counters.framesValid += 1
            counters.deviceEvents += 1
            if ev.name == "RTC_LOST" || ev.name == "SET_RTC" || ev.name == "BOOT" { clock.markDiscontinuity() }
            log(.init(at: ev.receivedAt, direction: "rx", characteristic: characteristic, summary: "event \(ev.name) (\(ev.eventID))",
                      hexPreview: Self.hex(Array(ev.data.prefix(24)))))

        case .batteryLevel(let percent, let receivedAt):
            liveAux.append(AuxMeasurement(deviceID: device.id, timestamp: receivedAt, kind: .batteryPercent, value: Double(percent),
                                          source: .liveVendorStream, validated: true, quality: [.phoneReceiveTime]))
            emit(.battery(percent: percent))

        case .clockReading(let deviceSeconds, let receivedAt):
            clock.add(DeviceClockReading(deviceSeconds: deviceSeconds, phoneTime: receivedAt))
            emit(.clockOffset(millis: receivedAt - Int64(deviceSeconds) * 1_000))

        case .deviceInformation(let field, let value):
            if field == "firmware" {
                device.firmwareVersion = value
                try? sink.upsertDevice(device)
            } else if field == "hardware" {
                device.hardwareRevision = value
                try? sink.upsertDevice(device)
            }
            emit(.deviceInformation(field: field, value: value))

        case .unknownPacket(let type, let length, _, let receivedAt):
            counters.framesValid += 1
            counters.unknownPackets += 1
            log(.init(at: receivedAt, direction: "rx", characteristic: characteristic, summary: "unknown packet type \(type) (\(length) bytes)", hexPreview: ""))

        case .malformed(let reason, let count, _, let receivedAt):
            counters.framesMalformed += 1
            log(.init(at: receivedAt, direction: "rx", characteristic: characteristic, summary: "malformed: \(reason) (\(count) bytes)", hexPreview: ""))
            if reason.lowercased().contains("pairing") { emit(.pairingRequired) }

        case .discarded(let count, _, _):
            counters.bytesDiscarded += count
        }
    }

    // MARK: - Live data

    private func ingestStandardHR(bpm: Int?, contact: SensorContactState, rr: [Double], receivedAt: EpochMillis) {
        var flags: QualityFlags = [.phoneReceiveTime]
        if contact == .notDetected { flags.insert(.noSensorContact) }
        if let bpm {
            var f = flags
            if !HeartRateSample.plausibleRange.contains(bpm) { f.insert(.outOfRange) }
            liveHR.append(HeartRateSample(deviceID: device.id, timestamp: receivedAt, bpm: bpm, source: .standardHeartRateService,
                                          receivedAt: receivedAt, quality: f))
            emit(.liveHeartRate(bpm: bpm, at: receivedAt, source: .standardHeartRateService))
        }
        // Beat intervals: the last interval ends at receive time; earlier ones are reconstructed backwards.
        var end = Double(receivedAt)
        var reconstructed: [BeatInterval] = []
        for (index, interval) in rr.enumerated().reversed() {
            var f = flags
            if !BeatInterval.plausibleMillis.contains(interval) { f.insert(.outOfRange) }
            reconstructed.append(BeatInterval(deviceID: device.id, timestamp: EpochMillis(end.rounded()), intervalMillis: interval,
                                              source: .standardHeartRateService, recordKey: receivedAt, indexInRecord: index,
                                              receivedAt: receivedAt, timingBasis: .reconstructedFromReceiveTime, quality: f))
            end -= interval
        }
        liveBeats.append(contentsOf: reconstructed.reversed())
    }

    private func flushLiveIfDue(now: EpochMillis) async {
        if let last = lastLiveFlush, now - last < options.liveFlushIntervalMillis { return }
        if lastLiveFlush == nil { lastLiveFlush = now; return }
        flushLive(force: true)
        lastLiveFlush = now
    }

    private func flushLive(force: Bool) {
        guard !(liveHR.isEmpty && liveBeats.isEmpty && liveAux.isEmpty) else { return }
        let batch = IngestBatch(provenance: provenance(source: .liveVendorStream, note: "live"),
                                heartRates: liveHR, beatIntervals: liveBeats, aux: liveAux)
        do {
            let result = try sink.ingest(batch)
            counters.persistedRecords += result.inserted
            counters.duplicateRecords += result.duplicates
            liveHR.removeAll(keepingCapacity: true)
            liveBeats.removeAll(keepingCapacity: true)
            liveAux.removeAll(keepingCapacity: true)
        } catch {
            // Keep the buffer (bounded) and retry on the next flush.
            emit(.persistenceFailed(message: "Saving live data failed: \(error)"))
            let cap = 20_000
            if liveHR.count > cap { liveHR.removeFirst(liveHR.count - cap) }
            if liveBeats.count > cap * 3 { liveBeats.removeFirst(liveBeats.count - cap * 3) }
            if liveAux.count > 1_000 { liveAux.removeFirst(liveAux.count - 1_000) }
        }
    }

    // MARK: - History

    private func startHistory() async {
        guard adapter.supports(.requestHistory) else {
            emit(.historyStopped(reason: "This band's history transfer is not supported by Forma yet", at: timeSource.now()))
            return
        }
        resetChunk()
        historyState = .requested
        lastHistoryActivity = timeSource.now()
        emit(.historyStarted(at: timeSource.now()))
        if adapter.supports(.readHistoryRange) { await sendIfSupported(.readHistoryRange) }
        await sendIfSupported(.requestHistory)
    }

    private func ingestHistoryRecord(_ r: HistoryRecord) {
        let mapped = clock.map(deviceSeconds: r.deviceSeconds, now: timeSource.now())
        var flags = mapped.flags
        switch discontinuity.observe(counter: r.counter, deviceSeconds: r.deviceSeconds) {
        case .continuous: break
        case .counterRestart, .clockWentBackwards: flags.insert(.nearClockDiscontinuity)
        }
        guard let ts = mapped.timestamp else {
            // Without a trustworthy time the record cannot be stored as a measurement, and the chunk
            // must not be acknowledged (the band keeps it).
            counters.historyRecordsUnmapped += 1
            chunkHasUnmappedRecords = true
            return
        }
        chunkRecordCount += 1
        let raw = Int64(r.deviceSeconds)
        if let bpm = r.heartRate {
            var f = flags
            if r.heartRateStatus == .unvalidated { f.insert(.unvalidatedField) }
            if !HeartRateSample.plausibleRange.contains(bpm) { f.insert(.outOfRange) }
            historyHR.append(HeartRateSample(deviceID: device.id, timestamp: ts, bpm: bpm, source: .deviceHistory,
                                             deviceTimeRaw: raw, receivedAt: r.receivedAt, clockOffsetMillis: mapped.appliedOffsetMillis,
                                             quality: f))
        }
        if let m = r.motion, m.sampleCount > 0 {
            historyMotion.append(MotionEpoch(deviceID: device.id, timestamp: ts, epochMillis: 1_000, activity: m.activity,
                                             sampleCount: m.sampleCount, source: .deviceHistory, quality: flags.union(.unvalidatedField)))
        }
        if !r.beatIntervalsMillis.isEmpty {
            // Intervals within one record: the last one ends at the record time (reconstruction, documented).
            var end = Double(ts)
            var items: [BeatInterval] = []
            let key = Int64(r.counter) << 32 | Int64(r.deviceSeconds)
            for (index, interval) in r.beatIntervalsMillis.enumerated().reversed() {
                var f = flags
                if !BeatInterval.plausibleMillis.contains(interval) { f.insert(.outOfRange) }
                items.append(BeatInterval(deviceID: device.id, timestamp: EpochMillis(end.rounded()), intervalMillis: interval,
                                          source: .deviceHistory, recordKey: key, indexInRecord: index, receivedAt: r.receivedAt,
                                          timingBasis: .reconstructedFromRecordTime, quality: f))
                end -= interval
            }
            historyBeats.append(contentsOf: items.reversed())
        }
        emit(.historyProgress(records: historyRecordsThisRun, newestRecord: ts))
    }

    private func handleMarker(_ marker: HistoryMarker) async {
        switch marker.kind {
        case .start:
            historyState = .receiving
            resetChunk()
        case .end:
            let persisted = persistHistory(cursorToken: marker.ackToken, final: true)
            var acknowledged = false
            if persisted, !chunkHasUnmappedRecords, !chunkPersistenceFailed, let token = marker.ackToken,
               options.history != .off, adapter.supports(.acknowledgeHistory(token: token)) {
                acknowledged = await send(.acknowledgeHistory(token: token))
            }
            emit(.historyChunkSaved(inserted: counters.persistedRecords, duplicates: counters.duplicateRecords, acknowledged: acknowledged))
            if !acknowledged {
                let reason: String
                if chunkPersistenceFailed || !persisted { reason = "Saving failed; nothing was acknowledged, the band keeps the data" }
                else if chunkHasUnmappedRecords { reason = "The band's clock could not be trusted for some records; they were left on the band" }
                else if marker.ackToken == nil { reason = "The band's end-of-chunk marker carried no acknowledgement token" }
                else { reason = "Acknowledgement not sent" }
                historyState = .failed
                if adapter.supports(.abortHistory) { _ = await send(.abortHistory) }
                emit(.historyStopped(reason: reason, at: marker.receivedAt))
            } else {
                historyState = .receiving
            }
            resetChunk()
        case .complete:
            if historyState != .failed {
                markHistoryComplete(at: marker.receivedAt)
                emit(.historyComplete(at: marker.receivedAt))
            }
            historyState = .idle
        }
    }

    /// Persists buffered history records. With `final`, also stores the cursor in the same transaction.
    /// Returns false if any write failed.
    @discardableResult
    private func persistHistory(cursorToken: [UInt8]?, final: Bool) -> Bool {
        let newest = (historyHR.map(\.timestamp) + historyMotion.map(\.timestamp) + historyBeats.map(\.timestamp)).max()
        var cursor: SyncCursor?
        if final {
            let existing = try? sink.syncCursor(deviceID: device.id)
            let newestPersisted = [existing?.newestPersistedRecordTime, newestPersistedInRun, newest].compactMap { $0 }.max()
            cursor = SyncCursor(deviceID: device.id, adapterID: adapter.adapterID, opaque: cursorToken.map { Data($0) },
                                newestPersistedRecordTime: chunkHasUnmappedRecords ? (existing?.newestPersistedRecordTime) : newestPersisted,
                                lastCompleteSyncAt: existing?.lastCompleteSyncAt, updatedAt: timeSource.now())
        }
        guard !(historyHR.isEmpty && historyMotion.isEmpty && historyBeats.isEmpty && cursor == nil) else { return !chunkPersistenceFailed }
        let batch = IngestBatch(provenance: provenance(source: .deviceHistory, note: "history"), heartRates: historyHR,
                                beatIntervals: historyBeats, motion: historyMotion, cursor: cursor)
        do {
            let result = try sink.ingest(batch)
            counters.persistedRecords += result.inserted
            counters.duplicateRecords += result.duplicates
            if let newest, !chunkHasUnmappedRecords { newestPersistedInRun = max(newestPersistedInRun ?? newest, newest) }
            historyHR.removeAll(keepingCapacity: true)
            historyMotion.removeAll(keepingCapacity: true)
            historyBeats.removeAll(keepingCapacity: true)
            return !chunkPersistenceFailed
        } catch {
            chunkPersistenceFailed = true
            emit(.persistenceFailed(message: "Saving band history failed: \(error)"))
            historyHR.removeAll()
            historyMotion.removeAll()
            historyBeats.removeAll()
            return false
        }
    }

    private func markHistoryComplete(at time: EpochMillis) {
        let existing = try? sink.syncCursor(deviceID: device.id)
        let cursor = SyncCursor(deviceID: device.id, adapterID: adapter.adapterID, opaque: existing?.opaque,
                                newestPersistedRecordTime: [existing?.newestPersistedRecordTime, newestPersistedInRun].compactMap { $0 }.max(),
                                lastCompleteSyncAt: time, updatedAt: timeSource.now())
        _ = try? sink.ingest(IngestBatch(provenance: provenance(source: .deviceHistory, note: "history complete"), cursor: cursor))
    }

    private func resetChunk() {
        chunkHasUnmappedRecords = false
        chunkPersistenceFailed = false
        chunkRecordCount = 0
    }

    private func checkHistoryIdle(now: EpochMillis) async {
        guard historyState == .requested || historyState == .receiving, let last = lastHistoryActivity else { return }
        if now - last > options.historyIdleTimeoutMillis {
            _ = persistHistory(cursorToken: nil, final: false)
            historyState = .failed
            if adapter.supports(.abortHistory) { _ = await send(.abortHistory) }
            emit(.historyStopped(reason: "No history data arrived for \(options.historyIdleTimeoutMillis / 1_000) s; transfer stopped without acknowledging", at: now))
        }
    }

    // MARK: - Commands

    private func sendIfSupported(_ command: AllowedCommand) async {
        guard adapter.supports(command) else { return }
        _ = await send(command)
    }

    /// Writes an allowlisted command. Returns false on encoding or write failure.
    private func send(_ command: AllowedCommand) async -> Bool {
        guard let link, let characteristic = adapter.gatt.commandCharacteristic else { return false }
        let seq = sequence.next()
        let bytes: [UInt8]
        do {
            bytes = try adapter.encode(command, sequence: seq)
        } catch {
            log(.init(at: timeSource.now(), direction: "tx", characteristic: characteristic, summary: "not sent (\(command.name)): \(error)", hexPreview: ""))
            return false
        }
        let now = timeSource.now()
        if options.rawCapture {
            recorder?.record(CaptureEntry(t: now, dir: .tx, c: characteristic, d: Self.hex(bytes), note: command.name))
        }
        do {
            try await link.write(bytes, characteristic: characteristic, withResponse: adapter.gatt.commandWriteWithResponse)
            counters.commandsSent += 1
            emit(.commandSent(name: command.name))
            log(.init(at: now, direction: "tx", characteristic: characteristic, summary: command.name, hexPreview: Self.hex(Array(bytes.prefix(24)))))
            return true
        } catch LinkError.pairingRequired {
            emit(.pairingRequired)
            return false
        } catch {
            log(.init(at: now, direction: "tx", characteristic: characteristic, summary: "write failed (\(command.name)): \(error)", hexPreview: ""))
            return false
        }
    }

    // MARK: - Helpers

    private func provenance(source: MeasurementSource, note: String) -> Provenance {
        Provenance(deviceID: device.id, adapterID: adapter.adapterID, parserVersion: adapter.parserVersion,
                   firmwareVersion: device.firmwareVersion, source: source, syncRunID: syncRunID, createdAt: timeSource.now(), note: note)
    }

    private func emit(_ update: SyncUpdate) {
        updateContinuation.yield(update)
    }

    private func log(_ entry: FrameLogEntry) {
        emit(.frame(entry))
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits: [Character] = Array("0123456789abcdef")
        var s = ""
        s.reserveCapacity(bytes.count * 2)
        for b in bytes {
            s.append(digits[Int(b >> 4)])
            s.append(digits[Int(b & 0x0F)])
        }
        return s
    }
}
