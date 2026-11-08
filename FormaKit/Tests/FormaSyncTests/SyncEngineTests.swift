import Foundation
import Testing
import FormaCore
import FormaProtocol
@testable import FormaSync

// MARK: - Test doubles

/// Thread-safe ordered log shared by the sink and the link so tests can assert "persisted before ack".
final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ s: String) { lock.withLock { entries.append(s) } }
    var all: [String] { lock.withLock { entries } }
}

/// In-memory IngestSink with real dedup keys and injectable failures.
final class RecordingSink: IngestSink, @unchecked Sendable {
    private let lock = NSLock()
    let log: OrderLog
    var failIngestWhen: (@Sendable (IngestBatch) -> Bool)?
    private(set) var hr: [HeartRateSample] = []
    private(set) var beats: [BeatInterval] = []
    private(set) var motion: [MotionEpoch] = []
    private(set) var aux: [AuxMeasurement] = []
    private var keys = Set<String>()
    private var cursor: SyncCursor?
    private(set) var runs: [SyncRunRecord] = []
    private(set) var devices: [DeviceRecord] = []
    private var nextID: Int64 = 1

    init(log: OrderLog) { self.log = log }

    func ingest(_ batch: IngestBatch) throws -> IngestResult {
        try lock.withLock {
            if let fail = failIngestWhen, fail(batch) {
                log.append("ingest-failed")
                throw NSError(domain: "test", code: 1)
            }
            var inserted = 0, dup = 0
            for s in batch.heartRates {
                if keys.insert("hr|\(s.deviceID)|\(s.source.rawValue)|\(s.timestamp)").inserted { hr.append(s); inserted += 1 } else { dup += 1 }
            }
            for b in batch.beatIntervals {
                if keys.insert("rr|\(b.deviceID)|\(b.source.rawValue)|\(b.recordKey)|\(b.indexInRecord)").inserted { beats.append(b); inserted += 1 } else { dup += 1 }
            }
            for m in batch.motion {
                if keys.insert("m|\(m.deviceID)|\(m.source.rawValue)|\(m.timestamp)|\(m.epochMillis)").inserted { motion.append(m); inserted += 1 } else { dup += 1 }
            }
            for a in batch.aux {
                if keys.insert("a|\(a.deviceID)|\(a.source.rawValue)|\(a.kind)|\(a.timestamp)").inserted { aux.append(a); inserted += 1 } else { dup += 1 }
            }
            if let c = batch.cursor { cursor = c }
            log.append("ingest:\(batch.provenance.note ?? "")")
            nextID += 1
            return IngestResult(batchID: nextID, inserted: inserted, duplicates: dup)
        }
    }
    func syncCursor(deviceID: String) throws -> SyncCursor? { lock.withLock { cursor } }
    func upsertDevice(_ device: DeviceRecord) throws { lock.withLock { devices.append(device) } }
    func recordConnectionEvent(_ event: ConnectionEvent) throws {}
    func recordRawFrame(_ frame: RawFrameRecord) throws {}
    func beginSyncRun(_ run: SyncRunRecord) throws -> Int64 { lock.withLock { runs.append(run); return Int64(runs.count) } }
    func finishSyncRun(_ run: SyncRunRecord) throws { lock.withLock { runs.append(run) } }
    var currentCursor: SyncCursor? { lock.withLock { cursor } }
}

/// A toy protocol for exercising the engine:
/// rx: [0x01, bpm] realtime HR (no device time) · [0x02, counter u32, seconds u32, hr] history record ·
///     [0x03] start · [0x04, token...] end · [0x05] complete · [0x06] malformed · [0x07, seconds u32] clock ·
///     [0x08] unknown packet · standard HR measurements arrive on 2A37.
/// tx: [opcode, seq, args...]; opcodes 0x10 identify, 0x11 clock, 0x12 history, 0x13 ack(+token), 0x14 abort, 0x15 hr on, 0x16 hr off.
struct ToyAdapter: DeviceAdapter {
    var supported: Set<String> = ["identify", "readClock", "requestHistory", "acknowledgeHistory", "abortHistory", "realtimeHROn", "realtimeHROff"]
    let adapterID = "test.toy"
    let parserVersion = "toy-1"
    let family = DeviceFamily.unknown
    let gatt = GATTProfile(vendorService: "AAAA0001-0000-0000-0000-000000000000", discoverServices: [], subscribeCharacteristics: [],
                           commandCharacteristic: "AAAA0002-0000-0000-0000-000000000000", commandWriteWithResponse: true,
                           scanServiceFilter: [], nameHints: [])
    let capabilities: [Capability: CapabilityStatus] = [:]

