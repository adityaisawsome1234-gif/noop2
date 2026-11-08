import Foundation
import FormaCore
import FormaProtocol
import FormaSync
import FormaStore
import FormaAnalytics

extension AppModel {
    // MARK: Sleep sessions

    public func suggestedNewSleepWindow() -> TimeRange {
        // Last night 23:00 → 07:00 in the current calendar, clamped to now.
        let today = LocalDay(timeSource.now(), calendar: calendar)
        let start = today.range(calendar: calendar).start - 60 * 60_000
        let end = min(timeSource.now(), today.range(calendar: calendar).start + 7 * 3_600_000)
        return TimeRange(start: start, end: max(end, start + 3_600_000))
    }

    public func addManualSleep(range: TimeRange) async {
        guard let store else { return }
        let session = Session(kind: .sleep, range: range, origin: .manual, deviceID: selectedDevice?.id,
                              createdAt: timeSource.now(), updatedAt: timeSource.now())
        do {
            let id = try store.insertSession(session)
            try supersedeCandidates(overlapping: range, keeping: id, in: store)
            invalidateDerived(in: store, overlapping: range)
        } catch { alertMessage = "Saving the sleep window failed: \(error)" }
        await refreshNow()
    }

    public func confirmSleep(_ session: Session) async {
        var s = session
        s.origin = .userConfirmed
        s.updatedAt = timeSource.now()
        await save(s)
    }

    public func updateSleep(_ session: Session, range: TimeRange) async {
        var s = session
        s.range = range
        s.origin = session.origin == .manual ? .manual : .userEdited
        s.updatedAt = timeSource.now()
        await save(s)
    }

    public func rejectSleep(_ session: Session) async {
        guard let store, let id = session.id else { return }
        do {
            let affected = try store.softDeleteSession(id: id)
            invalidateDerived(in: store, overlapping: affected)
        } catch { alertMessage = "Updating the sleep window failed: \(error)" }
        await refreshNow()
    }

    func save(_ session: Session) async {
        guard let store else { return }
        do {
            let affected = try store.updateSession(session)
            if session.isConfirmed { try supersedeCandidates(overlapping: session.range, keeping: session.id, in: store) }
            invalidateDerived(in: store, overlapping: affected)
        } catch { alertMessage = "Saving the change failed: \(error)" }
        await refreshNow()
    }

    /// Once the user has a confirmed window for a night, a detected candidate overlapping it is
    /// superseded (soft-deleted, so it is neither offered for review nor proposed again, and cannot be
    /// confirmed on top of the user's own window and counted twice).
    func supersedeCandidates(overlapping range: TimeRange, keeping id: Int64?, in store: FormaStore) throws {
        let candidates = try store.sessions(kind: .sleep, in: range, includeCandidates: true, includeDeleted: false)
            .filter { $0.origin == .detectedCandidate && $0.id != id && $0.range.overlaps(range) }
        for candidate in candidates {
            if let candidateID = candidate.id { _ = try store.softDeleteSession(id: candidateID) }
        }
    }

    // MARK: Workouts

    public func startWorkout() async {
        guard !isDemo else { return }
        liveWorkoutStart = timeSource.now()
        liveWorkoutSamples.removeAll()
        // With "Request live heart-rate stream" on, the workout keeps the request while Forma is in the background.
        await applyEngineOptions()
        startTicking()
        updateLiveWorkout()
    }

    public func stopWorkout(save: Bool) async {
        guard let start = liveWorkoutStart else { return }
        let end = timeSource.now()
        liveWorkoutStart = nil
        liveWorkoutSamples.removeAll()
        await applyEngineOptions()
        startTicking()
        if save, end - start >= 60_000, let store = liveStore {
            let session = Session(kind: .workout, range: TimeRange(start: start, end: end), origin: .manual, label: "Workout",
                                  deviceID: selectedDevice?.id, createdAt: end, updatedAt: end)
            do { _ = try store.insertSession(session) } catch { alertMessage = "Saving the workout failed: \(error)" }
        }
        await refreshNow()
    }

