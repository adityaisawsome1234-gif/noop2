// Breaker tests for the rewritten history state machine (SyncEngine + Whoop5Adapter), derived from the documented
// contract, not from the implementation:
//   - docs/ARCHITECTURE.md §1 (persist before acknowledge; owned transfers: clock → range (cmd 34) → request (cmd 22);
//     per-chunk acknowledgement eligibility; no abort; timeouts against the engine clock = later of the time source and
//     the newest receive time, "so a replayed capture reproduces a silent band"; interrupted vs complete;
//     lastCompleteSyncAt only after the completion marker with every chunk saved intact),
//   - docs/ARCHITECTURE.md §2–3 (reassembly reports damage; clock mapping rules),
//   - docs/COMPATIBILITY.md §1 (command responses matched by command id, "an echoed-sequence mismatch is counted in
//     diagnostics", "Forma proceeds only on an explicit 1"; range: 25 s per pending, two retries after a refusal, short
//     answer or silence; clock read once per connection and again after clock events, "history waits for it (up to 7 s)";
//     K21 / type 52 chunks never acknowledged; real-time HR "switched off otherwise"),
//   - docs/research/WHOOP5_PROTOCOL.md (frame layout, CRCs, payload layouts, command ids, "no answer within 7 s, retry").
//
// Everything runs through the real `Whoop5Adapter`. Band frames are built by an independent implementation of the
// documented wire algorithm (CRC-16/MODBUS header, CRC-32/ISO-HDLC payload), checked against the documented vectors.
// Re-entrancy is tested deterministically: the scripted link can hold a chosen write open (a gate) so the test can call
// into the engine actor while it is suspended in that write, exactly as the app's timer, settings and "Sync now" can.
// All timeouts are driven with a ManualTimeSource, `timerIntervalMillis: 0` and explicit `checkDeadlines()` calls.
//
// Tests marked IMPLEMENTATION BUG failed because the implementation violated the documented contract; they pass
// since the fixes of the second review (re-entrancy generation checks, deadlines checked before each notification,
// owned/unsolicited buffers, echoed-sequence checks, fresh clock reads after clock events, real-time toggle loop).

import Foundation
import Testing
import FormaCore
@testable import FormaProtocol
@testable import FormaSync

// MARK: - Independent WHOOP 5.0 wire builder (WHOOP5_PROTOCOL.md §2–3)

fileprivate enum BrkWire {
    /// CRC-16/MODBUS: poly 0x8005 reflected, init 0xFFFF, no final XOR.
    static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    /// CRC-32/ISO-HDLC (zlib), bitwise.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }

    /// `AA 01 LEN(u16) 00 01 HCRC(u16) | payload | PCRC(u32)`, LEN = payload + 4. Frames from the band are not always
    /// padded; `pad` zero-pads to a multiple of 4 like the frames Forma builds.
    static func frame(_ payload: [UInt8], pad: Bool = false) -> [UInt8] {
        var p = payload
        if pad { while p.count % 4 != 0 { p.append(0) } }
        var header: [UInt8] = [0xAA, 0x01] + le16(UInt16(p.count + 4)) + [0x00, 0x01]
        header += le16(crc16Modbus(header))
        return header + p + le32(crc32(p))
    }
}

/// Payload layouts (WHOOP5_PROTOCOL.md §3).
fileprivate enum BrkPayload {
    /// 47 HISTORICAL_DATA (or another data type): [1] kind, [2] status, [3…6] counter, [7…10] Unix seconds,
    /// [11…12] sub-seconds, body from 13. Heart-rate candidate at 17 (K24/K9/K12/K10), 14 (K18) or 27 (K7).
    static func record(type: UInt8 = 47, kind: UInt8 = 24, counter: UInt32, seconds: UInt32, hr: UInt8? = nil, length: Int = 40) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: max(13, length))
        p[0] = type
        p[1] = kind
        p.replaceSubrange(3..<7, with: BrkWire.le32(counter))
        p.replaceSubrange(7..<11, with: BrkWire.le32(seconds))
        if let hr {
            let offset = kind == 18 ? 14 : (kind == 7 ? 27 : 17)
            if offset < p.count { p[offset] = hr }
        }
        return p
    }

    /// 49 METADATA kind 1: history start.
    static func start() -> [UInt8] { [49, 0, 1] }

    /// 49 METADATA kind 2: history end. The 8-byte acknowledgement token sits at payload 13…20 and exists only when the
    /// marker is longer than 21 bytes.
    static func end(token: [UInt8]?) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: token == nil ? 16 : 24)
        p[0] = 49
        p[2] = 2
        if let token { p.replaceSubrange(13..<21, with: token) }
        return p
    }

    /// 49 METADATA kind 3: history complete.
    static func complete() -> [UInt8] { [49, 0, 3] }

    /// 36 COMMAND_RESPONSE: [1] sequence, [2] command answered, [3] echoed sequence, [4] result, [5…] data.
    static func response(cmd: UInt8, echo: UInt8, result: UInt8, data: [UInt8] = []) -> [UInt8] {
        [36, 0x40, cmd, echo, result] + data
    }

    /// 48 EVENT: [2…3] u16 event id (13 RTC_LOST, 15 BOOT, 16 SET_RTC, 9 WRIST_ON …).
    static func event(_ id: UInt16) -> [UInt8] { [48, 0] + BrkWire.le16(id) + [0, 0, 0, 0] }
}

// MARK: - Constants and builders

fileprivate let brkData = Whoop5Adapter.dataFromStrap
fileprivate let brkResp = Whoop5Adapter.commandFromStrap
fileprivate let brkEvents = Whoop5Adapter.eventsFromStrap
/// A SIG characteristic the WHOOP decoder does not parse: every notification on it is one `unknownPacket`. Used as a
/// sentinel to know the engine processed everything queued before it (it never touches history state).
fileprivate let brkSentinel = UUIDs.normalize("2A00")
fileprivate let brkDeviceID = "brk-band"
/// Band record time base: 2026-09-21T14:13:20Z (plausible).
fileprivate let brkBase: UInt32 = 1_790_000_000
/// Phone time the tests start at: six hours after the base (whole seconds, so a band clock equal to the phone clock
/// has a zero offset).
fileprivate let brkNow: EpochMillis = Int64(brkBase) * 1_000 + 6 * 3_600_000
fileprivate let brkRangeBody = [UInt8](repeating: 0x5A, count: 25)

/// K24 record `i`: counter 100 + i, band time base + i minutes, heart-rate candidate `hr`.
fileprivate func brkRec(_ i: UInt32, hr: UInt8 = 60, kind: UInt8 = 24, type: UInt8 = 47) -> [UInt8] {
    BrkPayload.record(type: type, kind: kind, counter: 100 + i, seconds: brkBase + i * 60, hr: hr)
}

/// Normalized time of `brkRec(i)` when no clock correction applies.
fileprivate func brkRecTime(_ i: UInt32) -> EpochMillis { Int64(brkBase + i * 60) * 1_000 }

/// A distinct 8-byte acknowledgement token per chunk.
fileprivate func brkToken(_ n: UInt8) -> [UInt8] { (0..<8).map { n &* 16 &+ UInt8($0) } }

/// One frame per notification.
fileprivate func brkNote(_ payload: [UInt8], _ characteristic: String = brkData, at t: EpochMillis = brkNow) -> LinkEvent {
    .notification(characteristic: characteristic, bytes: BrkWire.frame(payload), receivedAt: t)
}

fileprivate func brkRaw(_ bytes: [UInt8], _ characteristic: String = brkData, at t: EpochMillis = brkNow) -> LinkEvent {
    .notification(characteristic: characteristic, bytes: bytes, receivedAt: t)
}

/// Start, records, end(+token) — each frame in its own notification on the data characteristic.
fileprivate func brkChunk(_ records: [[UInt8]], token: [UInt8]?, start: Bool = true, at t: EpochMillis = brkNow) -> [LinkEvent] {
    (start ? [brkNote(BrkPayload.start(), at: t)] : []) + records.map { brkNote($0, at: t) } + [brkNote(BrkPayload.end(token: token), at: t)]
}

fileprivate func brkComplete(at t: EpochMillis = brkNow) -> LinkEvent { brkNote(BrkPayload.complete(), at: t) }

/// Splits a byte stream into notifications of `size` bytes (the last one may be shorter).
fileprivate func brkSplit(_ bytes: [UInt8], size: Int, _ characteristic: String = brkData, at t: EpochMillis = brkNow) -> [LinkEvent] {
    stride(from: 0, to: bytes.count, by: max(1, size)).map {
        .notification(characteristic: characteristic, bytes: Array(bytes[$0..<min(bytes.count, $0 + max(1, size))]), receivedAt: t)
    }
}

// MARK: - Test doubles

fileprivate struct BrkInjectedFailure: Error {}

/// Ordered journal shared by the sink and the link ("ingest:…", "durable", "write:<cmd>").
fileprivate final class BrkJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var entries: [String] { lock.withLock { items } }
}

