// Adversarial tests for the sync area: SyncEngine, ClockMapper, DiscontinuityDetector, ReplayLink,
// CaptureFile/CaptureRecorder, ReconnectPolicy/SequenceCounter, PeripheralLink, and the forma-replay CLI.
//
// Every expectation is derived from the documented intent (docs/ARCHITECTURE.md, docs/PRD.md,
// docs/HARDWARE_TEST_CHECKLIST.md, the doc comments on the public types) and the project invariants:
//   - history acknowledgements only after the chunk's records are durably persisted, never for a chunk with
//     unmappable timestamps, and history sync is opt-in (HistoryPolicy.off means Forma stays out of history);
//   - received data is persisted ("Persist what arrived (dedup-safe)"), re-downloads never duplicate;
//   - never fabricate measurements (nil, not 0; an HR value of 0 is `deviceMarkedInvalid`, not a reading);
//   - only allowlisted commands the adapter supports are written, and the capture is honest evidence;
//   - unknown/malformed/untrusted input is counted and logged, never fatal (no traps).
// The test doubles below (toy adapter/decoder, sink with the documented dedup keys, scripted link) are
// written independently of the existing tests.
//
// History: these tests were written by an independent breaker against the first engine; the failures they
// exposed (unsolicited-history handling, buffered records dropped at Complete/timeout, run status, stuck
// requests, per-chunk counts, 0-bpm samples, clock-step stalls, discontinuity resets, re-download dedup,
// capture honesty, overflow traps, strict hex, single disconnect, raw-frame table, CLI null stats and
// multi-connection replay) were fixed and the tests now pass. Contract changes since then are reflected
// in the expectations: acknowledgements are opt-in (`acknowledgeHistory`), Forma never writes an abort,
// timeouts are enforced by `checkDeadlines()` against the engine's time source, and links accept only
// adapter-encoded commands. The forma-replay tests run the built binary (`.build/debug/forma-replay`):
// run `swift build` before `swift test` (a missing or stale binary is reported as an issue).

import Foundation
import Testing
import FormaCore
@testable import FormaProtocol
import FormaStore
@testable import FormaSync

// MARK: - Constants and packet builders (toy protocol, independent of the existing test doubles)

/// Toy vendor data characteristic (notifications) and command characteristic (writes).
fileprivate let advData = "ADF00005-0000-0000-0000-000000000000"
fileprivate let advCmd = "ADF00002-0000-0000-0000-000000000000"
/// Band record time base: 2026-02-02T02:40:00Z (plausible).
fileprivate let advBase: UInt32 = 1_770_000_000
/// Phone "now" used by the engine's time source: six hours after the base.
fileprivate let advNow: EpochMillis = Int64(advBase) * 1_000 + 6 * 3_600_000

/// Phone receive time `ms` after `advNow`.
fileprivate func advT(_ ms: Int64) -> EpochMillis { advNow + ms }

fileprivate func advLE32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
fileprivate func advLE16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

/// Command opcodes written by the toy adapter: `[opcode, sequence] + arguments`.
fileprivate enum AdvOp {
    static let identify: UInt8 = 0x10
    static let readClock: UInt8 = 0x11
    static let requestHistory: UInt8 = 0x12
    static let ack: UInt8 = 0x13
    static let abort: UInt8 = 0x14
    static let hrOn: UInt8 = 0x15
    static let hrOff: UInt8 = 0x16
    static let readBattery: UInt8 = 0x17
    static let readRange: UInt8 = 0x18
    static let historyOps: Set<UInt8> = [requestHistory, ack, abort, readRange]
}

/// Notification payloads of the toy protocol (first byte = packet type).
fileprivate enum AdvPkt {
    /// Vendor real-time HR: `01 bpm status [seconds u32]` (status 1 = unvalidated field).
    static func realtime(bpm: UInt8, unvalidated: Bool = false, deviceSeconds: UInt32? = nil) -> [UInt8] {
        [0x01, bpm, unvalidated ? 1 : 0] + (deviceSeconds.map(advLE32) ?? [])
    }
    /// History record: `02 counter u32, seconds u32, hr u8 (passed through verbatim), rr u16 ms…`.
    static func history(counter: UInt32, seconds: UInt32, hr: UInt8, rr: [UInt16] = []) -> [UInt8] {
        [0x02] + advLE32(counter) + advLE32(seconds) + [hr] + rr.flatMap(advLE16)
    }
    static let start: [UInt8] = [0x03]
    static func end(_ token: [UInt8]?) -> [UInt8] { [0x04] + (token ?? []) }
    static let complete: [UInt8] = [0x05]
    static let malformed: [UInt8] = [0x06]
    static func clock(_ seconds: UInt32) -> [UInt8] { [0x07] + advLE32(seconds) }
    static let unknown: [UInt8] = [0x08, 0x42]
    /// Device event: 1 BOOT, 2 RTC_LOST, 3 SET_RTC.
    static func event(_ id: UInt8) -> [UInt8] { [0x09, id] }
    static func battery(_ percent: UInt8) -> [UInt8] { [0x0A, percent] }
}

/// History record `i`: counter 100 + i, band time base + i minutes, HR 60 + i.
fileprivate func advRec(_ i: UInt32, hr: UInt8? = nil) -> [UInt8] {
    AdvPkt.history(counter: 100 + i, seconds: advBase + i * 60, hr: hr ?? UInt8(60 + i))
}
/// Normalized time of `advRec(i)` when no clock correction applies.
fileprivate func advRecTime(_ i: UInt32) -> EpochMillis { Int64(advBase + i * 60) * 1_000 }

fileprivate func advNote(_ bytes: [UInt8], _ at: EpochMillis, _ characteristic: String = advData) -> LinkEvent {
    .notification(characteristic: characteristic, bytes: bytes, receivedAt: at)
}

/// Standard Heart Rate Measurement (0x2A37): flags, UINT8 bpm, RR in 1/1024 s.
fileprivate func advStdHR(_ bpm: UInt8, rr1024: [UInt16] = [], contact: SensorContactState = .notSupported) -> [UInt8] {
    var flags: UInt8 = rr1024.isEmpty ? 0 : 0x10
    switch contact {
    case .notSupported: break
    case .detected: flags |= 0x06
    case .notDetected: flags |= 0x04
    }
    return [flags, bpm] + rr1024.flatMap(advLE16)
}

/// One history chunk as the band would stream it: start, records, end(+token).
fileprivate func advChunk(_ records: [[UInt8]], token: [UInt8]?, start: Bool = true, at t0: EpochMillis) -> [LinkEvent] {
    var events: [LinkEvent] = []
    if start { events.append(advNote(AdvPkt.start, t0)) }
    for (i, r) in records.enumerated() { events.append(advNote(r, t0 + 1 + Int64(i))) }
    events.append(advNote(AdvPkt.end(token), t0 + 1 + Int64(records.count)))
    return events
}

// MARK: - Toy adapter and decoder

fileprivate struct AdvToyAdapter: DeviceAdapter {
    var supported: Set<String> = ["identify", "readClock", "requestHistory", "acknowledgeHistory", "abortHistory",
                                  "realtimeHROn", "realtimeHROff"]
    /// Simulates a buggy adapter whose encoder would happily encode commands it does not support.
    var encodeIgnoresSupport = false
    /// When set, only acknowledgement tokens of exactly this length are supported.
    var tokenLength: Int?

    let adapterID = "adv.toy"
    let parserVersion = "adv-toy-1"
    let family = DeviceFamily.unknown
    var gatt: GATTProfile {
        GATTProfile(vendorService: "ADF00001-0000-0000-0000-000000000000", discoverServices: [], subscribeCharacteristics: [advData],
                    commandCharacteristic: advCmd, commandWriteWithResponse: true, scanServiceFilter: [], nameHints: [])
    }
    let capabilities: [Capability: CapabilityStatus] = [:]

    func supports(_ command: AllowedCommand) -> Bool {
        guard supported.contains(command.name) else { return false }
        if case .acknowledgeHistory(let token) = command, let n = tokenLength { return token.count == n }
        return true
    }

    func encode(_ command: AllowedCommand, sequence: UInt8) throws -> EncodedCommand {
        if !encodeIgnoresSupport, !supports(command) { throw CommandEncodingError.unsupported(command.name) }
        let bytes: [UInt8]
        switch command {
        case .identify: bytes = [AdvOp.identify, sequence]
        case .readClock: bytes = [AdvOp.readClock, sequence]
        case .requestHistory: bytes = [AdvOp.requestHistory, sequence]
        case .acknowledgeHistory(let token): bytes = [AdvOp.ack, sequence] + token
        case .abortHistory: bytes = [AdvOp.abort, sequence]
        case .setRealtimeHeartRate(let on): bytes = [on ? AdvOp.hrOn : AdvOp.hrOff, sequence]
        case .readBattery: bytes = [AdvOp.readBattery, sequence]
        case .readHistoryRange: bytes = [AdvOp.readRange, sequence]
        }
        return EncodedCommand(command: command, sequence: sequence, bytes: bytes)
    }

    func makeDecoder() -> any DeviceDecoder { AdvToyDecoder() }
}

