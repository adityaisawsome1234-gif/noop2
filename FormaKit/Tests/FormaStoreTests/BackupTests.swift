import Foundation
import Testing
import FormaCore
@testable import FormaStore

private let hour = EpochMillis.millisPerHour

/// Session fields that must survive a backup (ids are reassigned on import).
private struct SessionFacts: Hashable {
    let kind: SessionKind, start: EpochMillis, end: EpochMillis, origin: SessionOrigin, label: String?
    let deviceID: String?, detector: String?, confidence: Double?, createdAt: EpochMillis, updatedAt: EpochMillis
    let deleted: Bool

    init(_ s: Session) {
        kind = s.kind; start = s.range.start; end = s.range.end; origin = s.origin; label = s.label
        deviceID = s.deviceID; detector = s.detector; confidence = s.confidence; createdAt = s.createdAt
        updatedAt = s.updatedAt; deleted = s.deleted
    }
}

/// Corrections keyed by the facts of the session they belong to.
private func correctionFacts(_ store: FormaStore) throws -> [String] {
    let sessions = Dictionary(uniqueKeysWithValues: try store.sessions(includeDeleted: true).map { ($0.id ?? -1, $0) })
    return try store.corrections().map { c in
        let owner = c.sessionID.flatMap { sessions[$0] }.map { "\($0.kind.rawValue)@\($0.range.start)" } ?? "none"
        return "\(owner) \(c.field) \(c.oldValue ?? "nil")→\(c.newValue ?? "nil") @\(c.createdAt)"
    }.sorted()
}

/// A store holding every backed-up record type: two devices, history + live + standard-service data,
/// an edited candidate, a manual and a deleted session, settings, a profile and a cursor.
private func richStore() throws -> FormaStore {
    let store = try makeStore(time: ManualTimeSource(t0 + 24 * hour))
    try store.upsertDevice(DeviceRecord(id: deviceA, family: .whoop5, name: "WHOOP \"A\"\n", firmwareVersion: "50.1",
                                        hardwareRevision: "MG", firstSeen: t0 - 1_000, lastConnected: t0))
    try store.upsertDevice(DeviceRecord(id: deviceB, family: .standardHeartRate, name: "Strap", firstSeen: t0))
    _ = try store.ingest(IngestBatch(
        provenance: provenance(deviceA),
        heartRates: (0..<30).map { hr(t0 + Int64($0) * 1_000, 55 + $0, deviceTimeRaw: Int64($0) * 32, clockOffset: 12) },
        beatIntervals: (0..<12).map { rr(t0 + Int64($0) * 800, 800 + Double($0) * 0.9765625,
                                         recordKey: t0 + Int64($0 / 3) * 1_000, index: $0 % 3) },
        motion: (0..<5).map { motionEpoch(t0 + Int64($0) * 60_000, activity: 0.0123 * Double($0)) },
        aux: [auxMeasurement(t0, .skinTemperatureCelsius, 33.25), auxMeasurement(t0, .batteryPercent, 77, validated: true)],
        cursor: cursor(newest: t0 + 29_000, opaque: [0xDE, 0xAD, 0xBE, 0xEF])))
    _ = try store.ingest(IngestBatch(provenance: provenance(deviceA, source: .liveVendorStream),
                                     heartRates: [hr(t0, 99, source: .liveVendorStream, quality: [.phoneReceiveTime])]))
    _ = try store.ingest(IngestBatch(provenance: provenance(deviceB, source: .standardHeartRateService),
                                     heartRates: [hr(t0 + 500, 70, device: deviceB, source: .standardHeartRateService,
                                                     quality: [.phoneReceiveTime])]))
    let night = try store.insertSession(Session(kind: .sleep, range: TimeRange(start: t0 - 8 * hour, end: t0),
                                                origin: .detectedCandidate, deviceID: deviceA, detector: "sleep/1",
                                                confidence: 0.75, createdAt: t0, updatedAt: t0))
    var edited = try #require(try store.session(id: night))
    edited.origin = .userEdited
    edited.range = TimeRange(start: t0 - 7 * hour, end: t0)
    try store.updateSession(edited)
    try store.insertSession(Session(kind: .workout, range: TimeRange(start: t0 + hour, end: t0 + 2 * hour),
                                    origin: .manual, label: "Intervals, 6\u{D7}400 \"hard\"", createdAt: t0, updatedAt: t0))
    let removed = try store.insertSession(Session(kind: .workout, range: TimeRange(start: t0 + 3 * hour, end: t0 + 4 * hour),
                                                  origin: .detectedCandidate, confidence: 0.4, createdAt: t0, updatedAt: t0))
    try store.softDeleteSession(id: removed)
    try store.setUserProfile(UserProfile(birthYear: 1985, sex: .male, maxHeartRateOverride: 190))
    try store.setSetting("metric", forKey: "units")
    try store.setRawCaptureEnabled(true)
    return store
}

