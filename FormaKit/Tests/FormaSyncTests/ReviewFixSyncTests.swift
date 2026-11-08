// Regression tests for the second review of the rewritten SyncEngine, for the findings that had no breaker
// test: acknowledgement eligibility that failed open (frames Forma does not decode, records missing their
// fields, distinct records collapsing onto one stored time), damage between chunks, echoed sequences,
// result 0 on the history request, clock changes during a transfer, correction jitter between connections,
// lost notifications, buffered history when history is switched off, failed unsolicited saves, late
// acknowledgement answers, option overflow, telemetry, engine reuse, backward phone-clock steps, replay
// plausibility and the forma-replay summary.
//
// Everything runs through the real `Whoop5Adapter`; band frames use the adapter's own frame builder (its
// output is checked against the documented vectors in BreakerRewriteTests).

import Foundation
import Testing
import FormaCore
@testable import FormaProtocol
import FormaStore
@testable import FormaSync

// MARK: - Payloads and frames

fileprivate let fxData = Whoop5Adapter.dataFromStrap
fileprivate let fxResp = Whoop5Adapter.commandFromStrap
fileprivate let fxEvents = Whoop5Adapter.eventsFromStrap
/// SIG characteristic the WHOOP decoder does not parse: one `unknownPacket` per notification, never history.
fileprivate let fxSentinel = UUIDs.normalize("2A00")
fileprivate let fxBase: UInt32 = 1_790_000_000
fileprivate let fxNow: EpochMillis = Int64(fxBase) * 1_000 + 6 * 3_600_000

fileprivate func fxLE32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }

fileprivate func fxRecord(kind: UInt8 = 24, counter: UInt32, seconds: UInt32, hr: UInt8? = 60, length: Int = 40, type: UInt8 = 47) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: max(13, length))
    p[0] = type
    p[1] = kind
    p.replaceSubrange(3..<7, with: fxLE32(counter))
    p.replaceSubrange(7..<11, with: fxLE32(seconds))
    if let hr {
        let offset = kind == 18 ? 14 : (kind == 7 ? 27 : 17)
        if offset < p.count { p[offset] = hr }
    }
    return p
}

/// K24 record `i`: counter 100 + i, band time base + i minutes.
fileprivate func fxRec(_ i: UInt32, hr: UInt8 = 60) -> [UInt8] { fxRecord(counter: 100 + i, seconds: fxBase + i * 60, hr: hr) }
fileprivate func fxRecTime(_ i: UInt32) -> EpochMillis { Int64(fxBase + i * 60) * 1_000 }
fileprivate func fxToken(_ n: UInt8) -> [UInt8] { (0..<8).map { n &* 16 &+ UInt8($0) } }

fileprivate enum FxPay {
    static let start: [UInt8] = [49, 0, 1]
    static let complete: [UInt8] = [49, 0, 3]
    static func end(_ token: [UInt8]?) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: token == nil ? 16 : 24)
        p[0] = 49
        p[2] = 2
        if let token { p.replaceSubrange(13..<21, with: token) }
        return p
    }
    static func response(cmd: UInt8, echo: UInt8, result: UInt8, data: [UInt8] = []) -> [UInt8] { [36, 0x40, cmd, echo, result] + data }
    static func event(_ id: UInt16) -> [UInt8] { [48, 0, UInt8(id & 0xFF), UInt8(id >> 8), 0, 0, 0, 0] }
}

fileprivate func fxFrame(_ payload: [UInt8]) -> [UInt8] { (try? Whoop5Adapter.frame(payload: payload)) ?? [] }

fileprivate func fxNote(_ payload: [UInt8], _ c: String = fxData, at t: EpochMillis = fxNow) -> LinkEvent {
    .notification(characteristic: c, bytes: fxFrame(payload), receivedAt: t)
}

fileprivate func fxChunk(_ records: [[UInt8]], token: [UInt8]?, at t: EpochMillis = fxNow) -> [LinkEvent] {
    [fxNote(FxPay.start, at: t)] + records.map { fxNote($0, at: t) } + [fxNote(FxPay.end(token), at: t)]
}

// MARK: - Test doubles

