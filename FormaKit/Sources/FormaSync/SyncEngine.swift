import Foundation
import FormaCore
import FormaProtocol

/// Whether band history is requested (mirrors the user's explicit choice).
public enum HistoryPolicy: String, Sendable, Codable {
    /// Never request history. History another app triggers is counted, not stored.
    case off
    /// Request history only when asked (`requestHistorySync()`).
    case manual
    /// Request history after every connection.
    case automatic
}

public struct SyncOptions: Sendable, Equatable {
    public var history: HistoryPolicy
    /// Send the band an acknowledgement for each history chunk that arrived intact and was durably
    /// saved. Off by default: the acknowledgement layout comes from public research and is not verified
    /// on hardware, and an acknowledgement may let the band free that data. Without it the band keeps
    /// its copy and sends it again next time (duplicates are skipped).
    public var acknowledgeHistory: Bool
    /// Ask the band for its vendor real-time heart-rate stream while connected.
    public var liveHeartRate: Bool
    /// Record raw notifications/commands into the capture recorder, and unparsed frames into the
    /// sink's bounded raw-frame table.
    public var rawCapture: Bool
    /// Persist live samples at least this often (ms of receive time) — keeps transactions short.
    public var liveFlushIntervalMillis: Int64
    /// Persist history records in sub-batches of this size while a chunk is still arriving.
    public var historySubBatchSize: Int
    /// Give up on a transfer when no history packet arrives for this long (ms).
    public var historyIdleTimeoutMillis: Int64
    /// How long to wait for the answer to a command before treating it as lost (ms).
    public var commandTimeoutMillis: Int64
    /// How long to keep waiting each time the band answers "pending" (ms).
    public var pendingGraceMillis: Int64
    /// Extra attempts at the history-range request after a refusal, an invalid answer or a timeout.
    public var rangeRetries: Int
    /// Delay before such a retry (ms).
    public var retryDelayMillis: Int64
    /// Send the read-only identify request after connecting (when the adapter supports it).
    public var identifyOnConnect: Bool
    /// Read the band's clock after connecting (when supported); history waits for it.
    public var readClockOnConnect: Bool
    /// Period of the internal timer that enforces the timeouts above (ms of real time). 0 disables it;
    /// callers (tests) then drive timeouts with `checkDeadlines()`.
    public var timerIntervalMillis: Int64

    public init(history: HistoryPolicy = .off, acknowledgeHistory: Bool = false, liveHeartRate: Bool = false,
                rawCapture: Bool = false, liveFlushIntervalMillis: Int64 = 10_000, historySubBatchSize: Int = 500,
                historyIdleTimeoutMillis: Int64 = 30_000, commandTimeoutMillis: Int64 = 7_000,
                pendingGraceMillis: Int64 = 25_000, rangeRetries: Int = 2, retryDelayMillis: Int64 = 1_000,
                identifyOnConnect: Bool = true, readClockOnConnect: Bool = true, timerIntervalMillis: Int64 = 1_000) {
        self.history = history
        self.acknowledgeHistory = acknowledgeHistory
        self.liveHeartRate = liveHeartRate
        self.rawCapture = rawCapture
        self.liveFlushIntervalMillis = max(0, liveFlushIntervalMillis)
        self.historySubBatchSize = max(1, historySubBatchSize)
        self.historyIdleTimeoutMillis = max(1_000, historyIdleTimeoutMillis)
        self.commandTimeoutMillis = max(100, commandTimeoutMillis)
        self.pendingGraceMillis = max(100, pendingGraceMillis)
        self.rangeRetries = max(0, rangeRetries)
        self.retryDelayMillis = max(0, retryDelayMillis)
        self.identifyOnConnect = identifyOnConnect
        self.readClockOnConnect = readClockOnConnect
        self.timerIntervalMillis = max(0, timerIntervalMillis)
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
    /// Latest vendor real-time heart-rate candidate (unvalidated; shown in diagnostics only).
    public var lastRealtimeCandidateBPM: Int?
    public var historyRecords = 0
    public var historyRecordsUnmapped = 0
    /// History records of kinds Forma does not decode (their chunks are never acknowledged).
    public var historyRecordsUndecoded = 0
    /// History records that arrived outside a transfer Forma requested.
    public var historyRecordsUnsolicited = 0
    public var historyChunksSaved = 0
    public var historyChunksAcknowledged = 0
    public var acknowledgementsAccepted = 0
    public var acknowledgementsRejected = 0
    public var commandsSent = 0
    public var commandResponses = 0
    /// Responses whose echoed sequence differed from the request's (accepted by command id).
    public var responseSequenceMismatches = 0
    public var deviceEvents = 0
    public var persistedRecords = 0
    public var duplicateRecords = 0
    public var logLinesSuppressed = 0

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
    /// A heart rate that may be shown as live data (standard service, or a validated vendor field).
    case liveHeartRate(bpm: Int, at: EpochMillis, source: MeasurementSource)
    case historyStarted(at: EpochMillis)
    /// `records`: records received in this transfer; `newestRecord`: newest record time seen so far.
    case historyProgress(records: Int, newestRecord: EpochMillis?)
    /// One chunk finished: counts are for that chunk only.
    case historyChunkSaved(inserted: Int, duplicates: Int, acknowledged: Bool)
    /// A transfer Forma requested finished and everything it sent was saved intact. `acknowledged`
    /// counts the chunks confirmed to the band (0 when acknowledgements are off).
    case historyComplete(at: EpochMillis, chunks: Int, acknowledged: Int)
    case historyStopped(reason: String, at: EpochMillis)
    case deviceInformation(field: String, value: String)
    case battery(percent: Int)
    case clockOffset(millis: Int64)
    /// The band's clock is off by more than a day (or before 2020): history cannot be placed in time.
    case clockImplausible(offsetMillis: Int64)
    case pairingRequired
    case commandSent(name: String)
    case counters(SyncCounters)
    case frame(FrameLogEntry)
    case persistenceFailed(message: String)
    case disconnected(reason: String?, at: EpochMillis)
}

/// Drives one band connection: decode → normalize → persist → (only then, and only if enabled)
/// acknowledge.
///
/// The engine is transport-agnostic: the app hands it a Core Bluetooth link, tests and `forma-replay`
/// hand it a `ReplayLink`. Guarantees:
/// - Forma acts on band history only inside a transfer it requested (policy on, after its own request).
///   History another app triggers on the shared link is never acknowledged, aborted or written to the
///   sync cursor; it is stored (dedup-safe) only when history is enabled.
/// - An acknowledgement is sent only when acknowledgements are enabled AND the chunk's start marker was
///   seen, every frame in it arrived intact (no checksum failure, no truncation, no partial frame left),
///   every record could be placed in time and was of a kind Forma stores, everything was saved, and the
///   save was made durable. Once a chunk of a transfer fails any of these, no later chunk of that
///   transfer is acknowledged.
/// - Forma never sends an abort; it simply stops acknowledging, so the band keeps the data.
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
    private var batchesThisRun = 0
    private var timerTask: Task<Void, Never>?
    /// Newest receive time seen on the link; with the time source it defines the engine's clock for
    /// timeouts, so replayed captures reproduce a band that went silent.
    private var latestEventTime: EpochMillis = .min