/// In-memory sink with the documented dedup keys and injectable save / durability failures.
fileprivate final class BrkSink: IngestSink, @unchecked Sendable {
    let journal: BrkJournal
    private let lock = NSLock()
    private var ingestRule: (@Sendable (IngestBatch) -> Bool)?
    private var durableRule: (@Sendable (Int) -> Bool)?
    private var durableCalls = 0
    private var keys = Set<String>()
    private var _hr: [HeartRateSample] = []
    private var _beats: [BeatInterval] = []
    private var _motion: [MotionEpoch] = []
    private var _aux: [AuxMeasurement] = []
    private var _cursor: SyncCursor?
    private var _finished: [SyncRunRecord] = []
    private var _inserted = 0
    private var _duplicates = 0
    private var _okBatches = 0

    init(journal: BrkJournal = BrkJournal()) { self.journal = journal }

    /// `rule(batch)` returning true makes that ingest throw (nothing of it is stored).
    func failIngest(when rule: @escaping @Sendable (IngestBatch) -> Bool) { lock.withLock { ingestRule = rule } }
    /// `rule(zeroBasedCallIndex)` returning true makes that `ensureDurable()` throw.
    func failDurable(when rule: @escaping @Sendable (Int) -> Bool) { lock.withLock { durableRule = rule } }

    func ingest(_ batch: IngestBatch) throws -> IngestResult {
        try lock.withLock {
            let n = batch.heartRates.count + batch.beatIntervals.count + batch.motion.count + batch.aux.count
            if let rule = ingestRule, rule(batch) {
                journal.add("ingest-failed:\(batch.provenance.note ?? ""):\(n)")
                throw BrkInjectedFailure()
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
            _inserted += inserted
            _duplicates += duplicates
            _okBatches += 1
            journal.add("ingest:\(batch.provenance.note ?? ""):\(n)\(batch.cursor == nil ? "" : "+cursor")")
            return IngestResult(batchID: Int64(_okBatches), inserted: inserted, duplicates: duplicates)
        }
    }

    func ensureDurable() throws {
        try lock.withLock {
            let index = durableCalls
            durableCalls += 1
            if let rule = durableRule, rule(index) {
                journal.add("durable-failed")
                throw BrkInjectedFailure()
            }
            journal.add("durable")
        }
    }

    func syncCursor(deviceID: String) throws -> SyncCursor? { lock.withLock { _cursor } }
    func upsertDevice(_ device: DeviceRecord) throws {}
    func recordConnectionEvent(_ event: ConnectionEvent) throws {}
    func recordRawFrame(_ frame: RawFrameRecord) throws {}
    func beginSyncRun(_ run: SyncRunRecord) throws -> Int64 { 1 }
    func finishSyncRun(_ run: SyncRunRecord) throws { lock.withLock { _finished.append(run) } }

    var historyHR: [HeartRateSample] { lock.withLock { _hr.filter { $0.source == .deviceHistory } } }
    var historyTimes: [EpochMillis] { historyHR.map(\.timestamp).sorted() }
    var cursor: SyncCursor? { lock.withLock { _cursor } }
    var finishedRuns: [SyncRunRecord] { lock.withLock { _finished } }
    var insertedTotal: Int { lock.withLock { _inserted } }
    var duplicatesTotal: Int { lock.withLock { _duplicates } }
}

/// A command as the scripted band saw it (frame bytes; command id at 10, sequence at 9, data from 11).
fileprivate struct BrkWrite: Hashable, Sendable {
    let bytes: [UInt8]
    var cmd: UInt8 { bytes.count > 10 ? bytes[10] : 0 }
    var seq: UInt8 { bytes.count > 9 ? bytes[9] : 0 }
    /// First data byte (01/00 for the real-time toggle, 01 for an acknowledgement).
    var arg: UInt8? { bytes.count > 15 ? bytes[11] : nil }
    /// The 8-byte token an acknowledgement echoes.
    var ackToken: [UInt8]? { cmd == 23 && bytes.count >= 24 ? Array(bytes[12..<20]) : nil }
}

/// Holds one write open until `open()` is called, so the test can act while the engine actor is suspended in it.
fileprivate final class BrkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { lock.withLock { waiters.count } }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if opened { return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            let w = waiters
            waiters = []
            return w
        }
        for w in pending { w.resume() }
    }
}

/// A scripted WHOOP 5.0 link: a responder plays the band's reaction to each write (after any gate on that write opens),
/// and tests can push notifications directly.
fileprivate final class BrkLink: PeripheralLink, @unchecked Sendable {
    typealias Responder = @Sendable (_ write: BrkWrite, _ nthOfThisCommand: Int) throws -> [LinkEvent]

    let peripheralID = "brk-link"
    let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let lock = NSLock()
    private let responder: Responder?
    private let journal: BrkJournal?
    private var gates: [String: BrkGate] = [:]
    private var attemptLog: [BrkWrite] = []
    private var writeLog: [BrkWrite] = []
    private var closed = false

    init(journal: BrkJournal? = nil, responder: Responder? = nil) {
        self.journal = journal
        self.responder = responder
        var cont: AsyncStream<LinkEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        continuation.yield(.ready(services: [Whoop5Adapter.service: [Whoop5Adapter.commandToStrap, brkResp, brkEvents, brkData]]))
    }

    /// The `nth` (0-based) write of command `cmd` waits for the returned gate.
    func gate(cmd: UInt8, nth: Int = 0) -> BrkGate {
        lock.withLock {
            let key = "\(cmd)#\(nth)"
            if let g = gates[key] { return g }
            let g = BrkGate()
            gates[key] = g
            return g
        }
    }

    private func yieldLocked(_ e: LinkEvent) {
        guard !closed else { return }
        continuation.yield(e)
        if case .disconnected = e {
            closed = true
            continuation.finish()
        }
    }

    func emit(_ e: LinkEvent) { lock.withLock { yieldLocked(e) } }
    func emit(_ es: [LinkEvent]) { lock.withLock { for e in es { yieldLocked(e) } } }
    func disconnect(at t: EpochMillis, reason: String = "test end") { emit(.disconnected(reason: reason, at: t)) }

    func write(_ command: EncodedCommand, characteristic: String, withResponse: Bool) async throws {
        let w = BrkWrite(bytes: command.bytes)
        let (gate, nth) = try lock.withLock { () throws -> (BrkGate?, Int) in
            if closed { throw LinkError.notConnected }
            let nth = attemptLog.filter { $0.cmd == w.cmd }.count
            attemptLog.append(w)
            return (gates["\(w.cmd)#\(nth)"], nth)
        }
        if let gate { await gate.wait() }
        try lock.withLock {
            if closed { throw LinkError.notConnected }
            let reaction = try responder?(w, nth) ?? []
            writeLog.append(w)
            journal?.add("write:\(w.cmd)")
            for e in reaction { yieldLocked(e) }
        }
    }

    var attempts: [BrkWrite] { lock.withLock { attemptLog } }
    var writes: [BrkWrite] { lock.withLock { writeLog } }
    func attempts(cmd: UInt8) -> Int { attempts.filter { $0.cmd == cmd }.count }
    func writes(cmd: UInt8) -> [BrkWrite] { writes.filter { $0.cmd == cmd } }
    /// Command ids of successful writes, in order, restricted to `ids`.
    func order(_ ids: Set<UInt8>) -> [UInt8] { writes.map(\.cmd).filter { ids.contains($0) } }
}

/// The band's answer to a command.
fileprivate enum BrkAnswer: Sendable {
    case silent
    case result(UInt8, body: Int)
    static let success = BrkAnswer.result(1, body: 25)
    static let pending = BrkAnswer.result(2, body: 0)
}

/// A scripted WHOOP band. Answers carry the time source's current time as receive time.
fileprivate struct BrkBand: Sendable {
    let time: ManualTimeSource
    /// Seconds the band clock is behind the phone, per GET_CLOCK (0-based); nil = that read is never answered.
    var clockBehind: @Sendable (_ nth: Int) -> Int64? = { _ in 0 }
    /// Absolute band clock seconds (overrides `clockBehind` when set).
    var clockSeconds: UInt32?
    /// Answer to each GET_DATA_RANGE (the last entry repeats).
    var range: [BrkAnswer] = [.success]
    /// Added to the echoed sequence of range answers (0 = echo the request's sequence).
    var rangeEchoOffset: UInt8 = 0
    /// Notifications streamed right after the success answer to the n-th SEND_HISTORICAL_DATA.
    var history: @Sendable (_ nth: Int) -> [LinkEvent] = { _ in [] }
    /// Notifications after the answer to the n-th acknowledgement.
    var afterAck: @Sendable (_ nth: Int) -> [LinkEvent] = { _ in [] }
    var ackResult: UInt8 = 1

    init(time: ManualTimeSource) { self.time = time }

    func responder() -> BrkLink.Responder {
        let band = self
        return { w, nth in
            let now = band.time.now()
            func answer(_ result: UInt8, _ data: [UInt8] = [], echo: UInt8? = nil) -> LinkEvent {
                brkNote(BrkPayload.response(cmd: w.cmd, echo: echo ?? w.seq, result: result, data: data), brkResp, at: now)
            }
            switch w.cmd {
            case 145:
                return [answer(1)]
            case 11:
                if let s = band.clockSeconds { return [answer(1, BrkWire.le32(s) + BrkWire.le32(0))] }
                guard let behind = band.clockBehind(nth) else { return [] }
                let seconds = UInt32(clamping: now / 1_000 - behind)
                return [answer(1, BrkWire.le32(seconds) + BrkWire.le32(0))]
            case 34:
                switch band.range[min(nth, band.range.count - 1)] {
                case .silent: return []
                case .result(let code, let body):
                    return [answer(code, [UInt8](repeating: 0x5A, count: body), echo: w.seq &+ band.rangeEchoOffset)]
                }
            case 22:
                return [answer(1)] + band.history(nth)
            case 23:
                return [answer(band.ackResult)] + band.afterAck(nth)
            case 3:
                return [answer(1)]
            default:
                return []
            }
        }
    }
}