fileprivate final class FxSink: IngestSink, @unchecked Sendable {
    private let lock = NSLock()
    private var keys = Set<String>()
    private var _hr: [HeartRateSample] = []
    private var _motion: [MotionEpoch] = []
    private var _cursor: SyncCursor?
    private var _finished: [SyncRunRecord] = []
    private var failNext: (@Sendable (IngestBatch) -> Bool)?
    private var _failures = 0

    /// Batches for which `rule` returns true fail (nothing of them is stored).
    func fail(when rule: @escaping @Sendable (IngestBatch) -> Bool) { lock.withLock { failNext = rule } }

    func ingest(_ batch: IngestBatch) throws -> IngestResult {
        try lock.withLock {
            if let rule = failNext, rule(batch) {
                _failures += 1
                throw CocoaError(.fileWriteUnknown)
            }
            var inserted = 0, duplicates = 0
            for s in batch.heartRates {
                if keys.insert("hr|\(s.deviceID)|\(s.source.rawValue)|\(s.timestamp)").inserted { _hr.append(s); inserted += 1 } else { duplicates += 1 }
            }
            for m in batch.motion {
                if keys.insert("m|\(m.deviceID)|\(m.source.rawValue)|\(m.timestamp)|\(m.epochMillis)").inserted { _motion.append(m); inserted += 1 } else { duplicates += 1 }
            }
            inserted += batch.beatIntervals.count + batch.aux.count
            if let c = batch.cursor { _cursor = c }
            return IngestResult(batchID: 1, inserted: inserted, duplicates: duplicates)
        }
    }

    func syncCursor(deviceID: String) throws -> SyncCursor? { lock.withLock { _cursor } }
    func upsertDevice(_ device: DeviceRecord) throws {}
    func recordConnectionEvent(_ event: ConnectionEvent) throws {}
    func recordRawFrame(_ frame: RawFrameRecord) throws {}
    func beginSyncRun(_ run: SyncRunRecord) throws -> Int64 { 1 }
    func finishSyncRun(_ run: SyncRunRecord) throws { lock.withLock { _finished.append(run) } }

    var historyHR: [HeartRateSample] { lock.withLock { _hr.filter { $0.source == .deviceHistory }.sorted { $0.timestamp < $1.timestamp } } }
    var motion: [MotionEpoch] { lock.withLock { _motion } }
    var cursor: SyncCursor? { lock.withLock { _cursor } }
    var finishedRuns: [SyncRunRecord] { lock.withLock { _finished } }
    var failures: Int { lock.withLock { _failures } }
}

fileprivate struct FxWrite: Sendable {
    let bytes: [UInt8]
    var cmd: UInt8 { bytes.count > 10 ? bytes[10] : 0 }
    var seq: UInt8 { bytes.count > 9 ? bytes[9] : 0 }
    var ackToken: [UInt8]? { cmd == 23 && bytes.count >= 24 ? Array(bytes[12..<20]) : nil }
}

/// Scripted WHOOP link: `react(write, nthOfThatCommand)` returns the band's reaction (nil = default answer).
fileprivate final class FxLink: PeripheralLink, @unchecked Sendable {
    typealias React = @Sendable (_ write: FxWrite, _ nth: Int) -> [LinkEvent]?

    let peripheralID = "fx-link"
    let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let lock = NSLock()
    private let time: ManualTimeSource
    private let react: React
    private var log: [FxWrite] = []
    private var closed = false

    init(time: ManualTimeSource, react: @escaping React = { _, _ in nil }) {
        self.time = time
        self.react = react
        var cont: AsyncStream<LinkEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        continuation.yield(.ready(services: [Whoop5Adapter.service: [Whoop5Adapter.commandToStrap, fxResp, fxEvents, fxData]]))
    }

    func emit(_ es: [LinkEvent]) {
        lock.withLock {
            for e in es where !closed {
                continuation.yield(e)
                if case .disconnected = e { closed = true; continuation.finish() }
            }
        }
    }

    func write(_ command: EncodedCommand, characteristic: String, withResponse: Bool) async throws {
        let w = FxWrite(bytes: command.bytes)
        try lock.withLock {
            if closed { throw LinkError.notConnected }
            let nth = log.filter { $0.cmd == w.cmd }.count
            log.append(w)
            let now = time.now()
            let reaction = react(w, nth) ?? Self.defaultAnswer(w, now: now)
            for e in reaction where !closed { continuation.yield(e) }
        }
    }

    static func answer(_ w: FxWrite, result: UInt8 = 1, data: [UInt8] = [], echo: UInt8? = nil, at t: EpochMillis) -> LinkEvent {
        fxNote(FxPay.response(cmd: w.cmd, echo: echo ?? w.seq, result: result, data: data), fxResp, at: t)
    }

    /// Band clock equal to the phone clock; range success with a 25-byte body; everything else success.
    static func defaultAnswer(_ w: FxWrite, now: EpochMillis) -> [LinkEvent] {
        switch w.cmd {
        case 11: return [answer(w, data: fxLE32(UInt32(now / 1_000)) + fxLE32(0), at: now)]
        case 34: return [answer(w, data: [UInt8](repeating: 0x5A, count: 25), at: now)]
        default: return [answer(w, at: now)]
        }
    }

    var writes: [FxWrite] { lock.withLock { log } }
    func writes(cmd: UInt8) -> [FxWrite] { writes.filter { $0.cmd == cmd } }
    var acked: [[UInt8]] { writes(cmd: 23).compactMap(\.ackToken) }
}

fileprivate final class FxUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SyncUpdate] = []
    func append(_ u: SyncUpdate) { lock.withLock { items.append(u) } }
    var all: [SyncUpdate] { lock.withLock { items } }
    var completed: Bool { all.contains { if case .historyComplete = $0 { return true } else { return false } } }
    var stopped: [String] { all.compactMap { if case .historyStopped(let r, _) = $0 { return r } else { return nil } } }
    var lastCounters: SyncCounters? { all.compactMap { if case .counters(let c) = $0 { return c } else { return nil } }.last }
}