fileprivate final class AdvToyDecoder: DeviceDecoder {
    func decode(characteristic: String, bytes: [UInt8], receivedAt: EpochMillis) -> [DecodedEvent] {
        let c = UUIDs.normalize(characteristic)
        if c == UUIDs.heartRateMeasurement {
            guard bytes.count >= 2 else {
                return [.malformed(reason: "short heart rate measurement", byteCount: bytes.count, characteristic: c, receivedAt: receivedAt)]
            }
            let flags = bytes[0]
            let contact: SensorContactState = flags & 0x04 == 0 ? .notSupported : (flags & 0x02 != 0 ? .detected : .notDetected)
            var rr: [Double] = []
            var i = 2
            while i + 1 < bytes.count {
                rr.append(Double(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8) * 1_000 / 1_024)
                i += 2
            }
            return [.standardHeartRate(bpm: bytes[1] == 0 ? nil : Int(bytes[1]), contact: contact, rrMillis: rr, energyKJ: nil,
                                       receivedAt: receivedAt)]
        }
        guard c == advData, let type = bytes.first else {
            return [.unknownPacket(packetType: bytes.first ?? 0, length: bytes.count, characteristic: c, receivedAt: receivedAt)]
        }
        func u32(_ o: Int) -> UInt32? {
            guard o + 4 <= bytes.count else { return nil }
            return UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        func malformed(_ reason: String) -> [DecodedEvent] {
            [.malformed(reason: reason, byteCount: bytes.count, characteristic: c, receivedAt: receivedAt)]
        }
        switch type {
        case 0x01:
            guard bytes.count >= 3 else { return malformed("short realtime") }
            return [.realtimeHeartRate(bpm: Int(bytes[1]), deviceSeconds: u32(3), status: bytes[2] == 1 ? .unvalidated : .validated,
                                       receivedAt: receivedAt)]
        case 0x02:
            guard let counter = u32(1), let seconds = u32(5), bytes.count >= 10 else { return malformed("short history record") }
            var rr: [Double] = []
            var i = 10
            while i + 1 < bytes.count {
                rr.append(Double(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8))
                i += 2
            }
            return [.historyRecord(HistoryRecord(kind: 24, counter: counter, deviceSeconds: seconds, subseconds: 0, receivedAt: receivedAt,
                                                 heartRate: Int(bytes[9]), heartRateStatus: .unvalidated, beatIntervalsMillis: rr,
                                                 motion: nil, payloadLength: bytes.count))]
        case 0x03: return [.historyMarker(HistoryMarker(kind: .start, ackToken: nil, receivedAt: receivedAt))]
        case 0x04:
            return [.historyMarker(HistoryMarker(kind: .end, ackToken: bytes.count > 1 ? Array(bytes.dropFirst()) : nil, receivedAt: receivedAt))]
        case 0x05: return [.historyMarker(HistoryMarker(kind: .complete, ackToken: nil, receivedAt: receivedAt))]
        case 0x06: return malformed("bad checksum")
        case 0x07:
            guard let seconds = u32(1) else { return malformed("short clock") }
            return [.clockReading(deviceSeconds: seconds, subsecondMillis: nil, receivedAt: receivedAt)]
        case 0x09:
            guard bytes.count >= 2 else { return malformed("short event") }
            let names: [UInt8: String] = [1: "BOOT", 2: "RTC_LOST", 3: "SET_RTC"]
            return [.deviceEvent(DeviceEventRecord(eventID: UInt16(bytes[1]), name: names[bytes[1]] ?? "EVENT_\(bytes[1])", deviceSeconds: nil,
                                                   data: [], receivedAt: receivedAt))]
        case 0x0A:
            guard bytes.count >= 2 else { return malformed("short battery") }
            return [.batteryLevel(percent: Int(bytes[1]), receivedAt: receivedAt)]
        default:
            return [.unknownPacket(packetType: type, length: bytes.count, characteristic: c, receivedAt: receivedAt)]
        }
    }

    func reset(at time: EpochMillis) -> [DecodedEvent] { [] }
}

// MARK: - Sink with the documented dedup keys and injectable failures

fileprivate struct AdvInjectedFailure: Error {}

fileprivate final class AdvSink: IngestSink, @unchecked Sendable {
    struct Batch: Sendable {
        var note: String?
        var source: MeasurementSource
        var heartRates: Int
        var records: Int
        var hasCursor: Bool
        var failed: Bool
    }

    private let lock = NSLock()
    private var failRule: (@Sendable (IngestBatch, Int) -> Bool)?
    private var calls = 0
    private var keys = Set<String>()
    private var _hr: [HeartRateSample] = []
    private var _beats: [BeatInterval] = []
    private var _motion: [MotionEpoch] = []
    private var _aux: [AuxMeasurement] = []
    private var _cursor: SyncCursor?
    private var _batches: [Batch] = []
    private var _raw: [RawFrameRecord] = []
    private var _begun: [SyncRunRecord] = []
    private var _finished: [SyncRunRecord] = []

    /// `rule(batch, zeroBasedIngestCallIndex)` returning true makes that ingest throw (nothing is stored).
    func failIngest(when rule: @escaping @Sendable (IngestBatch, Int) -> Bool) { lock.withLock { failRule = rule } }

    func ingest(_ batch: IngestBatch) throws -> IngestResult {
        try lock.withLock {
            let index = calls
            calls += 1
            let count = batch.heartRates.count + batch.beatIntervals.count + batch.motion.count + batch.aux.count
            if let rule = failRule, rule(batch, index) {
                _batches.append(Batch(note: batch.provenance.note, source: batch.provenance.source, heartRates: batch.heartRates.count,
                                      records: count, hasCursor: batch.cursor != nil, failed: true))
                throw AdvInjectedFailure()
            }
            var inserted = 0, duplicates = 0
            for s in batch.heartRates {
                if keys.insert("hr|\(s.deviceID)|\(s.source.rawValue)|\(s.timestamp)").inserted { _hr.append(s); inserted += 1 } else { duplicates += 1 }
            }
            for b in batch.beatIntervals {
                if keys.insert("rr|\(b.deviceID)|\(b.source.rawValue)|\(b.recordKey)|\(b.indexInRecord)").inserted { _beats.append(b); inserted += 1 } else { duplicates += 1 }
            }
            for m in batch.motion {
                if keys.insert("m|\(m.deviceID)|\(m.source.rawValue)|\(m.timestamp)|\(m.epochMillis)").inserted { _motion.append(m); inserted += 1 } else { duplicates += 1 }
            }
            for a in batch.aux {
                if keys.insert("a|\(a.deviceID)|\(a.source.rawValue)|\(a.kind.rawValue)|\(a.timestamp)").inserted { _aux.append(a); inserted += 1 } else { duplicates += 1 }
            }
            if let c = batch.cursor { _cursor = c }
            _batches.append(Batch(note: batch.provenance.note, source: batch.provenance.source, heartRates: batch.heartRates.count,
                                  records: count, hasCursor: batch.cursor != nil, failed: false))
            return IngestResult(batchID: Int64(_batches.count), inserted: inserted, duplicates: duplicates)
        }
    }

    func syncCursor(deviceID: String) throws -> SyncCursor? { lock.withLock { _cursor } }
    func upsertDevice(_ device: DeviceRecord) throws {}
    func recordConnectionEvent(_ event: ConnectionEvent) throws {}
    func recordRawFrame(_ frame: RawFrameRecord) throws { lock.withLock { _raw.append(frame) } }
    func beginSyncRun(_ run: SyncRunRecord) throws -> Int64 { lock.withLock { _begun.append(run); return Int64(_begun.count) } }
    func finishSyncRun(_ run: SyncRunRecord) throws { lock.withLock { _finished.append(run) } }
    func ensureDurable() throws {}

    var hr: [HeartRateSample] { lock.withLock { _hr } }
    var historyHR: [HeartRateSample] { lock.withLock { _hr.filter { $0.source == .deviceHistory } } }
    var liveHR: [HeartRateSample] { lock.withLock { _hr.filter { $0.source != .deviceHistory } } }
    var aux: [AuxMeasurement] { lock.withLock { _aux } }
    var beats: [BeatInterval] { lock.withLock { _beats } }
    var cursor: SyncCursor? { lock.withLock { _cursor } }
    var batches: [Batch] { lock.withLock { _batches } }
    var finishedRuns: [SyncRunRecord] { lock.withLock { _finished } }
}

// MARK: - Scripted link

/// A `PeripheralLink` whose band behaviour is scripted: a responder reacts to each write (its reaction is
/// enqueued before the write becomes visible in `writes`), and tests can push events directly.
fileprivate final class AdvLink: PeripheralLink, @unchecked Sendable {
    typealias Responder = @Sendable (_ bytes: [UInt8], _ characteristic: String) throws -> [LinkEvent]

    let peripheralID: String
    let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let lock = NSLock()
    private let responder: Responder?
    private var attemptLog: [[UInt8]] = []
    private var writeLog: [[UInt8]] = []
    private var closed = false

    init(peripheralID: String = "adv-link", services: [String: [String]] = [:], responder: Responder? = nil) {
        self.peripheralID = peripheralID
        self.responder = responder
        var cont: AsyncStream<LinkEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        continuation.yield(.ready(services: services))
    }

    private func yieldLocked(_ event: LinkEvent) {
        guard !closed else { return }
        continuation.yield(event)
        if case .disconnected = event {
            closed = true
            continuation.finish()
        }
    }

    func emit(_ event: LinkEvent) { lock.withLock { yieldLocked(event) } }
    func emit(_ events: [LinkEvent]) { for e in events { emit(e) } }
    func disconnect(at time: EpochMillis, reason: String = "test end") { emit(.disconnected(reason: reason, at: time)) }

    func write(_ command: EncodedCommand, characteristic: String, withResponse: Bool) async throws {
        let bytes = command.bytes
        try lock.withLock {
            attemptLog.append(bytes)
            if closed { throw LinkError.notConnected }
            let reaction = try responder?(bytes, UUIDs.normalize(characteristic)) ?? []
            for e in reaction { yieldLocked(e) }
            writeLog.append(bytes)
        }
    }

    /// Every write the engine attempted (including ones that failed).
    var attempts: [[UInt8]] { lock.withLock { attemptLog } }
    /// Writes that succeeded.
    var writes: [[UInt8]] { lock.withLock { writeLog } }
    func wrote(_ op: UInt8) -> Bool { writes.contains { $0.first == op } }
    func writes(_ op: UInt8) -> [[UInt8]] { writes.filter { $0.first == op } }
    func attempts(_ op: UInt8) -> Int { attempts.filter { $0.first == op }.count }
}

// MARK: - Small concurrency helpers

fileprivate final class AdvBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}

fileprivate final class AdvUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SyncUpdate] = []
    func append(_ u: SyncUpdate) { lock.withLock { items.append(u) } }
    var all: [SyncUpdate] { lock.withLock { items } }
}

/// Starts consuming the engine's update stream (single consumer).
fileprivate func advCollect(_ engine: SyncEngine) -> (AdvUpdates, Task<Void, Never>) {
    let log = AdvUpdates()
    let stream = engine.updates
    let task = Task { for await u in stream { log.append(u) } }
    return (log, task)
}

