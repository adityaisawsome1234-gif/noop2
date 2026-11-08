import Foundation
import Testing
import FormaCore
@testable import FormaStore

@Suite("Ingest")
struct IngestTests {
    @Test func storesEveryRecordTypeWithProvenanceAndCursor() throws {
        let store = try makeStore()
        let heartRates = [hr(t0, 58, deviceTimeRaw: 1_000, clockOffset: -250), hr(t0 + 1_000, 59), hr(t0 + 2_000, 60)]
        let intervals = [rr(t0 + 500, 1_017.578125, recordKey: t0, index: 0), rr(t0 + 1_500, 998.046875, recordKey: t0, index: 1)]
        let epochs = [motionEpoch(t0, activity: 0.012)]
        let aux = [auxMeasurement(t0, .batteryPercent, 81, validated: true)]
        let batch = IngestBatch(provenance: provenance(note: "history chunk 1"), heartRates: heartRates,
                                beatIntervals: intervals, motion: epochs, aux: aux, cursor: cursor(newest: t0 + 2_000))
        let result = try store.ingest(batch)
        #expect(result.inserted == 7)
        #expect(result.duplicates == 0)
        #expect(result.batchID > 0)

        #expect(try store.provenance(batchID: result.batchID) == provenance(note: "history chunk 1"))
        let storedHR = try store.heartRates(in: everything)
        #expect(withoutBatch(storedHR) == heartRates)
        #expect(storedHR.allSatisfy { $0.batchID == result.batchID })
        #expect(withoutBatch(try store.beatIntervals(in: everything)) == intervals)
        #expect(withoutBatch(try store.motion(in: everything)) == epochs)
        #expect(withoutBatch(try store.aux(in: everything)) == aux)
        #expect(try store.syncCursor(deviceID: deviceA) == cursor(newest: t0 + 2_000))
        #expect(try store.syncCursor(deviceID: deviceB) == nil)
    }