private func writeLines(_ lines: [String], to url: URL) throws {
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
}

private let validHeader = #"{"format":"forma-backup","formatVersion":1,"schemaVersion":1,"exportedAt":1,"app":"Forma"}"#

private func hrLine(_ ts: EpochMillis, bpm: String = "60", source: String = "2", extra: String = "") -> String {
    #"{"type":"hr","data":{"device_id":"band-A","ts_ms":\#(ts),"bpm":\#(bpm),"source":\#(source),"#
        + #""device_time_raw":null,"received_at":\#(ts),"clock_offset_ms":null,"quality":0\#(extra)}}"#
}

@Suite("Backup")
struct BackupTests {
    @Test func roundTripIntoAFreshStoreKeepsEverything() throws {
        let source = try richStore()
        let directory = try TemporaryDirectory()
        let url = directory.file("forma-backup.ndjson")
        let summary = try source.exportBackup(to: url)
        #expect(summary.counts == [.device: 2, .setting: 2, .cursor: 1, .session: 3, .correction: 3, .hr: 32, .rr: 12,
                                   .motion: 5, .aux: 2])
        #expect(summary.lineCount == summary.totalRecords + 1)
        #expect(summary.byteCount == Int64(try Data(contentsOf: url).count))
        #expect(summary.exportedAt == t0 + 24 * hour)
        #expect(summary.measurementRange == TimeRange(start: t0, end: t0 + 240_001))
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false) + ".partial"))

        let target = try makeStore(time: ManualTimeSource(t0 + 48 * hour))
        let report = try target.importBackup(from: url)
        #expect(report.invalidLines == 0)
        #expect(report.errors.isEmpty)
        #expect(report.fileName == "forma-backup.ndjson")
        #expect(report.formatVersion == 1)
        #expect(report.sourceSchemaVersion == FormaStore.schemaVersion)
        #expect(report.exportedAt == t0 + 24 * hour)
        #expect(report.inserted == [.device: 2, .setting: 2, .session: 3, .correction: 3, .hr: 32, .rr: 12, .motion: 5,
                                    .aux: 2])
        #expect(report.totalDuplicates == 0)
        #expect(report.notApplied == [.cursor: 1])

        #expect(withoutBatch(try target.heartRates(in: everything)) == withoutBatch(try source.heartRates(in: everything)))
        #expect(withoutBatch(try target.beatIntervals(in: everything)) == withoutBatch(try source.beatIntervals(in: everything)))
        #expect(withoutBatch(try target.motion(in: everything)) == withoutBatch(try source.motion(in: everything)))
        #expect(withoutBatch(try target.aux(in: everything)) == withoutBatch(try source.aux(in: everything)))
        #expect(try target.devices() == source.devices())
        #expect(Set(try target.sessions(includeDeleted: true).map(SessionFacts.init))
                    == Set(try source.sessions(includeDeleted: true).map(SessionFacts.init)))
        #expect(try correctionFacts(target) == correctionFacts(source))
        #expect(try target.userProfile() == UserProfile(birthYear: 1985, sex: .male, maxHeartRateOverride: 190))
        #expect(try target.setting(forKey: "units") == "metric")
        // Device-local settings are not carried over.
        #expect(try target.rawCaptureEnabled() == false)

        // Cursors are reported but never applied to sync state.
        #expect(try target.syncCursor(deviceID: deviceA) == nil)
        #expect(report.cursorsNotApplied == [cursor(newest: t0 + 29_000, opaque: [0xDE, 0xAD, 0xBE, 0xEF])])

        // Imported measurements carry backup-import provenance, one batch per device.
        #expect(report.batchIDs.count == 2)
        for batchID in report.batchIDs {
            let provenance = try #require(try target.provenance(batchID: batchID))
            #expect(provenance.source == .backupImport)
            #expect(provenance.note == "forma-backup.ndjson")
            #expect(provenance.createdAt == t0 + 48 * hour)
        }
        #expect(try target.heartRates(in: everything).allSatisfy { report.batchIDs.contains($0.batchID ?? -1) })
        // Measurements keep their original source, so live and history copies stay apart.
        #expect(try target.heartRates(in: everything, sources: [.liveVendorStream]).map(\.bpm) == [99])

        // Everything new is inside the reported range (sessions included).
        let range = try #require(report.importedRange)
        #expect(range == TimeRange(start: t0 - 7 * hour, end: t0 + 4 * hour))
    }

    @Test func importingTheSameFileTwiceAddsNothing() throws {
        let source = try richStore()
        let directory = try TemporaryDirectory()
        let url = directory.file("backup.ndjson")
        try source.exportBackup(to: url)
        let target = try makeStore()
        let first = try target.importBackup(from: url)
        let countsAfterFirst = try target.tableCounts()
        let second = try target.importBackup(from: url)
        #expect(second.totalInserted == 0)
        #expect(second.duplicates == first.inserted)
        #expect(second.importedRange == nil)
        // Not even a provenance row: batches whose records were all duplicates are removed again.
        #expect(second.batchIDs.isEmpty)
        #expect(try target.tableCounts() == countsAfterFirst)
    }

    @Test func restoringIntoTheOriginalStoreAddsNothing() throws {
        let store = try richStore()
        let directory = try TemporaryDirectory()
        let url = directory.file("self.ndjson")
        try store.exportBackup(to: url)
        let before = try store.tableCounts()
        let report = try store.importBackup(from: url)
        #expect(report.totalInserted == 0)
        #expect(report.invalidLines == 0)
        #expect(report.duplicates[.session] == 3)
        #expect(report.duplicates[.correction] == 3)
        #expect(report.notApplied == [.cursor: 1])
        #expect(report.batchIDs.isEmpty)
        #expect(try store.tableCounts() == before)
    }

    @Test func malformedLinesAreSkippedCountedAndExplained() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("damaged.ndjson")
        let oversized = #"{"type":"hr","data":{"pad":""# + String(repeating: "x", count: 1_200_000) + #""}}"#
        try writeLines([
            validHeader,                                                                   // 1
            hrLine(t0),                                                                    // 2 ok
            "{not json",                                                                   // 3
            hrLine(t0 + 1, bpm: "\"fast\""),                                               // 4 wrong type
            #"{"type":"rr","data":{"device_id":"band-A","ts_ms":1,"interval_ms":NaN,"source":2,"record_key":1,"idx":0,"received_at":1,"timing_basis":2,"quality":0}}"#, // 5
            #"{"type":"rr","data":{"device_id":"band-A","ts_ms":1,"interval_ms":"NaN","source":2,"record_key":1,"idx":0,"received_at":1,"timing_basis":2,"quality":0}}"#, // 6
            hrLine(t0 + 2, source: "7"),                                                   // 7 unknown source
            #"{"type":"hr","data":{"device_id":"band-A","ts_ms":5,"source":2,"received_at":5,"quality":0}}"#, // 8 no bpm
            #"{"type":"aux","data":{"device_id":"band-A","ts_ms":5,"kind":"batteryPercent","value":1e400,"source":2,"validated":true,"quality":0}}"#, // 9
            #"{"type":"teleport","data":{}}"#,                                             // 10
            #"{"type":"session","data":{"id":1,"kind":"sleep","start_ms":10,"end_ms":5,"origin":"manual","created_at":1,"updated_at":1,"deleted":false}}"#, // 11
            #"{"type":"motion","data":{"device_id":"band-A","ts_ms":5,"epoch_ms":1000,"activity":0.1,"sample_count":-1,"source":2,"quality":0}}"#, // 12
            #"{"type":"correction","data":{"session_id":424242,"field":"label","old_value":null,"new_value":"x","created_at":1}}"#, // 13
            "[1,2,3]",                                                                     // 14
            oversized,                                                                     // 15
            "",                                                                            // 16 blank: ignored
            hrLine(t0 + 3, extra: #","future_field":"ignored""#),                         // 17 ok
            #"{"type":"hr","data":{"device_id":"","ts_ms":5,"bpm":60,"source":2,"received_at":5,"quality":0}}"#, // 18
            #"{"type":"setting","data":{"key":"","value":"x"}}"#,                          // 19
            #"{"type":"cursor","data":{"device_id":"band-A","adapter_id":"whoop5","opaque":"%%%","updated_at":1}}"#, // 20
        ], to: url)
        let store = try makeStore()
        let report = try store.importBackup(from: url)
        #expect(report.inserted == [.hr: 2])
        #expect(report.invalidLines == 16)
        #expect(report.errors.count == 16)
        #expect(report.errors[0] == "line 3: not valid JSON")
        #expect(report.errors[1] == "line 4: wrong type for 'data.bpm'")
        #expect(report.errors[2] == "line 5: not valid JSON")
        #expect(report.errors[3] == "line 6: wrong type for 'data.interval_ms'")
        #expect(report.errors[4] == "line 7: unknown source '7'")
        #expect(report.errors[5] == "line 8: missing field 'data.bpm'")
        #expect(report.errors[6].hasPrefix("line 9: "))
        #expect(report.errors[7] == "line 10: unknown record type 'teleport'")
        #expect(report.errors[8] == "line 11: session end_ms is before start_ms")
        #expect(report.errors[9] == "line 12: data.sampleCount is negative")
        #expect(report.errors[10] == "line 13: correction refers to session 424242, which is not in this backup")
        #expect(report.errors[11] == "line 14: expected a JSON object")
        #expect(report.errors[12].hasPrefix("line 15: line is 12000"))
        #expect(report.errors[13] == "line 18: data.deviceID is empty")
        #expect(report.errors[14] == "line 19: setting key is empty")
        #expect(report.errors[15] == "line 20: cursor opaque is not base64")
        #expect(try store.heartRates(in: everything).map(\.timestamp) == [t0, t0 + 3])
        #expect(try store.tableCounts()["aux_measurement"] == 0)
    }

    @Test func onlyTheFirstTwentyErrorsAreKept() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("noisy.ndjson")
        try writeLines([validHeader] + (0..<30).map { "garbage \($0)" } + [hrLine(t0)], to: url)
        let report = try makeStore().importBackup(from: url)
        #expect(report.invalidLines == 30)
        #expect(report.errors.count == ImportReport.maxRecordedErrors)
        #expect(report.errors.last == "line 21: not valid JSON")
        #expect(report.inserted[.hr] == 1)
    }

    @Test func newerFormatVersionIsRefused() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("future.ndjson")
        try writeLines([#"{"format":"forma-backup","formatVersion":2,"schemaVersion":9,"exportedAt":1,"app":"Forma"}"#,
                        hrLine(t0)], to: url)
        let store = try makeStore()
        #expect(throws: StoreError.unsupportedBackupVersion(found: 2, supported: 1)) { try store.importBackup(from: url) }
        #expect(try store.tableCounts().values.allSatisfy { $0 == 0 })
    }

    @Test(arguments: [
        ("", "the file is empty"),
        ("hello", "the first line is not a Forma backup header"),
        (#"{"format":"other-app","formatVersion":1}"#, "format is 'other-app', expected 'forma-backup'"),
        (#"{"format":"forma-backup","formatVersion":0}"#, "formatVersion 0 is not valid"),
        (#"{"format":"forma-backup"}"#, "the first line is not a Forma backup header"),
    ])
    func unusableHeadersAreRefused(_ firstLine: String, _ reason: String) throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("bad.ndjson")
        try writeLines([firstLine], to: url)
        #expect(throws: StoreError.invalidBackup(reason)) { try makeStore().importBackup(from: url) }
    }

    @Test func missingFileIsAFileError() throws {
        let directory = try TemporaryDirectory()
        #expect(throws: StoreError.self) { try makeStore().importBackup(from: directory.file("absent.ndjson")) }
    }

    @Test func headerAndRecordLinesHaveTheDocumentedShape() throws {
        let store = try makeStore(time: ManualTimeSource(t0 + 7))
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 61)], cursor: cursor(newest: nil)))
        let directory = try TemporaryDirectory()
        let url = directory.file("shape.ndjson")
        try store.exportBackup(to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines[0] == #"{"format":"forma-backup","formatVersion":1,"schemaVersion":2,"exportedAt":\#(t0 + 7),"app":"Forma"}"#)
        #expect(lines.contains(#"{"type":"cursor","data":{"device_id":"band-A","adapter_id":"whoop5","opaque":"AQID","newest_record_ms":null,"last_complete_ms":null,"updated_at":\#(t0)}}"#))
        #expect(lines.contains(#"{"type":"hr","data":{"device_id":"band-A","ts_ms":\#(t0),"bpm":61,"source":2,"device_time_raw":null,"received_at":\#(t0 + 5_000),"clock_offset_ms":null,"quality":0,"adapter_id":"whoop5","firmware":"50.1.2"}}"#))
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            #expect(object != nil)
        }
    }

    @Test func importsAreAppliedInChunksAcrossManyRecords() throws {
        let source = try makeStore()
        let count = FormaStore.importChunkSize * 2 + 17
        _ = try source.ingest(IngestBatch(provenance: provenance(),
                                          heartRates: (0..<count).map { hr(t0 + Int64($0) * 1_000, 50 + $0 % 50) }))
        let directory = try TemporaryDirectory()
        let url = directory.file("big.ndjson")
        try source.exportBackup(to: url)
        let target = try makeStore()
        let report = try target.importBackup(from: url)
        #expect(report.inserted[.hr] == count)
        #expect(report.batchIDs.count == 1)
        #expect(withoutBatch(try target.heartRates(in: everything)) == withoutBatch(try source.heartRates(in: everything)))
    }

    @Test func exportReplacesAnExistingFile() throws {
        let store = try makeStore()
        let directory = try TemporaryDirectory()
        let url = directory.file("replace.ndjson")
        try Data("old content".utf8).write(to: url)
        let summary = try store.exportBackup(to: url)
        #expect(summary.lineCount == 1)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix(#"{"format":"forma-backup""#))
    }

    @Test(arguments: [UInt64(1), 2, 3, 4])
    func importSurvivesRandomlyCorruptedLines(seed: UInt64) throws {
        let source = try richStore()
        let directory = try TemporaryDirectory()
        let clean = directory.file("clean.ndjson")
        try source.exportBackup(to: clean)
        let lines = try String(contentsOf: clean, encoding: .utf8).split(separator: "\n").map { Array($0.utf8) }
        var generator = SplitMix64(seed: seed)
        var corrupted = [lines[0]]
        for line in lines.dropFirst() {
            var bytes = line
            for _ in 0..<Int(generator.next() % 4) where !bytes.isEmpty {
                let position = Int(generator.next() % UInt64(bytes.count))
                var byte = UInt8(truncatingIfNeeded: generator.next())
                if byte == 0x0A || byte == 0x0D { byte = 0x00 }
                switch generator.next() % 3 {
                case 0: bytes[position] = byte
                case 1: bytes.remove(at: position)
                default: bytes.insert(byte, at: position)
                }
            }
            corrupted.append(bytes)
        }
        let url = directory.file("corrupted.ndjson")
        try Data(corrupted.joined(separator: [0x0A])).write(to: url)
        let target = try makeStore()
        let report = try target.importBackup(from: url)
        let blank = corrupted.dropFirst().filter { $0.allSatisfy { $0 == 0x20 || $0 == 0x09 } }.count
        let accounted = report.totalInserted + report.totalDuplicates + report.notApplied.values.reduce(0, +)
            + report.invalidLines
        #expect(accounted == corrupted.count - 1 - blank)
        #expect(report.invalidLines > 0)
        #expect(report.totalInserted > 0)
        #expect(report.errors.count == min(report.invalidLines, ImportReport.maxRecordedErrors))
        // Whatever was accepted reads back and re-exports cleanly.
        try target.exportBackup(to: directory.file("again.ndjson"))
        #expect(try makeStore().importBackup(from: directory.file("again.ndjson")).invalidLines == 0)
    }

    @Test func exportNeverDeletesADirectoryAtTheDestination() throws {
        let store = try makeStore()
        let directory = try TemporaryDirectory()
        let precious = directory.url.appendingPathComponent("precious", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: precious.appendingPathComponent("note.txt"))
        #expect(throws: StoreError.self) { try store.exportBackup(to: precious) }
        #expect(try String(contentsOf: precious.appendingPathComponent("note.txt"), encoding: .utf8) == "keep me")

        // A CSV "directory" that is actually a file is refused too.
        let file = directory.file("not-a-directory")
        try Data("x".utf8).write(to: file)
        #expect(throws: StoreError.self) { try store.exportCSV(to: file) }
        #expect(try Data(contentsOf: file) == Data("x".utf8))

        // Missing parent directories of a backup file are created.
        let nested = directory.url.appendingPathComponent("a/b/backup.ndjson")
        #expect(try store.exportBackup(to: nested).lineCount == 1)
        #expect(FileManager.default.fileExists(atPath: nested.path(percentEncoded: false)))
    }

    @Test func extremeValuesNeverTrapAndImportAdmitsOnlyTheTimeWindow() throws {
        let store = try makeStore()
        let extremes = [
            HeartRateSample(deviceID: deviceA, timestamp: .min, bpm: 0, source: .deviceHistory, deviceTimeRaw: .max,
                            receivedAt: .max, clockOffsetMillis: .min, quality: [.outOfRange, QualityFlags(rawValue: .min)]),
            HeartRateSample(deviceID: deviceA, timestamp: .max, bpm: 65_535, source: .deviceHistory, receivedAt: .min,
                            quality: [.outOfRange]),
        ]
        let edge = rr(0, -.greatestFiniteMagnitude, recordKey: .min, index: .max)
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: extremes, beatIntervals: [edge]))
        try store.insertSession(Session(kind: .sleep, range: TimeRange(start: .min, end: .max), origin: .manual,
                                        createdAt: .min, updatedAt: .max))
        // Ingest stores what the sync engine delivers, extreme times included.
        #expect(try store.dataBounds() == TimeRange(start: .min, end: .max))
        #expect(try store.newestSampleTime() == .max)

        let directory = try TemporaryDirectory()
        let urls = try store.exportCSV(to: directory.url)
        let sessions = try CSVTable(readCSV(urls[4]))
        #expect(try sessions.value(0, "duration_s") == "")
        #expect(try CSVTable(readCSV(urls[0])).rows.count == 2)

        // A backup is untrusted input: timeline values outside the window are reported, not restored,
        // so nothing derived from an import can overflow (the old behaviour handed out [min, max)).
        let url = directory.file("extreme.ndjson")
        try store.exportBackup(to: url)
        let restored = try makeStore()
        let report = try restored.importBackup(from: url)
        #expect(report.invalidLines == 3, "the session and both heart rates: \(report.errors)")
        #expect(report.errors.count == 3)
        #expect(report.errors.allSatisfy { $0.contains("outside the importable time range") })
        #expect(report.inserted == [.rr: 1])
        let range = try #require(report.importedRange)
        #expect(range == TimeRange(start: 0, end: 1))
        #expect(range.durationMillis == 1)
        #expect(try restored.dataBounds() == TimeRange(start: 0, end: 1))
        #expect(withoutBatch(try restored.beatIntervals(in: everything)) == [edge])
        #expect(try restored.sessions(includeDeleted: true).isEmpty)
    }

    @Test func importToleratesCRLFAndAByteOrderMark() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("windows.ndjson")
        let text = "\u{FEFF}" + validHeader + "\r\n" + hrLine(t0) + "\r\n" + hrLine(t0 + 1_000)
        try Data(text.utf8).write(to: url)
        let report = try makeStore().importBackup(from: url)
        #expect(report.inserted[.hr] == 2)
        #expect(report.invalidLines == 0)
    }
}