/// Waits until the collected updates stop growing (they are yielded before the engine call returns).
fileprivate func advSettle(_ log: AdvUpdates) async {
    var last = -1
    var stable = 0
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        let n = log.all.count
        if n == last {
            stable += 1
            if stable >= 15 { return }
        } else {
            stable = 0
            last = n
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

@discardableResult
fileprivate func advWait(_ timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

/// Pushes a sentinel (unknown packet) and waits until the engine has processed it, i.e. everything queued before it.
@discardableResult
fileprivate func advDrain(_ engine: SyncEngine, _ link: AdvLink, at time: EpochMillis) async -> Bool {
    let before = await engine.currentCounters.unknownPackets
    link.emit(advNote([0x08, 0xDD], time))
    return await advWait { await engine.currentCounters.unknownPackets > before }
}

fileprivate func advEngine(_ sink: any IngestSink, adapter: AdvToyAdapter = AdvToyAdapter(), history: HistoryPolicy = .automatic,
                           liveHeartRate: Bool = false, rawCapture: Bool = false, flushMillis: Int64 = 0, subBatch: Int = 500,
                           idleMillis: Int64 = 30_000, identify: Bool = false, time: ManualTimeSource = ManualTimeSource(advNow),
                           recorder: CaptureRecorder? = nil, deviceID: String = "adv-band", acknowledge: Bool = true,
                           readClock: Bool = false) -> SyncEngine {
    let device = DeviceRecord(id: deviceID, family: .unknown, name: "Adversarial band", firstSeen: advNow - EpochMillis.millisPerDay)
    return SyncEngine(adapter: adapter, sink: sink, device: device, timeSource: time,
                      options: SyncOptions(history: history, acknowledgeHistory: acknowledge, liveHeartRate: liveHeartRate,
                                           rawCapture: rawCapture, liveFlushIntervalMillis: flushMillis, historySubBatchSize: subBatch,
                                           historyIdleTimeoutMillis: idleMillis, identifyOnConnect: identify,
                                           readClockOnConnect: readClock, timerIntervalMillis: 0),
                      recorder: recorder)
}

fileprivate extension SyncUpdate {
    var isDisconnected: Bool { if case .disconnected = self { return true } else { return false } }
    var chunkSaved: (inserted: Int, duplicates: Int, acknowledged: Bool)? {
        if case .historyChunkSaved(let i, let d, let a) = self { return (i, d, a) } else { return nil }
    }
    var progressNewest: EpochMillis?? {
        if case .historyProgress(_, let newest) = self { return .some(newest) } else { return nil }
    }
    /// "started" / "stopped" / "complete" for the history lifecycle updates, nil otherwise.
    var historyPhase: String? {
        switch self {
        case .historyStarted: return "started"
        case .historyStopped: return "stopped"
        case .historyComplete: return "complete"
        default: return nil
        }
    }
}

fileprivate let advEverything = TimeRange(start: 0, end: .max)

// MARK: - Persist-before-acknowledge and opt-in

@Suite struct AdvSyncAckTests {
    @Test func ackIsWrittenOnlyAfterEveryRecordOfItsChunkIsPersisted() async {
        let sink = AdvSink()
        let storedAtAck = AdvBox<[Int]>([])
        let token: [UInt8] = [0xA1, 0xB2]
        let link = AdvLink { bytes, _ in
            switch bytes.first ?? 0 {
            case AdvOp.requestHistory: return advChunk((1...7).map { advRec($0) }, token: token, at: advT(1_000))
            case AdvOp.ack:
                storedAtAck.mutate { $0.append(sink.historyHR.count) }
                return [advNote(AdvPkt.complete, advT(3_000))]
            default: return []
            }
        }
        let engine = advEngine(sink, subBatch: 3)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { link.wrote(AdvOp.ack) }
        await advDrain(engine, link, at: advT(3_001))
        link.disconnect(at: advT(4_000))
        _ = await run.value

        #expect(link.writes(AdvOp.ack).map { Array($0.dropFirst(2)) } == [token], "exactly one ack, echoing the end token verbatim")
        #expect(storedAtAck.value == [7], "all 7 records of the chunk must be persisted before the ack is written")
        #expect(sink.historyHR.count == 7)
        #expect(sink.cursor?.opaque == Data(token))
        #expect(sink.cursor?.lastCompleteSyncAt == advT(3_000))
    }

    @Test func realStoreAlreadyHoldsEveryChunkRecordWhenTheAckIsWritten() async throws {
        let store = try FormaStore(path: nil, timeSource: ManualTimeSource(advNow))
        let storedAtAck = AdvBox<[Int]>([])
        let link = AdvLink { bytes, _ in
            switch bytes.first ?? 0 {
            case AdvOp.requestHistory: return advChunk((1...5).map { advRec($0) }, token: [0x0F, 0x0E], at: advT(1_000))
            case AdvOp.ack:
                let stored = (try? store.heartRates(in: advEverything, sources: [.deviceHistory]).count) ?? -1
                storedAtAck.mutate { $0.append(stored) }
                return []
            default: return []
            }
        }
        let engine = advEngine(store, subBatch: 2)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { link.wrote(AdvOp.ack) }
        link.disconnect(at: advT(5_000))
        _ = await run.value
        #expect(storedAtAck.value == [5], "the committed SQLite rows must already contain the whole chunk when the ack goes out")
    }

    @Test func noAckWhenAnEarlierSubBatchOfTheSameChunkFailed() async {
        let sink = AdvSink()
        let failedOnce = AdvBox(false)
        sink.failIngest { batch, _ in
            guard batch.provenance.source == .deviceHistory, !batch.heartRates.isEmpty, !failedOnce.value else { return false }
            failedOnce.mutate { $0 = true }
            return true
        }
        let link = AdvLink { bytes, _ in
            bytes.first == AdvOp.requestHistory ? advChunk((1...5).map { advRec($0) }, token: [0x01, 0x02], at: advT(1_000)) : []
        }
        let engine = advEngine(sink, subBatch: 2)
        let (updates, consumer) = advCollect(engine)
        defer { consumer.cancel() }
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { await engine.currentCounters.historyRecords == 5 }
        await advDrain(engine, link, at: advT(1_010))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        await advSettle(updates)

        #expect(failedOnce.value, "the scripted failure must have been hit")
        #expect(!link.wrote(AdvOp.ack), "a chunk with a failed save must never be acknowledged, even if later sub-batches saved")
        #expect(!link.wrote(AdvOp.abort), "Forma never sends an abort; the band keeps what was not acknowledged")
        #expect(updates.all.contains { $0.historyPhase == "stopped" })
    }

    @Test func noAckWhenTheFinalCommitWithTheCursorFails() async {
        let sink = AdvSink()
        sink.failIngest { batch, _ in batch.provenance.source == .deviceHistory && batch.cursor != nil && batch.cursor?.lastCompleteSyncAt == nil }
        let link = AdvLink { bytes, _ in
            bytes.first == AdvOp.requestHistory ? advChunk((1...3).map { advRec($0) }, token: [0x01], at: advT(1_000)) : []
        }
        let engine = advEngine(sink)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { await engine.currentCounters.historyRecords == 3 }
        await advDrain(engine, link, at: advT(1_010))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        #expect(sink.batches.contains { $0.failed }, "the scripted failure must have been hit")
        #expect(!link.wrote(AdvOp.ack))
    }

    @Test func noAckWhenAnyRecordHasAnUnmappableTimeEvenAcrossSubBatches() async {
        let sink = AdvSink()
        let records = (1...4).map { advRec($0) } + [AdvPkt.history(counter: 105, seconds: 1_000, hr: 70)] // band clock lost (1970)
        let link = AdvLink { bytes, _ in
            bytes.first == AdvOp.requestHistory ? advChunk(records, token: [0x01, 0x02], at: advT(1_000)) : []
        }
        let engine = advEngine(sink, subBatch: 2)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { await engine.currentCounters.historyRecords == 5 }
        await advDrain(engine, link, at: advT(1_010))
        link.disconnect(at: advT(2_000))
        _ = await run.value

        #expect(!link.wrote(AdvOp.ack), "a chunk containing an unmappable record must stay on the band")
        #expect(sink.historyHR.map(\.timestamp).sorted() == (1...4).map { advRecTime($0) })
        #expect(!sink.hr.contains { $0.deviceTimeRaw == 1_000 }, "the unmappable record is never stored as a measurement")
        #expect(!sink.hr.contains { $0.timestamp == $0.receivedAt && $0.source == .deviceHistory }, "history is never arrival-timed")
        #expect(await engine.currentCounters.historyRecordsUnmapped == 1)
    }

    /// IMPLEMENTATION BUG: history sync is opt-in ("HistoryPolicy: whether band history is requested/acknowledged
    /// (mirrors the user's explicit choice)"). With history OFF, a transfer the band streams on its own (e.g. one
    /// the official app requested — ARCHITECTURE "Coexistence") must be left alone. The engine instead writes
    /// ABORT_HISTORY when the unacknowledged chunk ends, interfering with another client's transfer and putting
    /// the UI into a "history failed" state although the user never enabled history.
    @Test func historyOffNeverWritesAnyHistoryCommandEvenWhenTheBandStreamsHistoryUnasked() async {
        let sink = AdvSink()
        let link = AdvLink()
        let engine = advEngine(sink, history: .off)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        link.emit(advChunk([advRec(1), advRec(2)], token: [0x01, 0x02], at: advT(1_000)) + [advNote(AdvPkt.complete, advT(1_100))])
        await advDrain(engine, link, at: advT(1_101))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        let historyWrites = link.attempts.filter { AdvOp.historyOps.contains($0.first ?? 0) }
        #expect(historyWrites.isEmpty, "history is off: no request/ack/abort/range command may be written, got \(historyWrites)")
    }

    @Test func manualHistoryWaitsForSyncNow() async {
        let sink = AdvSink()
        let link = AdvLink { bytes, _ in bytes.first == AdvOp.requestHistory ? [advNote(AdvPkt.complete, advT(500))] : [] }
        let engine = advEngine(sink, history: .manual)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advDrain(engine, link, at: advT(100))
        #expect(!link.wrote(AdvOp.requestHistory), "manual: nothing is requested on connect")
        await engine.requestHistorySync()
        #expect(link.wrote(AdvOp.requestHistory), "manual: Sync now requests history")
        link.disconnect(at: advT(1_000))
        _ = await run.value
    }

    @Test func syncNowIsIgnoredWhileHistoryIsOff() async {
        let sink = AdvSink()
        let link = AdvLink()
        let engine = advEngine(sink, history: .off)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advDrain(engine, link, at: advT(100))
        await engine.requestHistorySync()
        link.disconnect(at: advT(1_000))
        _ = await run.value
        #expect(link.attempts.filter { AdvOp.historyOps.contains($0.first ?? 0) }.isEmpty)
    }

    @Test func eachChunkIsAcknowledgedWithItsOwnTokenAfterItsOwnRecordsArePersisted() async {
        let sink = AdvSink()
        let t1: [UInt8] = [0x11, 0x11], t2: [UInt8] = [0x22, 0x22]
        let seen = AdvBox<[[Int]]>([])
        let link = AdvLink { bytes, _ in
            switch bytes.first ?? 0 {
            case AdvOp.requestHistory:
                return advChunk([advRec(1), advRec(2)], token: t1, at: advT(1_000))
            case AdvOp.ack:
                let token = Array(bytes.dropFirst(2))
                seen.mutate { $0.append([Int(token[0]), sink.historyHR.count]) }
                if token == t1 { return advChunk([advRec(3)], token: t2, at: advT(2_000)) }
                return [advNote(AdvPkt.complete, advT(3_000))]
            default: return []
            }
        }
        let engine = advEngine(sink)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { link.writes(AdvOp.ack).count == 2 }
        await advDrain(engine, link, at: advT(3_001))
        link.disconnect(at: advT(4_000))
        _ = await run.value
        #expect(seen.value == [[0x11, 2], [0x22, 3]], "ack 1 after records 1–2 were saved, ack 2 after record 3 was saved")
        #expect(sink.cursor?.lastCompleteSyncAt == advT(3_000))
    }

    @Test func ackIsNotSentForATokenTheAdapterCannotEncode() async {
        let sink = AdvSink()
        var adapter = AdvToyAdapter()
        adapter.tokenLength = 2
        let link = AdvLink { bytes, _ in
            bytes.first == AdvOp.requestHistory ? advChunk([advRec(1)], token: [0x01, 0x02, 0x03], at: advT(1_000)) : []
        }
        let engine = advEngine(sink, adapter: adapter)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { await engine.currentCounters.historyRecords == 1 }
        await advDrain(engine, link, at: advT(1_010))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        #expect(!link.wrote(AdvOp.ack))
        #expect(sink.historyHR.count == 1, "what arrived is still persisted")
    }

    @Test func noAckAfterHistoryIsSwitchedOffMidTransfer() async {
        let sink = AdvSink()
        let link = AdvLink { bytes, _ in
            bytes.first == AdvOp.requestHistory ? [advNote(AdvPkt.start, advT(1_000)), advNote(advRec(1), advT(1_001))] : []
        }
        let engine = advEngine(sink)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { await engine.currentCounters.historyRecords == 1 }
        await engine.setOptions(SyncOptions(history: .off, liveHeartRate: false, liveFlushIntervalMillis: 0, identifyOnConnect: false))
        link.emit([advNote(AdvPkt.end([0x01, 0x02]), advT(1_002)), advNote(AdvPkt.complete, advT(1_003))])
        await advDrain(engine, link, at: advT(1_004))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        #expect(!link.wrote(AdvOp.ack), "the user turned history off before the chunk ended: no acknowledgement")
        #expect(sink.historyHR.count == 1)
    }

    @Test func failedAckWriteMeansTheSyncIsNotRecordedAsComplete() async {
        let sink = AdvSink()
        let link = AdvLink { bytes, _ in
            switch bytes.first ?? 0 {
            case AdvOp.requestHistory: return advChunk([advRec(1)], token: [0x01, 0x02], at: advT(1_000))
            case AdvOp.ack: throw LinkError.writeFailed("link lost")
            default: return []
            }
        }
        let engine = advEngine(sink)
        let (updates, consumer) = advCollect(engine)
        defer { consumer.cancel() }
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { link.attempts(AdvOp.ack) == 1 }
        link.emit(advNote(AdvPkt.complete, advT(1_500)))
        await advDrain(engine, link, at: advT(1_501))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        await advSettle(updates)
        #expect(sink.cursor?.lastCompleteSyncAt == nil, "an unacknowledged transfer is not a completed sync")
        #expect(!updates.all.contains { $0.historyPhase == "complete" })
        #expect(updates.all.contains { $0.historyPhase == "stopped" })
    }
}

// MARK: - Received data is never silently dropped

@Suite struct AdvSyncReceivedDataTests {
    /// IMPLEMENTATION BUG: "Persist what arrived (dedup-safe), but never acknowledge an incomplete chunk."
    /// When HistoryComplete arrives without a HistoryEnd for the chunk in progress (the goose dry-run treats that
    /// as a failed attempt), the buffered records are neither persisted on `.complete` nor on the later
    /// disconnect (the state is already idle), so received, mapped records vanish — while the engine reports a
    /// completed sync. Chunks of >= `historySubBatchSize` records would have been saved, smaller ones are lost.
    @Test func recordsOfAChunkCutShortByHistoryCompleteArePersisted() async {
        let sink = AdvSink()
        let link = AdvLink { bytes, _ in
            guard bytes.first == AdvOp.requestHistory else { return [] }
            return [advNote(AdvPkt.start, advT(1_000)), advNote(advRec(1), advT(1_001)), advNote(advRec(2), advT(1_002)),
                    advNote(AdvPkt.complete, advT(1_003))]
        }
        let engine = advEngine(sink)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { await engine.currentCounters.historyRecords == 2 }
        await advDrain(engine, link, at: advT(1_004))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        #expect(!link.wrote(AdvOp.ack), "no end marker, no token: nothing may be acknowledged")
        #expect(sink.historyHR.map(\.timestamp).sorted() == [advRecTime(1), advRecTime(2)],
                "both received records must be persisted before the run ends")
    }

    /// IMPLEMENTATION BUG (same root cause): a record delivered after the end marker (out-of-order delivery is a
    /// documented test scenario) is buffered after the ack and then dropped on HistoryComplete. If it belonged to
    /// the acknowledged chunk the band has already discarded it, so this is permanent data loss.
    @Test func recordArrivingBetweenTheEndMarkerAndHistoryCompleteIsPersisted() async {
        let sink = AdvSink()
        let link = AdvLink { bytes, _ in
            switch bytes.first ?? 0 {
            case AdvOp.requestHistory: return advChunk([advRec(1)], token: [0x01, 0x02], at: advT(1_000))
            case AdvOp.ack: return [advNote(advRec(2), advT(1_500)), advNote(AdvPkt.complete, advT(1_501))]
            default: return []
            }
        }
        let engine = advEngine(sink)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { link.wrote(AdvOp.ack) }
        await advDrain(engine, link, at: advT(1_502))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        #expect(sink.historyHR.map(\.timestamp).sorted() == [advRecTime(1), advRecTime(2)])
    }

    /// IMPLEMENTATION BUG (same root cause): after an idle timeout the transfer is `.failed`; a record still in
    /// flight from the band arrives afterwards and is buffered, but `onDisconnect` only persists in the
    /// requested/receiving states, so it is silently dropped instead of persisted (dedup-safe, unacknowledged).
    @Test func recordsArrivingAfterAnIdleTimeoutArePersistedBeforeTheLinkCloses() async {
        let sink = AdvSink()
        let link = AdvLink { bytes, _ in
            bytes.first == AdvOp.requestHistory ? [advNote(AdvPkt.start, advT(1_000)), advNote(advRec(1), advT(1_001))] : []
        }
        let engine = advEngine(sink, idleMillis: 30_000)
        let (updates, consumer) = advCollect(engine)
        defer { consumer.cancel() }
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { await engine.currentCounters.historyRecords == 1 }
        // 31 s without history traffic (a live HR notification arrives) → idle timeout.
        link.emit(advNote(advStdHR(70), advT(32_001), UUIDs.heartRateMeasurement))
        await advWait { updates.all.contains { $0.historyPhase == "stopped" } }
        // A record that was already in flight arrives after the timeout.
        link.emit(advNote(advRec(2), advT(32_100)))
        await advDrain(engine, link, at: advT(32_101))
        link.disconnect(at: advT(33_000))
        _ = await run.value
        #expect(updates.all.contains { $0.historyPhase == "stopped" }, "precondition: the idle timeout fired")
        #expect(!link.wrote(AdvOp.abort) && !link.wrote(AdvOp.ack))
        #expect(sink.historyHR.map(\.timestamp).sorted() == [advRecTime(1), advRecTime(2)],
                "every received, mappable record is persisted (unacknowledged, dedup-safe)")
    }

    @Test func reDownloadAfterAnInterruptedSyncDoesNotDuplicate() async throws {
        let store = try FormaStore(path: nil, timeSource: ManualTimeSource(advNow))
        // Session 1: link drops mid-chunk.
        let link1 = AdvLink { bytes, _ in
            bytes.first == AdvOp.requestHistory ? [advNote(AdvPkt.start, advT(1_000))] + (1...3).map { advNote(advRec($0), advT(1_000 + Int64($0))) } : []
        }
        let engine1 = advEngine(store)
        let run1 = Task { await engine1.run(link: link1) }
        await advWait { await engine1.currentCounters.historyRecords == 3 }
        link1.disconnect(at: advT(2_000), reason: "out of range")
        _ = await run1.value
        #expect(!link1.wrote(AdvOp.ack))
        // Session 2: the band re-sends everything that was not acknowledged.
        let link2 = AdvLink { bytes, _ in
            switch bytes.first ?? 0 {
            case AdvOp.requestHistory: return advChunk((1...4).map { advRec($0) }, token: [0x09], at: advT(10_000))
            case AdvOp.ack: return [advNote(AdvPkt.complete, advT(10_100))]
            default: return []
            }
        }
        let engine2 = advEngine(store, readClock: true)
        let run2 = Task { await engine2.run(link: link2) }
        await advWait { link2.wrote(AdvOp.ack) }
        await advDrain(engine2, link2, at: advT(10_101))
        link2.disconnect(at: advT(11_000))
        _ = await run2.value
        let stored = try store.heartRates(in: advEverything, sources: [.deviceHistory])
        #expect(stored.map(\.timestamp) == (1...4).map { advRecTime($0) }, "no duplicates after the re-download")
        #expect(await engine2.currentCounters.duplicateRecords == 3)
    }
}

// MARK: - Sync run bookkeeping

@Suite struct AdvSyncRunRecordTests {
    /// IMPLEMENTATION BUG: the run status is derived from "did any history record arrive" instead of whether the
    /// transfer finished. A history transfer that ran to completion (saved, acknowledged, HistoryComplete) and a
    /// later normal disconnect is recorded as `.interrupted` (HARDWARE_TEST_CHECKLIST 5.3 reserves "interrupted"
    /// for a transfer cut off mid-way).
    @Test func runWhoseHistoryTransferCompletedIsRecordedAsCompleted() async throws {
        let store = try FormaStore(path: nil, timeSource: ManualTimeSource(advNow))
        let link = AdvLink { bytes, _ in
            switch bytes.first ?? 0 {
            case AdvOp.requestHistory: return advChunk([advRec(1), advRec(2)], token: [0x01, 0x02], at: advT(1_000))
            case AdvOp.ack: return [advNote(AdvPkt.complete, advT(1_100))]
            default: return []
            }
        }
        let engine = advEngine(store)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { link.wrote(AdvOp.ack) }
        await advDrain(engine, link, at: advT(1_101))
        link.disconnect(at: advT(60_000), reason: "user disconnected")
        let record = await run.value
        #expect(try store.syncCursor(deviceID: "adv-band")?.lastCompleteSyncAt == advT(1_100), "precondition: the transfer completed")
        #expect(record.status == .completed)
        let id = try #require(record.id)
        #expect(try store.syncRun(id: id)?.status == .completed)
    }

    /// IMPLEMENTATION BUG (same root cause): the link drops right after the band started the requested transfer,
    /// before any record arrived. The engine itself reports "Disconnected during history transfer", yet records
    /// the run as `.completed` because no history record had arrived yet.
    @Test func runCutOffWhileARequestedTransferIsPendingIsRecordedAsInterrupted() async {
        let sink = AdvSink()
        let link = AdvLink { bytes, _ in bytes.first == AdvOp.requestHistory ? [advNote(AdvPkt.start, advT(1_000))] : [] }
        let engine = advEngine(sink)
        let (updates, consumer) = advCollect(engine)
        defer { consumer.cancel() }
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { link.wrote(AdvOp.requestHistory) }
        await advDrain(engine, link, at: advT(1_001))
        link.disconnect(at: advT(1_500), reason: "out of range")
        let record = await run.value
        await advSettle(updates)
        #expect(updates.all.contains { $0.historyPhase == "stopped" }, "precondition: the engine knows the transfer was cut off")
        #expect(record.status == .interrupted)
    }

    @Test func liveOnlyRunIsRecordedAsCompleted() async {
        let sink = AdvSink()
        let link = AdvLink()
        let engine = advEngine(sink, history: .off)
        let run = Task { await engine.run(link: link) }
        link.emit(advNote(advStdHR(70), advT(1_000), UUIDs.heartRateMeasurement))
        link.disconnect(at: advT(2_000))
        let record = await run.value
        #expect(record.status == .completed)
        #expect(record.endedAt == advT(2_000))
        #expect(sink.finishedRuns.count == 1)
    }

    /// IMPLEMENTATION BUG: a ReplayLink responder that scripts a disconnect makes the stream deliver TWO
    /// `.disconnected` events (the scripted one, then "replay finished" at t = 0), and the engine processes both:
    /// `finishSyncRun` runs twice, the UI gets two disconnects, and the run's `endedAt` is overwritten with 0
    /// (before `startedAt`).
    @Test func scriptedReplayDisconnectEndsTheRunOnceAtTheDisconnectTime() async {
        let sink = AdvSink()
        let link = ReplayLink(entries: [], services: [:], responder: { bytes, _ in
            guard bytes.first == AdvOp.requestHistory else { return [] }
            return [advNote(AdvPkt.start, advT(1_000)), advNote(advRec(1), advT(1_001)),
                    .disconnected(reason: "out of range", at: advT(1_002))]
        })
        let engine = advEngine(sink)
        let (updates, consumer) = advCollect(engine)
        defer { consumer.cancel() }
        let record = await engine.run(link: link)
        await advSettle(updates)
        #expect(record.endedAt == advT(1_002), "the run ends when the link went down, got \(String(describing: record.endedAt))")
        #expect(updates.all.filter(\.isDisconnected).count == 1)
        #expect(sink.finishedRuns.count == 1)
        #expect(sink.historyHR.count == 1)
    }
}

// MARK: - Status updates the UI relies on

@Suite struct AdvSyncStatusTests {
    /// IMPLEMENTATION BUG: when the history request itself cannot be written (link error, pairing prompt),
    /// the engine stays in `.requested`: no `historyStopped` follows `historyStarted` (the UI keeps showing
    /// "syncing"), and every later "Sync now" is ignored as if a transfer were running ("ignored when ... a
    /// transfer is running") until something else happens to trip the idle timeout.
    @Test func historyRequestThatCannotBeWrittenDoesNotLeaveTheEngineStuck() async {
        let sink = AdvSink()
        let requests = AdvBox(0)
        let link = AdvLink { bytes, _ in
            guard bytes.first == AdvOp.requestHistory else { return [] }
            let n = requests.value
            requests.mutate { $0 += 1 }
            if n == 0 { throw LinkError.writeFailed("radio busy") }
            return [advNote(AdvPkt.complete, advT(5_000))]
        }
        let engine = advEngine(sink, history: .manual)
        let (updates, consumer) = advCollect(engine)
        defer { consumer.cancel() }
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advDrain(engine, link, at: advT(100))
        await engine.requestHistorySync()
        await advSettle(updates)
        let phases = updates.all.compactMap(\.historyPhase)
        #expect(link.attempts(AdvOp.requestHistory) == 1, "precondition: the first request was attempted and failed")
        #expect(phases.last != "started", "the UI must not be left showing a running transfer after the request failed: \(phases)")
        await engine.requestHistorySync()
        #expect(link.attempts(AdvOp.requestHistory) == 2, "a later Sync now must try again")
        link.disconnect(at: advT(6_000))
        _ = await run.value
    }

    /// IMPLEMENTATION BUG: `historyChunkSaved(inserted:duplicates:acknowledged:)` reports the engine's lifetime
    /// totals (including live samples saved meanwhile) instead of what that chunk saved. With live HR streaming,
    /// a 2-record chunk is reported as having inserted 6 records (3 live HR + 1 battery + its own 2), and a repeated
    /// sync in the same connection re-reports earlier inserts instead of "0 new records" (HARDWARE_TEST_CHECKLIST 5.4).
    @Test func historyChunkSavedReportsOnlyThatChunksRecords() async {
        let sink = AdvSink()
        let link = AdvLink { bytes, _ in
            switch bytes.first ?? 0 {
            case AdvOp.requestHistory: return advChunk([advRec(1), advRec(2)], token: [0x01, 0x02], at: advT(10_000))
            case AdvOp.ack: return [advNote(AdvPkt.complete, advT(10_100))]
            default: return []
            }
        }
        let engine = advEngine(sink, history: .manual)
        let (updates, consumer) = advCollect(engine)
        defer { consumer.cancel() }
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        for i in 0..<3 { link.emit(advNote(advStdHR(70 + UInt8(i)), advT(1_000 * Int64(i + 1)), UUIDs.heartRateMeasurement)) }
        link.emit(advNote(AdvPkt.battery(80), advT(4_000)))
        await advWait { sink.liveHR.count == 3 && sink.aux.count == 1 }
        await engine.requestHistorySync()
        await advWait { link.wrote(AdvOp.ack) }
        await advDrain(engine, link, at: advT(10_101))
        link.disconnect(at: advT(11_000))
        _ = await run.value
        await advSettle(updates)
        let saved = updates.all.compactMap(\.chunkSaved)
        #expect(saved.count == 1)
        #expect(saved.first.map { [$0.inserted, $0.duplicates] } == [2, 0], "the chunk saved 2 new records, got \(saved)")
    }

    /// IMPLEMENTATION BUG: `historyProgress(records:newestRecord:)` reports the time of the record just
    /// decoded, not the newest record so far, so out-of-order delivery makes "newest" go backwards.
    @Test func historyProgressReportsTheNewestRecordSeenSoFar() async {
        let sink = AdvSink()
        let link = AdvLink { bytes, _ in
            bytes.first == AdvOp.requestHistory ? advChunk([advRec(3), advRec(1), advRec(2)], token: [0x01], at: advT(1_000)) : []
        }
        let engine = advEngine(sink)
        let (updates, consumer) = advCollect(engine)
        defer { consumer.cancel() }
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { await engine.currentCounters.historyRecords == 3 }
        await advDrain(engine, link, at: advT(1_010))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        await advSettle(updates)
        // Progress is throttled (≤ 4 per second of engine time) and forced at each end marker, so the count
        // varies; every report must be the newest record seen so far, never going backwards.
        let newest = updates.all.compactMap(\.progressNewest)
        #expect(!newest.isEmpty)
        #expect(newest.allSatisfy { $0 == .some(advRecTime(3)) }, "newest record so far is record 3, got \(newest)")
    }
}

// MARK: - Live data

@Suite struct AdvSyncLiveTests {
    /// IMPLEMENTATION BUG: "never fabricate measurements (nil, not 0)"; `HeartRateSample`: "`bpm` is never 0:
    /// 'no reading' is represented by not storing a sample (or by `deviceMarkedInvalid` when we keep raw
    /// evidence)"; `QualityFlags.deviceMarkedInvalid`: "e.g. HR value 0". A vendor real-time HR of 0 is stored as a
    /// 0-bpm sample flagged only `outOfRange`, and pushed to the UI as a live reading of 0 bpm (which the app also
    /// appends to the running workout).
    @Test func vendorRealtimeHeartRateOfZeroIsNotStoredOrShownAsAMeasurement() async {
        let sink = AdvSink()
        let link = AdvLink()
        let engine = advEngine(sink, history: .off)
        let (updates, consumer) = advCollect(engine)
        defer { consumer.cancel() }
        let run = Task { await engine.run(link: link) }
        link.emit([advNote(AdvPkt.realtime(bpm: 72), advT(1_000)), advNote(AdvPkt.realtime(bpm: 0), advT(2_000)),
                   advNote(AdvPkt.realtime(bpm: 70), advT(3_000))])
        link.disconnect(at: advT(4_000))
        _ = await run.value
        await advSettle(updates)
        #expect(sink.hr.contains { $0.bpm == 72 } && sink.hr.contains { $0.bpm == 70 }, "precondition: real readings are stored")
        let zeros = sink.hr.filter { $0.bpm == 0 }
        #expect(zeros.allSatisfy { $0.quality.contains(.deviceMarkedInvalid) }, "a 0 bpm reading is not a measurement: \(zeros)")
        #expect(!updates.all.contains { if case .liveHeartRate(0, _, _) = $0 { return true } else { return false } },
                "the UI must not be told the live heart rate is 0 bpm")
    }

    /// IMPLEMENTATION BUG (same root cause, history path): a history record whose HR field is 0 becomes a 0-bpm
    /// `deviceHistory` sample without `deviceMarkedInvalid`.
    @Test func historyHeartRateOfZeroIsNotStoredAsAMeasurement() async {
        let sink = AdvSink()
        let link = AdvLink { bytes, _ in
            bytes.first == AdvOp.requestHistory ? advChunk([advRec(1, hr: 0), advRec(2, hr: 61)], token: [0x01], at: advT(1_000)) : []
        }
        let engine = advEngine(sink)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { await engine.currentCounters.historyRecords == 2 }
        await advDrain(engine, link, at: advT(1_010))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        #expect(sink.historyHR.contains { $0.bpm == 61 }, "precondition")
        let zeros = sink.historyHR.filter { $0.bpm == 0 }
        #expect(zeros.allSatisfy { $0.quality.contains(.deviceMarkedInvalid) }, "HR 0 must not be stored as a reading: \(zeros)")
    }

    /// IMPLEMENTATION BUG: "Persist live samples at least this often (ms of receive time) — keeps transactions
    /// short" / one short commit per ~10 s background wake (ARCHITECTURE §7). The flush test is
    /// `now - lastFlush < interval`, so after the phone's wall clock steps backwards (manual change, network time
    /// correction) nothing is persisted until the clock catches up with the old flush time — for a 1 h step,
    /// an hour of live data sits only in memory (lost if iOS suspends or kills the app).
    @Test func backwardsPhoneClockJumpDoesNotStallLivePersistence() async {
        let sink = AdvSink()
        let link = AdvLink()
        let engine = advEngine(sink, history: .off, flushMillis: 10_000)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        link.emit([advNote(advStdHR(70), advT(100_000), UUIDs.heartRateMeasurement),
                   advNote(advStdHR(71), advT(111_000), UUIDs.heartRateMeasurement)])
        await advWait { sink.liveHR.count == 2 }
        #expect(sink.liveHR.count == 2, "precondition: normal flushing works")
        // The phone clock steps back by 61 s; notifications keep arriving 11 s apart.
        for (i, t) in [50_000, 61_000, 72_000, 83_000].enumerated() {
            link.emit(advNote(advStdHR(72 + UInt8(i)), advT(Int64(t)), UUIDs.heartRateMeasurement))
        }
        await advWait { await engine.currentCounters.standardHRNotifications == 6 }
        let persistedBeforeDisconnect = sink.liveHR.count
        link.disconnect(at: advT(84_000))
        _ = await run.value
        #expect(persistedBeforeDisconnect >= 5,
                "33 s of receive time passed after the clock step; live samples must keep being persisted (got \(persistedBeforeDisconnect) of 6)")
        #expect(sink.liveHR.count == 6)
    }

    @Test func liveSaveFailureIsRetriedWithoutLosingSamples() async {
        let sink = AdvSink()
        let failedOnce = AdvBox(false)
        sink.failIngest { batch, _ in
            guard batch.provenance.note == "live", !failedOnce.value else { return false }
            failedOnce.mutate { $0 = true }
            return true
        }
        let link = AdvLink()
        let engine = advEngine(sink, history: .off)
        let run = Task { await engine.run(link: link) }
        for i in 0..<4 { link.emit(advNote(advStdHR(60 + UInt8(i)), advT(1_000 * Int64(i + 1)), UUIDs.heartRateMeasurement)) }
        link.disconnect(at: advT(10_000))
        _ = await run.value
        #expect(failedOnce.value, "precondition: a live save failed")
        #expect(sink.liveHR.map(\.bpm).sorted() == [60, 61, 62, 63])
    }

    @Test func standardHeartRateKeepsPhoneReceiveTimeEvenWhenABandClockOffsetIsKnown() async {
        let sink = AdvSink()
        let deviceSeconds = advBase + 7_200
        let link = AdvLink { bytes, _ in
            // The band's clock is 5 minutes behind the phone.
            bytes.first == AdvOp.readClock ? [advNote(AdvPkt.clock(deviceSeconds), Int64(deviceSeconds) * 1_000 + 300_000)] : []
        }
        let engine = advEngine(sink, history: .off)
        let run = Task { await engine.run(link: link) }
        let received = advT(2_000)
        link.emit(advNote(advStdHR(72, rr1024: [1_024, 2_048], contact: .notDetected), received, UUIDs.heartRateMeasurement))
        link.disconnect(at: advT(3_000))
        _ = await run.value
        let s = sink.hr
        #expect(s.count == 1)
        #expect(s.first?.timestamp == received)
        #expect(s.first.map { $0.quality.isSuperset(of: [.phoneReceiveTime, .noSensorContact]) } == true)
        #expect(s.first.map { !$0.quality.contains(.clockOffsetApplied) && $0.clockOffsetMillis == nil } == true)
        #expect(sink.beats.map(\.timestamp) == [received - 2_000, received])
        #expect(sink.beats.map(\.intervalMillis) == [1_000, 2_000])
        #expect(sink.beats.allSatisfy { $0.timingBasis == .reconstructedFromReceiveTime && $0.quality.contains(.noSensorContact) })
    }

    @Test func unvalidatedFieldsAreStoredAsEvidenceAndFlagged() async {
        let sink = AdvSink()
        let link = AdvLink { bytes, _ in
            bytes.first == AdvOp.requestHistory ? advChunk([advRec(1)], token: [0x01], at: advT(1_000)) : []
        }
        let engine = advEngine(sink)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        link.emit(advNote(AdvPkt.realtime(bpm: 64, unvalidated: true), advT(500)))
        await advWait { await engine.currentCounters.historyRecords == 1 }
        await advDrain(engine, link, at: advT(1_010))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        #expect(sink.historyHR.count == 1 && sink.historyHR.allSatisfy { $0.quality.contains(.unvalidatedField) })
        #expect(sink.liveHR.filter { $0.bpm == 64 }.allSatisfy { $0.quality.contains(.unvalidatedField) })
        #expect(sink.liveHR.contains { $0.bpm == 64 })
    }
}

