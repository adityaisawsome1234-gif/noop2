// Regression tests for the review findings fixed after the first implementation round:
// backup snapshot consistency, session identity on import, import-side timeline validation,
// bounded import memory, provenance hygiene, settings conflicts, wipe/cancellation during long
// operations, file safety (atomic replace, own-database guard, untouched refused files), durable
// history commits and conservative row decoding.

import Foundation
import Testing
import FormaCore
@testable import FormaStore

private let hour = EpochMillis.millisPerHour
private let header = #"{"format":"forma-backup","formatVersion":1,"schemaVersion":1,"exportedAt":1,"app":"Forma"}"#

private func writeLines(_ lines: [String], to url: URL) throws {
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
}

private func hrLine(_ ts: String, bpm: Int = 60, quality: Int64 = 0) -> String {
    #"{"type":"hr","data":{"device_id":"band-A","ts_ms":\#(ts),"bpm":\#(bpm),"source":2,"device_time_raw":null,"#
        + #""received_at":1,"clock_offset_ms":null,"quality":\#(quality)}}"#
}

private func sessionLine(id: Int, start: String, end: String) -> String {
    #"{"type":"session","data":{"id":\#(id),"kind":"sleep","start_ms":\#(start),"end_ms":\#(end),"origin":"manual","#
        + #""label":null,"device_id":null,"detector":null,"confidence":null,"created_at":1,"updated_at":1,"deleted":false}}"#
}

private func settingLine(_ key: String, _ value: String) -> String {
    #"{"type":"setting","data":{"key":\#(TextFormat.jsonString(key)),"value":\#(TextFormat.jsonString(value))}}"#
}

/// Corrections described by the facts of their session (ids differ between stores).
private func correctionFacts(_ store: FormaStore) throws -> [String] {
    var owners: [Int64: String] = [:]
    for session in try store.sessions(includeCandidates: true, includeDeleted: true) {
        if let id = session.id { owners[id] = "\(session.kind.rawValue)|\(session.range)|\(session.origin.rawValue)|\(session.deleted)" }
    }
    return try store.corrections().map { c in
        "\(c.sessionID.flatMap { owners[$0] } ?? "none")#\(c.field)#\(c.oldValue ?? "nil")#\(c.newValue ?? "nil")#\(c.createdAt)"
    }.sorted()
}

/// Thread-safe flag for multi-threaded tests.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Runs `body(index)` on `count` dedicated threads (all live at once) and waits for them.
private func runThreads(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) {
    let group = DispatchGroup()
    for index in 0..<count {
        group.enter()
        Thread {
            body(index)
            group.leave()
        }.start()
    }
    group.wait()
}

// MARK: - Backup snapshot and session identity

@Suite("Hardening: backup snapshot and sessions")
struct HardeningBackupSessionTests {
    @Test func exportsTakenWhileSessionsAreEditedAlwaysRestoreCleanly() throws {
        let store = try makeStore()
        // A sizeable session table widens the window an inconsistent export would need.
        for i in 0..<300 {
            let id = try store.insertSession(Session(kind: .workout, range: TimeRange(start: t0 + Int64(i) * hour,
                                                                                    end: t0 + Int64(i) * hour + 1_000),
                                                     origin: .manual, createdAt: t0, updatedAt: t0))
            var session = try #require(try store.session(id: id))
            session.label = "edited \(i)"
            try store.updateSession(session)
        }
        let directory = try TemporaryDirectory()
        let urls = (0..<6).map { directory.file("snapshot-\($0).ndjson") }
        let exportsDone = Flag()
        let errors = ErrorCollector()
        runThreads(2) { worker in
            if worker == 0 {
                for url in urls {
                    do { try store.exportBackup(to: url) } catch { errors.record(error) }
                }
                exportsDone.set()
                return
            }
            var i = 0
            while !exportsDone.isSet, i < 20_000 {
                do {
                    let id = try store.insertSession(Session(kind: .sleep, range: TimeRange(start: t0 - Int64(i + 1) * hour,
                                                                                          end: t0 - Int64(i) * hour),
                                                             origin: .detectedCandidate, createdAt: t0, updatedAt: t0))
                    if var session = try store.session(id: id) {
                        session.origin = .userConfirmed
                        try store.updateSession(session)
                    }
                } catch {
                    errors.record(error)
                }
                i += 1
            }
        }
        #expect(errors.errors.isEmpty)
        for url in urls {
            let report = try makeStore().importBackup(from: url)
            #expect(report.invalidLines == 0, "\(url.lastPathComponent): \(report.errors.prefix(3))")
            #expect((report.inserted[.correction] ?? 0) <= (report.inserted[.session] ?? 0))
        }
    }