fileprivate final class BrkUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SyncUpdate] = []
    func append(_ u: SyncUpdate) { lock.withLock { items.append(u) } }
    var all: [SyncUpdate] { lock.withLock { items } }
}

fileprivate extension SyncUpdate {
    var brkIsDisconnected: Bool { if case .disconnected = self { return true } else { return false } }
    var brkIsComplete: Bool { if case .historyComplete = self { return true } else { return false } }
    var brkIsStopped: Bool { if case .historyStopped = self { return true } else { return false } }
    var brkIsClockImplausible: Bool { if case .clockImplausible = self { return true } else { return false } }
    var brkChunkSaved: (inserted: Int, duplicates: Int, acknowledged: Bool)? {
        if case .historyChunkSaved(let i, let d, let a) = self { return (i, d, a) } else { return nil }
    }
}

@discardableResult
fileprivate func brkWait(_ timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

/// Pushes the sentinel and waits until the engine processed it (and therefore everything queued before it).
@discardableResult
fileprivate func brkDrain(_ engine: SyncEngine, _ link: BrkLink, at t: EpochMillis) async -> Bool {
    let before = await engine.currentCounters.unknownPackets
    link.emit(.notification(characteristic: brkSentinel, bytes: [0x00], receivedAt: t))
    return await brkWait { await engine.currentCounters.unknownPackets > before }
}

fileprivate func brkOptions(history: HistoryPolicy = .automatic, ack: Bool = true, liveHR: Bool = false, identify: Bool = true,
                            readClock: Bool = true, subBatch: Int = 500, idle: Int64 = 30_000) -> SyncOptions {
    SyncOptions(history: history, acknowledgeHistory: ack, liveHeartRate: liveHR, rawCapture: false, liveFlushIntervalMillis: 0,
                historySubBatchSize: subBatch, historyIdleTimeoutMillis: idle, commandTimeoutMillis: 7_000, pendingGraceMillis: 25_000,
                rangeRetries: 2, retryDelayMillis: 1_000, identifyOnConnect: identify, readClockOnConnect: readClock,
                timerIntervalMillis: 0)
}

/// One running engine on a scripted band.
fileprivate struct BrkRig: Sendable {
    let time: ManualTimeSource
    let sink: BrkSink
    let link: BrkLink
    let engine: SyncEngine
    let updates: BrkUpdates
    let consumer: Task<Void, Never>
    let run: Task<SyncRunRecord, Never>
    let gates: [BrkGate]

    var counters: SyncCounters { get async { await engine.currentCounters } }

    func drain(at t: EpochMillis? = nil) async { await brkDrain(engine, link, at: t ?? time.now()) }

    func acked() -> [[UInt8]] { link.writes(cmd: 23).compactMap(\.ackToken) }

    /// Opens every gate, disconnects, waits for the run to end and for the update stream to deliver the disconnect.
    func finish(at t: EpochMillis? = nil) async -> SyncRunRecord {
        for g in gates { g.open() }
        link.disconnect(at: t ?? time.now())
        let record = await run.value
        await brkWait { updates.all.contains { $0.brkIsDisconnected } }
        consumer.cancel()
        return record
    }
}

fileprivate func brkStart(_ band: BrkBand, _ options: SyncOptions, sink: BrkSink = BrkSink(), gates: [(cmd: UInt8, nth: Int)] = []) -> BrkRig {
    let link = BrkLink(journal: sink.journal, responder: band.responder())
    let gateList = gates.map { link.gate(cmd: $0.cmd, nth: $0.nth) }
    let device = DeviceRecord(id: brkDeviceID, family: .whoop5, name: "WHOOP", firstSeen: 0)
    let engine = SyncEngine(adapter: Whoop5Adapter(), sink: sink, device: device, timeSource: band.time, options: options)
    let updates = BrkUpdates()
    let stream = engine.updates
    let consumer = Task { for await u in stream { updates.append(u) } }
    let run = Task { await engine.run(link: link) }
    return BrkRig(time: band.time, sink: sink, link: link, engine: engine, updates: updates, consumer: consumer, run: run, gates: gateList)
}

// MARK: - Parameter types

enum BrkRangeRefusal: String, CaseIterable, Sendable {
    /// Result 0 is contested (failure in the reference client, success in the emulator): Forma proceeds only on 1.
    case contestedZero
    /// Result 3 UNSUPPORTED.
    case unsupported
    /// Success with a 24-byte body (the reference client needs at least 25).
    case successWithShortBody
    /// Success with no body at all.
    case successWithoutBody

    fileprivate var answer: BrkAnswer {
        switch self {
        case .contestedZero: return .result(0, body: 25)
        case .unsupported: return .result(3, body: 25)
        case .successWithShortBody: return .result(1, body: 24)
        case .successWithoutBody: return .result(1, body: 0)
        }
    }
}

enum BrkUndecodedRecord: String, CaseIterable, Sendable {
    /// K21 grouped channels: meaning unknown, content not stored.
    case k21
    /// Type 52 history IMU stream: not stored.
    case historyIMU
    /// A record kind no public source describes.
    case unknownKind

    fileprivate var payload: [UInt8] {
        switch self {
        case .k21: return BrkPayload.record(kind: 21, counter: 150, seconds: brkBase + 150, hr: 70)
        case .historyIMU: return BrkPayload.record(type: 52, kind: 24, counter: 151, seconds: brkBase + 151, hr: 70)
        case .unknownKind: return BrkPayload.record(kind: 99, counter: 152, seconds: brkBase + 152, hr: 70)
        }
    }
}

enum BrkBadClock: String, CaseIterable, Sendable {
    /// Band clock 24 h + 1 s behind the phone.
    case behindByMoreThanADay
    /// Band clock 24 h + 1 s ahead of the phone.
    case aheadByMoreThanADay
    /// Band clock in 2017 (before 2020).
    case before2020
}

enum BrkChunkFailure: String, CaseIterable, Sendable {
    /// The sub-batch carrying the chunk's record fails to save.
    case recordSave
    /// The chunk's final commit (with the sync cursor) fails.
    case finalCommit
    /// The durability flush before the acknowledgement fails.
    case durableFlush
}

// MARK: - Wire sanity

@Suite struct BrkWireSanityTests {
    @Test func independentBuilderReproducesTheDocumentedFramesAndTheAdapterAgrees() throws {
        let vectors: [([UInt8], String)] = [
            ([35, 0x01, 145, 0x01], "aa0108000001e67123019101363e5c8d"),
            ([35, 7, 34], "aa0108000001e67123072200698f3e31"),
            ([35, 8, 22], "aa0108000001e67123081600a33b4881"),
            ([35, 180, 3, 0x01], "aa0108000001e67123b4030155eabe0d"),
            ([35, 182, 3, 0x00], "aa0108000001e67123b60300ad0e3d79"),
            ([35, 96, 11], "aa0108000001e67123600b0027cde038"),
            ([35, 59, 23, 0x01] + [UInt8](repeating: 0, count: 8), "aa0110000001e0d1233b17010000000000000000ed8d38cd"),
        ]
        for (payload, hex) in vectors {
            #expect(BrkWire.frame(payload, pad: true) == HexCodec.decode(hex), "payload \(payload)")
        }
        let adapter = Whoop5Adapter()
        #expect(try adapter.encode(.readHistoryRange, sequence: 7).bytes == HexCodec.decode("aa0108000001e67123072200698f3e31"))
        #expect(try adapter.encode(.acknowledgeHistory(token: [UInt8](repeating: 0, count: 8)), sequence: 59).bytes
                == HexCodec.decode("aa0110000001e0d1233b17010000000000000000ed8d38cd"))
        // Unpadded band frames decode (a published real payload is unpadded).
        let events = Whoop5Decoder().decode(characteristic: brkData, bytes: BrkWire.frame(brkRec(1, hr: 61)), receivedAt: brkNow)
        #expect(events.count == 1)
        if case .historyRecord(let r)? = events.first {
            #expect(r.kind == 24 && r.counter == 101 && r.deviceSeconds == brkBase + 60 && r.heartRate == 61 && r.contentDecoded)
        } else {
            Issue.record("expected a history record, got \(events)")
        }
    }
}

// MARK: - Owned transfers: order, waits, retries, response matching

@Suite struct BrkOwnedTransferOrderTests {
    /// ARCHITECTURE §1: clock → range (cmd 34) → request (cmd 22); the acknowledgement only after the chunk's commit
    /// returned AND the durability flush succeeded.
    @Test func clockThenRangeThenRequestAndTheAckOnlyAfterCommitAndDurableFlush() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.history = { n in n == 0 ? brkChunk([brkRec(1), brkRec(2)], token: brkToken(1)) + [brkComplete()] : [] }
        let rig = brkStart(band, brkOptions())
        await brkWait { rig.link.writes(cmd: 23).count == 1 }
        await rig.drain()
        let record = await rig.finish()