// MARK: - Clock mapping and discontinuities

@Suite struct AdvSyncClockTests {
    @Test func offsetEqualToTheToleranceIsTrustedAndOneMillisecondMoreIsApplied() {
        let deviceNow = UInt32(advNow / 1_000)
        var atTolerance = ClockMapper(toleranceMillis: 2_000)
        atTolerance.add(DeviceClockReading(deviceSeconds: deviceNow, phoneTime: Int64(deviceNow) * 1_000 + 2_000))
        #expect(atTolerance.map(deviceSeconds: deviceNow - 60, now: advNow)
                == .init(timestamp: Int64(deviceNow - 60) * 1_000, flags: [], appliedOffsetMillis: nil))
        var beyond = ClockMapper(toleranceMillis: 2_000)
        beyond.add(DeviceClockReading(deviceSeconds: deviceNow, phoneTime: Int64(deviceNow) * 1_000 - 2_001))
        let mapped = beyond.map(deviceSeconds: deviceNow - 60, now: advNow)
        #expect(mapped.timestamp == Int64(deviceNow - 60) * 1_000 - 2_001)
        #expect(mapped.appliedOffsetMillis == -2_001)
        #expect(mapped.flags == [.clockOffsetApplied])
    }

    @Test func plausibleWindowIsInclusiveAndUnmappedResultsCarryNoTimestamp() {
        let m = ClockMapper()
        let firstOf2020: UInt32 = 1_577_836_800
        #expect(m.map(deviceSeconds: firstOf2020, now: advNow).timestamp == Int64(firstOf2020) * 1_000)
        let before = m.map(deviceSeconds: firstOf2020 - 1, now: advNow)
        #expect(before.timestamp == nil && before.flags.contains(.clockUnmapped))
        let latest = UInt32((advNow + EpochMillis.millisPerDay) / 1_000)
        #expect(m.map(deviceSeconds: latest, now: advNow).timestamp == Int64(latest) * 1_000)
        let after = m.map(deviceSeconds: latest + 1, now: advNow)
        #expect(after.timestamp == nil && after.flags.contains(.clockUnmapped))
        #expect(m.map(deviceSeconds: .max, now: advNow).timestamp == nil)
        #expect(m.map(deviceSeconds: 0, now: advNow).timestamp == nil)
    }

    @Test func appliedCorrectionIsAuditableAndReversibleFromStoredFields() async {
        let sink = AdvSink()
        let clockSeconds = advBase + 7_200
        let link = AdvLink { bytes, _ in
            switch bytes.first ?? 0 {
            case AdvOp.readClock: return [advNote(AdvPkt.clock(clockSeconds), Int64(clockSeconds) * 1_000 + 300_000)]
            case AdvOp.requestHistory: return advChunk([advRec(1), advRec(2)], token: [0x01], at: advT(1_000))
            default: return []
            }
        }
        let engine = advEngine(sink, readClock: true)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { await engine.currentCounters.historyRecords == 2 }
        await advDrain(engine, link, at: advT(1_010))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        let s = sink.historyHR.sorted { $0.timestamp < $1.timestamp }
        #expect(s.map(\.timestamp) == [advRecTime(1) + 300_000, advRecTime(2) + 300_000])
        #expect(s.allSatisfy { $0.quality.contains(.clockOffsetApplied) && $0.clockOffsetMillis == 300_000 })
        #expect(s.allSatisfy { $0.timestamp - ($0.clockOffsetMillis ?? 0) == ($0.deviceTimeRaw ?? -1) * 1_000 })
    }

    @Test func bandClockEventsMarkLaterRecordsAsNearADiscontinuity() async {
        let sink = AdvSink()
        let link = AdvLink { bytes, _ in
            bytes.first == AdvOp.requestHistory
                ? [advNote(AdvPkt.event(3), advT(999))] + advChunk([advRec(1)], token: [0x01], at: advT(1_000)) : []
        }
        let engine = advEngine(sink)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { await engine.currentCounters.historyRecords == 1 }
        await advDrain(engine, link, at: advT(1_010))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        #expect(sink.historyHR.count == 1 && sink.historyHR.allSatisfy { $0.quality.contains(.nearClockDiscontinuity) },
                "SET_RTC: later records' absolute time is uncertain")
    }

    @Test func discontinuityDetectorClassifiesForwardBackwardAndRestart() {
        var d = DiscontinuityDetector()
        #expect(d.observe(counter: 10, deviceSeconds: 1_000_000) == .continuous)
        #expect(d.observe(counter: 11, deviceSeconds: 1_000_060) == .continuous)
        #expect(d.observe(counter: 12, deviceSeconds: 1_000_058) == .continuous, "2 s of jitter is tolerated")
        #expect(d.observe(counter: 13, deviceSeconds: 1_000_000) == .clockWentBackwards(seconds: 58))
        #expect(d.observe(counter: 2, deviceSeconds: 1_000_100) == .counterRestart)
        d.reset()
        #expect(d.observe(counter: 0, deviceSeconds: 5) == .continuous)
    }

    /// IMPLEMENTATION BUG: the DiscontinuityDetector lives for the whole connection and is never reset when a
    /// new transfer starts. After a failed transfer (here: the save failed, nothing acknowledged), "Sync now" makes
    /// the band re-send the same records; the first one has a lower counter than the last record of the failed
    /// attempt and is stored flagged `.nearClockDiscontinuity` ("jump/reset/restart; its absolute time is
    /// uncertain") although the band neither restarted nor changed its clock.
    @Test func retriedTransferInTheSameConnectionIsNotFlaggedAsADeviceRestart() async {
        let sink = AdvSink()
        let failedOnce = AdvBox(false)
        sink.failIngest { batch, _ in
            guard batch.provenance.source == .deviceHistory, !batch.heartRates.isEmpty, !failedOnce.value else { return false }
            failedOnce.mutate { $0 = true }
            return true
        }
        let requests = AdvBox(0)
        let link = AdvLink { bytes, _ in
            switch bytes.first ?? 0 {
            case AdvOp.requestHistory:
                let n = requests.value
                requests.mutate { $0 += 1 }
                return advChunk((1...3).map { advRec($0) }, token: [0x0A + UInt8(n)], at: advT(1_000 + 10_000 * Int64(n)))
            case AdvOp.ack: return [advNote(AdvPkt.complete, advT(30_000))]
            default: return []
            }
        }
        let engine = advEngine(sink, history: .manual)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advDrain(engine, link, at: advT(100))
        await engine.requestHistorySync()
        await advWait { failedOnce.value }
        await advDrain(engine, link, at: advT(1_100))
        #expect(failedOnce.value && !link.wrote(AdvOp.ack), "precondition: attempt 1 failed to save and was not acknowledged")
        // The band sends nothing more for the idle period: the first transfer ends, unacknowledged.
        await advDrain(engine, link, at: advT(45_000))
        await engine.requestHistorySync()
        await advWait { link.wrote(AdvOp.ack) }
        await advDrain(engine, link, at: advT(30_001))
        link.disconnect(at: advT(31_000))
        _ = await run.value
        #expect(sink.historyHR.count == 3)
        let flagged = sink.historyHR.filter { $0.quality.contains(.nearClockDiscontinuity) }
        #expect(flagged.isEmpty, "a re-requested transfer is not a device restart: \(flagged.map(\.deviceTimeRaw))")
    }

    /// "Re-downloads ... never duplicate" and PRD acceptance 2 ("interrupted sync without duplicates"): a record
    /// saved unacknowledged in an interrupted session is re-sent in the next one and stored once. Note: neither
    /// session reads the clock (`advEngine` defaults to `readClock: false`), so no correction is applied. The case
    /// where the correction really changes between downloads (here: the scripted 10 s) still stores the record
    /// twice, because the HR/motion dedup key is the corrected time; that store-level issue is tracked as a known
    /// issue in ReviewFixClockTests (and a jittering correction for a steady clock is covered there too).
    @Test func clockOffsetChangeBetweenDownloadsDoesNotDuplicateHistory() async throws {
        let store = try FormaStore(path: nil, timeSource: ManualTimeSource(advNow))
        // Session 1: the band does not answer the clock read; the link drops mid-chunk (nothing acknowledged).
        let link1 = AdvLink { bytes, _ in
            bytes.first == AdvOp.requestHistory ? [advNote(AdvPkt.start, advT(1_000)), advNote(advRec(1), advT(1_001))] : []
        }
        let engine1 = advEngine(store)
        let run1 = Task { await engine1.run(link: link1) }
        await advWait { await engine1.currentCounters.historyRecords == 1 }
        link1.disconnect(at: advT(2_000), reason: "out of range")
        _ = await run1.value
        // Session 2: the band answers the clock read (10 s behind the phone) and re-sends the record.
        let clockSeconds = advBase + 7_200
        let link2 = AdvLink { bytes, _ in
            switch bytes.first ?? 0 {
            case AdvOp.readClock: return [advNote(AdvPkt.clock(clockSeconds), Int64(clockSeconds) * 1_000 + 10_000)]
            case AdvOp.requestHistory: return advChunk([advRec(1)], token: [0x01], at: advT(10_000))
            case AdvOp.ack: return [advNote(AdvPkt.complete, advT(10_100))]
            default: return []
            }
        }
        let engine2 = advEngine(store)
        let run2 = Task { await engine2.run(link: link2) }
        await advWait { link2.wrote(AdvOp.ack) }
        await advDrain(engine2, link2, at: advT(10_101))
        link2.disconnect(at: advT(11_000))
        _ = await run2.value
        let stored = try store.heartRates(in: advEverything, sources: [.deviceHistory])
        #expect(stored.count == 1, "one band record must be stored once, got \(stored.map { ($0.timestamp, $0.deviceTimeRaw) })")
    }
}