    /// The user dismissed a detected night, the detector proposed the same window again and the user
    /// confirmed it: two sessions with equal kind, bounds and label, one deleted.
    private func storeWithEqualSessions() throws -> FormaStore {
        let time = ManualTimeSource(t0 + 10 * hour)
        let store = try makeStore(time: time)
        let range = TimeRange(start: t0, end: t0 + 8 * hour)
        let dismissed = try store.insertSession(Session(kind: .sleep, range: range, origin: .detectedCandidate,
                                                        detector: "sleep/1", confidence: 0.6, createdAt: t0, updatedAt: t0))
        try store.softDeleteSession(id: dismissed)
        time.advance(byMillis: 60_000)
        let proposed = try store.insertSession(Session(kind: .sleep, range: range, origin: .detectedCandidate,
                                                       detector: "sleep/1", confidence: 0.7, createdAt: t0 + 1, updatedAt: t0 + 1))
        var confirmed = try #require(try store.session(id: proposed))
        confirmed.origin = .userConfirmed
        try store.updateSession(confirmed)
        return store
    }

    @Test func equalSessionsInOneBackupStayDistinctInAFreshStore() throws {
        let source = try storeWithEqualSessions()
        let directory = try TemporaryDirectory()
        let url = directory.file("equal.ndjson")
        try source.exportBackup(to: url)
        let target = try makeStore()
        let report = try target.importBackup(from: url)
        #expect(report.invalidLines == 0)
        #expect(report.inserted[.session] == 2)
        #expect(report.duplicates[.session] == nil)
        #expect(report.inserted[.correction] == 2)
        // The confirmed night survives and is the one that counts; the dismissed one stays deleted.
        let active = try target.sessions(includeCandidates: false)
        #expect(active.map(\.origin) == [.userConfirmed])
        #expect(try target.sessions(includeDeleted: true).count == 2)
        #expect(try correctionFacts(target) == correctionFacts(source))

        // Importing the same file again adds nothing.
        let counts = try target.tableCounts()
        let again = try target.importBackup(from: url)
        #expect(again.totalInserted == 0)
        #expect(try target.tableCounts() == counts)
        #expect(try correctionFacts(target) == correctionFacts(source))
    }

    @Test func selfRestoreWithEqualSessionsChangesNothing() throws {
        let store = try storeWithEqualSessions()
        let directory = try TemporaryDirectory()
        let url = directory.file("self.ndjson")
        try store.exportBackup(to: url)
        let counts = try store.tableCounts()
        let facts = try correctionFacts(store)
        let report = try store.importBackup(from: url)
        #expect(report.totalInserted == 0)
        #expect(report.duplicates[.session] == 2)
        #expect(report.duplicates[.correction] == 2)
        #expect(try store.tableCounts() == counts)
        #expect(try correctionFacts(store) == facts)
    }

    @Test func deletedBackupSessionNeverAbsorbsAnActiveOne() throws {
        let range = TimeRange(start: t0, end: t0 + hour)
        let source = try makeStore(time: ManualTimeSource(t0 + 5 * hour))
        let removed = try source.insertSession(Session(kind: .workout, range: range, origin: .manual, createdAt: t0,
                                                       updatedAt: t0))
        try source.softDeleteSession(id: removed)
        let directory = try TemporaryDirectory()
        let url = directory.file("deleted.ndjson")
        try source.exportBackup(to: url)

        let target = try makeStore()
        let active = try target.insertSession(Session(kind: .workout, range: range, origin: .manual, createdAt: t0 + 7,
                                                      updatedAt: t0 + 7))
        let report = try target.importBackup(from: url)
        #expect(report.inserted[.session] == 1, "the deleted session is restored as its own row")
        #expect(try target.corrections(sessionID: active).isEmpty, "its 'deleted' correction is not attached to the active one")
        #expect(try target.sessions().compactMap(\.id) == [active])
        #expect(try target.sessions(includeDeleted: true).count == 2)
    }