        #expect(rig.link.writes.map(\.cmd) == [145, 11, 34, 22, 23])
        let j = rig.sink.journal.entries
        let commit = j.firstIndex(of: "ingest:history:2+cursor")
        let durable = j.firstIndex(of: "durable")
        let ack = j.firstIndex(of: "write:23")
        #expect(commit != nil && durable != nil && ack != nil, "\(j)")
        if let commit, let durable, let ack {
            #expect(commit < durable && durable < ack, "commit, then durable flush, then acknowledgement: \(j)")
        }
        #expect(rig.acked() == [brkToken(1)])
        #expect(rig.sink.historyTimes == [brkRecTime(1), brkRecTime(2)])
        #expect(rig.sink.historyHR.allSatisfy { $0.quality.contains(.unvalidatedField) && !$0.quality.contains(.phoneReceiveTime) })
        #expect(rig.sink.cursor?.lastCompleteSyncAt == brkNow)
        #expect(record.status == .completed)
    }

    /// "read the band clock (wait up to 7 s for the answer)".
    @Test func historyWaitsUpToSevenSecondsForTheClockAnswerThenReadsTheRange() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.clockBehind = { _ in nil }
        let rig = brkStart(band, brkOptions(ack: false))
        await brkWait { rig.link.attempts(cmd: 11) == 1 }
        await rig.drain()
        #expect(rig.link.attempts(cmd: 34) == 0)
        time.advance(byMillis: 6_999)
        await rig.engine.checkDeadlines()
        #expect(rig.link.attempts(cmd: 34) == 0, "history waits up to 7 s for the clock answer")
        time.advance(byMillis: 1)
        await rig.engine.checkDeadlines()
        #expect(rig.link.attempts(cmd: 34) == 1, "after 7 s without a clock answer the range is read")
        #expect(await brkWait { rig.link.attempts(cmd: 22) == 1 })
        #expect(rig.link.attempts(cmd: 11) == 1)
        _ = await rig.finish()
    }

    /// "no answer within 7 s, retry, at most twice, 1 s apart"; history is requested only after a success.
    @Test func silentRangeIsRetriedTwiceOneSecondApartAndHistoryIsNeverRequested() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.range = [.silent, .silent, .silent, .success]
        let rig = brkStart(band, brkOptions(ack: false, identify: false, readClock: false))
        await brkWait { rig.link.attempts(cmd: 34) == 1 }
        await rig.drain()
        for attempt in 2...3 {
            time.advance(byMillis: 7_000)
            await rig.engine.checkDeadlines()
            time.advance(byMillis: 999)
            await rig.engine.checkDeadlines()
            #expect(rig.link.attempts(cmd: 34) == attempt - 1, "the retry waits 1 s")
            time.advance(byMillis: 1)
            await rig.engine.checkDeadlines()
            #expect(rig.link.attempts(cmd: 34) == attempt)
        }
        time.advance(byMillis: 7_000)
        await rig.engine.checkDeadlines()
        time.advance(byMillis: 60_000)
        await rig.engine.checkDeadlines()
        await rig.drain()
        #expect(rig.link.attempts(cmd: 34) == 3, "one attempt plus two retries")
        #expect(rig.link.attempts(cmd: 22) == 0, "history is requested only after an explicit range success")
        #expect(await brkWait { rig.updates.all.contains { $0.brkIsStopped } })
        // A later Sync now starts a fresh owned transfer, range first again.
        await rig.engine.requestHistorySync()
        #expect(await brkWait { rig.link.attempts(cmd: 22) == 1 })
        #expect(rig.link.order([34, 22]) == [34, 34, 34, 34, 22])
        _ = await rig.finish()
    }

    /// "keeps waiting 25 s on each pending".
    @Test func eachPendingRangeAnswerExtendsTheWaitBy25Seconds() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.range = [.pending, .success]
        let rig = brkStart(band, brkOptions(ack: false, identify: false, readClock: false))
        await brkWait { rig.link.attempts(cmd: 34) == 1 }
        await rig.drain()
        time.advance(byMillis: 20_000)
        await rig.engine.checkDeadlines()
        #expect(rig.link.attempts(cmd: 34) == 1, "pending: keep waiting, no 7 s retry")
        let seq = rig.link.writes(cmd: 34)[0].seq
        rig.link.emit(brkNote(BrkPayload.response(cmd: 34, echo: seq, result: 2), brkResp, at: time.now()))
        await rig.drain()
        time.advance(byMillis: 24_999)
        await rig.engine.checkDeadlines()
        #expect(rig.link.attempts(cmd: 34) == 1, "the second pending (at 20 s) extends the wait to 45 s")
        time.advance(byMillis: 1)
        await rig.engine.checkDeadlines()
        time.advance(byMillis: 1_000)
        await rig.engine.checkDeadlines()
        #expect(rig.link.attempts(cmd: 34) == 2)
        #expect(await brkWait { rig.link.attempts(cmd: 22) == 1 })
        #expect(rig.link.order([34, 22]) == [34, 34, 22])
        _ = await rig.finish()
    }

    /// "Forma proceeds only on an explicit 1"; "A success answer carries at least 25 body bytes".
    @Test(arguments: BrkRangeRefusal.allCases)
    func onlyAnExplicitSuccessWithAFullBodyLeadsToTheHistoryRequest(_ refusal: BrkRangeRefusal) async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.range = [refusal.answer]
        let rig = brkStart(band, brkOptions(ack: false, identify: false, readClock: false))
        await brkWait { rig.link.attempts(cmd: 34) == 1 }
        await rig.drain()
        for _ in 0..<2 {
            time.advance(byMillis: 1_000)
            await rig.engine.checkDeadlines()
            await rig.drain()
        }
        time.advance(byMillis: 60_000)
        await rig.engine.checkDeadlines()
        await rig.drain()
        #expect(rig.link.attempts(cmd: 34) == 3, "\(refusal): refused, retried twice")
        #expect(rig.link.attempts(cmd: 22) == 0, "\(refusal): history must not be requested")
        _ = await rig.finish()
    }

    /// "Read history range: before each history request".
    @Test func theRangeIsReadBeforeEveryHistoryRequestInOneConnection() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.history = { n in (n == 0 ? brkChunk([brkRec(1)], token: brkToken(1)) : []) + [brkComplete()] }
        let rig = brkStart(band, brkOptions(history: .manual, ack: false))
        await rig.drain()
        await rig.engine.requestHistorySync()
        await brkWait { rig.sink.cursor?.lastCompleteSyncAt != nil }
        await rig.drain()
        await rig.engine.requestHistorySync()
        await brkWait { rig.link.attempts(cmd: 22) == 2 }
        await rig.drain()
        _ = await rig.finish()
        #expect(rig.link.order([11, 34, 22]) == [11, 34, 22, 34, 22])
    }

    /// IMPLEMENTATION BUG: COMPATIBILITY §1 (command responses): "Matched to Forma's outstanding request by command id
    /// ...; an echoed-sequence mismatch is counted in diagnostics." `SyncCounters.responseSequenceMismatches` exists for
    /// exactly this, but the engine never compares the echoed sequence (`CommandResponse.originSequence`) with the
    /// request's sequence, so the counter stays 0.
    @Test func echoedSequenceMismatchIsCountedWhileTheAnswerIsStillMatchedByCommandID() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.rangeEchoOffset = 5
        band.history = { _ in [brkComplete()] }
        let rig = brkStart(band, brkOptions(ack: false))
        await brkWait { rig.link.attempts(cmd: 22) == 1 }
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(rig.link.attempts(cmd: 22) == 1, "matched by command id despite the wrong echo")
        #expect(counters.responseSequenceMismatches == 1, "the echoed-sequence mismatch must be counted in diagnostics")
    }

    /// IMPLEMENTATION BUG: COMPATIBILITY §1 (band clock): "Read once per connection and again after BOOT, SET_RTC or
    /// RTC_LOST events; history waits for it (up to 7 s)" — and ClockMapper: after a clock event "records are flagged
    /// until the next reading, which becomes the new baseline". After SET_RTC the engine re-reads the clock, but a
    /// transfer started before that answer arrives does not wait for it (`clockReadingReceived` stays true from the
    /// first read): range and history are requested at once and the history is mapped with the stale offset.
    @Test func historyStartedAfterAClockEventWaitsForTheFreshClockReading() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.clockBehind = { nth in nth == 0 ? 0 : nil }
        let rig = brkStart(band, brkOptions(history: .manual, ack: false))
        await brkWait { rig.link.attempts(cmd: 11) == 1 }
        await rig.drain()
        // The official app sets the band clock: SET_RTC (16). Forma reads the clock again; the band has not answered yet.
        rig.link.emit(brkNote(BrkPayload.event(16), brkEvents))
        await rig.drain()
        #expect(rig.link.attempts(cmd: 11) == 2, "precondition: the clock is read again after SET_RTC")
        await rig.engine.requestHistorySync()
        await rig.drain()
        #expect(rig.link.attempts(cmd: 34) == 0, "history must wait (up to 7 s) for the fresh clock reading")
        // The band answers the re-read: now the transfer may proceed.
        let seq = rig.link.writes(cmd: 11)[1].seq
        rig.link.emit(brkNote(BrkPayload.response(cmd: 11, echo: seq, result: 1, data: BrkWire.le32(UInt32(brkNow / 1_000)) + BrkWire.le32(0)),
                              brkResp))
        #expect(await brkWait { rig.link.attempts(cmd: 34) == 1 })
        _ = await rig.finish()
    }
}

