// Final integration review: a restored measurement keeps the adapter and firmware its field-validation
// verdict is keyed by, and settings a caller withholds are never written by an import, not even by one
// that stops midway or runs again.

import Foundation
import Testing
import FormaCore
@testable import FormaStore

private struct StopAfterFirstChunk: Error {}
private struct MissingBatch: Error {}

/// The provenance of the batch that stored a record.
private func batch(_ batchID: Int64?, in store: FormaStore) throws -> Provenance {
    guard let batchID, let provenance = try store.provenance(batchID: batchID) else { throw MissingBatch() }
    return provenance
}

private func lines(_ url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
}

private func write(_ lines: [String], to url: URL) throws {
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
}

private let header = #"{"format":"forma-backup","formatVersion":1,"schemaVersion":2,"exportedAt":1,"app":"Forma"}"#

private func settingLine(_ key: String, _ value: String) -> String {
    #"{"type":"setting","data":{"key":"\#(key)","value":"\#(value)"}}"#
}

private func hrLine(_ ts: EpochMillis, adapter: String? = nil, firmware: String? = nil) -> String {
    var origin = ""
    if let adapter { origin += #","adapter_id":"\#(adapter)""# }
    if let firmware { origin += #","firmware":"\#(firmware)""# }
    return #"{"type":"hr","data":{"device_id":"band-A","ts_ms":\#(ts),"bpm":60,"source":2,"device_time_raw":null,"#
        + #""received_at":\#(ts),"clock_offset_ms":null,"quality":0\#(origin)}}"#
}

@Suite("Backup: origin and withheld settings")
struct BackupOriginAndWithholdingTests {
    static let perPhone: Set<String> = ["historySyncMode", "historyAcknowledgement", "fieldValidation.historyHR.whoop5.50.1.2"]

    static func withhold(_ key: String) -> Bool { perPhone.contains(key) }

    /// A file whose settings come first and whose records need more than one chunk.
    static func twoChunkFile(_ directory: TemporaryDirectory) throws -> URL {
        let url = directory.file("two-chunks.ndjson")
        var file = [header, settingLine("historySyncMode", "automatic"), settingLine("historyAcknowledgement", "1"),
                    settingLine("fieldValidation.historyHR.whoop5.50.1.2", "passed"), settingLine("units", "metric")]
        file += (0..<(FormaStore.importChunkSize + 10)).map { hrLine(t0 + Int64($0) * 1_000) }
        try write(file, to: url)
        return url
    }

    @Test func withheldSettingsAreNeverWrittenWhenTheImportStopsMidwayOrRunsAgain() throws {
        let directory = try TemporaryDirectory()
        let url = try Self.twoChunkFile(directory)
        let store = try makeStore()
        #expect(throws: StopAfterFirstChunk.self) {
            try store.importBackup(from: url, withholdingSettings: Self.withhold, afterChunk: { if $0 == 1 { throw StopAfterFirstChunk() } })
        }
        // The first chunk (settings and the first records) is committed; the withheld keys are not in it.
        #expect(try store.setting(forKey: "units") == "metric")
        #expect(try store.heartRates(in: everything).count == FormaStore.importChunkSize - 4)
        for key in Self.perPhone { #expect(try store.setting(forKey: key) == nil, "\(key)") }

        // Running it again (a retry after the failure) applies the rest, never the withheld keys.
        let report = try store.importBackup(from: url, withholdingSettings: Self.withhold)
        for key in Self.perPhone { #expect(try store.setting(forKey: key) == nil, "\(key)") }
        #expect(report.settingsWithheld == 3)
        #expect(report.notApplied[.setting] == 3)
        #expect(report.duplicates[.setting] == 1)
        #expect(report.inserted[.hr] == 14)
        #expect(try store.heartRates(in: everything).count == FormaStore.importChunkSize + 10)
    }

    @Test func withoutARuleSettingsAreAppliedAsBefore() throws {
        let directory = try TemporaryDirectory()
        let url = try Self.twoChunkFile(directory)
        let store = try makeStore()
        let report = try store.importBackup(from: url)
        #expect(report.settingsWithheld == 0)
        #expect(try store.setting(forKey: "historySyncMode") == "automatic")
    }

    /// Restored band history is matched to its adapter-and-firmware verdict through its batch: the import
    /// batch keeps the original adapter and firmware (one batch per device, adapter and firmware).
    @Test func restoredMeasurementsKeepTheirAdapterAndFirmware() throws {
        let source = try makeStore()
        func origin(_ firmware: String?) -> Provenance {
            Provenance(deviceID: deviceA, adapterID: "whoop5", parserVersion: "1.0.0", firmwareVersion: firmware,
                       source: .deviceHistory, syncRunID: nil, createdAt: t0)
        }
        _ = try source.ingest(IngestBatch(provenance: origin("50.1.2"), heartRates: (0..<5).map { hr(t0 + Int64($0) * 1_000, 60) },
                                          motion: [motionEpoch(t0, activity: 0.1)], aux: [auxMeasurement(t0, .batteryPercent, 80)]))
        _ = try source.ingest(IngestBatch(provenance: origin("50.2.0"), heartRates: (5..<9).map { hr(t0 + Int64($0) * 1_000, 61) },
                                          beatIntervals: [rr(t0 + 5_000, 900, recordKey: 1, index: 0)]))
        _ = try source.ingest(IngestBatch(provenance: origin(nil), heartRates: [hr(t0 + 20_000, 62)]))
        let directory = try TemporaryDirectory()
        let url = directory.file("origin.ndjson")
        try source.exportBackup(to: url)
        #expect(try lines(url).filter { $0.contains(#""type":"hr""#) }.allSatisfy { $0.contains(#""adapter_id":"whoop5""#) })

        let target = try makeStore(time: ManualTimeSource(t0 + 1_000_000))
        let report = try target.importBackup(from: url)
        #expect(report.invalidLines == 0, "\(report.errors)")
        #expect(report.batchIDs.count == 3, "one batch per device, adapter and firmware")
        func firmware(of batchID: Int64?) throws -> String?? {
            let provenance = try batch(batchID, in: target)
            #expect(provenance.adapterID == "whoop5")
            #expect(provenance.source == .backupImport)
            #expect(provenance.note == "origin.ndjson")
            #expect(provenance.parserVersion == "forma-backup/1")
            return .some(provenance.firmwareVersion)
        }
        for sample in try target.heartRates(in: everything) {
            let expected: String? = sample.bpm == 60 ? "50.1.2" : (sample.bpm == 61 ? "50.2.0" : nil)
            #expect(try firmware(of: sample.batchID) == .some(expected), "\(sample.bpm)")
        }
        #expect(try firmware(of: try target.motion(in: everything).first?.batchID) == .some("50.1.2"))
        #expect(try firmware(of: try target.aux(in: everything).first?.batchID) == .some("50.1.2"))
        #expect(try firmware(of: try target.beatIntervals(in: everything).first?.batchID) == .some("50.2.0"))

        // A second round trip keeps them too.
        let again = directory.file("again.ndjson")
        try target.exportBackup(to: again)
        let third = try makeStore()
        _ = try third.importBackup(from: again)
        let firmwares = try Set(third.heartRates(in: everything).map { try batch($0.batchID, in: third).firmwareVersion })
        #expect(firmwares == ["50.1.2", "50.2.0", nil])
    }

    /// Files written before the origin was carried import as before: provenance unknown.
    @Test func linesWithoutAnOriginGetTheBackupImportAdapter() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("old.ndjson")
        try write([header, hrLine(t0), hrLine(t0 + 1_000, adapter: nil, firmware: "9.9")], to: url)
        let store = try makeStore()
        let report = try store.importBackup(from: url)
        #expect(report.inserted[.hr] == 2 && report.batchIDs.count == 1)
        let provenance = try batch(report.batchIDs.first, in: store)
        #expect(provenance.adapterID == FormaStore.backupImportAdapterID)
        #expect(provenance.firmwareVersion == nil, "a firmware without an adapter identifies nothing")
    }

    @Test func hostileOriginsAreRejectedOrBounded() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("hostile.ndjson")
        var file = [header,
                    hrLine(t0, adapter: ""),
                    hrLine(t0 + 1, adapter: String(repeating: "a", count: 257)),
                    hrLine(t0 + 2, adapter: "whoop5", firmware: String(repeating: "9", count: 257))]
        let distinct = FormaStore.maxImportOrigins + 20
        file += (0..<distinct).map { hrLine(t0 + 1_000 + Int64($0), adapter: "adapter-\($0)", firmware: "1") }
        try write(file, to: url)
        let store = try makeStore()
        let report = try store.importBackup(from: url)
        #expect(report.invalidLines == 3, "\(report.errors)")
        #expect(report.errors.contains { $0.hasPrefix("line 2:") && $0.contains("adapter_id") })
        #expect(report.errors.contains { $0.hasPrefix("line 4:") && $0.contains("firmware") })
        #expect(report.inserted[.hr] == distinct)
        // Bounded bookkeeping: past the limit, records go to the device's batch without an adapter.
        #expect(report.batchIDs.count == FormaStore.maxImportOrigins + 1)
        let adapters = try Set(store.heartRates(in: everything).map { try batch($0.batchID, in: store).adapterID })
        #expect(adapters.contains(FormaStore.backupImportAdapterID))
    }

    @Test(arguments: MeasurementTable.allCases, [false, true])
    func exportPagingWithOriginUsesTheTimestampIndexWithoutSorting(_ table: MeasurementTable, _ hasRange: Bool) throws {
        let store = try makeStore()
        let sql = FormaStore.pageSQL(table, hasRange: hasRange, withOrigin: true)
        var values: [any SQLiteValueConvertible] = [0, 0, 0]
        if hasRange { values.append(1) }
        values.append(10)
        let plan = try store.withConnectionForTesting { db in
            try db.query("EXPLAIN QUERY PLAN " + sql, values) { $0.string(3) }
        }
        #expect(plan.contains { $0.contains("idx_\(table.name)_ts") }, "\(plan)")
        #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
        #expect(plan.contains { $0.contains("ingest_batch") || $0.contains(" b ") }, "\(plan)")
    }
}

/// Schema v2 identifies a band record by its raw band time. A skipped record whose stored match differs in
/// stored time (beyond the clock tolerance) or in raw band time may be a distinct record — after the band
/// clock was set back, a band second can be reused — so ingest reports it apart (the engine then never
/// acknowledges its chunk).
@Suite("Ingest: ambiguous band-record duplicates")
struct AmbiguousDuplicateTests {
    static func history(_ ts: EpochMillis, raw: Int64?, bpm: Int = 60) -> HeartRateSample {
        hr(ts, bpm, deviceTimeRaw: raw)
    }

    static func motion(_ ts: EpochMillis, raw: Int64?) -> MotionEpoch {
        MotionEpoch(deviceID: deviceA, timestamp: ts, epochMillis: 60_000, activity: 0.1, sampleCount: 10, source: .deviceHistory,
                    deviceTimeRaw: raw)
    }

    @Test func reSentRecordsAreClearDuplicatesAndReusedBandSecondsAreAmbiguous() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [Self.history(t0, raw: 100)],
                                         motion: [Self.motion(t0, raw: 100)]))
        // The same record downloaded again, mapped with a correction 1 s different: a plain duplicate.
        let resent = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [Self.history(t0 + 1_000, raw: 100)],
                                                  motion: [Self.motion(t0 + 1_000, raw: 100)]))
        #expect(resent.duplicates == 2 && resent.ambiguousDuplicates == 0)
        // Band second 100 again, 6 s later on the timeline (the band clock was set back by 6 s).
        let reused = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [Self.history(t0 + 6_000, raw: 100, bpm: 61)],
                                                  motion: [Self.motion(t0 + 6_000, raw: 100)]))
        #expect(reused.inserted == 0 && reused.duplicates == 2 && reused.ambiguousDuplicates == 2)
        // Another band second on an already stored time.
        let collided = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [Self.history(t0, raw: 101)],
                                                    motion: [Self.motion(t0, raw: 101)]))
        #expect(collided.duplicates == 2 && collided.ambiguousDuplicates == 2)
        // Records without a raw band time keep the v1 meaning: a duplicate time is a duplicate.
        let live = try store.ingest(IngestBatch(provenance: provenance(source: .standardHeartRateService),
                                                heartRates: [hr(t0, 60, source: .standardHeartRateService)]))
        _ = live
        let again = try store.ingest(IngestBatch(provenance: provenance(source: .standardHeartRateService),
                                                 heartRates: [hr(t0, 60, source: .standardHeartRateService)]))
        #expect(again.duplicates == 1 && again.ambiguousDuplicates == 0)
    }
}