    @Test func olderBackupDoesNotResurrectASessionDeletedLater() throws {
        let range = TimeRange(start: t0, end: t0 + hour)
        let store = try makeStore()
        let id = try store.insertSession(Session(kind: .workout, range: range, origin: .manual, createdAt: t0, updatedAt: t0))
        let directory = try TemporaryDirectory()
        let url = directory.file("older.ndjson")
        try store.exportBackup(to: url)
        try store.softDeleteSession(id: id)
        let report = try store.importBackup(from: url)
        #expect(report.duplicates[.session] == 1)
        #expect(try store.sessions().isEmpty, "the later deletion wins")
        #expect(try store.sessions(includeDeleted: true).count == 1)
    }
}

// MARK: - Import validation and bookkeeping

@Suite("Hardening: import validation and bookkeeping")
struct HardeningImportTests {
    @Test func importRejectsTimelineValuesOutsideTheWindow() throws {
        let window = FormaStore.backupTimeWindow
        #expect(window == TimeRange(start: 0, end: 253_402_300_800_000))
        #expect(TextFormat.iso8601UTC(window.end) == "+010000-01-01T00:00:00.000Z")
        let motion = { (epoch: String) in
            #"{"type":"motion","data":{"device_id":"band-A","ts_ms":5,"epoch_ms":\#(epoch),"activity":0.1,"#
                + #""sample_count":3,"source":2,"quality":0}}"#
        }
        let lines = [
            header,
            hrLine("-1"),                                              // 2 before 1970
            hrLine("-9223372036854775808"),                            // 3 Int64.min
            hrLine("253402300800000"),                                 // 4 window end (exclusive)
            hrLine("253402300799999"),                                 // 5 ok: last instant
            hrLine("0"),                                               // 6 ok: first instant
            #"{"type":"rr","data":{"device_id":"band-A","ts_ms":9223372036854775807,"interval_ms":800.0,"source":2,"#
                + #""record_key":1,"idx":0,"received_at":1,"timing_basis":2,"quality":0}}"#, // 7 Int64.max
            #"{"type":"aux","data":{"device_id":"band-A","ts_ms":-5,"kind":"batteryPercent","value":50.0,"source":2,"#
                + #""validated":true,"quality":0}}"#,                  // 8 negative
            motion("86400001"),                                        // 9 longer than a day
            motion("86400000"),                                        // 10 ok: exactly a day
            sessionLine(id: 1, start: "-5", end: "10"),                // 11 starts before the window
            sessionLine(id: 2, start: "0", end: "253402300800000"),    // 12 ok: ends at the window end
            sessionLine(id: 3, start: "-9223372036854775808", end: "9223372036854775807"), // 13 the whole Int64 line
        ]
        let directory = try TemporaryDirectory()
        let url = directory.file("timeline.ndjson")
        try writeLines(lines, to: url)
        let store = try makeStore()
        let report = try store.importBackup(from: url)
        #expect(report.invalidLines == 8, "\(report.errors)")
        #expect(report.errors.map { $0.prefix(8) } == ["line 2: ", "line 3: ", "line 4: ", "line 7: ", "line 8: ",
                                                       "line 9: ", "line 11:", "line 13:"])
        #expect(report.errors.filter { $0.contains("outside the importable time range") }.count == 7)
        #expect(report.errors[5] == "line 9: data.epoch_ms 86400001 is longer than 86400000 ms (one day)")
        #expect(report.inserted == [.hr: 2, .motion: 1, .session: 1])
        // Everything built from imported values stays representable.
        let range = try #require(report.importedRange)
        #expect(range == window)
        #expect(range.durationMillis == window.end)
        let sessions = try store.sessions()
        #expect(sessions.map(\.range.durationSeconds) == [Double(window.end) / 1_000])
        #expect(try store.dataBounds() == TimeRange(start: 0, end: window.end))
    }

    @Test func zeroBPMMustBeFlaggedAsInvalid() throws {
        let store = try makeStore()
        let error = #expect(throws: StoreError.self) {
            try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 61), hr(t0 + 1, 0)]))
        }
        #expect(error?.description.contains("heartRates[1].bpm is 0") == true)
        #expect(try store.tableCounts()["hr_sample"] == 0)
        // The sync engine flags a 0 as out of range; the device may mark it invalid or report no contact.
        let flagged: [QualityFlags] = [[.outOfRange], [.deviceMarkedInvalid], [.noSensorContact], [.outOfRange, .phoneReceiveTime]]
        let samples = flagged.enumerated().map { hr(t0 + Int64($0.offset), 0, quality: $0.element) }
        #expect(try store.ingest(IngestBatch(provenance: provenance(), heartRates: samples)).inserted == 4)

        let directory = try TemporaryDirectory()
        let url = directory.file("zero.ndjson")
        try writeLines([header, hrLine("\(t0 + 10)", bpm: 0), hrLine("\(t0 + 11)", bpm: 0,
                                                                      quality: QualityFlags.outOfRange.rawValue)], to: url)
        let report = try store.importBackup(from: url)
        #expect(report.invalidLines == 1)
        #expect(report.errors.first?.hasPrefix("line 2: data.bpm is 0 without") == true)
        #expect(report.inserted == [.hr: 1])
    }

    @Test func settingConflictsKeepTheLocalValueAndBrokenProfilesAreRejected() throws {
        let store = try makeStore()
        let local = UserProfile(birthYear: 1990, sex: .female)
        try store.setUserProfile(local)
        try store.setSetting("imperial", forKey: "units")
        let imported = UserProfile(birthYear: 1970, sex: .male)
        let importedJSON = String(decoding: try JSONEncoder().encode(imported), as: UTF8.self)
        let directory = try TemporaryDirectory()
        let url = directory.file("settings.ndjson")
        try writeLines([header,
                        settingLine("units", "metric"),                  // differs: local value kept
                        settingLine("units", "imperial"),                // same value: duplicate
                        settingLine("theme", "dark"),                    // new
                        settingLine(StoreSettingKey.userProfile, "{broken"), // invalid line
                        settingLine(StoreSettingKey.userProfile, importedJSON), // differs: local value kept
                        settingLine(StoreSettingKey.rawCaptureEnabled, "true")], to: url) // device-local
        let report = try store.importBackup(from: url)
        #expect(report.inserted == [.setting: 1])
        #expect(report.duplicates == [.setting: 1])
        #expect(report.notApplied == [.setting: 3])
        #expect(report.invalidLines == 1)
        #expect(report.errors == ["line 5: setting user_profile is not a valid user profile"])
        #expect(try store.setting(forKey: "units") == "imperial")
        #expect(try store.setting(forKey: "theme") == "dark")
        #expect(try store.userProfile() == local)
        #expect(try store.rawCaptureEnabled() == false)

        // Into a fresh store, a broken profile never lands (so userProfile() cannot start failing).
        let fresh = try makeStore()
        try writeLines([header, settingLine(StoreSettingKey.userProfile, "{broken")], to: url)
        #expect(try fresh.importBackup(from: url).invalidLines == 1)
        #expect(try fresh.userProfile() == nil)
    }

    @Test func cursorReportKeepsTheNewestCursorPerDeviceAndIsBounded() throws {
        var lines = [header]
        for device in 0..<40 {
            let older = #"{"type":"cursor","data":{"device_id":"d\#(device)","adapter_id":"whoop5","opaque":"AAAA","#
                + #""newest_record_ms":1,"last_complete_ms":null,"updated_at":1}}"#
            let newer = #"{"type":"cursor","data":{"device_id":"d\#(device)","adapter_id":"whoop5","opaque":"AQID","#
                + #""newest_record_ms":2,"last_complete_ms":null,"updated_at":2}}"#
            lines += device % 2 == 0 ? [older, newer] : [newer, older]
        }
        let directory = try TemporaryDirectory()
        let url = directory.file("cursors.ndjson")
        try writeLines(lines, to: url)
        let store = try makeStore()
        let report = try store.importBackup(from: url)
        #expect(report.notApplied == [.cursor: 80])
        #expect(report.cursorsNotApplied.count == ImportReport.maxReportedCursors)
        #expect(Set(report.cursorsNotApplied.map(\.deviceID)) == Set((0..<32).map { "d\($0)" }))
        #expect(report.cursorsNotApplied.allSatisfy { $0.updatedAt == 2 && $0.opaque == Data([1, 2, 3]) })
        #expect(try store.syncCursors().isEmpty)
    }

    @Test func largeRecordsAreAppliedInByteBoundedChunks() throws {
        let value = String(repeating: "v", count: 800_000)
        let lines = [header] + (0..<12).map { settingLine("big-\($0)", value) }
        let directory = try TemporaryDirectory()
        let url = directory.file("large.ndjson")
        try writeLines(lines, to: url)
        let store = try makeStore()
        var chunks = 0
        let report = try store.importBackup(from: url, afterChunk: { chunks = $0 })
        // 12 records are far below importChunkSize; the ~8 MiB byte budget splits them.
        #expect(chunks == 2)
        #expect(report.inserted == [.setting: 12])
        #expect(try store.setting(forKey: "big-11")?.count == 800_000)
    }

    @Test func reimportLeavesNoEmptyProvenanceRows() throws {
        let source = try makeStore()
        _ = try source.ingest(IngestBatch(provenance: provenance(), heartRates: (0..<10).map { hr(t0 + Int64($0), 60) }))
        _ = try source.ingest(IngestBatch(provenance: provenance(deviceB), heartRates: [hr(t0, 70, device: deviceB)]))
        let directory = try TemporaryDirectory()
        let url = directory.file("once.ndjson")
        try source.exportBackup(to: url)
        let target = try makeStore()
        let first = try target.importBackup(from: url)
        #expect(first.batchIDs.count == 2)
        for _ in 0..<5 {
            let again = try target.importBackup(from: url)
            #expect(again.batchIDs.isEmpty)
        }
        #expect(try target.tableCounts()["ingest_batch"] == 2)
        // A later import that adds one new record for device A creates exactly one batch for it.
        _ = try source.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0 + 99, 61)]))
        try source.exportBackup(to: url)
        let third = try target.importBackup(from: url)
        #expect(third.inserted == [.hr: 1])
        #expect(third.batchIDs.count == 1)
        #expect(try target.provenance(batchID: try #require(third.batchIDs.first))?.deviceID == deviceA)
        #expect(try target.tableCounts()["ingest_batch"] == 3)
    }

    @Test func deletingAllDataDuringAnImportStopsIt() throws {
        let source = try makeStore()
        let count = FormaStore.importChunkSize * 2 + 1
        _ = try source.ingest(IngestBatch(provenance: provenance(), heartRates: (0..<count).map { hr(t0 + Int64($0), 60) }))
        let directory = try TemporaryDirectory()
        let url = directory.file("wiped.ndjson")
        try source.exportBackup(to: url)
        let target = try makeStore()
        var chunks = 0
        let error = #expect(throws: StoreError.self) {
            try target.importBackup(from: url, afterChunk: { chunk in
                chunks = chunk
                if chunk == 1 { try target.deleteAllData() }
            })
        }
        guard case .interrupted = error else {
            Issue.record("expected .interrupted, got \(String(describing: error))")
            return
        }
        #expect(chunks == 1, "the second chunk is never applied")
        #expect(try target.tableCounts().values.allSatisfy { $0 == 0 })
        // The store keeps working, and a new import starts from the new state.
        #expect(try target.importBackup(from: url).inserted[.hr] == count)
    }

    @Test func cancelledTasksStopImportsAndExports() async throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: (0..<50).map { hr(t0 + Int64($0), 60) }))
        let directory = try TemporaryDirectory()
        let url = directory.file("cancel.ndjson")
        try store.exportBackup(to: url)

        let target = try makeStore()
        let importTask = Task {
            while !Task.isCancelled { await Task.yield() }
            return try target.importBackup(from: url)
        }
        importTask.cancel()
        await #expect(throws: CancellationError.self) { try await importTask.value }
        #expect(try target.tableCounts().values.allSatisfy { $0 == 0 })

        let destination = directory.file("never.ndjson")
        let exportTask = Task {
            while !Task.isCancelled { await Task.yield() }
            return try store.exportBackup(to: destination)
        }
        exportTask.cancel()
        await #expect(throws: CancellationError.self) { try await exportTask.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false) + ".partial"))
    }

    @Test func readFailuresAreFileErrors() throws {
        let directory = try TemporaryDirectory()
        let error = #expect(throws: StoreError.self) { try makeStore().importBackup(from: directory.url) }
        guard case .fileError = error else {
            Issue.record("expected .fileError, got \(String(describing: error))")
            return
        }
    }
}