// MARK: - Acknowledgement eligibility under adversarial event sequences (acknowledgements ON)

@Suite struct BrkAckEligibilityTests {
    /// History another app triggers: saved (history on), never acknowledged, never moves the cursor, no history command.
    @Test func historyTheBandSendsUnaskedIsSavedButNeverActedOn() async {
        let time = ManualTimeSource(brkNow)
        let rig = brkStart(BrkBand(time: time), brkOptions(history: .manual))
        await rig.drain()
        rig.link.emit(brkChunk([brkRec(1), brkRec(2)], token: brkToken(1)) + [brkComplete()])
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(rig.link.writes.allSatisfy { ![34, 22, 23, 20].contains($0.cmd) }, "\(rig.link.writes.map(\.cmd))")
        #expect(rig.sink.historyTimes == [brkRecTime(1), brkRecTime(2)])
        #expect(rig.sink.cursor == nil, "unsolicited history never moves Forma's sync cursor")
        #expect(counters.historyRecordsUnsolicited == 2)
    }

    @Test func historyOffCountsUnaskedHistoryButStoresNothing() async {
        let time = ManualTimeSource(brkNow)
        let rig = brkStart(BrkBand(time: time), brkOptions(history: .off))
        await rig.drain()
        rig.link.emit(brkChunk([brkRec(1)], token: brkToken(1)) + [brkComplete()])
        await rig.drain()
        await rig.engine.requestHistorySync()
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(rig.sink.historyHR.isEmpty)
        #expect(counters.historyRecordsUnsolicited == 1)
        #expect(rig.link.writes.allSatisfy { ![34, 22, 23, 20].contains($0.cmd) })
    }

