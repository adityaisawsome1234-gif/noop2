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
            _ = try store.insertSession(session)
            _ = try store.invalidateDerived(overlapping: range)
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
            _ = try store.invalidateDerived(overlapping: affected)
        } catch { alertMessage = "Updating the sleep window failed: \(error)" }
        await refreshNow()
    }

    func save(_ session: Session) async {
        guard let store else { return }
        do {
            let affected = try store.updateSession(session)
            _ = try store.invalidateDerived(overlapping: affected)
        } catch { alertMessage = "Saving the change failed: \(error)" }
        await refreshNow()
    }

    // MARK: Workouts

    public func startWorkout() async {
        guard !isDemo else { return }
        liveWorkoutStart = timeSource.now()
        liveWorkoutSamples.removeAll()
        if !liveHeartRateEnabled { await setLiveHeartRate(true) }
        startTicking()
        updateLiveWorkout()
    }

    public func stopWorkout(save: Bool) async {
        guard let start = liveWorkoutStart else { return }
        let end = timeSource.now()
        liveWorkoutStart = nil
        liveWorkoutSamples.removeAll()
        startTicking()
        if save, end - start >= 60_000, let store = liveStore {
            let session = Session(kind: .workout, range: TimeRange(start: start, end: end), origin: .manual, label: "Workout",
                                  deviceID: selectedDevice?.id, createdAt: end, updatedAt: end)
            do { _ = try store.insertSession(session) } catch { alertMessage = "Saving the workout failed: \(error)" }
        }
        await refreshNow()
    }

    func updateLiveWorkout() {
        guard let start = liveWorkoutStart, let ctx = loaderContext() else { return }
        let live = ScreenLoader.liveWorkout(ctx, start: start, recentSamples: liveWorkoutSamples, sourceLabel: lastLiveSource?.description)
        if var a = activity {
            a.live = live
            activity = a
        } else {
            activity = ActivityState(live: live, workouts: [], zonesAvailability: .available)
        }
    }

    // MARK: Demo mode

    public func enterDemo() async {
        stopEngine()
        central.disconnect()
        isDemo = true
        platform.setPreference("1", forKey: "demo")
        connection = ConnectionSummary(isDemo: true)
        openDemoStore()
        if let demo = demoStore, (try? demo.dataBounds()) == nil {
            let output = DemoDataGenerator(end: timeSource.now(), calendar: calendar).generate()
            do {
                try demo.upsertDevice(output.device)
                for b in output.batches { _ = try demo.ingest(b) }
                for s in output.sessions { _ = try demo.insertSession(s) }
            } catch { alertMessage = "Creating demo data failed: \(error)" }
        }
        await refreshNow()
    }

    public func exitDemo() async {
        isDemo = false
        platform.setPreference("0", forKey: "demo")
        connection = ConnectionSummary(deviceName: selectedDevice?.name, family: selectedDevice?.family,
                                       link: selectedDevice == nil ? .noDeviceSelected : .searching, isDemo: false)
        if collectionEnabled, selectedDevice != nil { central.connectSelected(profile: Self.connectionProfile) }
        await refreshNow()
    }

    // MARK: Export, import, delete

    /// CSV files for every table, archived (zip on iOS). Returns the archive bytes for a user-chosen destination.
    public func exportCSVArchive() async throws -> Data {
        guard let store else { throw AppModelError.storeUnavailable }
        let platform = self.platform
        return try await Task.detached {
            let dir = try platform.makeStagingDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            _ = try store.exportCSV(to: dir, range: nil)
            return try platform.archiveDirectory(dir)
        }.value
    }

    /// Versioned NDJSON backup of everything in the active store.
    public func exportBackup() async throws -> Data {
        guard let store else { throw AppModelError.storeUnavailable }
        let platform = self.platform
        return try await Task.detached {
            let dir = try platform.makeStagingDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("forma-backup.jsonl")
            _ = try store.exportBackup(to: url)
            return try Data(contentsOf: url)
        }.value
    }

    /// Imports a backup into the live store and returns a human-readable report.
    public func importBackup(from url: URL) async -> String {
        guard let store = liveStore else { return "The database is not open." }
        #if canImport(Darwin)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #endif
        do {
            let report = try await Task.detached { try store.importBackup(from: url) }.value
            if let range = report.importedRange { _ = try? store.invalidateDerived(overlapping: range) }
            await refreshNow()
            var text = "Imported \(report.totalInserted) records; \(report.totalDuplicates) were already present."
            if report.invalidLines > 0 { text += " \(report.invalidLines) invalid lines were skipped." }
            if !report.cursorsNotApplied.isEmpty { text += " Sync positions from the backup were not applied to your band." }
            return text
        } catch {
            return "Import failed: \(error)"
        }
    }

    /// Erases every table of the active store and removes its files; reopens an empty store.
    public func deleteAllData() async -> String {
        stopEngine()
        do {
            if isDemo {
                try demoStore?.deleteAllData(keepSettings: false)
            } else {
                try liveStore?.deleteAllData(keepSettings: false)
                if let path = liveStore?.path {
                    liveStore?.close()
                    liveStore = nil
                    try FormaStore.destroyDatabaseFiles(at: path)
                }
                recorder.clear()
                openStores()
                loadSettingsFromStore()
                if collectionEnabled, selectedDevice != nil { central.connectSelected(profile: Self.connectionProfile) }
            }
        } catch {
            return "Deleting failed: \(error)"
        }
        await refreshNow()
        return "All Forma data on this iPhone was deleted."
    }

    // MARK: Connection history

    public func loadConnectionEvents() async {
        guard let store = liveStore else { return }
        if let events = try? store.connectionEvents(limit: 200, deviceID: nil) {
            connectionEvents = events
        }
    }
}