@Suite("Bounded line reader")
struct LineReaderTests {
    private func lines(_ text: String, max: Int, chunk: Int) throws -> [String] {
        let directory = try TemporaryDirectory()
        let url = directory.file("lines.txt")
        try Data(text.utf8).write(to: url)
        let reader = try BoundedLineReader(url: url, maxLineBytes: max, chunkSize: chunk)
        var out: [String] = []
        while let line = try reader.next() {
            switch line {
            case .text(let bytes): out.append(String(decoding: bytes, as: UTF8.self))
            case .tooLong(let count): out.append("<too long: \(count)>")
            }
        }
        return out
    }

    @Test(arguments: [1, 3, 7, 64, 4_096])
    func splitsLinesRegardlessOfChunkSize(_ chunk: Int) throws {
        #expect(try lines("a\nbb\r\n\nccc", max: 10, chunk: chunk) == ["a", "bb", "", "ccc"])
        #expect(try lines("one\n", max: 10, chunk: chunk) == ["one"])
        #expect(try lines("", max: 10, chunk: chunk).isEmpty)
        #expect(try lines("exactly10!\nnext", max: 10, chunk: chunk) == ["exactly10!", "next"])
        #expect(try lines("eleven char\nnext", max: 10, chunk: chunk) == ["<too long: 11>", "next"])
        #expect(try lines("short\n" + String(repeating: "z", count: 100) + "\nafter\n", max: 10, chunk: chunk)
                    == ["short", "<too long: 100>", "after"])
        #expect(try lines(String(repeating: "q", count: 50), max: 10, chunk: chunk) == ["<too long: 50>"])
    }
}