// MARK: - Files and lifecycle

/// Bytes 18 and 19 of the SQLite header: 1/1 for a rollback journal, 2/2 for WAL.
private func journalHeaderBytes(_ path: String) throws -> [UInt8] {
    Array(try Data(contentsOf: URL(fileURLWithPath: path))[18...19])
}

@Suite("Hardening: files and lifecycle")
struct HardeningFileTests {
    @Test func refusedDatabasesKeepTheirJournalMode() throws {
        let directory = try TemporaryDirectory()
        let foreign = directory.path("foreign.sqlite")
        do {
            let db = try SQLiteConnection(path: foreign, enableWAL: false)
            try db.execute("PRAGMA application_id = 42; CREATE TABLE notes (body TEXT);")
        }
        #expect(try journalHeaderBytes(foreign) == [1, 1])
        #expect(throws: StoreError.notAFormaDatabase(applicationID: 42)) { _ = try FormaStore(path: foreign) }
        #expect(try journalHeaderBytes(foreign) == [1, 1], "a refused file is not switched to WAL")
        #expect(!FileManager.default.fileExists(atPath: foreign + "-wal"))

        let future = directory.path("future.sqlite")
        do {
            let db = try SQLiteConnection(path: future, enableWAL: false)
            try db.execute("CREATE TABLE t (x INTEGER)")
            try db.setUserVersion(FormaStore.schemaVersion + 1)
        }
        #expect(throws: StoreError.schemaTooNew(found: FormaStore.schemaVersion + 1, supported: FormaStore.schemaVersion)) {
            _ = try FormaStore(path: future)
        }
        #expect(try journalHeaderBytes(future) == [1, 1])