    func supports(_ command: AllowedCommand) -> Bool { supported.contains(command.name) }

    func encode(_ command: AllowedCommand, sequence: UInt8) throws -> [UInt8] {
        guard supports(command) else { throw CommandEncodingError.unsupported(command.name) }
        switch command {
        case .identify: return [0x10, sequence]
        case .readClock: return [0x11, sequence]
        case .requestHistory: return [0x12, sequence]
        case .acknowledgeHistory(let token): return [0x13, sequence] + token
        case .abortHistory: return [0x14, sequence]
        case .setRealtimeHeartRate(let on): return [on ? 0x15 : 0x16, sequence]
        default: throw CommandEncodingError.unsupported(command.name)
        }
    }

    func makeDecoder() -> any DeviceDecoder { ToyDecoder() }
}

final class ToyDecoder: DeviceDecoder {
    func decode(characteristic: String, bytes: [UInt8], receivedAt: EpochMillis) -> [DecodedEvent] {
        if characteristic == UUIDs.heartRateMeasurement {
            // flags byte then UINT8 HR then RR (1/1024 s) pairs — enough for engine tests.
            guard bytes.count >= 2 else { return [.malformed(reason: "short", byteCount: bytes.count, characteristic: characteristic, receivedAt: receivedAt)] }
            var rr: [Double] = []
            var i = 2
            while i + 1 < bytes.count { rr.append(Double(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8) * 1000 / 1024); i += 2 }
            return [.standardHeartRate(bpm: bytes[1] == 0 ? nil : Int(bytes[1]), contact: .detected, rrMillis: rr, energyKJ: nil, receivedAt: receivedAt)]
        }
        guard let type = bytes.first else { return [] }
        func u32(_ o: Int) -> UInt32 { UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24 }
        switch type {
        case 0x01: return [.realtimeHeartRate(bpm: Int(bytes[1]), deviceSeconds: nil, status: .validated, receivedAt: receivedAt)]
        case 0x02:
            return [.historyRecord(HistoryRecord(kind: 24, counter: u32(1), deviceSeconds: u32(5), subseconds: 0, receivedAt: receivedAt,
                                                 heartRate: Int(bytes[9]), heartRateStatus: .unvalidated, beatIntervalsMillis: [],
                                                 motion: nil, payloadLength: bytes.count))]
        case 0x03: return [.historyMarker(HistoryMarker(kind: .start, ackToken: nil, receivedAt: receivedAt))]
        case 0x04: return [.historyMarker(HistoryMarker(kind: .end, ackToken: bytes.count > 1 ? Array(bytes.dropFirst()) : nil, receivedAt: receivedAt))]
        case 0x05: return [.historyMarker(HistoryMarker(kind: .complete, ackToken: nil, receivedAt: receivedAt))]
        case 0x06: return [.malformed(reason: "bad crc", byteCount: bytes.count, characteristic: characteristic, receivedAt: receivedAt)]
        case 0x07: return [.clockReading(deviceSeconds: u32(1), receivedAt: receivedAt)]
        default: return [.unknownPacket(packetType: type, length: bytes.count, characteristic: characteristic, receivedAt: receivedAt)]
        }
    }
    func reset(at time: EpochMillis) -> [DecodedEvent] { [] }
}

// MARK: - Helpers

let toyData = "AAAA0005-0000-0000-0000-000000000000"
let baseSeconds: UInt32 = 1_762_500_000 // 2025-11-07, plausible

func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
func historyRecord(counter: UInt32, seconds: UInt32, hr: UInt8) -> [UInt8] { [0x02] + le32(counter) + le32(seconds) + [hr] }