    // Live buffer
    private var liveHR: [HeartRateSample] = []
    private var liveBeats: [BeatInterval] = []
    private var liveAux: [AuxMeasurement] = []
    private var lastLiveFlush: EpochMillis?
    private var realtimeStreamOn = false

    // Clock
    private var clockReadSent = false
    private var clockReadingReceived = false

    // History
    private enum HistoryPhase: Equatable {
        case idle
        /// Waiting for the clock reading before asking for history.
        case awaitingClock(deadline: EpochMillis)
        /// GET-range sent; waiting for its answer.
        case awaitingRange(attempt: Int, deadline: EpochMillis)
        /// Range request will be re-sent at `at`.
        case rangeRetry(attempt: Int, at: EpochMillis)
        /// History requested; waiting for data.
        case requested(deadline: EpochMillis)
        case receiving(deadline: EpochMillis)
        /// A transfer Forma requested failed. Late records are still saved; nothing is acknowledged.
        case failed
    }

    private struct Transfer {
        var startedAt: EpochMillis
        var chunks = 0
        var chunksAcknowledged = 0
        var problems: [String] = []
        var ackBlocked = false
        var records = 0
        var newestRecord: EpochMillis?
    }

    private struct Chunk {
        var startSeen = false
        var records = 0
        var unmapped = 0
        var undecoded = 0
        var undecodedKinds: Set<UInt8> = []
        var integrityLost = false
        var persistenceFailed = false
        var inserted = 0
        var duplicates = 0
        var newestPersisted: EpochMillis?
        var isOpen: Bool { startSeen || records > 0 }
    }

    private var phase: HistoryPhase = .idle
    private var transfer: Transfer?
    private var chunk = Chunk()
    private var generation = 0
    private var pendingAck: (sequence: UInt8, token: [UInt8])?
    private var historyHR: [HeartRateSample] = []
    private var historyBeats: [BeatInterval] = []
    private var historyMotion: [MotionEpoch] = []
    private var historyOutcome: SyncRunRecord.Status?
    private var historyOutcomeNote: String?

    // Telemetry throttling
    private var lastTelemetryEmit: EpochMillis?
    private var logWindowStart: EpochMillis = .min
    private var logLinesInWindow = 0
    private static let telemetryIntervalMillis: Int64 = 250
    private static let maxLogLinesPerSecond = 100

    public init(adapter: any DeviceAdapter, sink: any IngestSink, device: DeviceRecord, timeSource: any TimeSource,
                options: SyncOptions, recorder: CaptureRecorder? = nil) {
        self.adapter = adapter
        self.sink = sink
        self.device = device
        self.timeSource = timeSource
        self.options = options
        self.recorder = recorder
        var cont: AsyncStream<SyncUpdate>.Continuation!
        // Unbounded so state changes are never dropped; high-rate telemetry is throttled at the source.
        self.updates = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.updateContinuation = cont
    }

    deinit {
        timerTask?.cancel()
        updateContinuation.finish()
    }

    public var currentCounters: SyncCounters { counters }