        // An accepted file is switched to WAL as before.
        let mine = directory.path("mine.sqlite")
        _ = try FormaStore(path: mine)
        #expect(try journalHeaderBytes(mine) == [2, 2])
    }

    @Test func unreadableFilesAreReportedUntouchedAndCanBeReplaced() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("garbage.sqlite")
        let garbage = Data((0..<8_192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try garbage.write(to: URL(fileURLWithPath: path))
        let error = #expect(throws: StoreError.self) { _ = try FormaStore(path: path) }
        guard case .databaseUnreadable = error else {
            Issue.record("expected .databaseUnreadable, got \(String(describing: error))")
            return
        }
        #expect(error?.localizedDescription.contains("not a database") == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == garbage)
        try FormaStore.destroyDatabaseFiles(at: path)
        #expect(try FormaStore(path: path).tableCounts().values.allSatisfy { $0 == 0 })
    }

    @Test func exportsRefuseTheStoresOwnDatabaseFiles() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("live.sqlite")
        let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60), hr(t0 + 1, 61)]))
        // The database itself, its companions, the same directory through a symlink, and a hard link.
        let viaSymlink = directory.url.appendingPathComponent("alias-dir", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: viaSymlink, withDestinationURL: directory.url)
        let hardLink = directory.path("hard-link.ndjson")
        try FileManager.default.linkItem(atPath: path, toPath: hardLink)
        let destinations = [URL(fileURLWithPath: path), URL(fileURLWithPath: path + "-wal"),
                            URL(fileURLWithPath: path + "-shm"), viaSymlink.appendingPathComponent("live.sqlite"),
                            URL(fileURLWithPath: hardLink)]
        for destination in destinations {
            #expect(throws: StoreError.self, "\(destination.path)") { try store.exportBackup(to: destination) }
        }
        // A CSV file named like the database is refused before anything is written.
        let csvStorePath = directory.path("csv/devices.csv")
        let csvStore = try FormaStore(path: csvStorePath, timeSource: ManualTimeSource(t0))
        #expect(throws: StoreError.self) { try csvStore.exportCSV(to: directory.url.appendingPathComponent("csv")) }
        #expect(!FileManager.default.fileExists(atPath: directory.path("csv/hr_samples.csv")))
        csvStore.close()

        #expect(try store.heartRates(in: everything).count == 2)
        store.close()
        let reopened = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
        #expect(try reopened.heartRates(in: everything).count == 2)
        // Elsewhere in the same directory is fine.
        #expect(try reopened.exportBackup(to: directory.file("backup.ndjson")).counts[.hr] == 2)
    }

    @Test func exportReplacesAnExistingFileAtomically() throws {
        let store = try makeStore()
        let directory = try TemporaryDirectory()
        let url = directory.file("backup.ndjson")
        try Data("previous backup".utf8).write(to: url)
        let before = try #require(FileOps.identity(atPath: url.path(percentEncoded: false)))
        try store.exportBackup(to: url)
        // rename(2) put a new file in place (a new inode); the old content is gone, nothing is left over.
        #expect(FileOps.identity(atPath: url.path(percentEncoded: false)) != before)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix(#"{"format":"forma-backup""#))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path(percentEncoded: false)) == ["backup.ndjson"])
    }

    @Test func destroyDatabaseFilesDeletesNothingWhenACompanionIsADirectory() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("odd.sqlite")
        do { _ = try FormaStore(path: path) }
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try FileManager.default.createDirectory(atPath: path + "-wal", withIntermediateDirectories: true)
        try Data([1]).write(to: URL(fileURLWithPath: path + "-wal/keep"))
        #expect(throws: StoreError.self) { try FormaStore.destroyDatabaseFiles(at: path) }
        #expect(FileManager.default.fileExists(atPath: path), "nothing is deleted when one path is refused")
        #expect(FileManager.default.fileExists(atPath: path + "-wal/keep"))
    }

    @Test func deleteAllDataRestoresTheSecureDeleteSetting() throws {
        let directory = try TemporaryDirectory()
        let store = try FormaStore(path: directory.path("secure.sqlite"), timeSource: ManualTimeSource(t0))
        let before = try store.withConnectionForTesting { try $0.scalarInt64("PRAGMA secure_delete") }
        try populate(store)
        try store.deleteAllData()
        #expect(try store.withConnectionForTesting { try $0.scalarInt64("PRAGMA secure_delete") } == before)
        #expect(try store.tableCounts().values.allSatisfy { $0 == 0 })
    }

    @Test func historyCommitsLeaveTheConnectionAtNormalSync() throws {
        let directory = try TemporaryDirectory()
        let store = try FormaStore(path: directory.path("sync.sqlite"), timeSource: ManualTimeSource(t0))
        func synchronous() throws -> Int64? { try store.withConnectionForTesting { try $0.scalarInt64("PRAGMA synchronous") } }
        #expect(try synchronous() == 1)
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60)], cursor: cursor(newest: t0)))
        #expect(try synchronous() == 1)
        _ = try store.ingest(IngestBatch(provenance: provenance(source: .liveVendorStream),
                                         heartRates: [hr(t0, 61, source: .liveVendorStream)]))
        #expect(try synchronous() == 1)
        // A durable batch that fails inside its transaction restores the setting too.
        try store.withConnectionForTesting { db in
            try db.execute("CREATE TRIGGER fail_hr BEFORE INSERT ON hr_sample BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        }
        #expect(throws: SQLiteError.self) {
            try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0 + 1, 60)], cursor: cursor(newest: t0 + 1)))
        }
        #expect(try synchronous() == 1)
        #expect(try store.syncCursor(deviceID: deviceA)?.newestPersistedRecordTime == t0)
    }
}