    /// "a chunk is acknowledged only if its start marker was seen"; "The first failing chunk blocks acknowledgements for
    /// the rest of that transfer."
    @Test func chunkWithoutItsStartMarkerIsNotAcknowledgedAndNeitherIsAnyLaterChunk() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.history = { n in
            n == 0 ? brkChunk([brkRec(1)], token: brkToken(1), start: false) + brkChunk([brkRec(2)], token: brkToken(2)) + [brkComplete()] : []
        }
        let rig = brkStart(band, brkOptions())
        await brkWait { await rig.counters.historyRecords == 2 }
        await rig.drain()
        _ = await rig.finish()
        #expect(rig.acked().isEmpty, "acknowledged \(rig.acked())")
        #expect(rig.sink.historyTimes == [brkRecTime(1), brkRecTime(2)], "what arrived is still saved")
    }

    /// "no frame on a vendor characteristic was malformed …"; lastCompleteSyncAt "only when … every chunk was saved intact".
    @Test func damagedFrameInsideAChunkThenACleanEndBlocksTheRestAndTheTransferIsNotComplete() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        var damaged = BrkWire.frame(brkRec(2))
        damaged[8 + 20] ^= 0xFF   // header intact, payload CRC now fails
        let bad = damaged
        band.history = { n in
            n == 0
                ? [brkNote(BrkPayload.start()), brkNote(brkRec(1)), brkRaw(bad), brkNote(brkRec(3)), brkNote(BrkPayload.end(token: brkToken(1)))]
                    + brkChunk([brkRec(4)], token: brkToken(2)) + [brkComplete()]
                : []
        }
        let rig = brkStart(band, brkOptions())
        await brkWait { await rig.counters.historyRecords == 3 }
        await rig.drain()
        let counters = await rig.counters
        let record = await rig.finish()
        #expect(counters.framesMalformed >= 1, "precondition: the damage was detected")
        #expect(rig.acked().isEmpty, "acknowledged \(rig.acked())")
        #expect(rig.sink.historyTimes == [brkRecTime(1), brkRecTime(3), brkRecTime(4)])
        #expect(rig.sink.cursor?.lastCompleteSyncAt == nil)
        #expect(!rig.updates.all.contains { $0.brkIsComplete })
        #expect(record.status != .completed)
    }

    /// ARCHITECTURE §2: "the outcome does not depend on how notifications split the stream" — at the engine level the
    /// acknowledgement decision, the stored records and completion must not depend on it either.
    @Test func ackDecisionForADamagedTransferDoesNotDependOnNotificationSplits() async {
        var damaged = BrkWire.frame(brkRec(2))
        damaged[8 + 20] ^= 0xFF
        let stream = [BrkWire.frame(BrkPayload.start()), BrkWire.frame(brkRec(1)), damaged, BrkWire.frame(brkRec(3)),
                      BrkWire.frame(BrkPayload.end(token: brkToken(1))), BrkWire.frame(BrkPayload.start()), BrkWire.frame(brkRec(4)),
                      BrkWire.frame(BrkPayload.end(token: brkToken(2))), BrkWire.frame(BrkPayload.complete())].flatMap { $0 }
        var outcomes: [String] = []
        for size in [stream.count, 64, 20, 13, 7, 3, 1] {
            let time = ManualTimeSource(brkNow)
            var band = BrkBand(time: time)
            band.history = { n in n == 0 ? brkSplit(stream, size: size) : [] }
            let rig = brkStart(band, brkOptions())
            await brkWait { await rig.counters.historyRecords == 3 }
            await rig.drain()
            _ = await rig.finish()
            outcomes.append("acks=\(rig.acked().count) stored=\(rig.sink.historyTimes.count) complete=\(rig.sink.cursor?.lastCompleteSyncAt != nil)")
        }
        #expect(Set(outcomes).count == 1, "outcome depends on notification size: \(outcomes)")
        #expect(outcomes.first == "acks=0 stored=3 complete=false", "\(outcomes)")
    }

    /// "no frame on a vendor characteristic was … left partial": a frame still incomplete on ANOTHER vendor
    /// characteristic when the end marker arrives means part of the chunk may be missing.
    @Test func partialFrameLeftOnAnotherVendorCharacteristicBlocksTheAcknowledgement() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        let event = BrkWire.frame(BrkPayload.event(9))
        band.history = { n in
            n == 0
                ? [brkNote(BrkPayload.start()), brkNote(brkRec(1)), brkRaw(Array(event.prefix(10)), brkEvents),
                   brkNote(BrkPayload.end(token: brkToken(1))), brkRaw(Array(event.dropFirst(10)), brkEvents)]
                    + brkChunk([brkRec(2)], token: brkToken(2)) + [brkComplete()]
                : []
        }
        let rig = brkStart(band, brkOptions())
        await brkWait { await rig.counters.historyRecords == 2 }
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(counters.deviceEvents == 1, "precondition: the split event frame completed later")
        #expect(rig.acked().isEmpty, "acknowledged \(rig.acked())")
        #expect(rig.sink.historyTimes == [brkRecTime(1), brkRecTime(2)])
    }

    /// Control: bytes pending on the end marker's OWN characteristic belong to the next frame, not to the chunk.
    @Test func nextFrameAlreadyArrivingOnTheSameCharacteristicDoesNotBlockTheAcknowledgement() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        let start2 = BrkWire.frame(BrkPayload.start())
        band.history = { n in
            n == 0
                ? [brkNote(BrkPayload.start()), brkNote(brkRec(1)),
                   brkRaw(BrkWire.frame(BrkPayload.end(token: brkToken(1))) + Array(start2.prefix(6))),
                   brkRaw(Array(start2.dropFirst(6)) + BrkWire.frame(brkRec(2)) + BrkWire.frame(BrkPayload.end(token: brkToken(2))))]
                    + [brkComplete()]
                : []
        }
        let rig = brkStart(band, brkOptions())
        await brkWait { rig.link.writes(cmd: 23).count == 2 }
        await rig.drain()
        let record = await rig.finish()
        #expect(rig.acked() == [brkToken(1), brkToken(2)])
        #expect(record.status == .completed)
    }

    /// "no frame … was … truncated": a record cut short, followed by the end marker.
    @Test func truncatedRecordBeforeTheEndMarkerBlocksTheAcknowledgement() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        let cut = Array(BrkWire.frame(brkRec(2)).prefix(30))
        band.history = { n in
            n == 0 ? [brkNote(BrkPayload.start()), brkNote(brkRec(1)), brkRaw(cut), brkNote(BrkPayload.end(token: brkToken(1))), brkComplete()] : []
        }
        let rig = brkStart(band, brkOptions())
        await brkWait { await rig.counters.historyRecords == 1 }
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(counters.framesMalformed >= 1, "the truncation is reported")
        #expect(rig.acked().isEmpty, "acknowledged \(rig.acked())")
        #expect(rig.sink.historyTimes == [brkRecTime(1)])
        #expect(rig.sink.cursor?.lastCompleteSyncAt == nil)
    }

    /// "every record was of a kind the adapter decodes (`HistoryRecord.contentDecoded`)"; K21 and type 52 chunks are
    /// "never acknowledged (the band keeps it)".
    @Test(arguments: BrkUndecodedRecord.allCases)
    func chunkWithARecordFormaDoesNotStoreIsNeverAcknowledged(_ undecoded: BrkUndecodedRecord) async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.history = { n in
            n == 0 ? brkChunk([brkRec(1), undecoded.payload], token: brkToken(1)) + brkChunk([brkRec(2)], token: brkToken(2)) + [brkComplete()] : []
        }
        let rig = brkStart(band, brkOptions())
        await brkWait { await rig.counters.historyRecords == 3 }
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(counters.historyRecordsUndecoded == 1, "\(undecoded)")
        #expect(rig.acked().isEmpty, "\(undecoded): acknowledged \(rig.acked())")
        #expect(rig.sink.historyTimes == [brkRecTime(1), brkRecTime(2)], "\(undecoded): only decoded content is stored")
        #expect(rig.sink.cursor?.lastCompleteSyncAt == nil, "\(undecoded): a chunk was not saved intact")
    }

    /// ARCHITECTURE §3: "A band clock before 2020 or off by more than 24 h makes every record unmappable (left on the band)".
    @Test(arguments: BrkBadClock.allCases)
    func implausibleBandClockMakesEveryRecordUnmappableAndNothingIsAcknowledged(_ bad: BrkBadClock) async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        switch bad {
        case .behindByMoreThanADay: band.clockBehind = { _ in 86_401 }
        case .aheadByMoreThanADay: band.clockBehind = { _ in -86_401 }
        case .before2020: band.clockSeconds = 1_500_000_000
        }
        band.history = { n in n == 0 ? brkChunk([brkRec(1), brkRec(2)], token: brkToken(1)) + [brkComplete()] : [] }
        let rig = brkStart(band, brkOptions())
        await brkWait { await rig.counters.historyRecords == 2 }
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(rig.updates.all.contains { $0.brkIsClockImplausible }, "\(bad)")
        #expect(counters.historyRecordsUnmapped == 2, "\(bad)")
        #expect(rig.sink.historyHR.isEmpty, "\(bad): records are never stored with a guessed time")
        #expect(rig.acked().isEmpty, "\(bad): the band keeps them")
        #expect(rig.sink.cursor?.lastCompleteSyncAt == nil, "\(bad)")
    }

    /// "Offsets within 2 s are ignored; larger offsets up to 24 h are applied" (boundary: exactly 24 h).
    @Test func bandClockExactlyOneDayBehindIsCorrectedAndRecorded() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.clockBehind = { _ in 86_400 }
        band.history = { n in n == 0 ? brkChunk([brkRec(1)], token: brkToken(1)) + [brkComplete()] : [] }
        let rig = brkStart(band, brkOptions())
        await brkWait { rig.link.writes(cmd: 23).count == 1 }
        await rig.drain()
        _ = await rig.finish()
        let s = rig.sink.historyHR
        #expect(s.map(\.timestamp) == [brkRecTime(1) + EpochMillis.millisPerDay])
        #expect(s.allSatisfy { $0.quality.contains(.clockOffsetApplied) && $0.clockOffsetMillis == EpochMillis.millisPerDay })
        #expect(rig.acked() == [brkToken(1)])
    }

    /// ARCHITECTURE §3: "Offsets within 2 s are ignored; larger offsets … are applied" and recorded on each record.
    @Test func clockOffsetOfTwoSecondsIsIgnoredAndThreeSecondsIsAppliedAndRecorded() async {
        for behind: Int64 in [2, 3] {
            let time = ManualTimeSource(brkNow)
            var band = BrkBand(time: time)
            band.clockBehind = { _ in behind }
            band.history = { n in n == 0 ? brkChunk([brkRec(1)], token: brkToken(1)) + [brkComplete()] : [] }
            let rig = brkStart(band, brkOptions(ack: false))
            await brkWait { rig.sink.cursor?.lastCompleteSyncAt != nil }
            await rig.drain()
            _ = await rig.finish()
            let s = rig.sink.historyHR
            if behind == 2 {
                #expect(s.map(\.timestamp) == [brkRecTime(1)], "2 s: band clock trusted as-is")
                #expect(s.allSatisfy { !$0.quality.contains(.clockOffsetApplied) && $0.clockOffsetMillis == nil })
            } else {
                #expect(s.map(\.timestamp) == [brkRecTime(1) + 3_000], "3 s: offset applied")
                #expect(s.allSatisfy { $0.quality.contains(.clockOffsetApplied) && $0.clockOffsetMillis == 3_000 && $0.deviceTimeRaw == Int64(brkBase + 60) })
            }
        }
    }

    /// "If either throws, no acknowledgement is sent"; "The first failing chunk blocks acknowledgements for the rest".
    @Test(arguments: BrkChunkFailure.allCases)
    func saveOrFlushFailureOfTheSecondChunkLeavesOnlyTheFirstAcknowledged(_ failure: BrkChunkFailure) async {
        let time = ManualTimeSource(brkNow)
        let sink = BrkSink()
        switch failure {
        case .recordSave: sink.failIngest { b in b.heartRates.contains { $0.timestamp == brkRecTime(2) } }
        case .finalCommit: sink.failIngest { b in b.heartRates.isEmpty && b.cursor?.newestPersistedRecordTime == brkRecTime(2) && b.cursor?.opaque == Data(brkToken(1)) }
        case .durableFlush: sink.failDurable { $0 == 1 }
        }
        var band = BrkBand(time: time)
        band.history = { n in
            n == 0
                ? brkChunk([brkRec(1)], token: brkToken(1)) + brkChunk([brkRec(2)], token: brkToken(2)) + brkChunk([brkRec(3)], token: brkToken(3))
                    + [brkComplete()]
                : []
        }
        let rig = brkStart(band, brkOptions(subBatch: 1), sink: sink)
        await brkWait { await rig.counters.historyRecords == 3 }
        await rig.drain()
        _ = await rig.finish()
        #expect(sink.journal.entries.contains { $0.hasSuffix("failed") || $0.hasPrefix("ingest-failed") }, "\(failure): precondition")
        #expect(rig.acked() == [brkToken(1)], "\(failure): acknowledged \(rig.acked())")
        if failure != .durableFlush {
            #expect(sink.cursor?.lastCompleteSyncAt == nil, "\(failure): chunk 2 was not saved intact")
        }
    }

    /// "never fabricate measurements (nil, not 0)": a heart-rate byte of 0 means "no reading" for every decoded kind.
    @Test func heartRateCandidateZeroIsNeverStoredForAnyDecodedKind() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        let records = [
            BrkPayload.record(kind: 24, counter: 1, seconds: brkBase + 60, hr: 0), BrkPayload.record(kind: 18, counter: 2, seconds: brkBase + 120, hr: 0),
            BrkPayload.record(kind: 7, counter: 3, seconds: brkBase + 180, hr: 0), BrkPayload.record(kind: 24, counter: 4, seconds: brkBase + 240, hr: 61),
            BrkPayload.record(kind: 18, counter: 5, seconds: brkBase + 300, hr: 62), BrkPayload.record(kind: 7, counter: 6, seconds: brkBase + 360, hr: 63),
        ]
        band.history = { n in n == 0 ? brkChunk(records, token: brkToken(1)) + [brkComplete()] : [] }
        let rig = brkStart(band, brkOptions())
        await brkWait { await rig.counters.historyRecords == 6 }
        await rig.drain()
        _ = await rig.finish()
        let s = rig.sink.historyHR.sorted { $0.timestamp < $1.timestamp }
        #expect(s.map(\.bpm) == [61, 62, 63])
        #expect(s.allSatisfy { $0.quality.contains(.unvalidatedField) })
    }

    /// IMPLEMENTATION BUG: ARCHITECTURE §1: "Records and markers that arrive outside such a transfer … are saved if history
    /// is enabled, but never acknowledged and never move Forma's sync cursor" (COMPATIBILITY: "never moves Forma's sync
    /// position"). Records of another app's transfer that arrive while Forma's range request is still unanswered are
    /// unsolicited (counted as such) and stay in the history buffer. When Forma's own chunk then ends, the cursor's
    /// newestPersistedRecordTime is computed over the whole buffer (`bufferedNewest()`), so the unsolicited record's time
    /// moves Forma's sync cursor (the coverage timeline then shows the uncovered gap as "not recorded" instead of
    /// "pending sync"), and `historyChunkSaved` counts it as part of Forma's chunk ("counts are for that chunk only").
    @Test func unsolicitedRecordsBufferedBeforeTheRequestNeverMoveTheSyncCursor() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.range = [.silent]
        band.history = { n in n == 0 ? brkChunk([brkRec(1)], token: brkToken(1)) + [brkComplete()] : [] }
        let rig = brkStart(band, brkOptions(history: .manual, identify: false, readClock: false))
        await rig.drain()
        await rig.engine.requestHistorySync()
        #expect(rig.link.attempts(cmd: 34) == 1)
        // Another app's transfer is streaming meanwhile; its chunk is still open (no end marker yet).
        let foreignTime = brkBase + 7_200
        rig.link.emit([brkNote(BrkPayload.start()), brkNote(BrkPayload.record(kind: 24, counter: 900, seconds: foreignTime, hr: 70))])
        await rig.drain()
        #expect(await rig.counters.historyRecordsUnsolicited == 1, "precondition: the foreign record is unsolicited")
        // The band answers Forma's range request: Forma requests history and receives its own chunk.
        let seq = rig.link.writes(cmd: 34)[0].seq
        rig.link.emit(brkNote(BrkPayload.response(cmd: 34, echo: seq, result: 1, data: brkRangeBody), brkResp))
        await brkWait { rig.sink.cursor?.lastCompleteSyncAt != nil }
        await rig.drain()
        _ = await rig.finish()
        #expect(rig.acked() == [brkToken(1)], "precondition: Forma's own chunk was intact")
        #expect(rig.sink.historyTimes == [brkRecTime(1), Int64(foreignTime) * 1_000], "both records are saved (history is on)")
        #expect(rig.sink.cursor?.newestPersistedRecordTime == brkRecTime(1),
                "the unsolicited record (band time +2 h) moved Forma's sync cursor to \(String(describing: rig.sink.cursor?.newestPersistedRecordTime))")
        let saved = rig.updates.all.compactMap(\.brkChunkSaved)
        #expect(saved.map { $0.inserted } == [1], "Forma's chunk inserted 1 record, reported \(saved.map { $0.inserted })")
    }
}