@discardableResult
fileprivate func fxWait(_ timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

fileprivate func fxOptions(history: HistoryPolicy = .automatic, ack: Bool = true, readClock: Bool = true, subBatch: Int = 500) -> SyncOptions {
    SyncOptions(history: history, acknowledgeHistory: ack, liveHeartRate: false, rawCapture: false, liveFlushIntervalMillis: 0,
                historySubBatchSize: subBatch, identifyOnConnect: false, readClockOnConnect: readClock, timerIntervalMillis: 0)
}

fileprivate struct FxRig: Sendable {
    let time: ManualTimeSource
    let sink: FxSink
    let link: FxLink
    let engine: SyncEngine
    let updates: FxUpdates
    let consumer: Task<Void, Never>
    let run: Task<SyncRunRecord, Never>

    var counters: SyncCounters { get async { await engine.currentCounters } }

    /// Waits until everything queued on the link before this call has been handled.
    func drain(at t: EpochMillis? = nil) async {
        let before = await engine.currentCounters.unknownPackets
        link.emit([.notification(characteristic: fxSentinel, bytes: [0], receivedAt: t ?? time.now())])
        await fxWait { await engine.currentCounters.unknownPackets > before }
    }

    func finish(at t: EpochMillis? = nil) async -> SyncRunRecord {
        link.emit([.disconnected(reason: "test end", at: t ?? time.now())])
        let record = await run.value
        await fxWait { updates.all.contains { if case .disconnected = $0 { return true } else { return false } } }
        consumer.cancel()
        return record
    }
}

fileprivate func fxStart(_ options: SyncOptions, time: ManualTimeSource = ManualTimeSource(fxNow), sink: FxSink = FxSink(),
                         react: @escaping FxLink.React = { _, _ in nil }) -> FxRig {
    let link = FxLink(time: time, react: react)
    let engine = SyncEngine(adapter: Whoop5Adapter(), sink: sink, device: DeviceRecord(id: "fx-band", family: .whoop5, name: "WHOOP", firstSeen: 0),
                            timeSource: time, options: options)
    let updates = FxUpdates()
    let stream = engine.updates
    let consumer = Task { for await u in stream { updates.append(u) } }
    let run = Task { await engine.run(link: link) }
    return FxRig(time: time, sink: sink, link: link, engine: engine, updates: updates, consumer: consumer, run: run)
}

/// A band that answers the history request with `history` (once).
fileprivate func fxHistory(_ history: [LinkEvent], afterAck: @escaping @Sendable (Int) -> [LinkEvent] = { _ in [] }) -> FxLink.React {
    { w, nth in
        switch w.cmd {
        case 22 where nth == 0: return [FxLink.answer(w, at: fxNow)] + history
        case 23: return [FxLink.answer(w, at: fxNow)] + afterAck(nth)
        default: return nil
        }
    }
}

// MARK: - Acknowledgement eligibility fails closed

@Suite struct ReviewFixEligibilityTests {
    /// Frames of types Forma does not decode (type 56 PUFFIN_METADATA, 53, an unknown metadata kind) or events
    /// inside a chunk may be stored band data: the chunk is saved but never acknowledged, and the transfer is
    /// not recorded as complete.
    @Test(arguments: ["type56", "type53", "metadataKind9", "eventOnData", "eventOnEvents"])
    func framesFormaDoesNotDecodeInsideAChunkBlockItsAcknowledgement(_ variant: String) async {
        let foreign: LinkEvent
        switch variant {
        case "type56": foreign = fxNote([56, 0, 2, 0] + [UInt8](repeating: 0, count: 20))
        case "type53": foreign = fxNote([53, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
        case "metadataKind9": foreign = fxNote([49, 0, 9])
        case "eventOnData": foreign = fxNote(FxPay.event(17))
        default: foreign = fxNote(FxPay.event(17), fxEvents)
        }
        let history = [fxNote(FxPay.start), fxNote(fxRec(1)), foreign, fxNote(fxRec(2)), fxNote(FxPay.end(fxToken(1)))]
            + fxChunk([fxRec(3)], token: fxToken(2)) + [fxNote(FxPay.complete)]
        let rig = fxStart(fxOptions(), react: fxHistory(history))
        await fxWait { await rig.counters.historyRecords == 3 }
        await rig.drain()
        _ = await rig.finish()
        #expect(rig.link.acked.isEmpty, "\(variant): acknowledged \(rig.link.acked)")
        #expect(rig.sink.historyHR.map(\.timestamp) == [fxRecTime(1), fxRecTime(2), fxRecTime(3)], "\(variant): what arrived is saved")
        #expect(rig.sink.cursor?.lastCompleteSyncAt == nil, "\(variant)")
    }

    /// A record of a decoded kind whose fields are missing stores nothing, so its chunk is not acknowledged;
    /// a K10 whose motion block is not understood keeps its heart rate but is not acknowledged either.
    @Test func recordsMissingTheirFieldsAreNeverAcknowledged() async {
        let shortK24 = fxRecord(counter: 300, seconds: fxBase + 600, hr: 70, length: 14)
        var k10 = fxRecord(kind: 10, counter: 301, seconds: fxBase + 660, hr: 71, length: 1_920)
        k10[18] = 50
        let history = fxChunk([fxRec(1), shortK24, k10], token: fxToken(1)) + [fxNote(FxPay.complete)]
        let rig = fxStart(fxOptions(), react: fxHistory(history))
        await fxWait { await rig.counters.historyRecords == 3 }
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(rig.link.acked.isEmpty)
        #expect(counters.historyRecordsUndecoded == 2)
        #expect(rig.sink.historyHR.map(\.bpm) == [60, 71], "the K10 heart rate is kept; the short K24 had none")
        #expect(rig.sink.motion.isEmpty)
    }

    /// Distinct band records that map to the same millisecond collapse onto one stored row: the chunk is not
    /// acknowledged (the band keeps the record Forma could not store) and the transfer is not complete.
    @Test func distinctRecordsOnOneStoredTimeAreNeverAcknowledged() async {
        let records = [fxRecord(counter: 200, seconds: fxBase + 100, hr: 60), fxRecord(counter: 201, seconds: fxBase + 101, hr: 61),
                       fxRecord(counter: 202, seconds: fxBase + 101, hr: 95)]
        let history = fxChunk(records, token: fxToken(1)) + [fxNote(FxPay.complete)]
        let rig = fxStart(fxOptions(), react: fxHistory(history))
        await fxWait { await rig.counters.historyRecords == 3 }
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(rig.link.acked.isEmpty, "acknowledged \(rig.link.acked)")
        #expect(counters.historyTimeCollisions == 1)
        #expect(rig.sink.historyHR.map(\.bpm) == [60, 61])
        #expect(rig.sink.cursor?.lastCompleteSyncAt == nil)
    }

    /// The same record re-sent within one transfer is not a collision.
    @Test func theSameRecordSentTwiceInOneTransferIsNotACollision() async {
        let history = fxChunk([fxRec(1)], token: fxToken(1)) + fxChunk([fxRec(1), fxRec(2)], token: fxToken(2)) + [fxNote(FxPay.complete)]
        let rig = fxStart(fxOptions(), react: fxHistory(history))
        await fxWait { rig.link.writes(cmd: 23).count == 2 }
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(counters.historyTimeCollisions == 0)
        #expect(rig.link.acked == [fxToken(1), fxToken(2)])
    }

    /// Damage that is not inside an open chunk (here: three damaged frames after chunk 1) may have hit a
    /// marker or a record: the transfer is never recorded as complete.
    @Test func damageBetweenChunksMeansTheTransferIsNotComplete() async {
        var damaged = fxFrame(fxRec(9))
        damaged[8 + 20] ^= 0xFF
        let bad = LinkEvent.notification(characteristic: fxData, bytes: damaged, receivedAt: fxNow)
        let history = fxChunk([fxRec(1)], token: fxToken(1)) + [bad, bad, bad, fxNote(FxPay.complete)]
        let rig = fxStart(fxOptions(), react: fxHistory(history))
        await fxWait { await rig.counters.framesMalformed >= 3 }
        await rig.drain()
        let record = await rig.finish()
        #expect(rig.link.acked == [fxToken(1)], "chunk 1 itself was intact")
        #expect(rig.sink.cursor?.lastCompleteSyncAt == nil)
        #expect(!rig.updates.completed)
        #expect(record.status == .failed)
    }

    /// Notifications the link lost inside a chunk: the chunk is damaged.
    @Test func notificationsLostByTheLinkInsideAChunkBlockItsAcknowledgement() async {
        let history = [fxNote(FxPay.start), fxNote(fxRec(1)), LinkEvent.gap(characteristic: nil, count: 3, at: fxNow), fxNote(fxRec(2)),
                       fxNote(FxPay.end(fxToken(1))), fxNote(FxPay.complete)]
        let rig = fxStart(fxOptions(), react: fxHistory(history))
        await fxWait { await rig.counters.historyRecords == 2 }
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(counters.notificationGaps == 3)
        #expect(rig.link.acked.isEmpty)
        #expect(rig.sink.cursor?.lastCompleteSyncAt == nil)
    }
}

// MARK: - Command responses

@Suite struct ReviewFixResponseTests {
    /// Result 0 is contested (failure in the reference client): Forma proceeds only on an explicit 1. What the
    /// band streams anyway is saved but never acknowledged and never completes a sync.
    @Test func historyRequestAnsweredWithContestedZeroFailsTheTransfer() async {
        let react: FxLink.React = { w, nth in
            guard w.cmd == 22 else { return nil }
            return [FxLink.answer(w, result: 0, at: fxNow)] + fxChunk([fxRec(1)], token: fxToken(1)) + [fxNote(FxPay.complete)]
        }
        let rig = fxStart(fxOptions(), react: react)
        await fxWait { await rig.counters.historyRecords == 1 }
        await rig.drain()
        let record = await rig.finish()
        #expect(rig.link.acked.isEmpty)
        #expect(rig.sink.cursor == nil)
        #expect(rig.sink.historyHR.map(\.timestamp) == [fxRecTime(1)])
        #expect(record.status == .failed)
    }

    /// Another client's answers on the shared link: counted, and acknowledgements stop for the transfer. Its
    /// acknowledgement answer does not stand in for Forma's, so Forma's own rejection is still counted.
    @Test func foreignAnswersAreCountedStopAcknowledgementsAndNeverHideFormasOwnAnswer() async {
        let react: FxLink.React = { w, nth in
            switch w.cmd {
            case 22:
                return [FxLink.answer(w, at: fxNow)] + fxChunk([fxRec(1)], token: fxToken(1))
            case 23 where nth == 0:
                // Another client's success (foreign echo) first, then the band's rejection of Forma's acknowledgement;
                // then the band goes on with the next chunk.
                return [FxLink.answer(w, result: 1, echo: w.seq &+ 77, at: fxNow), FxLink.answer(w, result: 3, at: fxNow)]
                    + fxChunk([fxRec(2)], token: fxToken(2)) + [fxNote(FxPay.complete)]
            default:
                return nil
            }
        }
        let rig = fxStart(fxOptions(), react: react)
        await fxWait { await rig.counters.historyRecords == 2 }
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(rig.link.acked == [fxToken(1)], "nothing after the foreign answer and the rejection")
        #expect(counters.responseSequenceMismatches == 1)
        #expect(counters.acknowledgementsRejected == 1, "Forma's own rejection is counted")
        #expect(counters.acknowledgementsAccepted == 0, "the foreign success is not Forma's")
    }

    /// An acknowledgement answer can arrive after the completion marker (another characteristic): it is still
    /// counted and recorded on the run.
    @Test func acknowledgementRejectedAfterCompletionIsCountedAndNoted() async {
        let react: FxLink.React = { w, nth in
            switch w.cmd {
            case 22: return [FxLink.answer(w, at: fxNow)] + fxChunk([fxRec(1)], token: fxToken(1))
            case 23: return [fxNote(FxPay.complete), FxLink.answer(w, result: 3, at: fxNow)]
            default: return nil
            }
        }
        let rig = fxStart(fxOptions(), react: react)
        await fxWait { await rig.counters.acknowledgementsRejected == 1 }
        await rig.drain()
        let record = await rig.finish()
        #expect(rig.sink.cursor?.lastCompleteSyncAt != nil, "the data was saved intact")
        #expect(record.note?.contains("did not accept an acknowledgement") == true, "\(String(describing: record.note))")
    }
}

// MARK: - Clock

@Suite struct ReviewFixClockTests {
    /// SET_RTC during a transfer (between two chunks): the records still arriving were written under the clock
    /// the transfer started with, so they keep its correction (flagged); nothing more is acknowledged, but the
    /// data was saved intact, so the transfer still completes.
    @Test func clockSetDuringATransferKeepsTheTransfersMappingAndStopsAcknowledgements() async {
        let time = ManualTimeSource(fxNow)
        let reads = AdvancedCounter()
        let react: FxLink.React = { w, nth in
            switch w.cmd {
            case 11:
                reads.increment()
                // First read: the band is 2 h behind. After SET_RTC: in step with the phone.
                let behind: Int64 = nth == 0 ? 7_200 : 0
                return [FxLink.answer(w, data: fxLE32(UInt32(fxNow / 1_000 - behind)) + fxLE32(0), at: fxNow)]
            case 22:
                return [FxLink.answer(w, at: fxNow)] + fxChunk([fxRec(1), fxRec(2)], token: fxToken(1)) + [fxNote(FxPay.event(16), fxEvents)]
                    + fxChunk([fxRec(3), fxRec(4)], token: fxToken(2)) + [fxNote(FxPay.complete)]
            default:
                return nil
            }
        }
        let rig = fxStart(fxOptions(), time: time, react: react)
        await fxWait { await rig.counters.historyRecords == 4 }
        await fxWait { reads.value == 2 }
        await rig.drain()
        _ = await rig.finish()
        let s = rig.sink.historyHR
        #expect(s.map(\.timestamp) == (1...4).map { fxRecTime($0) + 7_200_000 }, "one correction for the whole transfer")
        #expect(s.allSatisfy { $0.clockOffsetMillis == 7_200_000 })
        #expect(s.filter { $0.quality.contains(.nearClockDiscontinuity) }.map(\.timestamp) == [fxRecTime(3) + 7_200_000, fxRecTime(4) + 7_200_000])
        #expect(rig.link.acked == [fxToken(1)], "nothing after the clock change")
        #expect(rig.sink.cursor?.lastCompleteSyncAt != nil, "everything was saved intact")
    }

    /// A clock event after the transfer started but before history was requested (here while the range request
    /// is answered): every record of the transfer is flagged and nothing is acknowledged, even though the fresh
    /// reading arrives before the records do.
    @Test func clockEventBeforeTheHistoryRequestFlagsTheWholeTransfer() async {
        let react: FxLink.React = { w, nth in
            switch w.cmd {
            case 11:
                let behind: Int64 = nth == 0 ? 7_200 : 0
                return [FxLink.answer(w, data: fxLE32(UInt32(fxNow / 1_000 - behind)) + fxLE32(0), at: fxNow)]
            case 34:
                return [fxNote(FxPay.event(16), fxEvents), FxLink.answer(w, data: [UInt8](repeating: 0x5A, count: 25), at: fxNow)]
            case 22:
                return [FxLink.answer(w, at: fxNow)] + fxChunk([fxRec(1), fxRec(2)], token: fxToken(1)) + [fxNote(FxPay.complete)]
            default:
                return nil
            }
        }
        let rig = fxStart(fxOptions(), react: react)
        await fxWait { rig.updates.completed }
        await rig.drain()
        _ = await rig.finish()
        let s = rig.sink.historyHR
        #expect(s.count == 2 && s.allSatisfy { $0.quality.contains(.nearClockDiscontinuity) })
        #expect(rig.link.acked.isEmpty)
    }

    /// The first clock reading arrives only after history started (the band did not answer within 7 s): the
    /// rest of the transfer uses it (flagged) and nothing more is acknowledged.
    @Test func lateFirstClockReadingIsAdoptedFlaggedAndStopsAcknowledgements() async {
        let time = ManualTimeSource(fxNow)
        let react: FxLink.React = { w, nth in
            switch w.cmd {
            case 11: return []   // unanswered for now
            case 22: return [FxLink.answer(w, at: time.now())] + [fxNote(FxPay.start, at: time.now()), fxNote(fxRec(1), at: time.now())]
            default: return nil
            }
        }
        let rig = fxStart(fxOptions(), time: time, react: react)
        await fxWait { rig.link.writes(cmd: 11).count == 1 }
        await rig.drain()
        time.advance(byMillis: 7_000)
        await rig.engine.checkDeadlines()
        await fxWait { await rig.counters.historyRecords == 1 }
        // The band answers the clock read at last: it is 300 s behind.
        let seq = rig.link.writes(cmd: 11)[0].seq
        rig.link.emit([fxNote(FxPay.response(cmd: 11, echo: seq, result: 1, data: fxLE32(UInt32(time.now() / 1_000 - 300)) + fxLE32(0)), fxResp, at: time.now()),
                       fxNote(fxRec(2), at: time.now()), fxNote(FxPay.end(fxToken(1)), at: time.now()), fxNote(FxPay.complete, at: time.now())])
        await fxWait { await rig.counters.historyRecords == 2 }
        await rig.drain()
        _ = await rig.finish()
        let s = rig.sink.historyHR
        #expect(s.first { $0.deviceTimeRaw == Int64(fxBase + 60) }?.timestamp == fxRecTime(1), "placed before the reading, as-is")
        let second = s.first { $0.deviceTimeRaw == Int64(fxBase + 120) }
        #expect(second?.timestamp == fxRecTime(2) + 300_000 && second?.quality.contains(.nearClockDiscontinuity) == true)
        #expect(rig.link.acked.isEmpty)
    }

    /// The correction is measured with the band's sub-second field and rounded to whole seconds, so two
    /// connections that read a steady band clock at different sub-second phases store a re-sent record once.
    @Test func reSentHistoryIsStoredOnceWhenTheClockIsReadAtDifferentPhases() async throws {
        let store = try FormaStore(path: nil, timeSource: ManualTimeSource(fxNow))
        let behindMillis: Int64 = 3_400
        for phase: Int64 in [100, 10_600] {
            let time = ManualTimeSource(fxNow + phase)
            let react: FxLink.React = { w, nth in
                switch w.cmd {
                case 11:
                    let band = time.now() - behindMillis
                    let sub = UInt32((band % 1_000) * 32_768 / 1_000)
                    return [FxLink.answer(w, data: fxLE32(UInt32(band / 1_000)) + fxLE32(sub), at: time.now())]
                case 22:
                    return [FxLink.answer(w, at: time.now())] + fxChunk([fxRec(1)], token: fxToken(1), at: time.now()) + [fxNote(FxPay.complete, at: time.now())]
                default:
                    return nil
                }
            }
            let link = FxLink(time: time, react: react)
            let engine = SyncEngine(adapter: Whoop5Adapter(), sink: store, device: DeviceRecord(id: "fx-band", family: .whoop5, name: "WHOOP", firstSeen: 0),
                                    timeSource: time, options: fxOptions(ack: false))
            let run = Task { await engine.run(link: link) }
            await fxWait { await engine.currentCounters.historyRecords == 1 }
            await fxWait { (try? store.syncCursor(deviceID: "fx-band"))??.lastCompleteSyncAt != nil }
            link.emit([.disconnected(reason: "end", at: time.now())])
            _ = await run.value
        }
        let stored = try store.heartRates(in: TimeRange(start: 0, end: .max), sources: [.deviceHistory])
        #expect(stored.count == 1, "\(stored.map { ($0.timestamp, $0.clockOffsetMillis) })")
        #expect(stored.first?.clockOffsetMillis == 3_000)
    }

    /// KNOWN ISSUE (deferred, FormaStore): the HR/motion dedup keys use the corrected time, so a re-sent record
    /// whose correction really changed between downloads (band clock drifted across a half second, or was set)
    /// is stored twice. Fixing it needs a raw-device-time key for band history in the store.
    @Test func reSentHistoryWithAChangedCorrectionIsStoredTwiceUntilTheStoreKeysOnDeviceTime() async throws {
        let store = try FormaStore(path: nil, timeSource: ManualTimeSource(fxNow))
        for behind: Int64 in [0, 10] {
            let time = ManualTimeSource(fxNow)
            let react: FxLink.React = { w, nth in
                switch w.cmd {
                case 11: return [FxLink.answer(w, data: fxLE32(UInt32(fxNow / 1_000 - behind)) + fxLE32(0), at: fxNow)]
                case 22: return [FxLink.answer(w, at: fxNow)] + fxChunk([fxRec(1)], token: fxToken(1)) + [fxNote(FxPay.complete)]
                default: return nil
                }
            }
            let link = FxLink(time: time, react: react)
            let engine = SyncEngine(adapter: Whoop5Adapter(), sink: store, device: DeviceRecord(id: "fx-band", family: .whoop5, name: "WHOOP", firstSeen: 0),
                                    timeSource: time, options: fxOptions(ack: false))
            let run = Task { await engine.run(link: link) }
            await fxWait { await engine.currentCounters.historyRecords == 1 }
            link.emit([.disconnected(reason: "end", at: fxNow)])
            _ = await run.value
        }
        let stored = try store.heartRates(in: TimeRange(start: 0, end: .max), sources: [.deviceHistory])
        withKnownIssue("dedup keys use the corrected time; needs a raw-device-time key for band history in FormaStore") {
            #expect(stored.count == 1)
        }
    }

    /// A phone clock set back by an hour must not freeze the timeouts for that hour.
    @Test func phoneClockSetBackDoesNotFreezeTheIdleTimeout() async {
        let time = ManualTimeSource(fxNow)
        let rig = fxStart(fxOptions(ack: false), time: time, react: fxHistory(fxChunk([fxRec(1)], token: fxToken(1))))
        await fxWait { await rig.counters.historyRecords == 1 }
        await rig.drain()
        time.set(fxNow - 3_600_000)
        await rig.engine.checkDeadlines()
        time.advance(byMillis: 30_000)
        await rig.engine.checkDeadlines()
        #expect(await fxWait { !rig.updates.stopped.isEmpty }, "the transfer went quiet for 30 s and must end")
        let record = await rig.finish()
        #expect(record.status == .interrupted)
    }

    /// The plausibility bound ("phone now + 1 day") is taken at the record's receive time, so a capture
    /// replayed days later judges a future-stamped record exactly as the live engine did.
    @Test func plausibilityIsJudgedAtTheReceiveTime() async {
        let time = ManualTimeSource(fxNow + 10 * EpochMillis.millisPerDay)   // replayed ten days later
        let rig = fxStart(fxOptions(history: .manual, ack: false, readClock: false), time: time)
        let future = fxRecord(counter: 900, seconds: UInt32(fxNow / 1_000) + 3 * 86_400, hr: 70)
        rig.link.emit([fxNote(FxPay.start), fxNote(future), fxNote(fxRec(1)), fxNote(FxPay.end(nil))])
        await fxWait { await rig.counters.historyRecords == 2 }
        await rig.drain()
        let counters = await rig.counters
        _ = await rig.finish()
        #expect(counters.historyRecordsUnmapped == 1)
        #expect(rig.sink.historyHR.map(\.timestamp) == [fxRecTime(1)])
    }
}

// MARK: - Persistence and lifecycle

@Suite struct ReviewFixPersistenceTests {
    /// Turning history off saves what already arrived right away (not at some later event).
    @Test func historyTurnedOffSavesTheRecordsAlreadyReceived() async {
        let rig = fxStart(fxOptions(ack: false), react: fxHistory([fxNote(FxPay.start), fxNote(fxRec(1)), fxNote(fxRec(2))]))
        await fxWait { await rig.counters.historyRecords == 2 }
        await rig.drain()
        #expect(rig.sink.historyHR.isEmpty, "precondition: still buffered")
        await rig.engine.setOptions(fxOptions(history: .off, ack: false))
        #expect(rig.sink.historyHR.map(\.timestamp) == [fxRecTime(1), fxRecTime(2)])
        _ = await rig.finish()
    }

    /// Another app's history whose save fails is kept and saved with the next save (that app may acknowledge it).
    @Test func unsolicitedHistoryWhoseSaveFailedIsRetried() async {
        let sink = FxSink()
        let failedOnce = AdvancedCounter()
        sink.fail { batch in
            guard batch.provenance.note == "history (unsolicited)", failedOnce.value == 0 else { return false }
            failedOnce.increment()
            return true
        }
        let rig = fxStart(fxOptions(history: .manual, ack: false, readClock: false), sink: sink)
        rig.link.emit(fxChunk([fxRec(1)], token: fxToken(1)))
        await rig.drain()
        #expect(sink.failures == 1, "precondition: the first save failed")
        rig.link.emit(fxChunk([fxRec(2)], token: fxToken(2)))
        await rig.drain()
        _ = await rig.finish()
        #expect(sink.historyHR.map(\.timestamp) == [fxRecTime(1), fxRecTime(2)])
    }

    /// Durations far beyond the clamp neither trap at connect nor in the timer.
    @Test func hugeOptionValuesAreClampedAndNeverTrap() async {
        let clamped = SyncOptions(historyIdleTimeoutMillis: .max, commandTimeoutMillis: .max, pendingGraceMillis: .max, retryDelayMillis: .max,
                                  timerIntervalMillis: 20_000_000_000_000)
        #expect(clamped.commandTimeoutMillis == SyncOptions.maxDurationMillis)
        #expect(clamped.timerIntervalMillis == SyncOptions.maxDurationMillis)
        var raw = fxOptions(ack: false)
        raw.commandTimeoutMillis = .max          // set directly, bypassing the clamp
        raw.historyIdleTimeoutMillis = .max
        raw.timerIntervalMillis = .max
        let rig = fxStart(raw, react: fxHistory(fxChunk([fxRec(1)], token: fxToken(1)) + [fxNote(FxPay.complete)]))
        #expect(await fxWait { rig.updates.completed })
        _ = await rig.finish()
    }

    /// The trailing edge of the telemetry throttle: a burst's last counters reach the UI on the next tick.
    @Test func throttledTelemetryIsDeliveredOnTheNextTick() async {
        let time = ManualTimeSource(fxNow)
        let rig = fxStart(fxOptions(history: .off, ack: false, readClock: false), time: time)
        for _ in 0..<10 { rig.link.emit([.notification(characteristic: fxSentinel, bytes: [1], receivedAt: fxNow)]) }
        await fxWait { await rig.counters.unknownPackets == 10 }
        time.advance(byMillis: 1_000)
        await rig.engine.checkDeadlines()
        #expect(await fxWait { rig.updates.lastCounters?.unknownPackets == 10 }, "last emitted: \(String(describing: rig.updates.lastCounters?.unknownPackets))")
        _ = await rig.finish()
    }

    /// One engine run twice: the second connection starts from a clean clock (it waits for its own reading).
    @Test func aSecondRunStartsFromACleanConnectionState() async {
        let time = ManualTimeSource(fxNow)
        let sink = FxSink()
        let engine = SyncEngine(adapter: Whoop5Adapter(), sink: sink, device: DeviceRecord(id: "fx-band", family: .whoop5, name: "WHOOP", firstSeen: 0),
                                timeSource: time, options: fxOptions(ack: false))
        for (connection, behind) in [(0, Int64(10)), (1, Int64(0))] {
            let react: FxLink.React = { w, nth in
                switch w.cmd {
                case 11: return [FxLink.answer(w, data: fxLE32(UInt32(fxNow / 1_000 - behind)) + fxLE32(0), at: fxNow)]
                case 22: return [FxLink.answer(w, at: fxNow)] + fxChunk([fxRec(UInt32(connection) + 1)], token: fxToken(1)) + [fxNote(FxPay.complete)]
                default: return nil
                }
            }
            let link = FxLink(time: time, react: react)
            let run = Task { await engine.run(link: link) }
            await fxWait { sink.historyHR.count == connection + 1 }
            link.emit([.disconnected(reason: "end", at: fxNow)])
            let record = await run.value
            #expect(record.recordsInserted == 1, "per-run counts")
        }
        let second = sink.historyHR.first { $0.deviceTimeRaw == Int64(fxBase + 120) }
        #expect(second?.timestamp == fxRecTime(2) && second?.clockOffsetMillis == nil, "the second connection used its own reading")
    }

    @Test func replayLinkFinishDefaultsToTheLastEntryTime() async {
        let link = ReplayLink(entries: [CaptureEntry(t: 1_234, dir: .rx, c: "2A37", d: "0046")], services: [:], responder: { _, _ in [] })
        link.finish()
        var last: LinkEvent?
        for await e in link.events { last = e }
        #expect(last == .disconnected(reason: "replay finished", at: 1_234))
    }

    @Test func replayLinkReplaysRecordedGaps() async {
        let link = ReplayLink(entries: [CaptureEntry(t: 5, dir: .event, c: "", d: "", note: "gap: 4 notification(s) lost")], services: [:])
        var events: [LinkEvent] = []
        for await e in link.events { events.append(e) }
        #expect(events.contains(.gap(characteristic: nil, count: 4, at: 5)))
    }
}

// MARK: - forma-replay

@Suite struct ReviewFixReplayCLITests {
    /// Records re-sent in each connection of a capture are reported once, as the app's store would hold them.
    @Test func historyReSentInEveryConnectionIsCountedOnce() throws {
        let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/forma-replay")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            Issue.record("run `swift build` first: \(binary.path) is missing")
            return
        }
        var entries: [CaptureEntry] = []
        for connection in 0..<2 {
            let t0 = fxNow + Int64(connection) * 60_000
            for (i, p) in ([FxPay.start] + (1...3).map { fxRec(UInt32($0)) } + [FxPay.end(nil)]).enumerated() {
                entries.append(CaptureEntry(t: t0 + Int64(i), dir: .rx, c: fxData, d: HexCodec.encode(fxFrame(p))))
            }
            entries.append(CaptureEntry(t: t0 + 100, dir: .event, c: "", d: "", note: "disconnect: test"))
        }
        let file = CaptureFile(header: CaptureHeader(createdAt: fxNow, deviceFamily: .whoop5), entries: entries)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fx-\(UUID().uuidString).jsonl")
        try file.encoded().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--json", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let heartRate = json?["heartRate"] as? [String: Any]
        let counters = json?["counters"] as? [String: Any]
        #expect(heartRate?["samples"] as? Int == 3)
        #expect(counters?["historyRecords"] as? Int == 6, "six records were received")
        #expect(counters?["duplicateRecordsSkipped"] as? Int == 3)
    }
}

/// Thread-safe counter for scripted reactions.
fileprivate final class AdvancedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