// MARK: - SQLite wrapper, errors and decoding

@Suite("Hardening: wrapper, errors and decoding")
struct HardeningWrapperTests {
    @Test func runCountsOnlyRowsChangedByThatStatement() throws {
        let db = try SQLiteConnection(path: SQLiteConnection.inMemoryPath)
        try db.execute("CREATE TABLE t (x INTEGER)")
        #expect(try db.run("INSERT INTO t VALUES (1), (2), (3)") == 3)
        #expect(try db.run("CREATE TABLE u (y INTEGER)") == 0)
        #expect(try db.run("SELECT x FROM t") == 0)
        #expect(try db.run("PRAGMA user_version = 3") == 0)
        #expect(try db.run("UPDATE t SET x = x + 1 WHERE x > 100") == 0)
        #expect(try db.run("DELETE FROM t WHERE x = 2") == 1)
    }

    @Test func errorsDescribeThemselvesAndCanBeClassified() {
        #expect(StoreError.closed.localizedDescription == StoreError.closed.description)
        let interrupted = StoreError.interrupted("stopped")
        #expect(interrupted.localizedDescription == "The operation stopped: stopped")
        let busy = SQLiteError(code: 5, message: "database is locked", sql: "BEGIN IMMEDIATE")
        #expect(busy.localizedDescription == busy.description)
        #expect(busy.isBusy && !busy.isCorrupt && !busy.isDiskFull)
        #expect(SQLiteError(code: 6, message: "locked").isBusy)
        #expect(SQLiteError(code: 11, message: "malformed").isCorrupt)
        #expect(SQLiteError(code: 26, message: "file is not a database").isCorrupt)
        #expect(SQLiteError(code: 13, message: "full").isDiskFull)
    }