    @Test func missingOptionalValuesReadBackAsNilNotZero() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 64)]))
        let sample = try #require(try store.heartRates(in: everything).first)
        #expect(sample.deviceTimeRaw == nil)
        #expect(sample.clockOffsetMillis == nil)
        let rawColumns = try store.withConnectionForTesting { db in
            try db.query("SELECT typeof(device_time_raw), typeof(clock_offset_ms) FROM hr_sample") {
                [$0.string(0), $0.string(1)]
            }
        }
        #expect(rawColumns == [["null", "null"]])
    }

    @Test func repeatedDownloadsAreDeduplicated() throws {
        let store = try makeStore()
        let heartRates = (0..<50).map { hr(t0 + Int64($0) * 1_000, 60 + $0 % 7) }
        let intervals = (0..<20).map { rr(t0 + Int64($0) * 900, 900, recordKey: t0 + Int64($0 / 4), index: $0 % 4) }
        let batch = IngestBatch(provenance: provenance(), heartRates: heartRates, beatIntervals: intervals)
        let first = try store.ingest(batch)
        let second = try store.ingest(batch)
        #expect(first.inserted == 70 && first.duplicates == 0)
        #expect(second.inserted == 0 && second.duplicates == 70)
        #expect(second.batchID != first.batchID)

        // A partially overlapping re-download stores only what is new.
        let extended = IngestBatch(provenance: provenance(), heartRates: (40..<60).map { hr(t0 + Int64($0) * 1_000, 70) })
        let third = try store.ingest(extended)
        #expect(third.inserted == 10 && third.duplicates == 10)

        let counts = try store.tableCounts()
        #expect(counts["hr_sample"] == 60)
        #expect(counts["beat_interval"] == 20)
        #expect(counts["ingest_batch"] == 3)
        // First write wins: the overlapping samples keep their original values.
        #expect(try store.heartRates(in: TimeRange(start: t0 + 40_000, end: t0 + 41_000)).map(\.bpm) == [60 + 40 % 7])
    }

    @Test func duplicatesInsideOneBatchAreCounted() throws {
        let store = try makeStore()
        let result = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60), hr(t0, 61)]))
        #expect(result.inserted == 1)
        #expect(result.duplicates == 1)
    }

    @Test func liveAndHistoryCopiesOfTheSameMomentAreKeptSeparately() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(source: .liveVendorStream),
                                         heartRates: [hr(t0, 72, source: .liveVendorStream)]))
        let history = try store.ingest(IngestBatch(provenance: provenance(source: .deviceHistory),
                                                   heartRates: [hr(t0, 71, source: .deviceHistory)]))
        #expect(history.inserted == 1)
        #expect(try store.heartRates(in: everything).map(\.source) == [.liveVendorStream, .deviceHistory])
        #expect(try store.heartRates(in: everything, sources: [.deviceHistory]).map(\.bpm) == [71])
        #expect(try store.heartRates(in: everything, sources: [.liveVendorStream]).map(\.bpm) == [72])
        #expect(try store.heartRates(in: everything, sources: []).isEmpty)
    }

    @Test func outOfOrderInsertsReadBackSorted() throws {
        let store = try makeStore()
        var generator = SplitMix64(seed: 0x5EED)
        let timestamps = (0..<300).map { t0 + Int64($0) * 1_000 }
        let shuffled = timestamps.shuffled(using: &generator)
        for chunk in stride(from: 0, to: shuffled.count, by: 37) {
            let slice = shuffled[chunk..<min(chunk + 37, shuffled.count)]
            _ = try store.ingest(IngestBatch(provenance: provenance(),
                                             heartRates: slice.map { hr($0, 60) },
                                             motion: slice.map { motionEpoch($0, activity: 0.01) }))
        }
        #expect(try store.heartRates(in: everything).map(\.timestamp) == timestamps)
        #expect(try store.motion(in: everything).map(\.timestamp) == timestamps)
        let window = TimeRange(start: t0 + 10_000, end: t0 + 20_000)
        #expect(try store.heartRates(in: window).map(\.timestamp) == Array(timestamps[10..<20]))
    }

    @Test func invalidRecordMidBatchWritesNothingAndKeepsTheCursor() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(), cursor: cursor(newest: t0 - 1, opaque: [7])))
        let before = try store.tableCounts()
        let batch = IngestBatch(provenance: provenance(),
                                heartRates: [hr(t0, 60), hr(t0 + 1_000, 61)],
                                beatIntervals: [rr(t0, 1_000, recordKey: t0, index: 0),
                                                rr(t0 + 1, .nan, recordKey: t0, index: 1)],
                                cursor: cursor(newest: t0 + 1_000, opaque: [8]))
        let error = #expect(throws: StoreError.self) { try store.ingest(batch) }
        #expect(error == .invalidRecord("beatIntervals[1].intervalMillis is not a finite number"))
        #expect(try store.tableCounts() == before)
        #expect(try store.syncCursor(deviceID: deviceA) == cursor(newest: t0 - 1, opaque: [7]))
    }

    @Test func databaseFailureMidBatchRollsBackEverything() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(), cursor: cursor(newest: t0 - 1, opaque: [7])))
        // Make the third beat interval fail inside SQLite, after earlier records were written.
        try store.withConnectionForTesting { db in
            try db.execute("""
                CREATE TRIGGER fail_third_interval BEFORE INSERT ON beat_interval WHEN NEW.idx = 2
                BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
                """)
        }
        let before = try store.tableCounts()
        let batch = IngestBatch(provenance: provenance(),
                                heartRates: (0..<5).map { hr(t0 + Int64($0) * 1_000, 60) },
                                beatIntervals: (0..<4).map { rr(t0 + Int64($0) * 900, 900, recordKey: t0, index: $0) },
                                aux: [auxMeasurement(t0, .batteryPercent, 50)],
                                cursor: cursor(newest: t0 + 5_000, opaque: [9]))
        let error = #expect(throws: SQLiteError.self) { try store.ingest(batch) }
        #expect(error?.message == "injected failure")
        #expect(try store.tableCounts() == before)
        #expect(try store.heartRates(in: everything).isEmpty)
        #expect(try store.syncCursor(deviceID: deviceA) == cursor(newest: t0 - 1, opaque: [7]))
        // The store stays usable afterwards.
        try store.withConnectionForTesting { db in try db.execute("DROP TRIGGER fail_third_interval") }
        #expect(try store.ingest(batch).inserted == 10)
    }

    @Test func emptyOrMismatchedDeviceIDsAreRejected() throws {
        let store = try makeStore()
        #expect(throws: StoreError.invalidRecord("provenance.deviceID is empty")) {
            try store.ingest(IngestBatch(provenance: provenance("")))
        }
        #expect(throws: StoreError.invalidRecord("heartRates[0].deviceID is empty")) {
            try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60, device: "")]))
        }
        #expect(throws: StoreError.self) {
            try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60, device: deviceB)]))
        }
        #expect(throws: StoreError.self) {
            try store.ingest(IngestBatch(provenance: provenance(), cursor: cursor(deviceB, newest: nil)))
        }
        #expect(throws: StoreError.self) {
            try store.ingest(IngestBatch(provenance: provenance(String(repeating: "x", count: 300))))
        }
        #expect(try store.tableCounts()["ingest_batch"] == 0)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteValuesAreRejected(_ bad: Double) throws {
        let store = try makeStore()
        #expect(throws: StoreError.self) {
            try store.ingest(IngestBatch(provenance: provenance(), motion: [motionEpoch(t0, activity: bad)]))
        }
        #expect(throws: StoreError.self) {
            try store.ingest(IngestBatch(provenance: provenance(), aux: [auxMeasurement(t0, .skinTemperatureCelsius, bad)]))
        }
        #expect(throws: StoreError.self) {
            try store.ingest(IngestBatch(provenance: provenance(), beatIntervals: [rr(t0, bad, recordKey: 1, index: 0)]))
        }
        #expect(try store.tableCounts().values.reduce(0, +) == 0)
    }

    @Test func structurallyImpossibleValuesAreRejected() throws {
        let store = try makeStore()
        #expect(throws: StoreError.self) {
            try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, -1)]))
        }
        #expect(throws: StoreError.self) {
            try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 70_000)]))
        }
        #expect(throws: StoreError.self) {
            try store.ingest(IngestBatch(provenance: provenance(), motion: [motionEpoch(t0, activity: 0.1, samples: -1)]))
        }
        var zeroLength = motionEpoch(t0, activity: 0.1)
        zeroLength.epochMillis = 0
        #expect(throws: StoreError.self) {
            try store.ingest(IngestBatch(provenance: provenance(), motion: [zeroLength]))
        }
        #expect(throws: StoreError.self) {
            try store.ingest(IngestBatch(provenance: provenance(), beatIntervals: [rr(t0, 900, recordKey: 1, index: -1)]))
        }
    }

    @Test func flaggedButPlausibleRecordsAreStoredAsIs() throws {
        let store = try makeStore()
        let flagged = [
            hr(t0, 250, quality: [.outOfRange]),
            hr(t0 + 1_000, 0, quality: [.deviceMarkedInvalid, .noSensorContact]),
            hr(t0 + 2_000, 61, quality: QualityFlags(rawValue: 1 << 40)),
        ]
        let interval = rr(t0, 2_600, recordKey: 5, index: 0, quality: [.outOfRange])
        let result = try store.ingest(IngestBatch(provenance: provenance(), heartRates: flagged, beatIntervals: [interval]))
        #expect(result.inserted == 4)
        #expect(withoutBatch(try store.heartRates(in: everything)) == flagged)
        #expect(withoutBatch(try store.beatIntervals(in: everything)) == [interval])
    }

    @Test func cursorChangesOnlyWhenABatchCarriesOne() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60)], cursor: cursor(newest: t0)))
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0 + 1_000, 60)]))
        #expect(try store.syncCursor(deviceID: deviceA)?.newestPersistedRecordTime == t0)
        let next = SyncCursor(deviceID: deviceA, adapterID: "whoop5", opaque: nil, newestPersistedRecordTime: t0 + 1_000,
                              lastCompleteSyncAt: t0 + 2_000, updatedAt: t0 + 3_000)
        _ = try store.ingest(IngestBatch(provenance: provenance(), cursor: next))
        #expect(try store.syncCursor(deviceID: deviceA) == next)
        #expect(try store.syncCursors() == [next])
        #expect(try store.deleteSyncCursor(deviceID: deviceA))
        #expect(try store.syncCursor(deviceID: deviceA) == nil)
        #expect(try !store.deleteSyncCursor(deviceID: deviceA))
    }

    @Test func emptyBatchStillRecordsProvenance() throws {
        let store = try makeStore()
        let result = try store.ingest(IngestBatch(provenance: provenance()))
        #expect(result == IngestResult(batchID: result.batchID, inserted: 0, duplicates: 0))
        #expect(try store.provenance(batchID: result.batchID) != nil)
    }

    @Test func queriesFilterByDeviceSourceAndKind() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(deviceA), heartRates: [hr(t0, 60, device: deviceA)],
                                         beatIntervals: [rr(t0, 1_000, recordKey: 1, index: 0, device: deviceA)],
                                         motion: [motionEpoch(t0, activity: 0.1, device: deviceA)],
                                         aux: [auxMeasurement(t0, .batteryPercent, 80, device: deviceA),
                                               auxMeasurement(t0, .skinTemperatureCelsius, 33.5, device: deviceA)]))
        _ = try store.ingest(IngestBatch(provenance: provenance(deviceB), heartRates: [hr(t0, 90, device: deviceB)],
                                         beatIntervals: [rr(t0, 700, recordKey: 1, index: 0, device: deviceB)],
                                         motion: [motionEpoch(t0, activity: 0.2, device: deviceB)],
                                         aux: [auxMeasurement(t0 + 1, .batteryPercent, 40, device: deviceB)]))
        #expect(try store.heartRates(in: everything, deviceID: deviceB).map(\.bpm) == [90])
        #expect(try store.heartRates(in: everything).map(\.deviceID) == [deviceA, deviceB])
        #expect(try store.beatIntervals(in: everything, deviceID: deviceA).map(\.intervalMillis) == [1_000])
        #expect(try store.motion(in: everything, deviceID: deviceB).map(\.activity) == [0.2])
        #expect(try store.aux(in: everything, kinds: [.batteryPercent]).map(\.value) == [80, 40])
        #expect(try store.aux(in: everything, kinds: [.batteryPercent], deviceID: deviceA).map(\.value) == [80])
        #expect(try store.aux(in: everything, kinds: [.spo2Percent]).isEmpty)
        #expect(try store.aux(in: everything, kinds: []).isEmpty)
        #expect(try store.heartRates(in: TimeRange(start: t0 + 1, end: t0 + 10)).isEmpty)
        #expect(try store.heartRates(in: TimeRange(start: t0, end: t0)).isEmpty)
    }

    @Test func newestSampleTimeAndDataBounds() throws {
        let store = try makeStore()
        #expect(try store.newestSampleTime() == nil)
        #expect(try store.dataBounds() == nil)
        _ = try store.ingest(IngestBatch(provenance: provenance(deviceA), heartRates: [hr(t0, 60)],
                                         aux: [auxMeasurement(t0 + 9_000, .batteryPercent, 70)]))
        _ = try store.ingest(IngestBatch(provenance: provenance(deviceB),
                                         motion: [motionEpoch(t0 - 4_000, activity: 0.1, device: deviceB)]))
        #expect(try store.newestSampleTime() == t0 + 9_000)
        #expect(try store.newestSampleTime(deviceID: deviceB) == t0 - 4_000)
        #expect(try store.newestSampleTime(deviceID: "nobody") == nil)
        #expect(try store.dataBounds() == TimeRange(start: t0 - 4_000, end: t0 + 9_001))
    }
}
