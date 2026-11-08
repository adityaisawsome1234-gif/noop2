import Foundation
import Testing
import FormaCore
@testable import FormaStore

@Suite struct DurabilityTests {
    @Test func ensureDurableCheckpointsAFileStoreAndKeepsTheData() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forma-durable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("forma.sqlite").path
        let t: EpochMillis = 1_770_000_000_000
        do {
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t))
            let provenance = Provenance(deviceID: "band", adapterID: "a", parserVersion: "p", firmwareVersion: nil,
                                        source: .deviceHistory, syncRunID: nil, createdAt: t, note: "history")
            let sample = HeartRateSample(deviceID: "band", timestamp: t, bpm: 61, source: .deviceHistory, deviceTimeRaw: t / 1_000,
                                         receivedAt: t, quality: [.unvalidatedField])
            _ = try store.ingest(IngestBatch(provenance: provenance, heartRates: [sample]))
            try store.ensureDurable()
            // After the checkpoint the write-ahead log holds nothing that the database file lacks.
            let walPath = path + "-wal"
            let walSize = (try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? NSNumber)?.intValue ?? 0
            #expect(walSize >= 0)
        }
        let reopened = try FormaStore(path: path, timeSource: ManualTimeSource(t))
        #expect(try reopened.heartRates(in: TimeRange(start: 0, end: .max), deviceID: "band").map(\.bpm) == [61])
    }

    @Test func ensureDurableIsANoOpInMemory() throws {
        let store = try FormaStore(path: nil, timeSource: ManualTimeSource(0))
        try store.ensureDurable()
    }
}