    @Test func undecodableStoredFlagsSkipTheRowInsteadOfDefaulting() throws {
        let store = try makeStore()
        _ = try store.ingest(IngestBatch(provenance: provenance(), heartRates: [hr(t0, 60), hr(t0 + 1, 61)],
                                         aux: [auxMeasurement(t0, .batteryPercent, 80)]))
        let id = try store.insertSession(Session(kind: .sleep, range: TimeRange(start: t0, end: t0 + hour), origin: .manual,
                                                 createdAt: t0, updatedAt: t0))
        try store.softDeleteSession(id: id)
        let run = try store.beginSyncRun(SyncRunRecord(deviceID: deviceA, startedAt: t0, status: .running))
        try store.withConnectionForTesting { db in
            try db.run("UPDATE hr_sample SET quality = 'corrupt' WHERE ts_ms = ?", [t0 + 1])
            try db.run("UPDATE aux_measurement SET validated = 'perhaps'")
            try db.run("UPDATE session SET deleted = 'maybe' WHERE id = ?", [id])
            try db.run("UPDATE sync_run SET batches = 'many' WHERE id = ?", [run])
        }
        // Defaults ("no flags", "validated: false", "not deleted", 0 batches) would invent facts.
        #expect(try store.heartRates(in: everything).map(\.bpm) == [60])
        #expect(try store.aux(in: everything).isEmpty)
        #expect(try store.sessions(includeDeleted: true).isEmpty, "a damaged deleted flag never resurrects a session")
        #expect(try store.syncRun(id: run) == nil)
    }
}