// MARK: - Re-entrancy: settings, Sync now and timers while the engine is suspended in a write

@Suite struct BrkReentrancyTests {
    /// IMPLEMENTATION BUG: HistoryPolicy.off: "Never request history. History another app triggers is counted, not
    /// stored"; ARCHITECTURE §1: records outside a Forma transfer "are saved if history is enabled, but … never move Forma's
    /// sync cursor". The user turns history off while the engine is suspended writing a chunk's acknowledgement:
    /// `setOptions` ends the transfer (phase idle), but when the write returns `onHistoryMarker` unconditionally sets
    /// `phase = .receiving`. The engine is back in an owned state with no transfer: everything the band sends afterwards
    /// is treated as Forma's own — stored although history is off, not counted as unsolicited, and its chunk writes the
    /// sync cursor.
    @Test func historyTurnedOffWhileAnAcknowledgementIsBeingWrittenStaysOff() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.history = { n in n == 0 ? brkChunk([brkRec(1)], token: brkToken(1)) : [] }
        let rig = brkStart(band, brkOptions(), gates: [(23, 0)])
        #expect(await brkWait { rig.gates[0].waiting > 0 }, "precondition: suspended in the acknowledgement write")
        await rig.engine.setOptions(brkOptions(history: .off))
        rig.gates[0].open()
        await rig.drain()
        // The band keeps streaming (the rest of the abandoned transfer, or another app's): history is off now.
        rig.link.emit(brkChunk([brkRec(5)], token: brkToken(2)) + [brkComplete()])
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(rig.sink.historyTimes == [brkRecTime(1)], "history is off: later records are counted, not stored")
        #expect(counters.historyRecordsUnsolicited == 1, "records after the transfer ended are not Forma's")
        #expect(rig.sink.cursor?.newestPersistedRecordTime == brkRecTime(1), "data outside a Forma transfer never moves the cursor")
        #expect(rig.acked() == [brkToken(1)])
    }

    /// IMPLEMENTATION BUG: ARCHITECTURE §1: "The engine acts only on a transfer it requested, in this order: read the band
    /// clock …, read the history range (cmd 34 …), then request history (cmd 22)"; COMPATIBILITY: a chunk is acknowledged
    /// only if "Forma requested the transfer". While the engine is suspended writing chunk 1's acknowledgement, the user
    /// turns history off and on and taps Sync now: transfer 2 starts and its range request is answered SUCCESS. When the
    /// acknowledgement write returns, `onHistoryMarker` overwrites transfer 2's `.awaitingRange` with `.receiving`, so the
    /// range answer is ignored and cmd 22 is never written — and the next chunk the band streams (which Forma never
    /// requested) is treated as transfer 2's and acknowledged.
    @Test func transferStartedDuringAnAcknowledgementWriteRequestsHistoryAndNeverAcksUnrequestedData() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.history = { n in n == 0 ? brkChunk([brkRec(1)], token: brkToken(1)) : [] }
        let rig = brkStart(band, brkOptions(history: .manual), gates: [(23, 0)])
        await rig.drain()
        await rig.engine.requestHistorySync()
        #expect(await brkWait { rig.gates[0].waiting > 0 }, "precondition: suspended in chunk 1's acknowledgement write")
        await rig.engine.setOptions(brkOptions(history: .off))
        await rig.engine.setOptions(brkOptions(history: .manual))
        await rig.engine.requestHistorySync()
        #expect(rig.link.attempts(cmd: 34) == 2, "precondition: transfer 2 read the range (answered SUCCESS)")
        rig.gates[0].open()
        await rig.drain()
        // Data the band streams now was not requested by transfer 2 unless Forma wrote cmd 22 again.
        rig.link.emit(brkChunk([brkRec(7)], token: brkToken(2)))
        await rig.drain()
        let requests = rig.link.attempts(cmd: 22)
        let acked = rig.acked()
        _ = await rig.finish()
        #expect(requests == 2, "transfer 2's range succeeded, so history must be requested next (cmd 22 written \(requests)×)")
        #expect(!(acked.contains(brkToken(2)) && requests < 2), "acknowledged a chunk of a transfer Forma never requested: \(acked)")
    }

    /// IMPLEMENTATION BUG (same root cause, reached without touching settings): ARCHITECTURE §1 order "read the history
    /// range …, then request history (cmd 22)". A write with response can take up to the 30 s ATT timeout on a degraded
    /// link. While chunk 1's acknowledgement write hangs, the idle deadline passes and the deadline check fails the
    /// transfer; the user taps Sync now and transfer 2's range request is answered SUCCESS. When the hung write returns,
    /// the end-marker handler resets the phase to `.receiving` with the old (already expired) deadline, so transfer 2 is
    /// ended as "interrupted" by the next deadline check and its range answer is ignored: history is never requested.
    @Test func syncNowAfterATimeoutDuringASlowAcknowledgementWriteStillRequestsHistory() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.history = { n in n == 0 ? brkChunk([brkRec(1)], token: brkToken(1)) : [] }
        let rig = brkStart(band, brkOptions(history: .manual), gates: [(23, 0)])
        await rig.drain()
        await rig.engine.requestHistorySync()
        #expect(await brkWait { rig.gates[0].waiting > 0 }, "precondition: suspended in chunk 1's acknowledgement write")
        time.advance(byMillis: 30_000)
        await rig.engine.checkDeadlines()          // what the app's 1 s timer does meanwhile
        #expect(await brkWait { rig.updates.all.contains { $0.brkIsStopped } }, "precondition: transfer 1 was given up")
        await rig.engine.requestHistorySync()
        #expect(rig.link.attempts(cmd: 34) == 2, "precondition: transfer 2 read the range (answered SUCCESS)")
        rig.gates[0].open()
        await rig.drain()
        let requests = rig.link.attempts(cmd: 22)
        _ = await rig.finish()
        #expect(requests == 2, "transfer 2's range succeeded, so history must be requested next (cmd 22 written \(requests)×)")
    }

    /// IMPLEMENTATION BUG: COMPATIBILITY §1: "Read clock | 11 GET_CLOCK | Once per connection, and after clock events".
    /// `onReady` records that the clock read was sent only after its write returns, so a Sync now that arrives while that
    /// write is in flight sees `clockReadSent == false` and reads the clock a second time (no clock event happened).
    @Test func syncNowDuringTheConnectClockReadDoesNotReadTheClockTwice() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.history = { _ in [brkComplete()] }
        let rig = brkStart(band, brkOptions(history: .manual, ack: false), gates: [(11, 0)])
        #expect(await brkWait { rig.gates[0].waiting > 0 }, "precondition: suspended in the connect clock read")
        await rig.engine.requestHistorySync()
        rig.gates[0].open()
        #expect(await brkWait { rig.link.attempts(cmd: 22) == 1 }, "the transfer still proceeds")
        await rig.drain()
        _ = await rig.finish()
        #expect(rig.link.attempts(cmd: 11) == 1, "GET_CLOCK written \(rig.link.attempts(cmd: 11))× without any clock event")
    }

    /// IMPLEMENTATION BUG: COMPATIBILITY §1 (TOGGLE_REALTIME_HR): "Sent only while Live heart rate while open is on …;
    /// switched off otherwise." The user switches live heart rate off while the engine is still writing the "on" toggle:
    /// `setOptions` compares against `realtimeStreamOn`, which is set only after that write returns, sees nothing to do,
    /// and the write then marks the stream on. No "off" toggle is ever sent; the band keeps streaming.
    @Test func liveHeartRateSwitchedOffWhileTheOnToggleIsInFlightIsSwitchedOff() async {
        let time = ManualTimeSource(brkNow)
        let rig = brkStart(BrkBand(time: time), brkOptions(history: .off, liveHR: true, identify: false, readClock: false), gates: [(3, 0)])
        #expect(await brkWait { rig.gates[0].waiting > 0 }, "precondition: suspended in the 'on' toggle")
        await rig.engine.setOptions(brkOptions(history: .off, liveHR: false, identify: false, readClock: false))
        rig.gates[0].open()
        await rig.drain()
        let toggles = rig.link.writes(cmd: 3).map(\.arg)
        _ = await rig.finish()
        #expect(toggles.last == 0x00, "live heart rate is off: the stream must end switched off, toggles written \(toggles)")
    }

    @Test func historyTurnedOffWhileTheRangeRequestIsInFlightNeverRequestsHistory() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.history = { _ in brkChunk([brkRec(1)], token: brkToken(1)) + [brkComplete()] }
        let rig = brkStart(band, brkOptions(identify: false, readClock: false), gates: [(34, 0)])
        #expect(await brkWait { rig.gates[0].waiting > 0 })
        await rig.engine.setOptions(brkOptions(history: .off, identify: false, readClock: false))
        rig.gates[0].open()          // the band then answers SUCCESS
        await rig.drain()
        _ = await rig.finish()
        #expect(rig.link.attempts(cmd: 22) == 0)
        #expect(rig.sink.historyHR.isEmpty)
    }

    @Test func syncNowRepeatedDuringEveryAwaitStartsOnlyOneTransfer() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.history = { _ in brkChunk([brkRec(1)], token: brkToken(1)) + [brkComplete()] }
        let rig = brkStart(band, brkOptions(history: .manual), gates: [(34, 0), (22, 0), (23, 0)])
        await rig.drain()
        let first = Task { await rig.engine.requestHistorySync() }
        for (index, gate) in rig.gates.enumerated() {
            #expect(await brkWait { gate.waiting > 0 }, "gate \(index)")
            await rig.engine.requestHistorySync()
            await rig.engine.requestHistorySync()
            gate.open()
        }
        await first.value
        await brkWait { rig.sink.cursor?.lastCompleteSyncAt != nil }
        await rig.drain()
        let record = await rig.finish()
        #expect(rig.link.order([34, 22, 23]) == [34, 22, 23])
        #expect(record.status == .completed)
    }
}