// MARK: - Commands: allowlist, sequence numbers, honest evidence

@Suite struct AdvSyncCommandTests {
    @Test func onlySupportedAllowlistedCommandsAreWrittenEvenIfTheEncoderWouldEncodeMore() async {
        let sink = AdvSink()
        var adapter = AdvToyAdapter()
        adapter.supported = ["identify", "acknowledgeHistory"]
        adapter.encodeIgnoresSupport = true
        let link = AdvLink()
        let engine = advEngine(sink, adapter: adapter, history: .automatic, liveHeartRate: true, identify: true)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        // Unsolicited chunk with an unmappable record (would trigger an abort), then a clean chunk.
        link.emit(advChunk([AdvPkt.history(counter: 1, seconds: 5, hr: 60)], token: [0x01], at: advT(1_000)))
        link.emit(advChunk([advRec(2)], token: [0x02], at: advT(2_000)))
        await advDrain(engine, link, at: advT(2_010))
        await engine.setOptions(SyncOptions(history: .automatic, liveHeartRate: false, liveFlushIntervalMillis: 0))
        await engine.requestHistorySync()
        link.disconnect(at: advT(3_000))
        _ = await run.value
        let ops = Set(link.attempts.compactMap(\.first))
        #expect(ops.isSubset(of: [AdvOp.identify, AdvOp.ack]), "only supported commands may be written, got \(ops.sorted())")
        // History the engine did not request (the adapter cannot even request it) is never acknowledged.
        #expect(link.writes(AdvOp.ack).isEmpty, "history Forma did not request is never acknowledged")
    }

