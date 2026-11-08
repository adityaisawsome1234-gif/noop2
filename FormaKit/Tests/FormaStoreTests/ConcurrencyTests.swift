import Foundation
import Testing
import FormaCore
@testable import FormaStore

/// Thread-safe accumulation of ingest results.
private final class ResultTally: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [IngestResult] = []

    func add(_ result: IngestResult) {
        lock.lock()
        defer { lock.unlock() }
        results.append(result)
    }

    var all: [IngestResult] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}

@Suite("Concurrency")
struct ConcurrencyTests {
    @Test func concurrentIngestFromManyThreadsIsSafeAndExact() throws {
        let store = try makeStore()
        let errors = ErrorCollector()
        let tally = ResultTally()
        let workers = 8
        let batchesPerWorker = 25
        let samplesPerBatch = 20
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for batch in 0..<batchesPerWorker {
                // Workers 2k and 2k+1 deliver the same data, as two overlapping downloads would.
                let base = ((worker / 2) * batchesPerWorker + batch) * samplesPerBatch
                let samples = (0..<samplesPerBatch).map { hr(t0 + Int64(base + $0) * 1_000, 60 + $0) }
                let intervals = (0..<samplesPerBatch).map {
                    rr(t0 + Int64(base + $0) * 1_000, 1_000, recordKey: Int64(base + $0), index: 0)
                }
                do {
                    tally.add(try store.ingest(IngestBatch(provenance: provenance(), heartRates: samples,
                                                           beatIntervals: intervals)))
                } catch {
                    errors.record(error)
                }
            }
        }
        #expect(errors.errors.isEmpty)
        let results = tally.all
        let unique = (workers / 2) * batchesPerWorker * samplesPerBatch * 2
        #expect(results.count == workers * batchesPerWorker)
        #expect(results.reduce(0) { $0 + $1.inserted } == unique)
        #expect(results.reduce(0) { $0 + $1.duplicates } == unique)
        #expect(Set(results.map(\.batchID)).count == results.count)
        let counts = try store.tableCounts()
        #expect(counts["hr_sample"] == unique / 2)
        #expect(counts["beat_interval"] == unique / 2)
        #expect(counts["ingest_batch"] == workers * batchesPerWorker)
        let timestamps = try store.heartRates(in: everything).map(\.timestamp)
        #expect(timestamps == timestamps.sorted())
    }

    @Test func readersWritersAndExportsInterleaveSafely() async throws {
        let store = try makeStore()
        let directory = try TemporaryDirectory()
        let backupURL = directory.file("concurrent.ndjson")
        let csvDirectory = directory.url.appendingPathComponent("csv", isDirectory: true)
        try store.setRawCaptureEnabled(true)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<4 {
                group.addTask {
                    for batch in 0..<50 {
                        let base = (worker * 50 + batch) * 10
                        _ = try store.ingest(IngestBatch(provenance: provenance(),
                                                         heartRates: (0..<10).map { hr(t0 + Int64(base + $0) * 1_000, 70) }))
                    }
                }
            }
            group.addTask {
                for _ in 0..<50 {
                    let samples = try store.heartRates(in: everything)
                    #expect(samples.map(\.timestamp) == samples.map(\.timestamp).sorted())
                    _ = try store.tableCounts()
                    _ = try store.dataBounds()
                }
            }
            group.addTask {
                for index in 0..<200 {
                    try store.recordRawFrame(RawFrameRecord(deviceID: deviceA, receivedAt: t0 + Int64(index),
                                                            characteristic: "c", bytes: Data([UInt8(index % 256)]),
                                                            parseStatus: "ok"))
                    try store.recordConnectionEvent(ConnectionEvent(deviceID: deviceA, timestamp: t0 + Int64(index),
                                                                    kind: .connected))
                }
            }
            group.addTask {
                for index in 0..<20 {
                    let id = try store.insertSession(Session(kind: .workout,
                                                             range: TimeRange(start: t0 + Int64(index), end: t0 + 1_000),
                                                             origin: .manual, createdAt: t0, updatedAt: t0))
                    var session = try #require(try store.session(id: id))
                    session.label = "edited \(index)"
                    try store.updateSession(session)
                }
            }
            group.addTask { _ = try store.exportBackup(to: backupURL) }
            group.addTask { _ = try store.exportCSV(to: csvDirectory) }
            try await group.waitForAll()
        }
        let counts = try store.tableCounts()
        #expect(counts["hr_sample"] == 4 * 50 * 10)
        #expect(counts["raw_frame"] == 200)
        #expect(counts["connection_event"] == 200)
        #expect(counts["user_correction"] == 20)

        // Whatever the export captured is a valid backup that imports cleanly.
        let restored = try makeStore()
        let report = try restored.importBackup(from: backupURL)
        #expect(report.invalidLines == 0)
        #expect((report.inserted[.hr] ?? 0) <= 2_000)
    }
}