func hexString(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

/// Builds a link whose responder plays a history chunk when the history request is written.
func historyLink(log: OrderLog, chunk: [[UInt8]], endToken: [UInt8]? = [0xAB, 0xCD], complete: Bool = true) -> ReplayLink {
    let link = ReplayLink(entries: [], services: [:], responder: { bytes, _ in
        log.append("write:\(bytes.first.map { String(format: "%02x", $0) } ?? "")")
        guard bytes.first == 0x12 else { return [] }
        var events: [LinkEvent] = [.notification(characteristic: toyData, bytes: [0x03], receivedAt: 1_000)]
        for (i, r) in chunk.enumerated() { events.append(.notification(characteristic: toyData, bytes: r, receivedAt: 1_001 + Int64(i))) }
        events.append(.notification(characteristic: toyData, bytes: [0x04] + (endToken ?? []), receivedAt: 2_000))
        if complete { events.append(.notification(characteristic: toyData, bytes: [0x05], receivedAt: 2_001)) }
        return events
    })
    return link
}

func makeEngine(sink: RecordingSink, adapter: ToyAdapter = ToyAdapter(), history: HistoryPolicy = .automatic,
                now: EpochMillis = Int64(baseSeconds) * 1_000 + 3_600_000) -> SyncEngine {
    let device = DeviceRecord(id: "dev-1", family: .unknown, name: "Toy", firstSeen: 0)
    return SyncEngine(adapter: adapter, sink: sink, device: device, timeSource: ManualTimeSource(now),
                      options: SyncOptions(history: history, liveHeartRate: false, rawCapture: true, liveFlushIntervalMillis: 0),
                      recorder: CaptureRecorder())
}

/// Runs the engine until the scripted history completes, then disconnects.
func runScript(_ engine: SyncEngine, link: ReplayLink, settle: @escaping @Sendable () async -> Void = {}) async -> SyncRunRecord {
    async let result = engine.run(link: link)
    // Let the engine process the scripted reactions, then end the session.
    for _ in 0..<50 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 50_000_000)
    await settle()
    link.finish(reason: "test end", at: 9_999)
    return await result
}

// MARK: - Tests

@Suite struct SyncEngineHistoryTests {
    @Test func persistsBeforeAcknowledging() async {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        let engine = makeEngine(sink: sink)
        let link = historyLink(log: log, chunk: (0..<5).map { historyRecord(counter: UInt32($0), seconds: baseSeconds + UInt32($0), hr: 60) })
        _ = await runScript(engine, link: link)
        let entries = log.all
        let ackIndex = entries.firstIndex(of: "write:13")
        let lastHistoryIngest = entries.lastIndex(where: { $0 == "ingest:history" })
        #expect(ackIndex != nil, "an acknowledgement should be sent: \(entries)")
        #expect(lastHistoryIngest != nil && lastHistoryIngest! < ackIndex!, "history must be persisted before the ack: \(entries)")
        #expect(sink.hr.count == 5)
        #expect(sink.hr.allSatisfy { $0.source == .deviceHistory && $0.quality.contains(.unvalidatedField) })
        #expect(sink.currentCursor?.opaque == Data([0xAB, 0xCD]))
        #expect(sink.currentCursor?.lastCompleteSyncAt == 2_001)
        #expect(link.writtenCommands.contains { $0.bytes == [0x13, $0.bytes[1], 0xAB, 0xCD] })
    }

    @Test func persistenceFailureMeansNoAckAndAbort() async {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        sink.failIngestWhen = { $0.provenance.note == "history" }
        let engine = makeEngine(sink: sink)
        let link = historyLink(log: log, chunk: [historyRecord(counter: 1, seconds: baseSeconds, hr: 61)])
        _ = await runScript(engine, link: link)
        let writes = log.all.filter { $0.hasPrefix("write:") }
        #expect(!writes.contains("write:13"), "no ack after a failed save: \(writes)")
        #expect(writes.contains("write:14"), "transfer aborted: \(writes)")
        #expect(sink.currentCursor?.lastCompleteSyncAt == nil)
    }

    @Test func unmappableTimestampsAreLeftOnTheBand() async {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        let engine = makeEngine(sink: sink)
        // seconds = 5 → 1970: band clock lost. Must not be stored as a measurement nor acknowledged.
        let link = historyLink(log: log, chunk: [historyRecord(counter: 1, seconds: baseSeconds, hr: 60), historyRecord(counter: 2, seconds: 5, hr: 61)])
        _ = await runScript(engine, link: link)
        #expect(!log.all.contains("write:13"))
        #expect(sink.hr.count == 1)
        #expect(await engine.currentCounters.historyRecordsUnmapped == 1)
    }