    @Test func commandSequenceNumbersAdvanceByOneAndWrapAround() async {
        let sink = AdvSink()
        let link = AdvLink()
        let engine = advEngine(sink, history: .off)
        let run = Task { await engine.run(link: link) }
        await advDrain(engine, link, at: advT(100))
        for i in 0..<300 {
            await engine.setOptions(SyncOptions(history: .off, liveHeartRate: i % 2 == 0, liveFlushIntervalMillis: 0, identifyOnConnect: false))
        }
        link.disconnect(at: advT(1_000))
        _ = await run.value
        let sequences = link.writes.map { $0[1] }
        #expect(sequences.count == 300, "300 live toggles (the clock read is off in these tests)")
        #expect(zip(sequences, sequences.dropFirst()).allSatisfy { $1 == $0 &+ 1 }, "8-bit sequence, +1 per command, 255 → 0")
        #expect(Set(sequences).count == 256)
    }

    /// IMPLEMENTATION BUG: the diagnostics capture records a command as `.tx` ("Command bytes written to the
    /// band") before the write is attempted, and nothing marks it when the write then fails. A capture of a
    /// session whose acknowledgement never reached the band shows the ack as written — wrong evidence for the
    /// very question (did Forma acknowledge?) the capture exists to answer.
    @Test func failedCommandWriteIsNotRecordedAsWrittenInTheCapture() async {
        let sink = AdvSink()
        let recorder = CaptureRecorder()
        let link = AdvLink { bytes, _ in
            switch bytes.first ?? 0 {
            case AdvOp.requestHistory: return advChunk([advRec(1)], token: [0x01, 0x02], at: advT(1_000))
            case AdvOp.ack: throw LinkError.writeFailed("link lost")
            default: return []
            }
        }
        let engine = advEngine(sink, rawCapture: true, recorder: recorder)
        let run = Task { await engine.run(link: link) }
        defer { link.disconnect(at: advT(99_000)) }
        await advWait { link.attempts(AdvOp.ack) == 1 }
        await advDrain(engine, link, at: advT(1_010))
        link.disconnect(at: advT(2_000))
        _ = await run.value
        let entries = recorder.snapshot(header: CaptureHeader(createdAt: 0, deviceFamily: .unknown)).entries
        #expect(entries.contains { $0.dir == .tx && $0.d.hasPrefix("12") }, "precondition: successful commands are captured")
        let ackEntries = entries.filter { $0.dir == .tx && $0.d.hasPrefix("13") }
        #expect(ackEntries.allSatisfy { ($0.note ?? "").lowercased().contains("fail") },
                "the failed acknowledgement must not appear in the capture as written: \(ackEntries)")
    }
}

