// Final integration review: Forma switches off a real-time stream it may have left on (a new engine on a
// connection that outlived the previous one, or a relaunch after the app was ended mid-workout), and
// never touches a stream it did not request.

import Foundation
import Testing
import FormaCore
@testable import FormaProtocol
@testable import FormaSync

private func streamWrites(_ link: ReplayLink) -> [UInt8] {
    link.writtenCommands.compactMap { [0x15, 0x16].contains($0.bytes.first) ? $0.bytes.first : nil }
}

private func engine(liveHeartRate: Bool, mayBeOn: Bool, sink: RecordingSink) -> SyncEngine {
    SyncEngine(adapter: ToyAdapter(), sink: sink, device: DeviceRecord(id: "dev-1", family: .unknown, name: "Toy", firstSeen: 0),
               timeSource: ManualTimeSource(Int64(baseSeconds) * 1_000),
               options: SyncOptions(history: .off, liveHeartRate: liveHeartRate, readClockOnConnect: false, timerIntervalMillis: 0),
               realtimeStreamMayBeOn: mayBeOn)
}

@Suite("Real-time stream ownership")
struct RealtimeStreamOwnershipTests {
    @Test func aStreamFormaMayHaveLeftOnIsSwitchedOffWhenNotWanted() async {
        let link = ReplayLink(entries: [], services: [:], responder: { _, _ in [] })
        _ = await runScript(engine(liveHeartRate: false, mayBeOn: true, sink: RecordingSink(log: OrderLog())), link: link)
        #expect(streamWrites(link) == [0x16])
    }

    @Test func withoutThatHintNothingIsWrittenForTheStream() async {
        let link = ReplayLink(entries: [], services: [:], responder: { _, _ in [] })
        _ = await runScript(engine(liveHeartRate: false, mayBeOn: false, sink: RecordingSink(log: OrderLog())), link: link)
        #expect(streamWrites(link).isEmpty, "a stream another app requested is never switched off")
    }

    @Test func anUnknownStateIsSettledWithOneWriteWhenTheStreamIsWanted() async {
        let link = ReplayLink(entries: [], services: [:], responder: { _, _ in [] })
        let engine = engine(liveHeartRate: true, mayBeOn: true, sink: RecordingSink(log: OrderLog()))
        _ = await runScript(engine, link: link) {
            // Re-applying the same options writes nothing more.
            await engine.setOptions(SyncOptions(history: .off, liveHeartRate: true, readClockOnConnect: false, timerIntervalMillis: 0))
        }
        #expect(streamWrites(link) == [0x15])
    }

    /// History records saved and skipped are counted apart from live data (Diagnostics shows them).
    @Test func historySavesAreCountedSeparately() async {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        let records = (0..<4).map { historyRecord(counter: UInt32($0), seconds: baseSeconds + UInt32($0), hr: 60) }
        let first = makeEngine(sink: sink, acknowledge: false)
        _ = await runScript(first, link: historyLink(log: log, chunk: records))
        let firstCounters = await first.currentCounters
        #expect(firstCounters.historyRecordsSaved == 4 && firstCounters.historyRecordsAlreadyStored == 0)
        let second = makeEngine(sink: sink, acknowledge: false)
        _ = await runScript(second, link: historyLink(log: log, chunk: records))
        let secondCounters = await second.currentCounters
        #expect(secondCounters.historyRecordsSaved == 0 && secondCounters.historyRecordsAlreadyStored == 4)
    }
}

/// Reports `ambiguousDuplicates` for every band-history heart rate (as the store does after a band clock
/// was set back and a band second is reused).
private final class AmbiguousSink: IngestSink, @unchecked Sendable {
    let base: RecordingSink
    init(_ base: RecordingSink) { self.base = base }
    func ingest(_ batch: IngestBatch) throws -> IngestResult {
        var result = try base.ingest(batch)
        if batch.provenance.source == .deviceHistory { result.ambiguousDuplicates = batch.heartRates.count }
        return result
    }
    func syncCursor(deviceID: String) throws -> SyncCursor? { try base.syncCursor(deviceID: deviceID) }
    func upsertDevice(_ device: DeviceRecord) throws { try base.upsertDevice(device) }
    func recordConnectionEvent(_ event: ConnectionEvent) throws {}
    func recordRawFrame(_ frame: RawFrameRecord) throws {}
    func beginSyncRun(_ run: SyncRunRecord) throws -> Int64 { try base.beginSyncRun(run) }
    func finishSyncRun(_ run: SyncRunRecord) throws { try base.finishSyncRun(run) }
    func ensureDurable() throws { try base.ensureDurable() }
}

@Suite("History outcome reporting")
struct HistoryOutcomeReportingTests {
    /// A chunk whose records matched stored band records only partly is saved but never acknowledged; the
    /// transfer still completes (nothing it delivered was lost by Forma).
    @Test func ambiguousDuplicatesHoldTheAcknowledgement() async {
        let log = OrderLog()
        let base = RecordingSink(log: log)
        let device = DeviceRecord(id: "dev-1", family: .unknown, name: "Toy", firstSeen: 0)
        let engine = SyncEngine(adapter: ToyAdapter(), sink: AmbiguousSink(base), device: device,
                                timeSource: ManualTimeSource(Int64(baseSeconds) * 1_000 + 3_600_000),
                                options: SyncOptions(history: .automatic, acknowledgeHistory: true, liveFlushIntervalMillis: 0,
                                                     readClockOnConnect: false, timerIntervalMillis: 0))
        let link = historyLink(log: log, chunk: [historyRecord(counter: 1, seconds: baseSeconds, hr: 60)])
        let run = await runScript(engine, link: link)
        #expect(!log.all.contains("write:13"), "acknowledged a chunk with ambiguous duplicates")
        #expect(run.status == .completed)
        let counters = await engine.currentCounters
        #expect(counters.historyAmbiguousDuplicates == 1 && counters.historyChunksSaved == 1)
        #expect(base.currentCursor?.lastCompleteSyncAt != nil)
    }

    /// The band's own outcome (chunks received, completion marker) is reported apart from Forma's verdict:
    /// a chunk with a record Forma does not decode keeps the transfer incomplete, but the reason says the
    /// band finished it, and the counters show it.
    @Test func theBandsOwnOutcomeIsReportedApartFromFormasVerdict() async {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        let engine = makeEngine(sink: sink, acknowledge: false)
        let updates = Task { () -> [SyncUpdate] in
            var all: [SyncUpdate] = []
            for await u in engine.updates { all.append(u) }
            return all
        }
        let link = historyLink(log: log, chunk: [historyRecord(counter: 1, seconds: baseSeconds, hr: 60), [0x0A] + le32(2) + le32(baseSeconds + 1)])
        let run = await runScript(engine, link: link)
        #expect(run.status == .failed, "a record Forma does not store keeps the transfer incomplete")
        let counters = await engine.currentCounters
        #expect(counters.historyChunksReceived == 1 && counters.historyChunksSaved == 0)
        #expect(counters.historyTransfersFinishedByBand == 1)
        updates.cancel()
        let stopped = await updates.value.compactMap { u -> String? in
            if case .historyStopped(let reason, _) = u { return reason } else { return nil }
        }
        #expect(stopped.contains { $0.hasPrefix("The band finished the transfer (1 chunk), but it is not complete for Forma") }, "\(stopped)")
    }
}