    @Test func missingAckTokenMeansNoAck() async {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        let engine = makeEngine(sink: sink)
        let link = historyLink(log: log, chunk: [historyRecord(counter: 1, seconds: baseSeconds, hr: 60)], endToken: nil)
        _ = await runScript(engine, link: link)
        #expect(!log.all.contains("write:13"))
    }

    @Test func repeatedDownloadsDoNotDuplicate() async {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        let chunk = (0..<3).map { historyRecord(counter: UInt32($0), seconds: baseSeconds + UInt32($0), hr: 58) }
        for _ in 0..<2 {
            let engine = makeEngine(sink: sink)
            _ = await runScript(engine, link: historyLink(log: log, chunk: chunk))
        }
        #expect(sink.hr.count == 3)
    }

    @Test func historyOffNeverRequestsOrAcknowledges() async {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        let engine = makeEngine(sink: sink, history: .off)
        let link = historyLink(log: log, chunk: [historyRecord(counter: 1, seconds: baseSeconds, hr: 60)])
        _ = await runScript(engine, link: link)
        #expect(!log.all.contains("write:12"))
        #expect(!log.all.contains("write:13"))
    }

    @Test func disconnectMidChunkPersistsButDoesNotAck() async {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        let engine = makeEngine(sink: sink)
        // No end marker: the chunk is cut off by the disconnect.
        let link = ReplayLink(entries: [], services: [:], responder: { bytes, _ in
            log.append("write:\(String(format: "%02x", bytes[0]))")
            guard bytes.first == 0x12 else { return [] }
            return [.notification(characteristic: toyData, bytes: [0x03], receivedAt: 1_000),
                    .notification(characteristic: toyData, bytes: historyRecord(counter: 1, seconds: baseSeconds, hr: 60), receivedAt: 1_001),
                    .disconnected(reason: "out of range", at: 1_002)]
        })
        let run = await runScript(engine, link: link)
        #expect(!log.all.contains("write:13"))
        #expect(sink.hr.count == 1)
        #expect(run.status == .interrupted)
    }

    @Test func unsupportedCommandsAreNeverWritten() async {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        var adapter = ToyAdapter()
        adapter.supported = ["identify"] // no history support at all
        let engine = makeEngine(sink: sink, adapter: adapter)
        let link = historyLink(log: log, chunk: [])
        _ = await runScript(engine, link: link)
        let writes = log.all.filter { $0.hasPrefix("write:") }
        #expect(writes == ["write:10"], "only the supported identify command may be written: \(writes)")
    }
}

@Suite struct SyncEngineLiveTests {
    @Test func standardHeartRateBecomesPhoneTimedSamplesWithReconstructedBeats() async {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        let engine = makeEngine(sink: sink, history: .off)
        // 1024 → exactly 1000 ms; 2048 → 2000 ms.
        let link = ReplayLink(entries: [
            CaptureEntry(t: 10_000, dir: .rx, c: "2A37", d: "1048" + "0004" + "0008"),
            CaptureEntry(t: 11_000, dir: .rx, c: "2A37", d: "1000"),          // HR 0 → no sample
            CaptureEntry(t: 12_000, dir: .rx, c: toyData, d: "06"),            // malformed
            CaptureEntry(t: 12_500, dir: .rx, c: toyData, d: "08"),            // unknown packet type
        ], services: [:])
        _ = await engine.run(link: link)
        #expect(sink.hr.count == 1)
        #expect(sink.hr[0].bpm == 72 && sink.hr[0].timestamp == 10_000 && sink.hr[0].quality.contains(.phoneReceiveTime))
        #expect(sink.beats.map(\.intervalMillis) == [1_000, 2_000])
        #expect(sink.beats.map(\.timestamp) == [8_000, 10_000])
        #expect(sink.beats.allSatisfy { $0.timingBasis == .reconstructedFromReceiveTime })
        let c = await engine.currentCounters
        #expect(c.framesMalformed == 1 && c.unknownPackets == 1 && c.standardHRWithRR == 1)
    }
}