// MARK: - Crash-freedom on band data and untrusted captures (exit tests)

/// Exit-test body: a plausible record followed by one whose device time is 0xFFFFFFFF.
fileprivate func advExitDetectorAllOnes() {
    var d = DiscontinuityDetector()
    _ = d.observe(counter: 1, deviceSeconds: 1_770_000_000)
    _ = d.observe(counter: 2, deviceSeconds: .max)
}

/// Exit-test body: two WHOOP 5.0 K24 history frames through the real adapter; the second is an erased-flash page
/// (all 0xFF header fields), which a band emits with valid CRCs when a page was never written.
fileprivate func advExitWhoop5ErasedRecord() async {
    func record(counter: UInt32, seconds: UInt32, hr: UInt8) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 24)
        p[0] = 47 // HISTORICAL_DATA
        p[1] = 24 // K24
        for i in 0..<4 {
            p[3 + i] = UInt8((counter >> (8 * UInt32(i))) & 0xFF)
            p[7 + i] = UInt8((seconds >> (8 * UInt32(i))) & 0xFF)
        }
        p[17] = hr
        return try! Whoop5Adapter.frame(payload: p)
    }
    var erased = [UInt8](repeating: 0xFF, count: 24)
    erased[0] = 47
    erased[1] = 24
    let hex: ([UInt8]) -> String = { $0.map { String(format: "%02x", $0) }.joined() }
    let entries = [
        CaptureEntry(t: advT(1_000), dir: .rx, c: Whoop5Adapter.dataFromStrap, d: hex(record(counter: 1, seconds: advBase, hr: 60))),
        CaptureEntry(t: advT(1_001), dir: .rx, c: Whoop5Adapter.dataFromStrap, d: hex(try! Whoop5Adapter.frame(payload: erased))),
    ]
    let sink = AdvSink()
    let engine = SyncEngine(adapter: Whoop5Adapter(), sink: sink,
                            device: DeviceRecord(id: "band", family: .whoop5, name: "WHOOP", firstSeen: 0),
                            timeSource: ManualTimeSource(advNow),
                            // History enabled but never requested: what the band sends is stored, nothing is acknowledged.
                            options: SyncOptions(history: .manual, liveHeartRate: false, liveFlushIntervalMillis: 0, identifyOnConnect: false,
                                                 readClockOnConnect: false, timerIntervalMillis: 0))
    _ = await engine.run(link: ReplayLink(entries: entries, services: [:]))
    let c = await engine.currentCounters
    // The erased record cannot be mapped and must not be stored; the good one must be.
    exit(c.historyRecords == 2 && c.historyRecordsUnmapped == 1 && sink.historyHR.count == 1 ? 0 : 3)
}

/// Exit-test body: a capture whose receive times are at the Int64 extremes (first entry carries an RR interval).
fileprivate func advExitAbsurdCaptureTimes() async {
    let text = """
    {"format":"forma-capture","version":1,"createdAt":0,"deviceFamily":"standardHeartRate"}
    {"t":9223372036854775807,"dir":"rx","c":"2A37","d":"10480004"}
    {"t":-9223372036854775807,"dir":"rx","c":"2A37","d":"0048"}
    {"t":1772323200000,"dir":"rx","c":"2A37","d":"0049"}
    """
    guard let decoded = try? CaptureFile.decode(Data(text.utf8)) else { exit(0) } // rejecting the file is acceptable
    let engine = SyncEngine(adapter: StandardHeartRateAdapter(), sink: AdvSink(),
                            device: DeviceRecord(id: "replay", family: .standardHeartRate, name: "replay", firstSeen: 0),
                            timeSource: ManualTimeSource(advNow),
                            options: SyncOptions(history: .off, liveHeartRate: false, liveFlushIntervalMillis: 0, identifyOnConnect: false))
    _ = await engine.run(link: ReplayLink(entries: decoded.file.entries, services: [:]))
    exit(0)
}

@Suite struct AdvSyncRobustnessTests {
    /// IMPLEMENTATION BUG: `DiscontinuityDetector.observe` computes `deviceSeconds + maxBackwardJumpSeconds` in
    /// UInt32, which traps for device times >= 0xFFFFFFFE. Band data is untrusted input ("never fatal").
    @Test func discontinuityDetectorDoesNotTrapOnAllOnesDeviceTime() async {
        await #expect(processExitsWith: .success) {
            advExitDetectorAllOnes()
        }
    }

    /// IMPLEMENTATION BUG (impact of the above): a WHOOP 5.0 history record read from an erased flash page
    /// (counter and time 0xFFFFFFFF, valid CRCs) crashes the whole sync pipeline — in the app that is a crash
    /// during history sync, and because nothing was acknowledged the band re-sends it on every sync (crash loop).
    /// Expected: the record is counted as unmapped, not stored, not acknowledged.
    @Test func erasedFlashHistoryRecordDoesNotCrashTheWhoop5Pipeline() async {
        await #expect(processExitsWith: .success) {
            await advExitWhoop5ErasedRecord()
        }
    }

    /// IMPLEMENTATION BUG: capture files are untrusted input (`CaptureFile.maxLineBytes` "bounds memory when reading
    /// untrusted files"), yet extreme receive times trap in the shared replay pipeline: beat-interval reconstruction
    /// converts `Double(Int64.max)` back to Int64, and the live-flush check computes `now - lastFlush` without
    /// overflow protection. forma-replay crashes instead of reporting the file as malformed.
    @Test func absurdCaptureReceiveTimesDoNotCrashTheReplayPipeline() async {
        await #expect(processExitsWith: .success) {
            await advExitAbsurdCaptureTimes()
        }
    }
}

// MARK: - Capture files, recorder and replay link

@Suite struct AdvSyncCaptureTests {
    @Test func captureRoundTripsEveryDirectionAndAwkwardNotes() throws {
        let header = CaptureHeader(createdAt: 1, deviceFamily: .whoop5, deviceName: "Band \"β\"\nline", firmwareVersion: "50.1",
                                   adapterID: "forma.whoop5", parserVersion: "p", appVersion: "1.0", phoneOS: "iOS 27", note: "ü\u{2028}x")
        let entries = [
            CaptureEntry(t: 10, dir: .rx, c: UUIDs.heartRateMeasurement, d: "0048"),
            CaptureEntry(t: 11, dir: .tx, c: Whoop5Adapter.commandToStrap, d: "aa01", note: "identify"),
            CaptureEntry(t: 12, dir: .event, c: "", d: "", note: "disconnect: \"reason\"\r\nwith newline"),
            CaptureEntry(t: 0, dir: .rx, c: "2A19", d: ""),
        ]
        let data = try CaptureFile(header: header, entries: entries).encoded()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        #expect(lines.count == entries.count + 2, "one JSON object per line plus the trailing newline")
        let (decoded, skipped) = try CaptureFile.decode(data, strict: true)
        #expect(skipped.isEmpty)
        #expect(decoded.header == header)
        #expect(decoded.entries == entries)
    }

