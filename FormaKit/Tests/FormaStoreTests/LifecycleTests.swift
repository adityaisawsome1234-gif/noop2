import Foundation
import Testing
import FormaCore
@testable import FormaStore

/// Fills every table with at least one row.
func populate(_ store: FormaStore) throws {
    try store.upsertDevice(DeviceRecord(id: deviceA, family: .whoop5, name: "WHOOP", firstSeen: t0))
    _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60)],
                                     beatIntervals: [rr(t0, 1_000, recordKey: 1, index: 0)],
                                     motion: [motionEpoch(t0, activity: 0.1)],
                                     aux: [auxMeasurement(t0, .batteryPercent, 90)], cursor: cursor(newest: t0)))
    try store.setRawCaptureEnabled(true)
    try store.recordRawFrame(RawFrameRecord(deviceID: deviceA, receivedAt: t0, characteristic: "c", bytes: Data([1]),
                                            parseStatus: "ok"))
    try store.recordConnectionEvent(ConnectionEvent(deviceID: deviceA, timestamp: t0, kind: .connected))
    _ = try store.beginSyncRun(SyncRunRecord(deviceID: deviceA, startedAt: t0, status: .running))
    let sessionID = try store.insertSession(Session(kind: .sleep, range: TimeRange(start: t0, end: t0 + 1_000),
                                                    origin: .manual, createdAt: t0, updatedAt: t0))
    var edited = try #require(try store.session(id: sessionID))
    edited.label = "edited"
    try store.updateSession(edited)
    try store.putDerived([DerivedMetricRecord(metricID: "m", specVersion: 1, window: TimeRange(start: t0, end: t0 + 1),
                                              value: 1, unit: "u", availability: "available", coverage: 1,
                                              confidence: .high, inputsJSON: "{}", computedAt: t0)])
    try store.setUserProfile(UserProfile(birthYear: 1990))
}

@Suite("Deletion and persistence")
struct LifecycleTests {
    @Test func deleteAllDataEmptiesEveryTable() throws {
        let store = try makeStore()
        try populate(store)
        #expect(try store.tableCounts().values.allSatisfy { $0 > 0 })
        try store.deleteAllData()
        #expect(try store.tableCounts().values.allSatisfy { $0 == 0 })
        #expect(try store.rawCaptureEnabled() == false)
        // The store keeps working afterwards.
        #expect(try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60)])).inserted == 1)
    }

    @Test func deleteAllDataCanKeepSettings() throws {
        let store = try makeStore()
        try populate(store)
        try store.deleteAllData(keepSettings: true)
        let counts = try store.tableCounts()
        #expect(counts["setting"] == 2)
        #expect(counts.filter { $0.key != "setting" }.values.allSatisfy { $0 == 0 })
        #expect(try store.userProfile() == UserProfile(birthYear: 1990))
        #expect(try store.rawCaptureEnabled())
    }

    @Test func deleteAllDataShrinksTheFile() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("shrink.sqlite")
        let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
        let samples = (0..<20_000).map { hr(t0 + Int64($0) * 1_000, 60 + $0 % 40) }
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: samples))
        try store.withConnectionForTesting { db in try db.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
        let fullSize = try fileSize(path)
        try store.deleteAllData()
        let emptySize = try fileSize(path)
        #expect(emptySize < fullSize / 4)
        #expect(try fileSize(path + "-wal") == 0)
    }

    private func fileSize(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.size] as? NSNumber)?.intValue ?? -1
    }

    @Test func fileDatabaseKeepsDataAcrossCloseAndReopen() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("forma.sqlite")
        var store: FormaStore? = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
        try populate(try #require(store))
        let expectedCounts = try store?.tableCounts()
        store?.close()
        #expect(store?.isOpen == false)
        #expect(throws: StoreError.closed) { _ = try store?.tableCounts() }
        store = nil

        let reopened = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
        #expect(reopened.isOpen)
        #expect(try reopened.tableCounts() == expectedCounts)
        #expect(try reopened.heartRates(in: everything).map(\.bpm) == [60])
        #expect(try reopened.syncCursor(deviceID: deviceA) == cursor(newest: t0))
        #expect(try reopened.userProfile() == UserProfile(birthYear: 1990))
    }

    @Test func closedStoreThrowsFromEveryEntryPoint() throws {
        let store = try makeStore()
        store.close()
        store.close()
        #expect(throws: StoreError.closed) { try store.ingest(IngestBatch(provenance: provenance())) }
        #expect(throws: StoreError.closed) { _ = try store.heartRates(in: everything) }
        #expect(throws: StoreError.closed) { try store.recordRawFrame(RawFrameRecord(deviceID: nil, receivedAt: 0,
                                                                                    characteristic: "c", bytes: Data(),
                                                                                    parseStatus: "ok")) }
        #expect(throws: StoreError.closed) { try store.setSetting("v", forKey: "k") }
        #expect(throws: StoreError.closed) { try store.deleteAllData() }
    }

    @Test func destroyDatabaseFilesRemovesTheDatabaseAndItsCompanions() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("doomed.sqlite")
        do {
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            try populate(store)
            #expect(FileManager.default.fileExists(atPath: path + "-wal"))
        }
        try FormaStore.destroyDatabaseFiles(at: path)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            #expect(!FileManager.default.fileExists(atPath: path + suffix))
        }
        try FormaStore.destroyDatabaseFiles(at: path)
        try FormaStore.destroyDatabaseFiles(at: ":memory:")
        let fresh = try FormaStore(path: path)
        #expect(try fresh.tableCounts().values.allSatisfy { $0 == 0 })
    }
}