    public func setOptions(_ newOptions: SyncOptions) async {
        let old = options
        options = newOptions
        guard link != nil else { return }
        if newOptions.history == .off, old.history != .off {
            // Stop owning any transfer: from now on history is only counted.
            if isOwnedTransferActive { finishTransfer(problem: "History sync was turned off during the transfer", at: timeSource.now()) }
            phase = .idle
        }
        if newOptions.liveHeartRate != realtimeStreamOn {
            await setRealtimeStream(newOptions.liveHeartRate)
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
        startTimer()

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
        timerTask?.cancel()
        timerTask = nil
        return runRecord ?? record
    }

    /// User-initiated "Sync now" (ignored when history is off or a transfer is running).
    public func requestHistorySync() async {
        await startHistory()
    }

    /// Enforces command and transfer timeouts against the engine's clock (the later of the time source
    /// and the newest receive time). Called by the internal timer and after every notification; tests with
    /// `timerIntervalMillis == 0` call it after advancing a manual clock.
    public func checkDeadlines() async {
        guard link != nil else { return }
        let now = engineNow()
        switch phase {
        case .awaitingClock(let deadline) where now >= deadline:
            log(.init(at: now, direction: "--", characteristic: "", summary: "no clock reading; using the band clock as-is", hexPreview: ""))
            await requestRangeOrHistory(attempt: 0)
        case .awaitingRange(let attempt, let deadline) where now >= deadline:
            await rangeAttemptFailed(attempt: attempt, reason: "The band did not answer the history-range request")
        case .rangeRetry(let attempt, let at) where now >= at:
            await sendRangeRequest(attempt: attempt)
        case .requested(let deadline) where now >= deadline:
            failTransfer("The band sent no history within \(options.historyIdleTimeoutMillis / 1_000) s of the request", at: now)
        case .receiving(let deadline) where now >= deadline:
            persistHistoryBuffer(note: "history")
            if chunk.isOpen { blockAcks("A history chunk stopped arriving before its end marker") }
            endTransferWithoutCompletion(at: now)
        default:
            break
        }
    }

    private func engineNow() -> EpochMillis { max(timeSource.now(), latestEventTime) }

    // MARK: - Event handling

    private func onReady(services: [String: [String]]) async {
        emit(.linkReady(services: services))
        recorder?.record(CaptureEntry(t: timeSource.now(), dir: .event, c: "", d: "", note: "ready: \(services.keys.sorted().joined(separator: ","))"))
        if options.identifyOnConnect { await sendIfSupported(.identify) }
        if options.readClockOnConnect, adapter.supports(.readClock) {
            clockReadSent = await send(.readClock)
        }
        await sendIfSupported(.readBattery)
        if options.liveHeartRate { await setRealtimeStream(true) }
        if options.history == .automatic { await startHistory() }
    }

    private func onNotification(characteristic: String, bytes: [UInt8], receivedAt: EpochMillis) async {
        latestEventTime = max(latestEventTime, receivedAt)
        if options.rawCapture {
            recorder?.record(CaptureEntry(t: receivedAt, dir: .rx, c: characteristic, d: HexCodec.encode(bytes)))
        }
        guard let decoder else { return }
        let events = decoder.decode(characteristic: characteristic, bytes: bytes, receivedAt: receivedAt)
        if options.rawCapture, let status = Self.rawStatus(of: events) {
            try? sink.recordRawFrame(RawFrameRecord(deviceID: device.id, receivedAt: receivedAt, characteristic: characteristic,
                                                    bytes: Data(bytes), parseStatus: status))
        }
        for e in events { await handle(e, characteristic: characteristic) }
        flushLiveIfDue(now: receivedAt)
        await checkDeadlines()
        emitTelemetry()
    }

    private func onDisconnect(reason: String?, at: EpochMillis) async {
        guard link != nil else { return }   // a link goes down once
        if let decoder {
            for e in decoder.reset(at: at) { await handle(e, characteristic: "") }
        }
        flushLive(force: true)
        // Persist whatever history arrived, whatever the state (dedup-safe); nothing is acknowledged.
        persistHistoryBuffer(note: "history")
        if isOwnedTransferActive {
            historyOutcome = .interrupted
            historyOutcomeNote = "Disconnected during history transfer"
            emit(.historyStopped(reason: "Disconnected during history transfer; unacknowledged data stays on the band", at: at))
        }
        phase = .idle
        transfer = nil
        chunk = Chunk()
        pendingAck = nil
        recorder?.record(CaptureEntry(t: at, dir: .event, c: "", d: "", note: "disconnect: \(reason ?? "")"))
        if var record = runRecord {
            record.endedAt = at
            if record.status == .running {
                record.status = historyOutcome ?? .completed
                record.note = historyOutcomeNote
            }
            record.batches = batchesThisRun
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
        timerTask?.cancel()
        timerTask = nil
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
            ingestRealtimeHR(bpm: bpm, deviceSeconds: deviceSeconds, status: status, receivedAt: receivedAt)

        case .historyRecord(let r):
            counters.framesValid += 1
            counters.historyRecords += 1
            await onHistoryRecord(r)

        case .historyMarker(let marker):
            counters.framesValid += 1
            await onHistoryMarker(marker, characteristic: characteristic)

        case .commandResponse(let response):
            counters.framesValid += 1
            counters.commandResponses += 1
            log(.init(at: response.receivedAt, direction: "rx", characteristic: characteristic,
                      summary: "response to cmd \(response.command) (\(response.answers?.rawValue ?? "unknown")) result \(response.resultCode.map(String.init) ?? "?")",
                      hexPreview: HexCodec.encode(response.data.prefix(24))))
            await onCommandResponse(response)

        case .deviceEvent(let ev):
            counters.framesValid += 1
            counters.deviceEvents += 1
            if ev.name == "RTC_LOST" || ev.name == "SET_RTC" || ev.name == "BOOT" {
                clock.markDiscontinuity()
                // Re-read the clock so the mapping has a fresh baseline.
                if adapter.supports(.readClock), link != nil { _ = await send(.readClock) }
            }
            log(.init(at: ev.receivedAt, direction: "rx", characteristic: characteristic, summary: "event \(ev.name) (\(ev.eventID))",
                      hexPreview: HexCodec.encode(ev.data.prefix(24))))

        case .batteryLevel(let percent, let receivedAt):
            liveAux.append(AuxMeasurement(deviceID: device.id, timestamp: receivedAt, kind: .batteryPercent, value: Double(percent),
                                          source: .liveVendorStream, validated: true, quality: [.phoneReceiveTime]))
            emit(.battery(percent: percent))

        case .clockReading(let deviceSeconds, let subsecondMillis, let receivedAt):
            clockReadingReceived = true
            let reading = DeviceClockReading(deviceSeconds: deviceSeconds, subsecondMillis: subsecondMillis, phoneTime: receivedAt)
            switch clock.add(reading) {
            case .accepted(let offset):
                emit(.clockOffset(millis: offset))
            case .implausible(let offset):
                emit(.clockImplausible(offsetMillis: offset))
                log(.init(at: receivedAt, direction: "rx", characteristic: characteristic,
                          summary: "band clock implausible (offset \(offset / 1_000) s); history cannot be placed in time", hexPreview: ""))
            }
            if case .awaitingClock = phase { await requestRangeOrHistory(attempt: 0) }

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

        case .malformed(let reason, let count, let source, let receivedAt):
            counters.framesMalformed += 1
            // Damage on a vendor characteristic inside a chunk may have hit a history record.
            if chunk.isOpen, Self.isVendorCharacteristic(source) { chunk.integrityLost = true }
            log(.init(at: receivedAt, direction: "rx", characteristic: source, summary: "malformed: \(reason) (\(count) bytes)", hexPreview: ""))
            if reason.lowercased().contains("pairing") { emit(.pairingRequired) }

        case .discarded(let count, let source, _):
            counters.bytesDiscarded += count
            if chunk.isOpen, Self.isVendorCharacteristic(source) { chunk.integrityLost = true }
        }
    }

    // MARK: - Live data

    private func ingestStandardHR(bpm: Int?, contact: SensorContactState, rr: [Double], receivedAt: EpochMillis) {
        var flags: QualityFlags = [.phoneReceiveTime]
        if contact == .notDetected { flags.insert(.noSensorContact) }
        if let bpm, bpm > 0 {
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
            guard let ts = EpochMillis(exactly: end.rounded()) else { break }
            var f = flags
            if !BeatInterval.plausibleMillis.contains(interval) { f.insert(.outOfRange) }
            reconstructed.append(BeatInterval(deviceID: device.id, timestamp: ts, intervalMillis: interval,
                                              source: .standardHeartRateService, recordKey: receivedAt, indexInRecord: index,
                                              receivedAt: receivedAt, timingBasis: .reconstructedFromReceiveTime, quality: f))
            end -= interval
        }
        liveBeats.append(contentsOf: reconstructed.reversed())
    }

    private func ingestRealtimeHR(bpm: Int, deviceSeconds: UInt32?, status: FieldStatus, receivedAt: EpochMillis) {
        // 0 (or less) is the band saying "no reading": never a measurement.
        guard bpm > 0 else { return }
        var flags: QualityFlags = []
        var ts = receivedAt
        var offset: Int64?
        var raw: Int64?
        if let s = deviceSeconds {
            let mapped = clock.map(deviceSeconds: s, now: timeSource.now())
            if let t = mapped.timestamp {
                ts = t
                raw = Int64(s)
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
                                      deviceTimeRaw: raw, receivedAt: receivedAt, clockOffsetMillis: offset, quality: flags))
        if status == .validated {
            emit(.liveHeartRate(bpm: bpm, at: ts, source: .liveVendorStream))
        } else {
            counters.lastRealtimeCandidateBPM = bpm
        }
    }

    private func flushLiveIfDue(now: EpochMillis) {
        guard let last = lastLiveFlush else {
            lastLiveFlush = now
            return
        }
        // A phone clock that stepped backwards must not stall persistence.
        if now >= last, Self.elapsed(from: last, to: now) < options.liveFlushIntervalMillis { return }
        flushLive(force: true)
        lastLiveFlush = now
    }

    private func flushLive(force: Bool) {
        guard !(liveHR.isEmpty && liveBeats.isEmpty && liveAux.isEmpty) else { return }
        let batch = IngestBatch(provenance: provenance(source: .liveVendorStream, note: "live"),
                                heartRates: liveHR, beatIntervals: liveBeats, aux: liveAux)
        do {
            let result = try sink.ingest(batch)
            batchesThisRun += 1
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

    private func setRealtimeStream(_ on: Bool) async {
        guard adapter.supports(.setRealtimeHeartRate(enabled: on)), link != nil else { return }
        if await send(.setRealtimeHeartRate(enabled: on)) { realtimeStreamOn = on }
    }

    // MARK: - History transfer (Forma-requested)

    private var isOwnedTransferActive: Bool {
        switch phase {
        case .idle, .failed: return false
        default: return true
        }
    }

    private func startHistory() async {
        guard options.history != .off, link != nil else { return }
        switch phase {
        case .idle, .failed: break
        default: return   // a transfer is already running
        }
        guard adapter.supports(.requestHistory) else {
            emit(.historyStopped(reason: "This band's history transfer is not supported by Forma yet", at: timeSource.now()))
            return
        }
        let now = timeSource.now()
        generation += 1
        // Late records of an earlier (failed) transfer are saved before this one starts.
        persistHistoryBuffer(note: "history")
        transfer = Transfer(startedAt: now)
        chunk = Chunk()
        pendingAck = nil
        discontinuity.reset()
        historyOutcome = nil
        historyOutcomeNote = nil
        emit(.historyStarted(at: now))
        if options.readClockOnConnect, adapter.supports(.readClock), !clockReadingReceived {
            phase = .awaitingClock(deadline: engineNow() + options.commandTimeoutMillis)
            if !clockReadSent { clockReadSent = await send(.readClock) }
            return
        }
        await requestRangeOrHistory(attempt: 0)
    }

    private func requestRangeOrHistory(attempt: Int) async {
        if adapter.supports(.readHistoryRange) {
            await sendRangeRequest(attempt: attempt)
        } else {
            await sendHistoryRequest()
        }
    }

    private func sendRangeRequest(attempt: Int) async {
        let gen = generation
        phase = .awaitingRange(attempt: attempt, deadline: engineNow() + options.commandTimeoutMillis)
        let ok = await send(.readHistoryRange)
        guard gen == generation, case .awaitingRange = phase else { return }
        if !ok { await rangeAttemptFailed(attempt: attempt, reason: "The history-range request could not be written") }
    }

    private func rangeAttemptFailed(attempt: Int, reason: String) async {
        if attempt < options.rangeRetries {
            phase = .rangeRetry(attempt: attempt + 1, at: engineNow() + options.retryDelayMillis)
            if options.retryDelayMillis == 0 { await checkDeadlines() }
        } else {
            failTransfer("\(reason) (after \(attempt + 1) attempts); nothing was requested", at: timeSource.now())
        }
    }

    private func sendHistoryRequest() async {
        let gen = generation
        phase = .requested(deadline: engineNow() + options.historyIdleTimeoutMillis)
        let ok = await send(.requestHistory)
        guard gen == generation, case .requested = phase else { return }
        if !ok { failTransfer("The history request could not be written", at: timeSource.now()) }
    }

    private func onCommandResponse(_ r: CommandResponse) async {
        guard let kind = r.answers else { return }
        switch kind {
        case .readHistoryRange:
            guard case .awaitingRange(let attempt, _) = phase else { return }
            switch r.status {
            case .pending:
                phase = .awaitingRange(attempt: attempt, deadline: engineNow() + options.pendingGraceMillis)
            case .success where r.data.count >= 25:
                // The range body is kept as evidence only (its fields are not interpreted).
                await sendHistoryRequest()
            case .success:
                await rangeAttemptFailed(attempt: attempt, reason: "The band's history-range answer was too short")
            case .rejected, .unknown:
                await rangeAttemptFailed(attempt: attempt, reason: "The band refused the history-range request (result \(r.resultCode.map(String.init) ?? "?"))")
            }
        case .requestHistory:
            switch phase {
            case .requested, .receiving:
                switch r.status {
                case .rejected:
                    failTransfer("The band declined the history request (result \(r.resultCode.map(String.init) ?? "?"))", at: timeSource.now())
                case .pending:
                    rearm(grace: options.pendingGraceMillis)
                case .success, .unknown:
                    rearm(grace: options.historyIdleTimeoutMillis)
                }
            default:
                return
            }
        case .acknowledgeHistory:
            guard pendingAck != nil else { return }
            pendingAck = nil
            if r.status == .success {
                counters.acknowledgementsAccepted += 1
            } else {
                counters.acknowledgementsRejected += 1
                if transfer != nil {
                    transfer?.ackBlocked = true
                    transfer?.problems.append("The band did not accept an acknowledgement (result \(r.resultCode.map(String.init) ?? "?"))")
                }
            }
        case .readClock:
            if r.status == .rejected, case .awaitingClock = phase { await requestRangeOrHistory(attempt: 0) }
        default:
            return
        }
    }

    private func rearm(grace: Int64) {
        let deadline = engineNow() + grace
        switch phase {
        case .requested: phase = .requested(deadline: deadline)
        case .receiving: phase = .receiving(deadline: deadline)
        default: break
        }
    }

    private func onHistoryRecord(_ r: HistoryRecord) async {
        let owned: Bool
        switch phase {
        case .requested, .receiving:
            owned = true
            phase = .receiving(deadline: engineNow() + options.historyIdleTimeoutMillis)
        default:
            owned = false
        }
        if !owned {
            counters.historyRecordsUnsolicited += 1
            // Not part of a transfer Forma asked for: never acknowledged. Stored only when history is on.
            guard options.history != .off else { return }
        }
        if owned { chunk.records += 1 }
        guard r.contentDecoded else {
            counters.historyRecordsUndecoded += 1
            if owned {
                chunk.undecoded += 1
                chunk.undecodedKinds.insert(r.kind)
            }
            return
        }
        let mapped = clock.map(deviceSeconds: r.deviceSeconds, now: timeSource.now())
        guard let ts = mapped.timestamp else {
            // Without a trustworthy time the record cannot be stored as a measurement, and the chunk
            // must not be acknowledged (the band keeps it).
            counters.historyRecordsUnmapped += 1
            if owned { chunk.unmapped += 1 }
            return
        }
        var flags = mapped.flags
        switch discontinuity.observe(kind: r.kind, counter: r.counter, deviceSeconds: r.deviceSeconds) {
        case .continuous: break
        case .counterRestart, .clockWentBackwards: flags.insert(.nearClockDiscontinuity)
        }
        let raw = Int64(r.deviceSeconds)
        if let bpm = r.heartRate, bpm > 0 {
            var f = flags
            if r.heartRateStatus == .unvalidated { f.insert(.unvalidatedField) }
            if !HeartRateSample.plausibleRange.contains(bpm) { f.insert(.outOfRange) }
            historyHR.append(HeartRateSample(deviceID: device.id, timestamp: ts, bpm: bpm, source: .deviceHistory,
                                             deviceTimeRaw: raw, receivedAt: r.receivedAt, clockOffsetMillis: mapped.appliedOffsetMillis,
                                             quality: f))
        }
        if let m = r.motion, m.sampleCount > 0, m.spanMillis > 0 {
            historyMotion.append(MotionEpoch(deviceID: device.id, timestamp: ts, epochMillis: m.spanMillis, activity: m.activity,
                                             sampleCount: m.sampleCount, source: .deviceHistory, quality: flags.union(.unvalidatedField)))
        }
        if !r.beatIntervalsMillis.isEmpty {
            // Intervals within one record: the last one ends at the record time (reconstruction, documented).
            var end = Double(ts)
            var items: [BeatInterval] = []
            let key = Int64(r.counter) << 32 | Int64(r.deviceSeconds)
            for (index, interval) in r.beatIntervalsMillis.enumerated().reversed() {
                guard let t = EpochMillis(exactly: end.rounded()) else { break }
                var f = flags
                if !BeatInterval.plausibleMillis.contains(interval) { f.insert(.outOfRange) }
                items.append(BeatInterval(deviceID: device.id, timestamp: t, intervalMillis: interval,
                                          source: .deviceHistory, recordKey: key, indexInRecord: index, receivedAt: r.receivedAt,
                                          timingBasis: .reconstructedFromRecordTime, quality: f))
                end -= interval
            }
            historyBeats.append(contentsOf: items.reversed())
        }
        if owned, transfer != nil {
            transfer!.records += 1
            transfer!.newestRecord = max(transfer!.newestRecord ?? ts, ts)
        }
        if historyHR.count + historyMotion.count + historyBeats.count >= options.historySubBatchSize {
            persistHistoryBuffer(note: owned ? "history" : "history (unsolicited)")
        }
        if owned, let t = transfer { emitTelemetry(progress: (t.records, t.newestRecord)) }
    }

    private func onHistoryMarker(_ marker: HistoryMarker, characteristic: String) async {
        log(.init(at: marker.receivedAt, direction: "rx", characteristic: "", summary: "history \(marker.kind.rawValue)\(isOwnedTransferActive ? "" : " (not requested by Forma)")",
                  hexPreview: HexCodec.encode(marker.ackToken ?? [])))
        switch phase {
        case .requested, .receiving:
            break
        default:
            // Someone else's transfer (or a failed one of ours): save what arrived, never act on it.
            if marker.kind != .start { persistHistoryBuffer(note: "history (unsolicited)") }
            return
        }
        let now = engineNow()
        switch marker.kind {
        case .start:
            if chunk.isOpen {
                persistHistoryBuffer(note: "history")
                blockAcks("A history chunk ended without an end marker")
            }
            chunk = Chunk()
            chunk.startSeen = true
            phase = .receiving(deadline: now + options.historyIdleTimeoutMillis)
        case .end:
            await finishChunk(marker, characteristic: characteristic)
            phase = .receiving(deadline: now + options.historyIdleTimeoutMillis)
        case .complete:
            persistHistoryBuffer(note: "history")
            if chunk.isOpen { blockAcks("The transfer ended inside a chunk (no end marker)") }
            finishTransfer(problem: nil, at: marker.receivedAt)
        }
    }

    /// Persists the chunk, decides whether it may be acknowledged, and acknowledges it if enabled.
    private func finishChunk(_ marker: HistoryMarker, characteristic: String) async {
        transfer?.chunks += 1
        var problem: String?
        if !chunk.startSeen { problem = "A history chunk arrived without its start marker" }
        else if chunk.integrityLost || (decoder?.pendingPartialBytes(excluding: characteristic) ?? 0) > 0 {
            problem = "Part of a history chunk arrived damaged or incomplete"
        }
        else if chunk.unmapped > 0 { problem = "The band's clock could not be trusted for \(chunk.unmapped) record(s)" }
        else if chunk.undecoded > 0 {
            let kinds = chunk.undecodedKinds.sorted().map(String.init).joined(separator: ", ")
            problem = "The chunk contained \(chunk.undecoded) record(s) Forma does not store yet (kinds \(kinds))"
        }
        // Final batch: remaining records, plus the cursor when the whole chunk is intact.
        var cursor: SyncCursor?
        if problem == nil, !chunk.persistenceFailed {
            do {
                let existing = try sink.syncCursor(deviceID: device.id)
                let newest = [existing?.newestPersistedRecordTime, chunk.newestPersisted, bufferedNewest()].compactMap { $0 }.max()
                cursor = SyncCursor(deviceID: device.id, adapterID: adapter.adapterID, opaque: existing?.opaque,
                                    newestPersistedRecordTime: newest, lastCompleteSyncAt: existing?.lastCompleteSyncAt,
                                    updatedAt: timeSource.now())
            } catch {
                chunk.persistenceFailed = true
            }
        }
        let saved = persistHistoryBuffer(note: "history", cursor: cursor) && !chunk.persistenceFailed
        if problem == nil, !saved { problem = "Saving a history chunk failed" }

        var acknowledged = false
        if let problem {
            blockAcks(problem)
        } else {
            counters.historyChunksSaved += 1
            if options.acknowledgeHistory, transfer?.ackBlocked == false, let token = marker.ackToken,
               adapter.supports(.acknowledgeHistory(token: token)) {
                acknowledged = await acknowledge(token: token)
            }
        }
        emit(.historyChunkSaved(inserted: chunk.inserted, duplicates: chunk.duplicates, acknowledged: acknowledged))
        if let t = transfer { emitTelemetry(progress: (t.records, t.newestRecord), force: true) }
        chunk = Chunk()
    }

    private func acknowledge(token: [UInt8]) async -> Bool {
        do {
            try sink.ensureDurable()
        } catch {
            blockAcks("Could not make the saved chunk durable (\(error)); nothing was acknowledged")
            return false
        }
        let gen = generation
        guard let seq = await sendReturningSequence(.acknowledgeHistory(token: token)) else {
            if gen == generation { blockAcks("The acknowledgement could not be written") }
            return false
        }
        guard gen == generation else { return true }
        pendingAck = (seq, token)
        transfer?.chunksAcknowledged += 1
        counters.historyChunksAcknowledged += 1
        // Record the token as the position acknowledged last (separate from the chunk's transaction).
        if let existing = try? sink.syncCursor(deviceID: device.id) {
            var c = existing
            c.opaque = Data(token)
            c.updatedAt = timeSource.now()
            if (try? sink.ingest(IngestBatch(provenance: provenance(source: .deviceHistory, note: "history ack"), cursor: c))) != nil {
                batchesThisRun += 1
            }
        }
        return true
    }

    private func blockAcks(_ reason: String) {
        guard transfer != nil else { return }
        transfer!.ackBlocked = true
        if !transfer!.problems.contains(reason) { transfer!.problems.append(reason) }
    }

    /// Ends the current Forma-requested transfer: complete when nothing went wrong, stopped otherwise.
    private func finishTransfer(problem: String?, at time: EpochMillis) {
        if let problem { blockAcks(problem) }
        guard let t = transfer else {
            phase = .idle
            return
        }
        if t.problems.isEmpty {
            if markHistoryComplete(at: time) {
                historyOutcome = .completed
                emit(.historyComplete(at: time, chunks: t.chunks, acknowledged: t.chunksAcknowledged))
            } else {
                historyOutcome = .failed
                historyOutcomeNote = "Could not record the completed sync"
                emit(.historyStopped(reason: "The transfer finished but its completion could not be saved", at: time))
            }
        } else {
            historyOutcome = .failed
            historyOutcomeNote = t.problems.first
            let detail = t.problems.joined(separator: "; ")
            emit(.historyStopped(reason: "\(detail). Nothing unsaved was acknowledged; the band keeps that data.", at: time))
        }
        transfer = nil
        chunk = Chunk()
        phase = .idle
    }

    /// The band stopped sending (idle) after at least part of a transfer, without its completion marker.
    /// Everything received was saved; the band keeps what it did not send (it may be waiting for an
    /// acknowledgement, which may be off). Never recorded as a completed sync.
    private func endTransferWithoutCompletion(at time: EpochMillis) {
        guard let t = transfer else {
            phase = .idle
            return
        }
        if !t.problems.isEmpty {
            failTransfer(t.problems.joined(separator: "; "), at: time)
            return
        }
        historyOutcome = .interrupted
        historyOutcomeNote = "The band did not finish the transfer"
        let saved = t.chunks == 0 ? "Nothing was saved" : "Saved \(t.chunks) chunk\(t.chunks == 1 ? "" : "s")"
        let why = options.acknowledgeHistory ? "" : " (it may be waiting for an acknowledgement, which is off)"
        emit(.historyStopped(reason: "\(saved); the band then stopped sending without finishing\(why). The rest stays on the band.", at: time))
        transfer = nil
        chunk = Chunk()
        pendingAck = nil
        phase = .idle
    }

    private func failTransfer(_ reason: String, at time: EpochMillis) {
        blockAcks(reason)
        historyOutcome = .failed
        historyOutcomeNote = reason
        emit(.historyStopped(reason: "\(reason); nothing unsaved was acknowledged, the band keeps that data.", at: time))
        transfer = nil
        chunk = Chunk()
        pendingAck = nil
        phase = .failed
    }

    // MARK: - Persistence

    private func bufferedNewest() -> EpochMillis? {
        (historyHR.map(\.timestamp) + historyMotion.map(\.timestamp) + historyBeats.map(\.timestamp)).max()
    }

    /// Persists buffered history records (with `cursor` in the same transaction when given). Returns
    /// false if the write failed; the failure taints the open chunk.
    @discardableResult
    private func persistHistoryBuffer(note: String, cursor: SyncCursor? = nil) -> Bool {
        guard !(historyHR.isEmpty && historyMotion.isEmpty && historyBeats.isEmpty && cursor == nil) else { return true }
        let newest = bufferedNewest()
        let batch = IngestBatch(provenance: provenance(source: .deviceHistory, note: note), heartRates: historyHR,
                                beatIntervals: historyBeats, motion: historyMotion, cursor: cursor)
        historyHR.removeAll(keepingCapacity: true)
        historyMotion.removeAll(keepingCapacity: true)
        historyBeats.removeAll(keepingCapacity: true)
        do {
            let result = try sink.ingest(batch)
            batchesThisRun += 1
            counters.persistedRecords += result.inserted
            counters.duplicateRecords += result.duplicates
            if chunk.isOpen {
                chunk.inserted += result.inserted
                chunk.duplicates += result.duplicates
                if let newest { chunk.newestPersisted = max(chunk.newestPersisted ?? newest, newest) }
            }
            return true
        } catch {
            if chunk.isOpen { chunk.persistenceFailed = true }
            emit(.persistenceFailed(message: "Saving band history failed: \(error)"))
            return false
        }
    }

    private func markHistoryComplete(at time: EpochMillis) -> Bool {
        do {
            let existing = try sink.syncCursor(deviceID: device.id)
            let cursor = SyncCursor(deviceID: device.id, adapterID: adapter.adapterID, opaque: existing?.opaque,
                                    newestPersistedRecordTime: existing?.newestPersistedRecordTime,
                                    lastCompleteSyncAt: time, updatedAt: timeSource.now())
            _ = try sink.ingest(IngestBatch(provenance: provenance(source: .deviceHistory, note: "history complete"), cursor: cursor))
            batchesThisRun += 1
            return true
        } catch {
            emit(.persistenceFailed(message: "Saving the sync position failed: \(error)"))
            return false
        }
    }

    // MARK: - Commands

    private func sendIfSupported(_ command: AllowedCommand) async {
        guard adapter.supports(command) else { return }
        _ = await send(command)
    }

    /// Writes an allowlisted command. Returns false on encoding or write failure.
    @discardableResult
    private func send(_ command: AllowedCommand) async -> Bool {
        await sendReturningSequence(command) != nil
    }

    private func sendReturningSequence(_ command: AllowedCommand) async -> UInt8? {
        guard let link, let characteristic = adapter.gatt.commandCharacteristic, adapter.supports(command) else { return nil }
        let seq = sequence.next()
        let encoded: EncodedCommand
        do {
            encoded = try adapter.encode(command, sequence: seq)
        } catch {
            log(.init(at: timeSource.now(), direction: "tx", characteristic: characteristic, summary: "not sent (\(command.name)): \(error)", hexPreview: ""))
            return nil
        }
        let now = timeSource.now()
        do {
            try await link.write(encoded, characteristic: characteristic, withResponse: adapter.gatt.commandWriteWithResponse)
            counters.commandsSent += 1
            if options.rawCapture {
                recorder?.record(CaptureEntry(t: now, dir: .tx, c: characteristic, d: HexCodec.encode(encoded.bytes), note: command.name))
            }
            emit(.commandSent(name: command.name))
            log(.init(at: now, direction: "tx", characteristic: characteristic, summary: command.name, hexPreview: HexCodec.encode(encoded.bytes.prefix(24))))
            return seq
        } catch LinkError.pairingRequired {
            if options.rawCapture {
                recorder?.record(CaptureEntry(t: now, dir: .event, c: characteristic, d: "", note: "write refused (pairing required): \(command.name)"))
            }
            emit(.pairingRequired)
            return nil
        } catch {
            if options.rawCapture {
                recorder?.record(CaptureEntry(t: now, dir: .event, c: characteristic, d: "", note: "write failed: \(command.name)"))
            }
            log(.init(at: now, direction: "tx", characteristic: characteristic, summary: "write failed (\(command.name)): \(error)", hexPreview: ""))
            return nil
        }
    }

    // MARK: - Helpers

    private func startTimer() {
        timerTask?.cancel()
        let interval = options.timerIntervalMillis
        guard interval > 0 else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.checkDeadlines()
            }
        }
    }

    private func provenance(source: MeasurementSource, note: String) -> Provenance {
        Provenance(deviceID: device.id, adapterID: adapter.adapterID, parserVersion: adapter.parserVersion,
                   firmwareVersion: device.firmwareVersion, source: source, syncRunID: syncRunID, createdAt: timeSource.now(), note: note)
    }

    private func emit(_ update: SyncUpdate) {
        updateContinuation.yield(update)
    }

    /// Counters (and transfer progress) at most every 250 ms of `timeSource` time, or when forced.
    private func emitTelemetry(progress: (Int, EpochMillis?)? = nil, force: Bool = false) {
        let now = timeSource.now()
        if !force, let last = lastTelemetryEmit, now >= last, Self.elapsed(from: last, to: now) < Self.telemetryIntervalMillis { return }
        lastTelemetryEmit = now
        if let progress { emit(.historyProgress(records: progress.0, newestRecord: progress.1)) }
        emit(.counters(counters))
    }

    private func log(_ entry: FrameLogEntry) {
        let now = timeSource.now()
        if now < logWindowStart || Self.elapsed(from: logWindowStart, to: now) >= 1_000 {
            logWindowStart = now
            logLinesInWindow = 0
        }
        guard logLinesInWindow < Self.maxLogLinesPerSecond else {
            counters.logLinesSuppressed += 1
            return
        }
        logLinesInWindow += 1
        emit(.frame(entry))
    }

    /// Saturating `to − from` (capture times are untrusted).
    static func elapsed(from: EpochMillis, to: EpochMillis) -> Int64 {
        let (d, overflow) = to.subtractingReportingOverflow(from)
        if overflow { return to > from ? .max : .min }
        return d
    }

    /// Parse status for the raw-frame table: only notifications that produced unparsed bytes are kept.
    static func rawStatus(of events: [DecodedEvent]) -> String? {
        var status: String?
        for e in events {
            switch e {
            case .malformed: return "malformed"
            case .unknownPacket: status = "unknown"
            case .discarded: if status == nil { status = "discarded" }
            default: break
            }
        }
        return status
    }

    static func hex(_ bytes: [UInt8]) -> String { HexCodec.encode(bytes) }

    /// Bluetooth SIG characteristics (16-bit UUIDs on the SIG base) never carry vendor history frames.
    static func isVendorCharacteristic(_ uuid: String) -> Bool {
        !UUIDs.normalize(uuid).hasSuffix(UUIDs.sigBaseSuffix)
    }
}