    /// IMPLEMENTATION BUG: `CaptureFile.decode` validates payloads with `Character.isHexDigit`, which also accepts
    /// fullwidth digits/letters ("０４８Ａ"), so such an entry is neither rejected nor reported as skipped — and
    /// `ReplayLink` (byte-level hex parser) then drops it silently. Whatever the reader accepts must replay.
    @Test func everyEntryTheReaderAcceptsIsReplayedByteForByte() async throws {
        let text = """
        {"format":"forma-capture","version":1,"createdAt":0,"deviceFamily":"standardHeartRate"}
        {"t":1,"dir":"rx","c":"2A37","d":"0048"}
        {"t":2,"dir":"rx","c":"2A37","d":"\u{FF10}\u{FF10}\u{FF14}\u{FF18}"}
        {"t":3,"dir":"rx","c":"2A37","d":"004A"}
        """
        let (file, skipped) = try CaptureFile.decode(Data(text.utf8))
        let accepted = file.entries.filter { $0.dir == .rx }
        let link = ReplayLink(entries: file.entries, services: [:])
        var replayed: [LinkEvent] = []
        for await e in link.events { if case .notification = e { replayed.append(e) } }
        #expect(replayed.count == accepted.count,
                "accepted \(accepted.map(\.d)) (skipped lines \(skipped)) but replayed \(replayed.count) notifications")
        #expect(replayed.first == .notification(characteristic: UUIDs.heartRateMeasurement, bytes: [0x00, 0x48], receivedAt: 1))
    }

    @Test func lineLengthLimitIsExactAndReportsThePhysicalLine() throws {
        let header = #"{"format":"forma-capture","version":1,"createdAt":0,"deviceFamily":"unknown"}"#
        func entry(totalBytes: Int) -> String {
            var t = 10
            while true {
                let skeleton = #"{"c":"A","d":"","dir":"rx","t":\#(t)}"#
                let hexLength = totalBytes - skeleton.utf8.count
                if hexLength % 2 == 0 { return #"{"c":"A","d":"\#(String(repeating: "a", count: hexLength))","dir":"rx","t":\#(t)}"# }
                t *= 10
            }
        }
        let exact = entry(totalBytes: CaptureFile.maxLineBytes)
        #expect(exact.utf8.count == CaptureFile.maxLineBytes)
        let (file, skipped) = try CaptureFile.decode(Data((header + "\n" + exact + "\n").utf8))
        #expect(file.entries.count == 1 && skipped.isEmpty)
        let tooLong = String(exact.dropLast()) + " }"
        #expect(tooLong.utf8.count == CaptureFile.maxLineBytes + 1)
        #expect(throws: CaptureFileError.lineTooLong(line: 3)) {
            _ = try CaptureFile.decode(Data((header + "\n\n" + tooLong).utf8))
        }
    }

    @Test func skippedLineNumbersArePhysicalLinesWithCRLFAndBlankLines() throws {
        let text = "\r\n" + #"{"format":"forma-capture","version":1,"createdAt":0,"deviceFamily":"whoop5"}"# + "\r\n\r\n"
            + #"{"t":1,"dir":"rx","c":"2A37","d":"0048"}"# + "\r\n" + "garbage\r\n" + "   \r\n"
            + #"{"t":2,"dir":"rx","c":"2A37","d":"0049"}"# + "\r\n"
        let (file, skipped) = try CaptureFile.decode(Data(text.utf8))
        #expect(file.entries.map(\.t) == [1, 2])
        #expect(skipped == [5])
        #expect(throws: CaptureFileError.invalidEntry(line: 5, reason: "invalid JSON entry")) {
            _ = try CaptureFile.decode(Data(text.utf8), strict: true)
        }
    }

    @Test func recorderKeepsTheNewestEntriesAndCountsDropsUnderConcurrency() async {
        let recorder = CaptureRecorder(maxEntries: 100)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for i in 0..<125 { recorder.record(CaptureEntry(t: Int64(worker * 1_000 + i), dir: .rx, c: "A", d: "00")) }
                }
            }
        }
        let snapshot = recorder.snapshot(header: CaptureHeader(createdAt: 0, deviceFamily: .unknown))
        #expect(snapshot.entries.count == 100)
        #expect(recorder.dropped == 900)
        recorder.clear()
        #expect(recorder.snapshot(header: CaptureHeader(createdAt: 0, deviceFamily: .unknown)).entries.isEmpty && recorder.dropped == 0)
    }

    /// IMPLEMENTATION BUG: a responder that scripts `.disconnected` makes `ReplayLink` deliver two disconnect
    /// events — the scripted one, then a synthetic "replay finished" at t = 0 — although a link goes down once.
    @Test func replayLinkDeliversAScriptedDisconnectExactlyOnce() async throws {
        let link = ReplayLink(entries: [], services: [:], responder: { bytes, _ in
            bytes == [0x01] ? [.notification(characteristic: "AA", bytes: [0x02], receivedAt: 5), .disconnected(reason: "band out of range", at: 6)] : []
        })
        try await link.write(testCommand([0x01]), characteristic: "BB", withResponse: true)
        var events: [LinkEvent] = []
        for await e in link.events { events.append(e) }
        let disconnects = events.filter { if case .disconnected = $0 { return true } else { return false } }
        #expect(disconnects == [.disconnected(reason: "band out of range", at: 6)])
        await #expect(throws: LinkError.notConnected) { try await link.write(testCommand([0x02]), characteristic: "BB", withResponse: true) }
    }

    @Test func replayStopsAtTheRecordedDisconnectAndKeepsOriginalReceiveTimes() async {
        let link = ReplayLink(entries: [
            CaptureEntry(t: 10, dir: .rx, c: "2a37", d: "0048"),
            CaptureEntry(t: 11, dir: .tx, c: "x", d: "0102"),
            CaptureEntry(t: 12, dir: .event, c: "", d: "", note: "ready: something"),
            CaptureEntry(t: 13, dir: .event, c: "", d: "", note: "Disconnect: out of range"),
            CaptureEntry(t: 14, dir: .rx, c: "2a37", d: "0049"),
        ], services: ["180D": ["2A37"]])
        var events: [LinkEvent] = []
        for await e in link.events { events.append(e) }
        #expect(events == [.ready(services: ["180D": ["2A37"]]),
                           .notification(characteristic: UUIDs.heartRateMeasurement, bytes: [0x00, 0x48], receivedAt: 10),
                           .disconnected(reason: "Disconnect: out of range", at: 13)])
    }

    /// IMPLEMENTATION BUG: turning on raw capture enables the store's bounded `raw_frame` table
    /// (`AppModel.setCaptureEnabled` → `store.setRawCaptureEnabled`; PRD "Raw frames go only to the bounded
    /// diagnostic table"; ARCHITECTURE "kept as raw evidence when capture is enabled"), but the engine never calls
    /// `IngestSink.recordRawFrame`, so the table stays empty and raw evidence only lives in memory.
    @Test func rawCaptureFeedsTheBoundedRawFrameTable() async throws {
        let store = try FormaStore(path: nil, timeSource: ManualTimeSource(advNow))
        try store.setRawCaptureEnabled(true)
        let link = AdvLink()
        let engine = advEngine(store, history: .off, rawCapture: true, recorder: CaptureRecorder())
        let run = Task { await engine.run(link: link) }
        link.emit([advNote(AdvPkt.unknown, advT(1_000)), advNote(AdvPkt.malformed, advT(1_001))])
        link.disconnect(at: advT(2_000))
        _ = await run.value
        #expect(await engine.currentCounters.unknownPackets == 1, "precondition")
        let frames = try store.rawFrames()
        #expect(frames.contains { $0.bytes == Data(AdvPkt.unknown) }, "unknown packet kept as raw evidence, got \(frames.count) frames")
        #expect(frames.contains { $0.bytes == Data(AdvPkt.malformed) }, "malformed bytes kept as raw evidence")
    }
}

// MARK: - forma-replay CLI (run as a subprocess; build it first with `swift build`)

fileprivate enum AdvCLI {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Output {
        var status: Int32
        var exitedNormally: Bool
        var stdout: String
        var stderr: String
        var json: [String: Any]? {
            guard let data = stdout.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    static func binary() -> URL? {
        var candidates = [packageRoot.appendingPathComponent(".build/debug/forma-replay")]
        if let exe = Bundle.main.executableURL { candidates.append(exe.deletingLastPathComponent().appendingPathComponent("forma-replay")) }
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("forma-replay"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func isStale(_ binary: URL) -> Bool {
        let fm = FileManager.default
        guard let built = (try? fm.attributesOfItem(atPath: binary.path))?[.modificationDate] as? Date else { return false }
        let dirs = ["Sources/FormaReplayCLI", "Sources/FormaSync", "Sources/FormaProtocol", "Sources/FormaCore"]
        for dir in dirs {
            let url = packageRoot.appendingPathComponent(dir)
            for name in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] where name.hasSuffix(".swift") {
                if let m = (try? fm.attributesOfItem(atPath: url.appendingPathComponent(name).path))?[.modificationDate] as? Date, m > built {
                    return true
                }
            }
        }
        return false
    }

    /// Runs forma-replay on a capture made of `lines` (header first). Records an issue and returns nil when the
    /// binary is missing or older than its sources.
    static func replay(_ lines: [String], json: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) throws -> Output? {
        guard let binary = binary() else {
            Issue.record("forma-replay is not built; run `swift build` before `swift test`", sourceLocation: sourceLocation)
            return nil
        }
        if isStale(binary) {
            Issue.record("forma-replay is older than its sources; run `swift build` before `swift test`", sourceLocation: sourceLocation)
            return nil
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("adv-sync-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = binary
        process.arguments = (json ? ["--json"] : []) + [file.path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, exitedNormally: process.terminationReason == .exit,
                      stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }

    static let header = #"{"format":"forma-capture","version":1,"createdAt":0,"deviceFamily":"standardHeartRate"}"#
    static func rx(_ t: Int64, _ hex: String, _ c: String = "00002A37-0000-1000-8000-00805F9B34FB") -> String {
        #"{"t":\#(t),"dir":"rx","c":"\#(c)","d":"\#(hex)"}"#
    }
    static func event(_ t: Int64, _ note: String) -> String { #"{"t":\#(t),"dir":"event","c":"","d":"","note":"\#(note)"}"# }
}

@Suite struct AdvSyncReplayCLITests {
    @Test func cleanCaptureExitsZeroAndAMalformedOneExitsNonZero() throws {
        guard let clean = try AdvCLI.replay([AdvCLI.header, AdvCLI.rx(1_000, "0048")]) else { return }
        #expect(clean.exitedNormally && clean.status == 0, "stderr: \(clean.stderr)")
        let hr = clean.json?["heartRate"] as? [String: Any]
        #expect((hr?["samples"] as? Int) == 1)
        guard let bad = try AdvCLI.replay([AdvCLI.header, AdvCLI.rx(1_000, "01")]) else { return }
        #expect(bad.exitedNormally && bad.status == 1, "a malformed frame must make the replay fail")
    }

    /// IMPLEMENTATION BUG: "never fabricate measurements (nil, not 0)". The machine-readable summary reports
    /// `"min": 0, "max": 0` heart rate for a capture with no heart-rate samples (`hrValues.min() ?? 0`).
    @Test func jsonSummaryNeverReportsZeroBpmWhenThereAreNoSamples() throws {
        guard let out = try AdvCLI.replay([AdvCLI.header, AdvCLI.rx(1_000, "55", "00002A19-0000-1000-8000-00805F9B34FB")]) else { return }
        #expect(out.exitedNormally && out.status == 0)
        let hr = try #require(out.json?["heartRate"] as? [String: Any], "JSON output: \(out.stdout)")
        #expect((hr["samples"] as? Int) == 0, "precondition: no heart-rate samples")
        for key in ["min", "max"] {
            #expect(hr[key] == nil || hr[key] is NSNull, "heartRate.\(key) must be null/absent without samples, got \(String(describing: hr[key]))")
        }
    }

    /// IMPLEMENTATION BUG: the app keeps ONE capture recorder across connections, so an exported capture after a
    /// reconnect holds `ready … disconnect … ready … disconnect`. forma-replay feeds the whole file to a single
    /// `ReplayLink`, which ends at the first recorded disconnect: the second connection's samples are missing from
    /// the totals and its malformed frame does not fail the run (exit 0) — while the per-event listing shows them.
    @Test func captureSpanningAReconnectIsReplayedInFull() throws {
        guard let out = try AdvCLI.replay([
            AdvCLI.header,
            AdvCLI.event(1_000, "ready: 0000180D-0000-1000-8000-00805F9B34FB"),
            AdvCLI.rx(2_000, "0048"),
            AdvCLI.event(3_000, "disconnect: out of range"),
            AdvCLI.event(9_000, "ready: 0000180D-0000-1000-8000-00805F9B34FB"),
            AdvCLI.rx(10_000, "004a"),
            AdvCLI.rx(11_000, "01"),
            AdvCLI.event(12_000, "disconnect: app closed"),
        ]) else { return }
        #expect(out.exitedNormally)
        let hr = try #require(out.json?["heartRate"] as? [String: Any], "JSON output: \(out.stdout)")
        let counters = try #require(out.json?["counters"] as? [String: Any])
        #expect((hr["samples"] as? Int) == 2, "both connections' heart-rate samples must be replayed, got \(String(describing: hr["samples"]))")
        #expect((counters["framesMalformed"] as? Int) == 1, "the malformed frame of the second connection must be counted")
        #expect(out.status == 1, "a capture containing a malformed frame must not replay as clean")
    }
}

// MARK: - Reconnect policy

@Suite struct AdvSyncReconnectPolicyTests {
    @Test func normalDisconnectRetriesImmediatelyAndFailuresBackOffWithinJitterAndCap() {
        let p = ReconnectPolicy(initialDelaySeconds: 2, maxDelaySeconds: 300, multiplier: 2, jitter: 0.2)
        let units = [0.0, 0.1, 0.5, 0.9, 0.999_999, 1.0, -1.0, 2.0]
        for u in units { #expect(p.delay(afterFailures: 0, jitterUnit: u) == 0, "a normal disconnect re-issues the connect immediately") }
        var previousMid = 0.0
        for n in 1...64 {
            let base = min(300, 2 * pow(2, Double(min(n - 1, 30))))
            for u in units {
                let d = p.delay(afterFailures: n, jitterUnit: u)
                #expect(d.isFinite && d > 0, "failures never retry immediately (n=\(n), u=\(u))")
                #expect(d >= base * 0.8 - 1e-9 && d <= min(300, base * 1.2) + 1e-9, "n=\(n) u=\(u) d=\(d) base=\(base)")
            }
            let mid = p.delay(afterFailures: n, jitterUnit: 0.5)
            #expect(mid >= previousMid, "backoff never shrinks")
            previousMid = mid
        }
        let clamped = ReconnectPolicy(initialDelaySeconds: -1, maxDelaySeconds: -5, multiplier: 0.1, jitter: 7)
        #expect(clamped.initialDelaySeconds == 0 && clamped.maxDelaySeconds == 0 && clamped.multiplier == 1 && clamped.jitter == 0.9)
        #expect(ReconnectPolicy().delay(afterFailures: -3, jitterUnit: 0.5) == 0)
    }

    @Test func sequenceCounterWrapsFrom255ToZero() {
        var s = SequenceCounter(start: 253)
        #expect([s.next(), s.next(), s.next(), s.next()] == [254, 255, 0, 1])
    }
}