    func updateLiveWorkout() {
        guard let start = liveWorkoutStart, let ctx = loaderContext(resolveHistoryValidation: false) else { return }
        let live = ScreenLoader.liveWorkout(ctx, start: start, recentSamples: liveWorkoutSamples, sourceLabel: lastLiveSource?.description,
                                            overnightRestingHeartRate: overnightRestingHeartRate)
        if var a = activity {
            a.live = live
            activity = a
        } else {
            activity = ActivityState(live: live, workouts: [], zonesAvailability: .available)
        }
    }

    // MARK: Demo mode

    /// Demo data is older than this after a while in Demo mode (or across launches); it is then
    /// generated again so the demo always ends "now".
    static let demoDataMaxAgeMillis: Int64 = 6 * 3_600_000

    public func enterDemo() async {
        if liveWorkoutStart != nil { await stopWorkout(save: true) }
        stopEngine()
        central.disconnect()
        isDemo = true
        platform.setPreference("1", forKey: "demo")
        beginNewDataContext()
        connection = ConnectionSummary(isDemo: true)
        openDemoStore()
        await prepareDemoData()
        await refreshNow()
    }

    /// Generates the demo data (a few seconds of work) off the main actor when the demo store is empty or
    /// its data has gone stale.
    func prepareDemoData() async {
        guard let demo = demoStore, !isPreparingDemo else { return }
        isPreparingDemo = true
        defer { isPreparingDemo = false }
        let end = timeSource.now()
        let calendar = self.calendar
        let maxAge = Self.demoDataMaxAgeMillis
        let failure: String? = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                if let bounds = try demo.dataBounds() {
                    if bounds.end > end - maxAge { return nil }
                    try demo.deleteAllData(keepSettings: false)
                }
                let output = DemoDataGenerator(end: end, calendar: calendar).generate()
                try demo.upsertDevice(output.device)
                for b in output.batches { _ = try demo.ingest(b) }
                for s in output.sessions { _ = try demo.insertSession(s) }
                return nil
            } catch {
                return "Creating demo data failed: \(error)"
            }
        }.value
        if let failure { alertMessage = failure }
    }

    public func exitDemo() async {
        isDemo = false
        platform.setPreference("0", forKey: "demo")
        beginNewDataContext()
        connection = ConnectionSummary(deviceName: selectedDevice?.name, family: selectedDevice?.family,
                                       link: idleLinkState(), isDemo: false)
        if collectionEnabled, selectedDevice != nil { central.connectSelected(profile: Self.connectionProfile) }
        await refreshNow()
    }

    // MARK: Export, import, delete

    /// CSV files for every table of the user's own (live) data, archived (zip on iOS). Demo data is never
    /// exported. Returns the archive bytes for a user-chosen destination (memory-mapped by the platform,
    /// see `PlatformServices.archiveDirectory`).
    public func exportCSVArchive() async throws -> Data {
        guard let store = liveStore else { throw AppModelError.storeUnavailable }
        let platform = self.platform
        return try await Task.detached {
            let dir = try platform.makeStagingDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            _ = try store.exportCSV(to: dir, range: nil)
            return try platform.archiveDirectory(dir)
        }.value
    }

    /// Versioned NDJSON backup of the user's own (live) data. Demo data is never exported, also not while
    /// Demo mode is showing, so a backup can always be trusted to hold real records.
    ///
    /// The file is written as a stream; its bytes are returned memory-mapped, not read into memory, so a
    /// long history does not have to fit in RAM (the staging file is removed at once; the mapping keeps its
    /// contents readable until the returned data is released).
    public func exportBackup() async throws -> Data {
        guard let store = liveStore else { throw AppModelError.storeUnavailable }
        let platform = self.platform
        return try await Task.detached {
            let dir = try platform.makeStagingDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("forma-backup.jsonl")
            _ = try store.exportBackup(to: url)
            return try Data(contentsOf: url, options: .alwaysMapped)
        }.value
    }

    /// Imports a backup into the live store and returns a human-readable report.
    ///
    /// - A file containing demo records is refused as a whole: demo data never mixes with live data.
    /// - Per-phone choices in the backup (history download and acknowledgement, unvalidated motion,
    ///   field-validation verdicts) are never applied: the store withholds them inside each chunk's
    ///   transaction, so not even an import that stops midway, or one run again, can switch them on.
    /// - Other settings the backup adds (profile, zone method, readiness) take effect immediately, and
    ///   cached values they or the new records affect are recomputed. When the import stops midway, what
    ///   it applied so far stays (records, ordinary settings) and every cached value is recomputed.
    public func importBackup(from url: URL) async -> String {
        guard let store = liveStore else { return "The database is not open." }
        #if canImport(Darwin)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #endif
        do {
            if try await Task.detached(operation: { try BackupInspector.containsDemoData(at: url) }).value {
                return "This file contains Forma demo data. Demo data is never added to your own records, so nothing was imported."
            }
        } catch {
            return "Import failed: \(error)"
        }
        do {
            let report = try await Task.detached {
                try store.importBackup(from: url, withholdingSettings: SettingKey.isPerPhoneChoice)
            }.value
            if (report.inserted[.setting] ?? 0) > 0 {
                invalidateAllDerived()
            } else if let range = report.importedRange {
                invalidateDerived(in: store, overlapping: Self.affectedByRecords(in: range))
            }
            loadSettingsFromStore()
            await applyEngineOptions()
            await refreshNow()
            return Self.importSummary(report)
        } catch {
            // Earlier chunks stay applied: show what they changed.
            invalidateAllDerived()
            loadSettingsFromStore()
            await applyEngineOptions()
            await refreshNow()
            return "Import failed: \(error). Anything imported before the error was kept; importing the file again is safe, because records already present are skipped."
        }
    }

    /// The message shown after an import.
    nonisolated static func importSummary(_ report: ImportReport) -> String {
        var text = "Imported \(report.totalInserted) records; \(report.totalDuplicates) were already present."
        if report.invalidLines > 0 {
            text += " \(report.invalidLines) invalid line\(report.invalidLines == 1 ? " was" : "s were") skipped"
            let shown = report.errors.prefix(3)
            text += shown.isEmpty ? "." : " (\(shown.joined(separator: "; "))\(report.errors.count > shown.count || report.invalidLines > shown.count ? "; …" : ""))."
        }
        if !report.cursorsNotApplied.isEmpty { text += " Sync positions from the backup were not applied to your band." }
        if report.settingsWithheld > 0 {
            text += " History download and acknowledgement, unvalidated-motion and field-validation choices in the backup were not applied; they are made on each iPhone."
        }
        return text
    }

    /// Erases everything Forma stores on this iPhone — the live and the demo database files, the raw
    /// capture and the connection history — then starts with an empty database. Demo mode ends. The
    /// selected band stays selected (its identity only; Forget band removes it).
    public func deleteAllData() async -> String {
        if liveWorkoutStart != nil {
            liveWorkoutStart = nil
            liveWorkoutSamples.removeAll()
            startTicking()
        }
        // The connection stays up for the next engine: switch off a real-time stream nobody wants first.
        await applyEngineOptions()
        stopEngine()
        beginNewDataContext()
        let wasDemo = isDemo
        var problems: [String] = []
        let livePath = liveStore?.path ?? ((try? platform.databasePath(demo: false)) ?? nil)
        let demoPath = demoStore?.path ?? ((try? platform.databasePath(demo: true)) ?? nil)
        let liveWasUnopenable = liveStore == nil && livePath.map { FileManager.default.fileExists(atPath: $0) } == true
        // Close both stores and remove their files (an in-memory store is discarded by closing it).
        liveStore?.close()
        liveStore = nil
        demoStore?.close()
        demoStore = nil
        var undeletedFiles: [String] = []
        for path in [livePath, demoPath].compactMap({ $0 }) {
            do { try FormaStore.destroyDatabaseFiles(at: path) } catch { undeletedFiles.append(path) }
        }
        // Nothing from before survives in memory either.
        recorder.clear()
        connectionEvents = []
        countersBase = DiagnosticsCounters()
        diagnostics = DiagnosticsState(services: diagnostics.services, advertisement: diagnostics.advertisement,
                                       firmware: diagnostics.firmware, adapterID: diagnostics.adapterID,
                                       parserVersion: diagnostics.parserVersion)
        historyRunRange = nil
        historyChunksAcknowledged = 0
        autoValidationPending = false
        lastLiveUpdateAt = nil
        isDemo = false
        platform.setPreference("0", forKey: "demo")
        openStores()
        if liveStore == nil { problems.append("a new database could not be created") }
        // Files that could not be removed are emptied instead.
        for path in undeletedFiles {
            let store: FormaStore? = path == livePath ? liveStore : (try? FormaStore(path: path, timeSource: timeSource))
            let erased: Bool
            if let store {
                erased = await Task.detached { (try? store.deleteAllData(keepSettings: false)) != nil }.value
                if path != livePath { store.close() }
            } else {
                erased = false
            }
            if !erased { problems.append("\(URL(fileURLWithPath: path).lastPathComponent) could not be removed") }
        }
        // Settings are read only now that every store is empty (history sync is off again, and so on).
        loadSettingsFromStore()
        if let device = selectedDevice {
            // Keep the selection itself (no measurements) so the band is still recognised after a relaunch.
            try? liveStore?.upsertDevice(DeviceRecord(id: device.id, family: device.family, name: device.name,
                                                      firmwareVersion: device.firmwareVersion, hardwareRevision: device.hardwareRevision,
                                                      firstSeen: timeSource.now()))
        }
        connection = ConnectionSummary(deviceName: selectedDevice?.name, family: selectedDevice?.family, link: idleLinkState(),
                                       isDemo: false)
        if collectionEnabled, selectedDevice != nil { central.connectSelected(profile: Self.connectionProfile) }
        await refreshNow()
        guard problems.isEmpty else {
            return "Deleting did not finish: " + problems.joined(separator: "; ") + "."
        }
        let demoNote = wasDemo ? " Demo mode was turned off." : ""
        if liveWasUnopenable {
            return "Forma's database could not be opened, so its files were removed and a new, empty database was created.\(demoNote)"
        }
        return "All Forma data on this iPhone was deleted.\(demoNote)"
    }

    /// What "Your data" lists: rows of the user's own (live) database. Counting reads every table, so it
    /// runs off the main actor; nil when the database is not open.
    public func storedDataSummary() async -> StoredDataSummary? {
        guard let store = liveStore else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> StoredDataSummary? in
            guard let counts = try? store.tableCounts() else { return nil }
            return StoredDataSummary(heartRateSamples: counts["hr_sample"] ?? 0, beatIntervals: counts["beat_interval"] ?? 0,
                                     motionEpochs: counts["motion_epoch"] ?? 0, otherMeasurements: counts["aux_measurement"] ?? 0,
                                     sessions: counts["session"] ?? 0, range: (try? store.dataBounds()) ?? nil)
        }.value
    }

    /// The app's version and build, as shown in About (and written into capture headers).
    public var appVersion: String { platform.appVersion }

    // MARK: Connection history

    public func loadConnectionEvents() async {
        guard let store = liveStore else { return }
        if let events = try? store.connectionEvents(limit: 200, deviceID: nil) {
            connectionEvents = events
        }
    }
}