// MARK: - Timeouts against the engine clock; completion vs interruption; run record

@Suite struct BrkTimeoutAndStatusTests {
    /// "A timer task enforces command, pending and idle deadlines against the engine's clock": with the internal timer on,
    /// nobody calls `checkDeadlines()` — the clock wait still ends after 7 s of engine time, and not before.
    @Test func internalTimerEnforcesTheClockWaitWithoutExternalDeadlineChecks() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.clockBehind = { _ in nil }
        var options = brkOptions(ack: false)
        options.timerIntervalMillis = 2
        let rig = brkStart(band, options)
        await brkWait { rig.link.attempts(cmd: 11) == 1 }
        await rig.drain()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.link.attempts(cmd: 34) == 0, "no engine time has passed")
        time.advance(byMillis: 7_000)
        #expect(await brkWait { rig.link.attempts(cmd: 34) == 1 }, "the timer must notice the expired clock wait")
        _ = await rig.finish()
    }

    /// "A transfer that goes quiet after some chunks ends as interrupted, never as complete."
    @Test func transferThatGoesQuietAfterAChunkIsInterruptedNotComplete() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.history = { n in n == 0 ? brkChunk([brkRec(1), brkRec(2)], token: brkToken(1)) : [] }   // then the band waits
        let rig = brkStart(band, brkOptions(ack: false))
        await brkWait { await rig.counters.historyRecords == 2 }
        await rig.drain()
        time.advance(byMillis: 29_999)
        await rig.engine.checkDeadlines()
        await rig.drain()
        #expect(!rig.updates.all.contains { $0.brkIsStopped }, "not idle yet")
        time.advance(byMillis: 1)
        await rig.engine.checkDeadlines()
        #expect(await brkWait { rig.updates.all.contains { $0.brkIsStopped } })
        let record = await rig.finish()
        #expect(record.status == .interrupted)
        #expect(rig.sink.cursor?.lastCompleteSyncAt == nil)
        #expect(!rig.updates.all.contains { $0.brkIsComplete })
        #expect(rig.sink.historyTimes == [brkRecTime(1), brkRecTime(2)])
    }

    @Test func linkLostWhileWaitingForTheRangeAnswerIsInterrupted() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.range = [.silent]
        let rig = brkStart(band, brkOptions(identify: false, readClock: false))
        await brkWait { rig.link.attempts(cmd: 34) == 1 }
        await rig.drain()
        let record = await rig.finish()
        #expect(record.status == .interrupted)
        #expect(rig.link.attempts(cmd: 22) == 0)
    }

    @Test func bandSilentAfterTheRequestGivesUpAndLateDataIsSavedButNeverAcknowledged() async {
        let time = ManualTimeSource(brkNow)
        let rig = brkStart(BrkBand(time: time), brkOptions())
        await brkWait { rig.link.attempts(cmd: 22) == 1 }
        await rig.drain()
        time.advance(byMillis: 30_000)
        await rig.engine.checkDeadlines()
        #expect(await brkWait { rig.updates.all.contains { $0.brkIsStopped } })
        rig.link.emit(brkChunk([brkRec(3)], token: brkToken(3), at: time.now()) + [brkComplete(at: time.now())])
        await rig.drain()
        _ = await rig.finish()
        #expect(rig.acked().isEmpty)
        #expect(rig.sink.historyTimes == [brkRecTime(3)], "late data is saved (history is on)")
        #expect(rig.sink.cursor == nil, "and never moves the cursor")
    }

    /// IMPLEMENTATION BUG: ARCHITECTURE §1: "A timer task enforces command, pending and idle deadlines against the engine's
    /// clock: the later of the time source and the newest receive time, so a replayed capture reproduces a silent band. A
    /// transfer that goes quiet after some chunks ends as interrupted, never as complete." Here the band goes quiet for
    /// 40 s (idle timeout 30 s) after chunk 1 and then streams chunk 2 and the completion marker; the receive times carry
    /// the silence. Live, the 1 s timer ends the transfer at 30 s (interrupted) and chunk 2 is not Forma's. The engine
    /// handles a notification's events BEFORE checking deadlines against that notification's receive time, so replaying
    /// the same capture continues the timed-out transfer: chunk 2 is acknowledged and the sync is recorded as complete.
    @Test func notificationArrivingAfterTheIdleDeadlineDoesNotContinueTheTimedOutTransfer() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.history = { n in n == 0 ? brkChunk([brkRec(1)], token: brkToken(1)) : [] }
        let rig = brkStart(band, brkOptions())
        await brkWait { rig.link.writes(cmd: 23).count == 1 }
        await rig.drain()
        let late = brkNow + 40_000
        rig.link.emit(brkChunk([brkRec(2)], token: brkToken(2), at: late) + [brkComplete(at: late + 1)])
        await rig.drain(at: late + 2)
        let record = await rig.finish(at: late + 3)
        #expect(rig.acked() == [brkToken(1)], "chunk 2 arrived after the transfer timed out; acknowledged \(rig.acked())")
        #expect(rig.sink.cursor?.lastCompleteSyncAt == nil, "a transfer that went quiet is never recorded as complete")
        #expect(record.status == .interrupted)
    }

    /// IMPLEMENTATION BUG (same root cause as above): WHOOP5_PROTOCOL §5 / COMPATIBILITY: "On a refusal, a short answer or
    /// no answer within 7 s, retry". The range answer arrives 8 s after the request (its receive time says so); live,
    /// the timer has already failed that attempt and the answer is stale, so the range is read again before history is
    /// requested. The engine accepts the late answer because it handles the notification before checking the deadline.
    @Test func rangeAnswerArrivingAfterSevenSecondsIsNotAcceptedForTheExpiredAttempt() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.range = [.silent, .success]
        band.history = { _ in [brkComplete(at: time.now())] }
        let rig = brkStart(band, brkOptions(ack: false, identify: false, readClock: false))
        await brkWait { rig.link.attempts(cmd: 34) == 1 }
        await rig.drain()
        let seq = rig.link.writes(cmd: 34)[0].seq
        rig.link.emit(brkNote(BrkPayload.response(cmd: 34, echo: seq, result: 1, data: brkRangeBody), brkResp, at: brkNow + 8_000))
        await rig.drain(at: brkNow + 8_000)
        time.set(brkNow + 9_000)
        await rig.engine.checkDeadlines()
        await brkWait { rig.link.attempts(cmd: 22) == 1 }
        await rig.drain()
        _ = await rig.finish()
        #expect(rig.link.order([34, 22]) == [34, 34, 22], "no answer within 7 s means retry before requesting history")
    }

    /// Run-record truthfulness: the counts written to the run record are what was actually saved.
    @Test func runRecordCountsMatchWhatTheSinkActuallyStored() async {
        let time = ManualTimeSource(brkNow)
        var band = BrkBand(time: time)
        band.history = { _ in brkChunk([brkRec(1), brkRec(2)], token: brkToken(1)) + [brkComplete()] }
        let sink = BrkSink()
        let rig = brkStart(band, brkOptions(history: .manual, ack: false, identify: false, readClock: false), sink: sink)
        rig.link.emit([brkRaw([0x00, 70], UUIDs.heartRateMeasurement, at: brkNow), brkRaw([0x00, 72], UUIDs.heartRateMeasurement, at: brkNow + 1_000)])
        await rig.drain()
        for transfer in 1...2 {
            await rig.engine.requestHistorySync()
            await brkWait { rig.updates.all.filter { $0.brkIsComplete }.count == transfer }
            await rig.drain()
        }
        var damaged = BrkWire.frame(brkRec(9))
        damaged[8 + 20] ^= 0xFF
        rig.link.emit(brkRaw(damaged))
        await rig.drain()
        let record = await rig.finish(at: brkNow + 5_000)
        #expect(sink.historyTimes == [brkRecTime(1), brkRecTime(2)])
        #expect(record.recordsInserted == sink.insertedTotal, "run says \(record.recordsInserted), sink stored \(sink.insertedTotal)")
        #expect(record.duplicates == sink.duplicatesTotal, "run says \(record.duplicates), sink skipped \(sink.duplicatesTotal)")
        #expect(record.duplicates == 2)
        #expect(record.malformedFrames == 1)
        #expect(record.status == .completed)
        #expect(record.endedAt == brkNow + 5_000)
        #expect(sink.finishedRuns.count == 1)
    }
}
