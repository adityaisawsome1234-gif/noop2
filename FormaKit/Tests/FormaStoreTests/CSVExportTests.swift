import Foundation
import Testing
import FormaCore
@testable import FormaStore

@Suite("CSV export")
struct CSVExportTests {
    @Test func everyFileIsWrittenWithUnitBearingHeaders() throws {
        let store = try makeStore()
        try populate(store)
        let directory = try TemporaryDirectory()
        let exportDirectory = directory.url.appendingPathComponent("export", isDirectory: true)
        let urls = try store.exportCSV(to: exportDirectory, range: nil)
        #expect(urls.map(\.lastPathComponent) == ["hr_samples.csv", "beat_intervals.csv", "motion_epochs.csv",
                                                  "aux_measurements.csv", "sessions.csv", "derived_metrics.csv",
                                                  "devices.csv"])
        for (url, file) in zip(urls, FormaStore.CSVFile.allCases) {
            let records = try readCSV(url)
            #expect(records.first == file.columns)
            #expect(records.count == 2, "\(file.rawValue) should hold one data row")
            #expect(records.dropFirst().allSatisfy { $0.count == file.columns.count })
        }
        #expect(FormaStore.CSVFile.heartRates.columns.contains("bpm"))
        #expect(FormaStore.CSVFile.beatIntervals.columns.contains("interval_ms"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path(percentEncoded: false))
        #expect(leftovers.sorted() == urls.map(\.lastPathComponent).sorted())

        // Exporting again replaces the files.
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0 + 1_000, 61)]))
        let again = try store.exportCSV(to: exportDirectory)
        #expect(try readCSV(again[0]).count == 3)
    }

    @Test func heartRateRowsCarryCodesNamesAndEmptyCellsForMissingValues() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [
            hr(t0, 61, quality: [.outOfRange, .clockOffsetApplied], deviceTimeRaw: 123_456, clockOffset: -250),
            hr(t0 + 1_000, 62),
        ]))
        let directory = try TemporaryDirectory()
        let urls = try store.exportCSV(to: directory.url)
        let table = try CSVTable(readCSV(urls[0]))
        #expect(table.rows.count == 2)
        #expect(try table.value(0, "ts_epoch_ms") == String(t0))
        #expect(try table.value(0, "ts_utc_iso8601") == "2026-03-01T00:00:00.000Z")
        #expect(try table.value(0, "device_id") == deviceA)
        #expect(try table.value(0, "bpm") == "61")
        #expect(try table.value(0, "source") == "2")
        #expect(try table.value(0, "source_name") == "band history")
        #expect(try table.value(0, "device_time_raw") == "123456")
        #expect(try table.value(0, "received_at_epoch_ms") == String(t0 + 5_000))
        #expect(try table.value(0, "clock_offset_ms") == "-250")
        #expect(try table.value(0, "quality_flags") == "10")
        #expect(try table.value(0, "quality_flag_names") == "clockOffsetApplied|outOfRange")
        #expect(try table.value(0, "batch_id") == "1")
        #expect(try table.value(1, "ts_utc_iso8601") == "2026-03-01T00:00:01.000Z")
        // Missing values are empty cells, never 0.
        #expect(try table.value(1, "device_time_raw") == "")
        #expect(try table.value(1, "clock_offset_ms") == "")
        #expect(try table.value(1, "quality_flags") == "0")
        #expect(try table.value(1, "quality_flag_names") == "")
    }

    @Test func otherMeasurementFilesUseTheirUnits() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(),
                                         beatIntervals: [rr(t0, 830.078125, recordKey: 42, index: 3)],
                                         motion: [motionEpoch(t0, activity: 0.00001, samples: 25)],
                                         aux: [auxMeasurement(t0, .skinTemperatureCelsius, 33.5)]))
        let directory = try TemporaryDirectory()
        let urls = try store.exportCSV(to: directory.url)
        let intervals = try CSVTable(readCSV(urls[1]))
        #expect(try intervals.value(0, "interval_ms") == "830.078125")
        #expect(try intervals.value(0, "record_key") == "42")
        #expect(try intervals.value(0, "index_in_record") == "3")
        #expect(try intervals.value(0, "timing_basis") == "2")
        #expect(try intervals.value(0, "timing_basis_name") == "reconstructedFromRecordTime")
        let motion = try CSVTable(readCSV(urls[2]))
        #expect(try motion.value(0, "epoch_length_ms") == "1000")
        #expect(try motion.value(0, "activity") == "1e-05")
        #expect(try motion.value(0, "sample_count") == "25")
        let aux = try CSVTable(readCSV(urls[3]))
        #expect(try aux.value(0, "kind") == "skinTemperatureCelsius")
        #expect(try aux.value(0, "value") == "33.5")
        #expect(try aux.value(0, "unit") == "degC")
        #expect(try aux.value(0, "validated") == "0")
        #expect(try aux.value(0, "quality_flag_names") == "unvalidatedField")
    }

    @Test func textFieldsAreQuotedPerRFC4180() throws {
        let store = try makeStore()
        let label = "Run, \"fast\"\r\nsecond line"
        try store.insertSession(Session(kind: .workout, range: TimeRange(start: t0, end: t0 + 90_000), origin: .manual,
                                        label: label, createdAt: t0, updatedAt: t0))
        try store.putDerived([DerivedMetricRecord(metricID: "rmssd", specVersion: 1,
                                                  window: TimeRange(start: t0, end: t0 + 1), value: nil, unit: "ms",
                                                  availability: "insufficientData: needs 3 h, have 1 h", coverage: nil,
                                                  confidence: .none, inputsJSON: "{\"beats\":\"1,2\"}", computedAt: t0)])
        try store.upsertDevice(DeviceRecord(id: deviceA, family: .whoop5, name: "WHOOP \"MG\"", firstSeen: t0))
        let directory = try TemporaryDirectory()
        let urls = try store.exportCSV(to: directory.url)

        let sessions = try CSVTable(readCSV(urls[4]))
        #expect(try sessions.value(0, "label") == label)
        #expect(try sessions.value(0, "duration_s") == "90.0")
        #expect(try sessions.value(0, "detector_confidence_0_1") == "")
        #expect(try sessions.value(0, "detector") == "")
        #expect(try sessions.value(0, "deleted") == "0")
        #expect(try sessions.value(0, "end_ts_utc_iso8601") == "2026-03-01T00:01:30.000Z")
        let raw = try String(contentsOf: urls[4], encoding: .utf8)
        #expect(raw.contains(",\"Run, \"\"fast\"\"\r\nsecond line\","))

        let derived = try CSVTable(readCSV(urls[5]))
        #expect(try derived.value(0, "value") == "")
        #expect(try derived.value(0, "coverage_0_1") == "")
        #expect(try derived.value(0, "confidence") == "none")
        #expect(try derived.value(0, "inputs_json") == "{\"beats\":\"1,2\"}")
        #expect(try derived.value(0, "availability") == "insufficientData: needs 3 h, have 1 h")

        let devices = try CSVTable(readCSV(urls[6]))
        #expect(try devices.value(0, "name") == "WHOOP \"MG\"")
        #expect(try devices.value(0, "last_connected_epoch_ms") == "")
        #expect(try devices.value(0, "last_connected_utc_iso8601") == "")
    }

    @Test func rangeLimitsMeasurementsSessionsAndDerivedValues() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(),
                                         heartRates: (0..<10).map { hr(t0 + Int64($0) * 1_000, 60 + $0) }))
        try store.insertSession(Session(kind: .workout, range: TimeRange(start: t0, end: t0 + 2_000), origin: .manual,
                                        createdAt: t0, updatedAt: t0))
        try store.insertSession(Session(kind: .workout, range: TimeRange(start: t0 + 8_000, end: t0 + 9_000),
                                        origin: .manual, createdAt: t0, updatedAt: t0))
        let directory = try TemporaryDirectory()
        let urls = try store.exportCSV(to: directory.url, range: TimeRange(start: t0 + 3_000, end: t0 + 8_500))
        let heartRates = try CSVTable(readCSV(urls[0]))
        #expect(heartRates.rows.map { $0[3] } == ["63", "64", "65", "66", "67", "68"])
        #expect(try CSVTable(readCSV(urls[4])).rows.count == 1)
    }

    @Test func largeExportsAreStreamedAcrossManyPages() throws {
        let store = try makeStore()
        let count = 10_000
        _ = try store.ingest(IngestBatch(provenance: provenance(),
                                         heartRates: (0..<count).map { hr(t0 + Int64($0) * 1_000, 40 + $0 % 100) }))
        // Same timestamp from a second source, to exercise the (ts, rowid) page boundary.
        _ = try store.ingest(IngestBatch(provenance: provenance(source: .liveVendorStream),
                                         heartRates: (0..<count).map { hr(t0 + Int64($0) * 1_000, 99, source: .liveVendorStream) }))
        var seen: [EpochMillis] = []
        try store.forEachPage(.heartRate, range: nil, pageSize: 333, decode: RowDecoder.heartRate) { page in
            #expect(page.count <= 333)
            seen += page.map(\.timestamp)
        }
        #expect(seen.count == 2 * count)
        #expect(seen == seen.sorted())
        let directory = try TemporaryDirectory()
        let urls = try store.exportCSV(to: directory.url)
        #expect(try readCSV(urls[0]).count == 2 * count + 1)
    }

    @Test(arguments: MeasurementTable.allCases, [false, true])
    func exportPagingUsesTheTimestampIndexWithoutSorting(_ table: MeasurementTable, _ hasRange: Bool) throws {
        let store = try makeStore()
        // The exact statement forEachPage runs (not a copy), with and without a range bound.
        let sql = FormaStore.pageSQL(table, hasRange: hasRange)
        var values: [any SQLiteValueConvertible] = [0, 0, 0]
        if hasRange { values.append(1) }
        values.append(10)
        let plan = try store.withConnectionForTesting { db in
            try db.query("EXPLAIN QUERY PLAN " + sql, values) { $0.string(3) }
        }
        #expect(plan.contains { $0.contains("idx_\(table.name)_ts") }, "\(plan)")
        #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
    }

    @Test func iso8601FormattingCoversTheWholeRange() {
        #expect(TextFormat.iso8601UTC(0) == "1970-01-01T00:00:00.000Z")
        #expect(TextFormat.iso8601UTC(-1) == "1969-12-31T23:59:59.999Z")
        #expect(TextFormat.iso8601UTC(951_782_400_000) == "2000-02-29T00:00:00.000Z")
        #expect(TextFormat.iso8601UTC(t0 + 3_723_004) == "2026-03-01T01:02:03.004Z")
        #expect(TextFormat.iso8601UTC(253_402_300_799_999) == "9999-12-31T23:59:59.999Z")
        #expect(TextFormat.iso8601UTC(253_402_300_800_000) == "+010000-01-01T00:00:00.000Z")
        #expect(TextFormat.iso8601UTC(-62_167_219_200_000) == "0000-01-01T00:00:00.000Z")
        #expect(TextFormat.iso8601UTC(-62_167_219_200_001) == "-000001-12-31T23:59:59.999Z")
        #expect(TextFormat.iso8601UTC(.min).hasSuffix("Z"))
        #expect(TextFormat.iso8601UTC(.max).hasSuffix("Z"))
    }

    @Test func iso8601FormattingAgreesWithFoundationCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        var generator = SplitMix64(seed: 20_261_108)
        for _ in 0..<2_000 {
            // Whole seconds between 1900 and 2200 (exact as Double), plus a millisecond part.
            let seconds = Int64(generator.next() % 9_467_280_000) - 2_208_988_800
            let millis = Int64(generator.next() % 1_000)
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                from: Date(timeIntervalSince1970: TimeInterval(seconds)))
            func two(_ value: Int?) -> String { let v = value ?? -1; return v < 10 ? "0\(v)" : "\(v)" }
            let three = millis < 10 ? "00\(millis)" : millis < 100 ? "0\(millis)" : "\(millis)"
            let expected = "\(parts.year ?? -1)-\(two(parts.month))-\(two(parts.day))T\(two(parts.hour)):"
                + "\(two(parts.minute)):\(two(parts.second)).\(three)Z"
            #expect(TextFormat.iso8601UTC(seconds * 1_000 + millis) == expected)
        }
    }

    @Test func fieldEscapingAndFlagNames() {
        #expect(CSVWriter.escape("plain") == "plain")
        #expect(CSVWriter.escape("") == "")
        #expect(CSVWriter.escape("a,b") == "\"a,b\"")
        #expect(CSVWriter.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVWriter.escape("crlf\r\nline") == "\"crlf\r\nline\"")
        #expect(CSVWriter.escape("lf\nonly") == "\"lf\nonly\"")
        #expect(CSVWriter.escape("caf\u{E9} \u{1F3C3}") == "caf\u{E9} \u{1F3C3}")
        #expect(CSVField.flagNames([]) == "")
        #expect(CSVField.flagNames(QualityFlags(rawValue: (1 << 3) | (1 << 40) | Int64.min)) == "outOfRange|bit40|bit63")
        #expect(CSVField.number(.nan) == nil)
        #expect(CSVField.number(nil) == nil)
        #expect(CSVField.int(Optional<Int64>.none) == nil)
    }
}