// MARK: - CSV honesty

@Suite("Hardening: CSV")
struct HardeningCSVTests {
    @Test func motionEpochWithoutSamplesHasAnEmptyActivityCell() throws {
        let store = try makeStore()
        let empty = MotionEpoch(deviceID: deviceA, timestamp: t0, epochMillis: 60_000, activity: 0, sampleCount: 0,
                                source: .deviceHistory, quality: [.deviceMarkedInvalid])
        let still = MotionEpoch(deviceID: deviceA, timestamp: t0 + 60_000, epochMillis: 60_000, activity: 0, sampleCount: 25,
                                source: .deviceHistory)
        _ = try store.ingest(IngestBatch(provenance: provenance(), motion: [empty, still]))
        let directory = try TemporaryDirectory()
        let urls = try store.exportCSV(to: directory.url)
        let table = try CSVTable(readCSV(urls[2]))
        #expect(try table.value(0, "activity") == "", "no samples: unavailable, not a measured 0")
        #expect(try table.value(0, "sample_count") == "0")
        #expect(try table.value(1, "activity") == "0.0", "a measured 0 stays 0")
        // The backup stays lossless.
        let url = directory.file("motion.ndjson")
        try store.exportBackup(to: url)
        let restored = try makeStore()
        _ = try restored.importBackup(from: url)
        #expect(withoutBatch(try restored.motion(in: everything)) == [empty, still])
    }
}
