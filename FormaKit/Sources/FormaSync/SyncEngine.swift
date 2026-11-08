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
    /// Read the band's clock after connecting (when supported); history waits for it, and for the fresh
    /// reading taken after a clock event.
    public var readClockOnConnect: Bool
    /// Period of the internal timer that enforces the timeouts above (ms of real time). 0 disables it;
    /// callers (tests) then drive timeouts with `checkDeadlines()`.
    public var timerIntervalMillis: Int64

    /// Upper bound of every duration above (1 h). Larger values are clamped (the engine also saturates its
    /// deadline arithmetic, so values set directly on the properties cannot overflow either).
    public static let maxDurationMillis: Int64 = 3_600_000

    public init(history: HistoryPolicy = .off, acknowledgeHistory: Bool = false, liveHeartRate: Bool = false,
                rawCapture: Bool = false, liveFlushIntervalMillis: Int64 = 10_000, historySubBatchSize: Int = 500,
                historyIdleTimeoutMillis: Int64 = 30_000, commandTimeoutMillis: Int64 = 7_000,
                pendingGraceMillis: Int64 = 25_000, rangeRetries: Int = 2, retryDelayMillis: Int64 = 1_000,
                identifyOnConnect: Bool = true, readClockOnConnect: Bool = true, timerIntervalMillis: Int64 = 1_000) {
        self.history = history
        self.acknowledgeHistory = acknowledgeHistory
        self.liveHeartRate = liveHeartRate
        self.rawCapture = rawCapture
        self.liveFlushIntervalMillis = Self.clamp(liveFlushIntervalMillis, atLeast: 0)
        self.historySubBatchSize = min(max(1, historySubBatchSize), 100_000)
        self.historyIdleTimeoutMillis = Self.clamp(historyIdleTimeoutMillis, atLeast: 1_000)
        self.commandTimeoutMillis = Self.clamp(commandTimeoutMillis, atLeast: 100)
        self.pendingGraceMillis = Self.clamp(pendingGraceMillis, atLeast: 100)
        self.rangeRetries = min(max(0, rangeRetries), 10)
        self.retryDelayMillis = Self.clamp(retryDelayMillis, atLeast: 0)
        self.identifyOnConnect = identifyOnConnect
        self.readClockOnConnect = readClockOnConnect
        self.timerIntervalMillis = Self.clamp(timerIntervalMillis, atLeast: 0)
    }

    static func clamp(_ value: Int64, atLeast lower: Int64) -> Int64 { min(max(lower, value), maxDurationMillis) }
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
    /// History records Forma does not fully decode (their chunks are never acknowledged).
    public var historyRecordsUndecoded = 0
    /// History records that arrived outside a transfer Forma requested.
    public var historyRecordsUnsolicited = 0
    /// Records of a Forma transfer that mapped to the same stored time as a different record of that
    /// transfer (only one of them can be kept; their chunks are never acknowledged).
    public var historyTimeCollisions = 0
    /// End-of-chunk markers of Forma's transfers (whatever happened to the chunk's records).
    public var historyChunksReceived = 0
    /// Chunks saved intact: eligible for acknowledgement (sent only when that experimental setting is on).
    public var historyChunksSaved = 0
    public var historyChunksAcknowledged = 0
    /// Completion markers the band sent for Forma's transfers (whether or not the transfer was complete
    /// for Forma: a chunk with records Forma does not decode, for example, keeps it incomplete).
    public var historyTransfersFinishedByBand = 0
    /// Band records skipped as duplicates whose stored match was not clearly the same record (see
    /// `IngestResult.ambiguousDuplicates`); their chunks are not acknowledged.
    public var historyAmbiguousDuplicates = 0
    public var acknowledgementsAccepted = 0
    public var acknowledgementsRejected = 0
    public var commandsSent = 0
    public var commandResponses = 0
    /// Responses whose echoed sequence matched no command of that kind Forma wrote: another app's
    /// answer, or a band that does not echo the sequence. They are still matched by command id, but
    /// during a history transfer one stops acknowledgements for the rest of it.
    public var responseSequenceMismatches = 0
    /// Notifications the link reported lost before delivery (they may have carried history).
    public var notificationGaps = 0
    public var deviceEvents = 0
    public var persistedRecords = 0
    public var duplicateRecords = 0
    /// Band-history records newly saved, and those already stored (skipped as duplicates); live data is
    /// not included (it is in `persistedRecords` and `duplicateRecords`).
    public var historyRecordsSaved = 0
    public var historyRecordsAlreadyStored = 0
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
///   seen, every frame on the vendor characteristics arrived intact while it was open (no checksum
///   failure, truncation, partial frame, lost notification, or frame Forma does not decode), every record
///   was fully decoded, could be placed in time and kept (no two records on one stored time, and no
///   record skipped as a duplicate of a stored band record it matched only by band time or only by stored
///   time), everything was saved, and the save was made durable. Once a chunk of a transfer fails any of these
///   — or the band's clock changes, a history answer does not match Forma's request, or the band refuses
///   an acknowledgement — no later chunk of that transfer is acknowledged.
/// - Forma never sends an abort; it simply stops acknowledging, so the band keeps the data.
/// - Settings, "Sync now" and the timer may run while the engine waits for a write; every step after
///   such a wait re-checks that the transfer it belongs to is still the current one.
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
    /// Live mapping: real-time data, history outside a Forma transfer, and the start of the next transfer.
    private var clock = SyncEngine.makeClockMapper()
    private var discontinuity = DiscontinuityDetector()
    private var counters = SyncCounters()
    private var syncRunID: Int64?
    private var runRecord: SyncRunRecord?
    /// Counters when the current run started (the run record reports that run's share).
    private var runBaseline = SyncCounters()
    private var batchesThisRun = 0
    private var timerTask: Task<Void, Never>?

    // Engine clock (deadlines only): the later of the time source and the newest receive time, each kept
    // monotonic by absorbing backward steps, so replayed captures reproduce a silent band and a phone clock
    // set back does not freeze the timeouts.
    private var lastSourceTime: EpochMillis?
    private var sourceShift: Int64 = 0
    private var lastReceiveTime: EpochMillis?
    private var receiveShift: Int64 = 0
    private var receiveClock: EpochMillis = .min

    // Live buffer
    private var liveHR: [HeartRateSample] = []
    private var liveBeats: [BeatInterval] = []
    private var liveAux: [AuxMeasurement] = []
    private var lastLiveFlush: EpochMillis?
    /// The real-time stream state last confirmed by a successful write; nil while unknown (Forma may have
    /// left it on during an earlier connection, see `init(…realtimeStreamMayBeOn:)`).
    private var realtimeStreamOn: Bool? = false
    private var realtimeToggleRunning = false
    /// Whether Forma may have left the band's real-time stream on before this engine (the next connection
    /// then switches it off when it is not wanted).
    private var realtimeStreamMayBeOn: Bool

    // Clock reads
    /// A GET_CLOCK was written and not answered yet (set before the write, so nothing sends a second one).
    private var clockReadOutstanding = false
    /// A reading arrived since the connection started or since the last clock event.
    private var clockReadingReceived = false

    /// Sequences of written commands not answered yet, per kind (oldest first, bounded).
    private var sentSequences: [AllowedCommand.Kind: [UInt8]] = [:]

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
        /// What went wrong with the data: the transfer cannot be recorded as complete.
        var problems: [String] = []
        /// Why acknowledgements stopped although the data was saved intact.
        var ackHolds: [String] = []
        var ackBlocked = false
        var records = 0
        var newestRecord: EpochMillis?
        /// Mapping for this transfer's records, fixed when history was requested (the band wrote them under
        /// the clock it had then; a later clock change must not shift them).
        var clock: ClockMapper?
        /// The band's clock changed (clock event) after this transfer started: its records' absolute times
        /// are uncertain (flagged) and nothing more is acknowledged.
        var clockChanged = false
        var heartRateTimes = TimeClaims()
        var motionTimes = TimeClaims()
    }

    private struct Chunk {
        var startSeen = false
        var records = 0
        var unmapped = 0
        var undecoded = 0
        var undecodedKinds: Set<UInt8> = []
        /// Frames inside the chunk that are neither records nor markers Forma decodes.
        var foreignFrames = 0
        var foreignDescriptions: Set<String> = []
        var collisions = 0
        var integrityLost = false
        var persistenceFailed = false
        var inserted = 0
        var duplicates = 0
        /// Saved records whose stored match was not clearly the same record (never acknowledged).
        var ambiguousDuplicates = 0
        var newestPersisted: EpochMillis?
        var isOpen: Bool { startSeen || records > 0 }
    }

    private struct HistoryBuffer {
        var hr: [HeartRateSample] = []
        var beats: [BeatInterval] = []
        var motion: [MotionEpoch] = []
        var isEmpty: Bool { hr.isEmpty && beats.isEmpty && motion.isEmpty }
        var count: Int { hr.count + beats.count + motion.count }
        var newest: EpochMillis? {
            [hr.map(\.timestamp).max(), motion.map(\.timestamp).max(), beats.map(\.timestamp).max()].compactMap { $0 }.max()
        }
        mutating func removeAll() {
            hr.removeAll(keepingCapacity: true)
            beats.removeAll(keepingCapacity: true)
            motion.removeAll(keepingCapacity: true)
        }
        /// Bounds a buffer kept for a retry (oldest dropped first).
        mutating func trim(toAtMost limit: Int) {
            if hr.count > limit { hr.removeFirst(hr.count - limit) }
            if motion.count > limit { motion.removeFirst(motion.count - limit) }
            if beats.count > limit * 3 { beats.removeFirst(beats.count - limit * 3) }
        }
    }

    private var phase: HistoryPhase = .idle
    private var transfer: Transfer?
    private var chunk = Chunk()
    /// Changes whenever the current transfer starts or ends: work resumed after a write checks it.
    private var transferGeneration = 0
    /// Records of the open chunk of a Forma transfer (saved with the chunk; the only ones in the cursor).
    private var owned = HistoryBuffer()
    /// Records outside a Forma transfer (never acknowledged, never in the cursor; kept for a retry when a
    /// save fails, because another app may acknowledge them).
    private var unsolicited = HistoryBuffer()
    private var historyOutcome: SyncRunRecord.Status?
    private var historyOutcomeNote: String?

    // Telemetry throttling
    private var lastTelemetryEmit: EpochMillis?
    private var telemetryPending = false
    private var pendingProgress: (records: Int, newest: EpochMillis?)?
    private var logWindowStart: EpochMillis = .min
    private var logLinesInWindow = 0
    private static let telemetryIntervalMillis: Int64 = 250
    private static let maxLogLinesPerSecond = 100
    private static let maxRetainedUnsolicited = 20_000
    private static let maxRememberedSequences = 16

    /// - Parameter realtimeStreamMayBeOn: Forma requested the band's real-time stream earlier and has not
    ///   seen it switched off (for example the app was ended during a workout, or a new engine took over a
    ///   connection). The first connection then sends "off" when the stream is not wanted, instead of
    ///   assuming it is already off. Forma never switches off a stream it did not request.
    public init(adapter: any DeviceAdapter, sink: any IngestSink, device: DeviceRecord, timeSource: any TimeSource,
                options: SyncOptions, recorder: CaptureRecorder? = nil, realtimeStreamMayBeOn: Bool = false) {
        self.adapter = adapter
        self.sink = sink
        self.device = device
        self.timeSource = timeSource
        self.options = options
        self.recorder = recorder
        self.realtimeStreamMayBeOn = realtimeStreamMayBeOn
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

    /// The engine's clock mapping: corrections in whole seconds (see `ClockMapper.resolutionMillis`).
    static func makeClockMapper() -> ClockMapper { ClockMapper(resolutionMillis: 1_000) }

    public func setOptions(_ newOptions: SyncOptions) async {
        let old = options
        options = newOptions
        guard link != nil else { return }
        if newOptions.history == .off, old.history != .off {
            // Stop owning any transfer: what already arrived is saved first; from now on history is only counted.
            persistAllHistory()
            if isOwnedTransferActive {
                finishTransfer(problem: "History sync was turned off during the transfer", at: timeSource.now(), bandFinished: false)
            }
            transferGeneration += 1
            phase = .idle
        }
        await syncRealtimeStream()
    }

    /// Consumes the link's events until it disconnects. Returns the finished sync-run record.
    @discardableResult
    public func run(link: any PeripheralLink) async -> SyncRunRecord {
        resetConnectionState()
        self.link = link
        self.decoder = adapter.makeDecoder()
        let start = timeSource.now()
        runBaseline = counters
        batchesThisRun = 0
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
            case .gap(let characteristic, let count, let at):
                await onGap(characteristic: characteristic, count: count, at: at)
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

    /// Enforces command and transfer timeouts against the engine's clock (the later of the time source and
    /// the newest receive time). Called by the internal timer and before every notification is handled;
    /// tests with `timerIntervalMillis == 0` call it after advancing a manual clock.
    public func checkDeadlines() async {
        guard link != nil else { return }
        let now = engineNow()
        switch phase {
        case .awaitingClock(let deadline) where now >= deadline:
            clockReadOutstanding = false   // treat the read as lost; a later transfer asks again
            log(.init(at: timeSource.now(), direction: "--", characteristic: "", summary: "no clock reading; using the band clock as-is", hexPreview: ""))
            await requestRangeOrHistory(attempt: 0)
        case .awaitingRange(let attempt, let deadline) where now >= deadline:
            await rangeAttemptFailed(attempt: attempt, reason: "The band did not answer the history-range request")
        case .rangeRetry(let attempt, let at) where now >= at:
            await sendRangeRequest(attempt: attempt)
        case .requested(let deadline) where now >= deadline:
            persistAllHistory()
            failTransfer("The band sent no history within \(options.historyIdleTimeoutMillis / 1_000) s of the request", at: timeSource.now())
        case .receiving(let deadline) where now >= deadline:
            persistAllHistory()
            if chunk.isOpen { blockAcks("A history chunk stopped arriving before its end marker") }
            endTransferWithoutCompletion(at: timeSource.now())
        default:
            break
        }
        if telemetryPending { emitTelemetry() }
    }

    // MARK: - Engine clock

    private func engineNow() -> EpochMillis { max(sourceNow(), receiveClock) }

    /// The time source, made monotonic: a step back (phone clock set back) pauses it instead of rewinding it.
    private func sourceNow() -> EpochMillis {
        let t = timeSource.now()
        if let last = lastSourceTime, t < last { sourceShift = sat(sourceShift, Self.elapsed(from: t, to: last)) }
        lastSourceTime = t
        return sat(t, sourceShift)
    }

    /// A receive time advances the engine clock (made monotonic the same way). Receive times more than a day
    /// ahead of the time source are ignored: one absurd stamp must not expire every deadline for good.
    private func noteReceiveTime(_ receivedAt: EpochMillis) {
        var shift = receiveShift
        if let last = lastReceiveTime, receivedAt < last { shift = sat(shift, Self.elapsed(from: receivedAt, to: last)) }
        let projected = sat(receivedAt, shift)
        guard projected <= sat(sourceNow(), EpochMillis.millisPerDay) else { return }   // ignored entirely
        receiveShift = shift
        lastReceiveTime = receivedAt
        receiveClock = max(receiveClock, projected)
    }

    private func deadline(after millis: Int64) -> EpochMillis { sat(engineNow(), max(0, millis)) }

    // MARK: - Event handling

    private func resetConnectionState() {
        clock = Self.makeClockMapper()
        discontinuity.reset()
        lastSourceTime = nil
        sourceShift = 0
        lastReceiveTime = nil
        receiveShift = 0
        receiveClock = .min
        lastLiveFlush = nil
        realtimeStreamOn = realtimeStreamMayBeOn ? nil : false
        realtimeStreamMayBeOn = false
        realtimeToggleRunning = false
        clockReadOutstanding = false
        clockReadingReceived = false
        sentSequences = [:]
        transferGeneration += 1
        phase = .idle
        transfer = nil
        chunk = Chunk()
        historyOutcome = nil
        historyOutcomeNote = nil
        pendingProgress = nil
        telemetryPending = false
    }

    private func onReady(services: [String: [String]]) async {
        emit(.linkReady(services: services))
        recorder?.record(CaptureEntry(t: timeSource.now(), dir: .event, c: "", d: "", note: "ready: \(services.keys.sorted().joined(separator: ","))"))
        if options.identifyOnConnect { await sendIfSupported(.identify) }
        if options.readClockOnConnect { await readClock() }
        await sendIfSupported(.readBattery)
        await syncRealtimeStream()
        if options.history == .automatic { await startHistory() }
    }

    private func onNotification(characteristic: String, bytes: [UInt8], receivedAt: EpochMillis) async {
        noteReceiveTime(receivedAt)
        if options.rawCapture {
            recorder?.record(CaptureEntry(t: receivedAt, dir: .rx, c: characteristic, d: HexCodec.encode(bytes)))
        }
        // Deadlines that passed before this notification arrived expire first, so a late answer or a chunk
        // after a silence is judged exactly as the live timer would have judged it.
        await checkDeadlines()
        guard let decoder else { return }
        let events = decoder.decode(characteristic: characteristic, bytes: bytes, receivedAt: receivedAt)
        if options.rawCapture, let status = Self.rawStatus(of: events) {
            try? sink.recordRawFrame(RawFrameRecord(deviceID: device.id, receivedAt: receivedAt, characteristic: characteristic,
                                                    bytes: Data(bytes), parseStatus: status))
        }
        for e in events { await handle(e, characteristic: characteristic) }
        flushLiveIfDue(now: receivedAt)
        emitTelemetry()
    }

    /// The link lost notifications: whatever they carried is gone, so an open chunk is damaged.
    private func onGap(characteristic: String?, count: Int, at: EpochMillis) async {
        noteReceiveTime(at)
        let n = max(1, count)
        counters.notificationGaps += n
        recorder?.record(CaptureEntry(t: at, dir: .event, c: characteristic ?? "", d: "", note: "gap: \(n) notification(s) lost"))
        log(.init(at: at, direction: "rx", characteristic: characteristic ?? "", summary: "\(n) notification(s) lost by the link", hexPreview: ""))
        await checkDeadlines()
        if chunk.isOpen { chunk.integrityLost = true }
        if isReceivingOwnedHistory { blockAcks("Notifications were lost during the transfer") }
        emitTelemetry()
    }

    private func onDisconnect(reason: String?, at: EpochMillis) async {
        guard link != nil else { return }   // a link goes down once
        if let decoder {
            for e in decoder.reset(at: at) { await handle(e, characteristic: "") }
        }
        flushLive(force: true)
        // Persist whatever history arrived, whatever the state (dedup-safe); nothing is acknowledged.
        persistAllHistory()
        if isOwnedTransferActive {
            historyOutcome = .interrupted
            historyOutcomeNote = "Disconnected during history transfer"
            emit(.historyStopped(reason: "Disconnected during history transfer; unacknowledged data stays on the band", at: at))
        }
        transferGeneration += 1
        phase = .idle
        transfer = nil
        chunk = Chunk()
        pendingProgress = nil
        recorder?.record(CaptureEntry(t: at, dir: .event, c: "", d: "", note: "disconnect: \(reason ?? "")"))
        if var record = runRecord {
            record.endedAt = at
            if record.status == .running {
                record.status = historyOutcome ?? .completed
                record.note = historyOutcomeNote
            }
            record.batches = batchesThisRun
            record.recordsInserted = counters.persistedRecords - runBaseline.persistedRecords
            record.duplicates = counters.duplicateRecords - runBaseline.duplicateRecords
            record.malformedFrames = counters.framesMalformed - runBaseline.framesMalformed
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
            onHistoryRecord(r)

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
            log(.init(at: ev.receivedAt, direction: "rx", characteristic: characteristic, summary: "event \(ev.name) (\(ev.eventID))",
                      hexPreview: HexCodec.encode(ev.data.prefix(24))))
            // Inside a chunk an event may be stored band data (events are both live and history) that Forma
            // only logs: the chunk is not acknowledged, so the band keeps it.
            if chunk.isOpen, adapter.gatt.carriesVendorFrames(characteristic) {
                chunk.foreignFrames += 1
                chunk.foreignDescriptions.insert("event \(ev.name)")
            }
            if ev.name == "RTC_LOST" || ev.name == "SET_RTC" || ev.name == "BOOT" {
                await onClockDiscontinuity(ev)
            }

        case .batteryLevel(let percent, let receivedAt):
            liveAux.append(AuxMeasurement(deviceID: device.id, timestamp: receivedAt, kind: .batteryPercent, value: Double(percent),
                                          source: .liveVendorStream, validated: true, quality: [.phoneReceiveTime]))
            emit(.battery(percent: percent))

        case .clockReading(let deviceSeconds, let subsecondMillis, let receivedAt):
            await onClockReading(DeviceClockReading(deviceSeconds: deviceSeconds, subsecondMillis: subsecondMillis, phoneTime: receivedAt),
                                 characteristic: characteristic)

        case .deviceInformation(let field, let value):
            if field == "firmware" {
                device.firmwareVersion = value
                try? sink.upsertDevice(device)
            } else if field == "hardware" {
                device.hardwareRevision = value
                try? sink.upsertDevice(device)
            }
            emit(.deviceInformation(field: field, value: value))

        case .unknownPacket(let type, let length, let source, let receivedAt):
            counters.framesValid += 1
            counters.unknownPackets += 1
            log(.init(at: receivedAt, direction: "rx", characteristic: source, summary: "unknown packet type \(type) (\(length) bytes)", hexPreview: ""))
            // Inside a chunk, a frame Forma does not decode may be stored band data (another metadata or
            // record type): the chunk is not acknowledged, so the band keeps it.
            if chunk.isOpen, adapter.gatt.carriesVendorFrames(source) {
                chunk.foreignFrames += 1
                chunk.foreignDescriptions.insert("packet type \(type)")
            }

        case .malformed(let reason, let count, let source, let receivedAt):
            counters.framesMalformed += 1
            noteDamage(on: source)
            log(.init(at: receivedAt, direction: "rx", characteristic: source, summary: "malformed: \(reason) (\(count) bytes)", hexPreview: ""))
            if reason.lowercased().contains("pairing") { emit(.pairingRequired) }

        case .discarded(let count, let source, _):
            counters.bytesDiscarded += count
            noteDamage(on: source)
        }
    }

    /// Damage on a vendor characteristic: it may have hit a history frame (a record, or a marker between
    /// chunks), so the open chunk is not acknowledged and the transfer cannot be recorded as complete.
    private func noteDamage(on characteristic: String) {
        guard adapter.gatt.carriesVendorFrames(characteristic) else { return }
        if chunk.isOpen { chunk.integrityLost = true }
        if isReceivingOwnedHistory { blockAcks("Part of the transfer arrived damaged or incomplete") }
    }

    // MARK: - Clock

    private func onClockDiscontinuity(_ ev: DeviceEventRecord) async {
        clock.markDiscontinuity()
        // History waits for the fresh reading (the new baseline), not for the stale one.
        clockReadingReceived = false
        if transfer != nil {
            // Records of this transfer keep the mapping it started with (or gets when history is requested),
            // flagged from here on: some were written before the change, some perhaps after.
            transfer!.clockChanged = true
            transfer!.clock?.markDiscontinuity()
            holdAcks("The band's clock was changed during the transfer (\(ev.name))")
        }
        // Re-read the clock so the mapping has a fresh baseline (even if an older read is unanswered).
        clockReadOutstanding = false
        await readClock()
    }

    private func onClockReading(_ reading: DeviceClockReading, characteristic: String) async {
        clockReadOutstanding = false
        clockReadingReceived = true
        switch clock.add(reading) {
        case .accepted(let offset):
            emit(.clockOffset(millis: offset))
        case .implausible(let offset):
            emit(.clockImplausible(offsetMillis: offset))
            log(.init(at: reading.phoneTime, direction: "rx", characteristic: characteristic,
                      summary: "band clock implausible (offset \(offset / 1_000) s); history cannot be placed in time", hexPreview: ""))
        }
        if let fixed = transfer?.clock {
            // History is already being received with the mapping it started with.
            if fixed.readings.isEmpty, !fixed.implausible {
                // It started without a reading (the band did not answer in time): use this one from now on.
                transfer!.clock = clock
                if clock.implausible || clock.correctionMillis != fixed.correctionMillis {
                    transfer!.clock!.markDiscontinuity()
                    holdAcks("The band's clock was read only after the transfer had started; earlier records used the band clock as-is")
                } else if transfer!.clockChanged {
                    transfer!.clock!.markDiscontinuity()
                }
            } else if clock.implausible != fixed.implausible || clock.correctionMillis != fixed.correctionMillis {
                transfer!.clock!.markDiscontinuity()
                holdAcks("A clock reading during the transfer disagreed with the one it started with")
            }
        }
        if case .awaitingClock = phase { await requestRangeOrHistory(attempt: 0) }
    }

    /// Writes GET_CLOCK unless one is already outstanding.
    private func readClock() async {
        guard adapter.supports(.readClock), link != nil, !clockReadOutstanding else { return }
        clockReadOutstanding = true   // before the write: a call arriving while it is in flight must not send another
        if !(await send(.readClock)) { clockReadOutstanding = false }
    }

    /// The phone time used as "now" for a band time's plausibility bound: when the record arrived (never
    /// later than now), so a replayed capture is judged as the live engine judged it. Receive times before
    /// 2020 (synthetic links) fall back to the time source.
    private func plausibilityReference(_ receivedAt: EpochMillis) -> EpochMillis {
        let now = timeSource.now()
        guard receivedAt >= ClockMapper.earliestPlausible else { return now }
        return min(receivedAt, now)
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
            let mapped = clock.map(deviceSeconds: s, now: plausibilityReference(receivedAt))
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

    /// Brings the band's real-time stream in line with the current setting. One loop runs at a time and
    /// re-reads the setting after every write, so a change made while a toggle is in flight is applied too.
    /// An unknown state (see `realtimeStreamMayBeOn`) is settled with one write either way.
    private func syncRealtimeStream() async {
        guard !realtimeToggleRunning else { return }
        realtimeToggleRunning = true
        defer { realtimeToggleRunning = false }
        while link != nil, realtimeStreamOn != options.liveHeartRate {
            let want = options.liveHeartRate
            guard adapter.supports(.setRealtimeHeartRate(enabled: want)), await send(.setRealtimeHeartRate(enabled: want)) else { break }
            realtimeStreamOn = want
        }
    }

    // MARK: - History transfer (Forma-requested)

    private var isOwnedTransferActive: Bool {
        switch phase {
        case .idle, .failed: return false
        default: return true
        }
    }

    /// History has been requested and its data may be arriving.
    private var isReceivingOwnedHistory: Bool {
        switch phase {
        case .requested, .receiving: return transfer != nil
        default: return false
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
        transferGeneration += 1
        // Late records of an earlier (failed) transfer are saved before this one starts.
        persistAllHistory()
        transfer = Transfer(startedAt: now)
        chunk = Chunk()
        discontinuity.reset()
        historyOutcome = nil
        historyOutcomeNote = nil
        emit(.historyStarted(at: now))
        if options.readClockOnConnect, adapter.supports(.readClock), !clockReadingReceived {
            phase = .awaitingClock(deadline: deadline(after: options.commandTimeoutMillis))
            await readClock()
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
        let gen = transferGeneration
        phase = .awaitingRange(attempt: attempt, deadline: deadline(after: options.commandTimeoutMillis))
        let ok = await send(.readHistoryRange)
        guard gen == transferGeneration, case .awaitingRange = phase else { return }
        if !ok { await rangeAttemptFailed(attempt: attempt, reason: "The history-range request could not be written") }
    }

    private func rangeAttemptFailed(attempt: Int, reason: String) async {
        if attempt < options.rangeRetries {
            phase = .rangeRetry(attempt: attempt + 1, at: deadline(after: options.retryDelayMillis))
            if options.retryDelayMillis == 0 { await checkDeadlines() }
        } else {
            failTransfer("\(reason) (after \(attempt + 1) attempts); nothing was requested", at: timeSource.now())
        }
    }

    private func sendHistoryRequest() async {
        let gen = transferGeneration
        phase = .requested(deadline: deadline(after: options.historyIdleTimeoutMillis))
        // The band wrote the records it is about to send under the clock it has now.
        transfer?.clock = clock
        if transfer?.clockChanged == true { transfer?.clock?.markDiscontinuity() }
        let ok = await send(.requestHistory)
        guard gen == transferGeneration, case .requested = phase else { return }
        if !ok { failTransfer("The history request could not be written", at: timeSource.now()) }
    }

    private func onCommandResponse(_ r: CommandResponse) async {
        guard let kind = r.answers else { return }
        let match = consumeRequest(answeredBy: r, kind: kind)
        if !match.echoMatched {
            counters.responseSequenceMismatches += 1
            log(.init(at: r.receivedAt, direction: "rx", characteristic: "",
                      summary: "answer to cmd \(r.command) echoes sequence \(r.originSequence.map(String.init) ?? "?"), which matches no \(kind.rawValue) request Forma sent",
                      hexPreview: ""))
            if kind == .readHistoryRange || kind == .requestHistory || kind == .acknowledgeHistory {
                holdAcks("An answer to a history command did not match Forma's request; another app may be using the band's history")
            }
        }
        switch kind {
        case .readHistoryRange:
            guard case .awaitingRange(let attempt, _) = phase else { return }
            switch r.status {
            case .pending:
                phase = .awaitingRange(attempt: attempt, deadline: deadline(after: options.pendingGraceMillis))
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
                case .rejected, .unknown:
                    // Forma proceeds only on an explicit success (0 is contested: failure in the reference client).
                    failTransfer("The band declined the history request (result \(r.resultCode.map(String.init) ?? "?"))", at: timeSource.now())
                case .pending:
                    rearm(grace: options.pendingGraceMillis)
                case .success:
                    rearm(grace: options.historyIdleTimeoutMillis)
                }
            default:
                return
            }
        case .acknowledgeHistory:
            // Counted only for one of Forma's own acknowledgements: another app's answer (a mismatched echo,
            // already counted and stopping acknowledgements above) must not stand in for Forma's.
            guard match.hadRequest else { return }
            switch r.status {
            case .pending:
                return
            case .success:
                counters.acknowledgementsAccepted += 1
            case .rejected, .unknown:
                counters.acknowledgementsRejected += 1
                let why = "The band did not accept an acknowledgement (result \(r.resultCode.map(String.init) ?? "?"))"
                if transfer != nil {
                    blockAcks(why)
                } else {
                    // The answer came after its transfer ended (it travels on another characteristic than the
                    // completion marker): recorded on the run, the band keeps that chunk.
                    historyOutcomeNote = historyOutcomeNote.map { "\($0); \(why)" } ?? why
                    log(.init(at: r.receivedAt, direction: "rx", characteristic: "", summary: why, hexPreview: ""))
                }
            }
        case .readClock:
            if r.status == .rejected || r.status == .unknown {
                clockReadOutstanding = false
                if case .awaitingClock = phase { await requestRangeOrHistory(attempt: 0) }
            }
        default:
            return
        }
    }

    /// Finds the written command a response answers: the one with the echoed sequence when the adapter
    /// reports one, otherwise (by command id) the oldest unanswered one of that kind. A final answer
    /// consumes it; "pending" leaves it outstanding. An echo that matches nothing consumes nothing, so
    /// Forma's own answer, which may follow, still finds its command.
    private func consumeRequest(answeredBy r: CommandResponse, kind: AllowedCommand.Kind) -> (echoMatched: Bool, hadRequest: Bool) {
        var list = sentSequences[kind] ?? []
        let index: Int?
        if let echo = r.originSequence {
            guard let i = list.firstIndex(of: echo) else { return (false, false) }
            index = i
        } else {
            index = list.isEmpty ? nil : 0
        }
        guard let i = index else { return (true, false) }
        if r.status != .pending {
            list.remove(at: i)
            sentSequences[kind] = list
        }
        return (true, true)
    }

    private func rearm(grace: Int64) {
        let deadline = deadline(after: grace)
        switch phase {
        case .requested: phase = .requested(deadline: deadline)
        case .receiving: phase = .receiving(deadline: deadline)
        default: break
        }
    }

    private func onHistoryRecord(_ r: HistoryRecord) {
        let isOwned: Bool
        switch phase {
        case .requested, .receiving:
            isOwned = transfer != nil
            phase = .receiving(deadline: deadline(after: options.historyIdleTimeoutMillis))
        default:
            isOwned = false
        }
        if isOwned {
            chunk.records += 1
        } else {
            counters.historyRecordsUnsolicited += 1
            // Not part of a transfer Forma asked for: never acknowledged. Stored only when history is on.
            guard options.history != .off else { return }
        }
        let hasContent = (r.heartRate ?? 0) > 0 || r.motion != nil || !r.beatIntervalsMillis.isEmpty
        if !r.contentDecoded {
            counters.historyRecordsUndecoded += 1
            if isOwned {
                chunk.undecoded += 1
                chunk.undecodedKinds.insert(r.kind)
            }
            // Whatever was decoded is still kept; the chunk is not acknowledged, so the band keeps the record.
            guard hasContent else { return }
        }
        let mapper = isOwned ? (transfer?.clock ?? clock) : clock
        let mapped = mapper.map(deviceSeconds: r.deviceSeconds, now: plausibilityReference(r.receivedAt))
        guard let ts = mapped.timestamp else {
            // Without a trustworthy time the record cannot be stored as a measurement, and the chunk
            // must not be acknowledged (the band keeps it).
            counters.historyRecordsUnmapped += 1
            if isOwned { chunk.unmapped += 1 }
            return
        }
        var flags = mapped.flags
        switch discontinuity.observe(kind: r.kind, counter: r.counter, deviceSeconds: r.deviceSeconds) {
        case .continuous: break
        case .counterRestart: flags.insert(.nearClockDiscontinuity)
        case .clockWentBackwards:
            flags.insert(.nearClockDiscontinuity)
            if isOwned { holdAcks("The band's clock stepped back inside the transfer") }
        }
        let identity = UInt64(r.kind) << 32 | UInt64(r.counter)
        let raw = Int64(r.deviceSeconds)
        if let bpm = r.heartRate, bpm > 0 {
            var f = flags
            if r.heartRateStatus == .unvalidated { f.insert(.unvalidatedField) }
            if !HeartRateSample.plausibleRange.contains(bpm) { f.insert(.outOfRange) }
            let sample = HeartRateSample(deviceID: device.id, timestamp: ts, bpm: bpm, source: .deviceHistory, deviceTimeRaw: raw,
                                         receivedAt: r.receivedAt, clockOffsetMillis: mapped.appliedOffsetMillis, quality: f)
            if isOwned {
                if transfer?.heartRateTimes.claim(ts, by: identity) == true { noteCollision() }
                owned.hr.append(sample)
            } else {
                unsolicited.hr.append(sample)
            }
        }
        if let m = r.motion, m.sampleCount > 0, m.spanMillis > 0 {
            let epoch = MotionEpoch(deviceID: device.id, timestamp: ts, epochMillis: m.spanMillis, activity: m.activity,
                                    sampleCount: m.sampleCount, source: .deviceHistory, quality: flags.union(.unvalidatedField),
                                    deviceTimeRaw: raw)
            if isOwned {
                if transfer?.motionTimes.claim(ts, by: identity) == true { noteCollision() }
                owned.motion.append(epoch)
            } else {
                unsolicited.motion.append(epoch)
            }
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
            if isOwned { owned.beats.append(contentsOf: items.reversed()) } else { unsolicited.beats.append(contentsOf: items.reversed()) }
        }
        if isOwned {
            transfer!.records += 1
            transfer!.newestRecord = max(transfer!.newestRecord ?? ts, ts)
        }
        if owned.count >= options.historySubBatchSize { persistOwned(note: "history") }
        if unsolicited.count >= options.historySubBatchSize { persistUnsolicited() }
        if isOwned, let t = transfer { emitTelemetry(progress: (t.records, t.newestRecord)) }
    }

    /// Two records of the transfer map to one stored time: the store keeps one of them.
    private func noteCollision() {
        chunk.collisions += 1
        counters.historyTimeCollisions += 1
    }

    private func onHistoryMarker(_ marker: HistoryMarker, characteristic: String) async {
        log(.init(at: marker.receivedAt, direction: "rx", characteristic: "", summary: "history \(marker.kind.rawValue)\(isReceivingOwnedHistory ? "" : " (not requested by Forma)")",
                  hexPreview: HexCodec.encode(marker.ackToken ?? [])))
        guard isReceivingOwnedHistory else {
            // Someone else's transfer (or a failed one of ours): save what arrived, never act on it.
            if marker.kind != .start { persistUnsolicited() }
            return
        }
        switch marker.kind {
        case .start:
            if chunk.isOpen {
                persistOwned(note: "history")
                blockAcks("A history chunk ended without an end marker")
            }
            chunk = Chunk()
            chunk.startSeen = true
            phase = .receiving(deadline: deadline(after: options.historyIdleTimeoutMillis))
        case .end:
            // The end marker is band activity: the acknowledgement write below must not count as silence.
            phase = .receiving(deadline: deadline(after: options.historyIdleTimeoutMillis))
            let gen = transferGeneration
            await finishChunk(marker, characteristic: characteristic)
            // The acknowledgement write may have suspended this handler while settings, "Sync now" or the timer
            // ended this transfer (or started another): only the transfer it belongs to is re-armed.
            guard gen == transferGeneration, transfer != nil else { return }
            switch phase {
            case .requested, .receiving: phase = .receiving(deadline: deadline(after: options.historyIdleTimeoutMillis))
            default: break
            }
        case .complete:
            counters.historyTransfersFinishedByBand += 1
            persistAllHistory()
            if chunk.isOpen { blockAcks("The transfer ended inside a chunk (no end marker)") }
            if (decoder?.pendingPartialBytes(excluding: characteristic) ?? 0) > 0 {
                blockAcks("A frame was still incomplete when the transfer ended")
            }
            finishTransfer(problem: nil, at: marker.receivedAt, bandFinished: true)
        }
    }

    /// Persists the chunk, decides whether it may be acknowledged, and acknowledges it if enabled. The chunk
    /// is closed before the acknowledgement write, so nothing that runs during that write sees it.
    private func finishChunk(_ marker: HistoryMarker, characteristic: String) async {
        transfer?.chunks += 1
        counters.historyChunksReceived += 1
        var problem: String?
        if !chunk.startSeen { problem = "A history chunk arrived without its start marker" }
        else if chunk.integrityLost || (decoder?.pendingPartialBytes(excluding: characteristic) ?? 0) > 0 {
            problem = "Part of a history chunk arrived damaged or incomplete"
        }
        else if chunk.unmapped > 0 { problem = "The band's clock could not be trusted for \(chunk.unmapped) record(s)" }
        else if chunk.undecoded > 0 {
            let kinds = chunk.undecodedKinds.sorted().map(String.init).joined(separator: ", ")
            problem = "The chunk contained \(chunk.undecoded) record(s) Forma does not fully decode (kinds \(kinds))"
        }
        else if chunk.foreignFrames > 0 {
            let what = chunk.foreignDescriptions.sorted().joined(separator: ", ")
            problem = "The chunk contained \(chunk.foreignFrames) frame(s) Forma does not decode (\(what))"
        }
        else if chunk.collisions > 0 {
            problem = "\(chunk.collisions) record(s) mapped to the same time as another record; Forma could keep only one of each"
        }
        // Records from outside the transfer that arrived meanwhile are saved on their own.
        persistUnsolicited()
        // Final batch: remaining records, plus the cursor when the whole chunk is intact.
        var cursor: SyncCursor?
        if problem == nil, !chunk.persistenceFailed {
            do {
                let existing = try sink.syncCursor(deviceID: device.id)
                let newest = [existing?.newestPersistedRecordTime, chunk.newestPersisted, owned.newest].compactMap { $0 }.max()
                cursor = SyncCursor(deviceID: device.id, adapterID: adapter.adapterID, opaque: existing?.opaque,
                                    newestPersistedRecordTime: newest, lastCompleteSyncAt: existing?.lastCompleteSyncAt,
                                    updatedAt: timeSource.now())
            } catch {
                chunk.persistenceFailed = true
            }
        }
        let saved = persistOwned(note: "history", cursor: cursor) && !chunk.persistenceFailed
        if problem == nil, !saved { problem = "Saving a history chunk failed" }
        let inserted = chunk.inserted
        let duplicates = chunk.duplicates
        let ambiguous = chunk.ambiguousDuplicates
        chunk = Chunk()

        var acknowledged = false
        if let problem {
            blockAcks(problem)
        } else {
            counters.historyChunksSaved += 1
            if ambiguous > 0 {
                // Saved, but a skipped record may be a distinct one that reuses a band second after the band's
                // clock was set back: the band keeps the chunk.
                holdAcks("\(ambiguous) record(s) matched a stored band record only by band time or only by stored time (the band's clock may have been set back)")
            }
            if options.acknowledgeHistory, transfer?.ackBlocked == false, let token = marker.ackToken,
               adapter.supports(.acknowledgeHistory(token: token)) {
                acknowledged = await acknowledge(token: token)
            }
        }
        emit(.historyChunkSaved(inserted: inserted, duplicates: duplicates, acknowledged: acknowledged))
        if let t = transfer { emitTelemetry(progress: (t.records, t.newestRecord), force: true) }
    }

    private func acknowledge(token: [UInt8]) async -> Bool {
        do {
            try sink.ensureDurable()
        } catch {
            blockAcks("Could not make the saved chunk durable (\(error)); nothing was acknowledged")
            return false
        }
        let gen = transferGeneration
        guard await sendReturningSequence(.acknowledgeHistory(token: token)) != nil else {
            if gen == transferGeneration { blockAcks("The acknowledgement could not be written") }
            return false
        }
        // The band has the acknowledgement whatever happened during the write: count it and record its token.
        counters.historyChunksAcknowledged += 1
        if gen == transferGeneration { transfer?.chunksAcknowledged += 1 }
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

    /// The data of this transfer is not intact: nothing more is acknowledged and it cannot complete.
    private func blockAcks(_ reason: String) {
        guard transfer != nil else { return }
        transfer!.ackBlocked = true
        if !transfer!.problems.contains(reason) { transfer!.problems.append(reason) }
    }

    /// Acknowledgements stop for the rest of this transfer; what was saved is unaffected.
    private func holdAcks(_ reason: String) {
        guard transfer != nil else { return }
        transfer!.ackBlocked = true
        if !transfer!.ackHolds.contains(reason) {
            transfer!.ackHolds.append(reason)
            log(.init(at: timeSource.now(), direction: "--", characteristic: "", summary: "acknowledgements stopped: \(reason)", hexPreview: ""))
        }
    }

    /// Ends the current Forma-requested transfer: complete when nothing went wrong, stopped otherwise.
    /// `bandFinished`: the band sent its completion marker (reported apart from Forma's verdict).
    private func finishTransfer(problem: String?, at time: EpochMillis, bandFinished: Bool) {
        if let problem { blockAcks(problem) }
        transferGeneration += 1
        pendingProgress = nil
        guard let t = transfer else {
            phase = .idle
            return
        }
        if t.problems.isEmpty {
            if markHistoryComplete(at: time) {
                historyOutcome = .completed
                historyOutcomeNote = t.ackHolds.isEmpty ? nil : "Acknowledgements stopped: \(t.ackHolds.joined(separator: "; "))"
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
            // The band's own outcome is reported apart from Forma's verdict on the data.
            let outcome = bandFinished ? "The band finished the transfer (\(Self.chunkCount(t.chunks))), but it is not complete for Forma: " : ""
            emit(.historyStopped(reason: "\(outcome)\(detail). Nothing unsaved was acknowledged; the band keeps that data.", at: time))
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
            transferGeneration += 1
            phase = .idle
            return
        }
        if !t.problems.isEmpty {
            failTransfer("The band stopped sending without finishing (after \(Self.chunkCount(t.chunks))); "
                         + t.problems.joined(separator: "; "), at: time)
            return
        }
        transferGeneration += 1
        pendingProgress = nil
        historyOutcome = .interrupted
        historyOutcomeNote = "The band did not finish the transfer"
        let saved = t.chunks == 0 ? "Nothing was saved" : "Saved \(t.chunks) chunk\(t.chunks == 1 ? "" : "s")"
        let why = options.acknowledgeHistory ? "" : " (it may be waiting for an acknowledgement, which is off)"
        emit(.historyStopped(reason: "\(saved); the band then stopped sending without finishing\(why). The rest stays on the band.", at: time))
        transfer = nil
        chunk = Chunk()
        phase = .idle
    }

    /// "1 chunk", "3 chunks".
    static func chunkCount(_ n: Int) -> String { "\(n) chunk\(n == 1 ? "" : "s")" }

    private func failTransfer(_ reason: String, at time: EpochMillis) {
        blockAcks(reason)
        transferGeneration += 1
        pendingProgress = nil
        historyOutcome = .failed
        historyOutcomeNote = reason
        emit(.historyStopped(reason: "\(reason); nothing unsaved was acknowledged, the band keeps that data.", at: time))
        transfer = nil
        chunk = Chunk()
        phase = .failed
    }

    // MARK: - Persistence

    private func persistAllHistory() {
        persistUnsolicited()
        persistOwned(note: "history")
    }

    /// Persists the open chunk's buffered records (with `cursor` in the same transaction when given).
    /// Returns false if the write failed; the failure taints the chunk (it is not acknowledged, so the band
    /// keeps these records and sends them again).
    @discardableResult
    private func persistOwned(note: String, cursor: SyncCursor? = nil) -> Bool {
        guard !owned.isEmpty || cursor != nil else { return true }
        let newest = owned.newest
        let batch = IngestBatch(provenance: provenance(source: .deviceHistory, note: note), heartRates: owned.hr,
                                beatIntervals: owned.beats, motion: owned.motion, cursor: cursor)
        owned.removeAll()
        do {
            let result = try sink.ingest(batch)
            batchesThisRun += 1
            counters.persistedRecords += result.inserted
            counters.duplicateRecords += result.duplicates
            counters.historyRecordsSaved += result.inserted
            counters.historyRecordsAlreadyStored += result.duplicates
            counters.historyAmbiguousDuplicates += result.ambiguousDuplicates
            chunk.inserted += result.inserted
            chunk.duplicates += result.duplicates
            chunk.ambiguousDuplicates += result.ambiguousDuplicates
            if let newest { chunk.newestPersisted = max(chunk.newestPersisted ?? newest, newest) }
            return true
        } catch {
            chunk.persistenceFailed = true
            emit(.persistenceFailed(message: "Saving band history failed: \(error)"))
            return false
        }
    }

    /// Persists records that arrived outside a Forma transfer. On failure they are kept (bounded) and
    /// retried with the next save: another app may acknowledge them, so the band may not send them again.
    @discardableResult
    private func persistUnsolicited() -> Bool {
        guard !unsolicited.isEmpty else { return true }
        let batch = IngestBatch(provenance: provenance(source: .deviceHistory, note: "history (unsolicited)"), heartRates: unsolicited.hr,
                                beatIntervals: unsolicited.beats, motion: unsolicited.motion)
        do {
            let result = try sink.ingest(batch)
            unsolicited.removeAll()
            batchesThisRun += 1
            counters.persistedRecords += result.inserted
            counters.duplicateRecords += result.duplicates
            counters.historyRecordsSaved += result.inserted
            counters.historyRecordsAlreadyStored += result.duplicates
            counters.historyAmbiguousDuplicates += result.ambiguousDuplicates
            return true
        } catch {
            emit(.persistenceFailed(message: "Saving band history failed: \(error)"))
            unsolicited.trim(toAtMost: Self.maxRetainedUnsolicited)
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
        // Registered before the write: the answer can be handled while the write is still in flight.
        rememberSent(command.kind, seq)
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
            forgetSent(command.kind, seq)
            if options.rawCapture {
                recorder?.record(CaptureEntry(t: now, dir: .event, c: characteristic, d: "", note: "write refused (pairing required): \(command.name)"))
            }
            emit(.pairingRequired)
            return nil
        } catch {
            forgetSent(command.kind, seq)
            if options.rawCapture {
                recorder?.record(CaptureEntry(t: now, dir: .event, c: characteristic, d: "", note: "write failed: \(command.name)"))
            }
            log(.init(at: now, direction: "tx", characteristic: characteristic, summary: "write failed (\(command.name)): \(error)", hexPreview: ""))
            return nil
        }
    }

    private func rememberSent(_ kind: AllowedCommand.Kind, _ seq: UInt8) {
        var list = sentSequences[kind] ?? []
        list.removeAll { $0 == seq }   // sequences wrap: the older command with this number is long answered
        list.append(seq)
        if list.count > Self.maxRememberedSequences { list.removeFirst(list.count - Self.maxRememberedSequences) }
        sentSequences[kind] = list
    }

    private func forgetSent(_ kind: AllowedCommand.Kind, _ seq: UInt8) {
        sentSequences[kind]?.removeAll { $0 == seq }
    }

    // MARK: - Helpers

    private func startTimer() {
        timerTask?.cancel()
        let interval = min(max(0, options.timerIntervalMillis), SyncOptions.maxDurationMillis)
        guard interval > 0 else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(interval))
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

    /// Counters (and transfer progress) at most every 250 ms of `timeSource` time, or when forced. What a
    /// burst leaves unsent is delivered by the next call or by the timer (trailing edge).
    private func emitTelemetry(progress: (Int, EpochMillis?)? = nil, force: Bool = false) {
        if let progress { pendingProgress = (progress.0, progress.1) }
        let now = timeSource.now()
        if !force, let last = lastTelemetryEmit, now >= last, Self.elapsed(from: last, to: now) < Self.telemetryIntervalMillis {
            telemetryPending = true
            return
        }
        lastTelemetryEmit = now
        telemetryPending = false
        if let p = pendingProgress, transfer != nil {
            emit(.historyProgress(records: p.records, newestRecord: p.newest))
        }
        pendingProgress = nil
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
}

/// Saturating addition (deadlines and clock shifts must never trap on extreme values).
private func sat(_ a: Int64, _ b: Int64) -> Int64 {
    let (r, overflow) = a.addingReportingOverflow(b)
    if overflow { return b > 0 ? .max : .min }
    return r
}

/// Stored-time keys claimed by the records of one transfer — a bounded window of the most recent ones — to
/// detect distinct band records that would collapse onto one stored row.
struct TimeClaims: Sendable {
    static let window = 8_192
    private var owners: [EpochMillis: UInt64] = [:]
    private var order: [EpochMillis] = []
    private var head = 0

    /// Claims `key` for the record `identity`; true when a different record already holds it.
    mutating func claim(_ key: EpochMillis, by identity: UInt64) -> Bool {
        if let owner = owners[key] { return owner != identity }
        owners[key] = identity
        if order.count < Self.window {
            order.append(key)
        } else {
            owners.removeValue(forKey: order[head])
            order[head] = key
            head = (head + 1) % Self.window
        }
        return false
    }
}
