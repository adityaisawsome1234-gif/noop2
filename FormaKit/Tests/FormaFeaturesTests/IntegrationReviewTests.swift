// Regression tests for the final integration review (how the reviewed modules work together).
// Fixtures (`Adv`, `AdvCentral`, `AdvPlatform`) come from Adversarial_features.swift.

import Foundation
import Testing
import FormaCore
import FormaProtocol
import FormaSync
import FormaStore
import FormaAnalytics
@testable import FormaFeatures

// MARK: - Backup and field validation

@Suite("Integration: backup keeps validation keys")
struct IntegrationBackupValidationTests {
    /// A restored band history keeps the adapter and firmware its verdict is keyed by: once this phone
    /// validates that adapter and firmware, the restored values are used like freshly synced ones.
    @Test func restoredBandHistoryIsAdmittedOnceItsAdapterAndFirmwarePass() throws {
        let source = try Adv.store()
        try Adv.ingestHR(source, "W-1", from: Adv.now - 10 * Adv.minute, to: Adv.now, every: 1_000, bpm: 63,
                         source: .deviceHistory, quality: [.unvalidatedField], firmware: "50.36.1.0", adapter: "forma.whoop5")
        let key = FieldValidator.historyHeartRateKey(adapterID: "forma.whoop5", firmware: "50.36.1.0")
        func admitted(_ store: FormaStore, passed: Set<String>) throws -> Int {
            var ctx = Adv.context(store, deviceID: "W-1")
            ctx.historyHeartRatePolicy = .validatedBatches(passedKeys: passed, cache: BatchValidationKeyCache())
            return try ScreenLoader.heartRates(ctx, in: Adv.everything).count
        }
        #expect(try admitted(source, passed: [key]) == 600, "control")

        let directory = Adv.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("backup.jsonl")
        try source.exportBackup(to: url)
        let restored = try Adv.store()
        let report = try restored.importBackup(from: url)
        #expect(report.inserted[.hr] == 600)
        #expect(try admitted(restored, passed: []) == 0, "unvalidated until this phone has a verdict")
        #expect(try admitted(restored, passed: [key]) == 600, "the restored rows keep their adapter-and-firmware key")
        let otherFirmware = FieldValidator.historyHeartRateKey(adapterID: "forma.whoop5", firmware: "50.37.0.0")
        #expect(try admitted(restored, passed: [otherFirmware]) == 0, "another firmware's verdict never applies")
    }
}

// MARK: - App model

@MainActor
@Suite("Integration: app model", .serialized)
struct IntegrationAppModelTests {
    func make(platform: AdvPlatform = AdvPlatform(), central: AdvCentral = AdvCentral(), now: EpochMillis = Adv.now) async
        -> (AppModel, AdvCentral, ManualTimeSource) {
        let clock = ManualTimeSource(now)
        let model = AppModel(central: central, platform: platform, timeSource: clock, calendar: Adv.utc)
        await model.refreshTask?.value
        return (model, central, clock)
    }

    func band(_ id: String, _ family: DeviceFamily = .whoop5) -> DiscoveredDevice {
        DiscoveredDevice(id: id, name: id, rssi: -60, family: family, advertisedServiceUUIDs: [], manufacturerDataHex: nil,
                         connectedToThisPhone: false, lastSeen: Adv.now)
    }

    /// Per-phone choices in a backup — history download, the experimental acknowledgement, unvalidated
    /// motion, verdicts — are never written to this phone's store, and a choice already made here stays.
    @Test func importNeverWritesPerPhoneChoicesAndKeepsThisPhonesOwn() async throws {
        let backupURL = Adv.temporaryDirectory().appendingPathComponent("backup.jsonl")
        let verdictKey = FieldValidator.historyHeartRateKey(adapterID: "forma.whoop5", firmware: "1.0")
        do {
            let (a, _, _) = await make()
            await a.setHistorySyncMode(.automatic)
            await a.setHistoryAcknowledgement(true)
            await a.setAllowUnvalidatedMotion(true)
            try #require(a.liveStore).setSetting("passed", forKey: verdictKey)
            try await a.exportBackup().write(to: backupURL)
        }
        let dir = Adv.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let platform = AdvPlatform(directory: dir)
        do {
            let (b, _, _) = await make(platform: platform)
            await b.setHistorySyncMode(.manual)
            let message = await b.importBackup(from: backupURL)
            #expect(message.contains("were not applied"), "\(message)")
            #expect(b.historySyncMode == .manual, "this phone's own choice stays")
            #expect(!b.historyAcknowledgementEnabled && !b.syncOptions().acknowledgeHistory)
            let store = try #require(b.liveStore)
            #expect(try store.setting(forKey: SettingKey.historyAcknowledgement) == nil)
            #expect(try store.setting(forKey: SettingKey.allowUnvalidatedMotion) == nil)
            #expect(try store.setting(forKey: verdictKey) == nil)
            // Importing again (as after a failed attempt) changes nothing either.
            _ = await b.importBackup(from: backupURL)
            #expect(try store.setting(forKey: SettingKey.historyAcknowledgement) == nil)
        }
        let (relaunched, _, _) = await make(platform: platform)
        #expect(relaunched.historySyncMode == .manual)
        #expect(!relaunched.historyAcknowledgementEnabled)
    }

    /// PRIVACY_AND_DATA: invalid lines are skipped and counted, and the first errors are shown.
    @Test func importMessageNamesTheFirstInvalidLines() async throws {
        let dir = Adv.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("broken.jsonl")
        let lines = [#"{"format":"forma-backup","formatVersion":1,"schemaVersion":2,"exportedAt":1,"app":"Forma"}"#,
                     #"{"type":"hr","data":{}}"#, "not json"]
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        let (model, _, _) = await make()
        let message = await model.importBackup(from: url)
        #expect(message.contains("2 invalid lines were skipped"), "\(message)")
        #expect(message.contains("line 2:") && message.contains("line 3:"), "\(message)")
    }
}

// MARK: - Scene, stream, compatibility test

@MainActor
@Suite("Integration: scene, stream and diagnostics", .serialized)
struct IntegrationSceneAndStreamTests {
    func make(platform: AdvPlatform = AdvPlatform(), central: AdvCentral = AdvCentral(), now: EpochMillis = Adv.now) async
        -> (AppModel, AdvCentral, ManualTimeSource) {
        let clock = ManualTimeSource(now)
        let model = AppModel(central: central, platform: platform, timeSource: clock, calendar: Adv.utc)
        await model.refreshTask?.value
        return (model, central, clock)
    }

    func band(_ id: String, _ family: DeviceFamily = .whoop5) -> DiscoveredDevice {
        DiscoveredDevice(id: id, name: id, rssi: -60, family: family, advertisedServiceUUIDs: [], manufacturerDataHex: nil,
                         connectedToThisPhone: false, lastSeen: Adv.now)
    }

    func eventually(_ timeoutMillis: Int = 3_000, _ condition: () throws -> Bool) async rethrows -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMillis) / 1_000)
        while Date() < deadline {
            if try condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return try condition()
    }

    static let whoopServices = [GATTServiceSummary(uuid: Whoop5Adapter.service, name: "Vendor", characteristics: [])]

    /// A WHOOP link that stays open and records what Forma writes.
    func whoopLink(_ id: String) -> ReplayLink {
        ReplayLink(peripheralID: id, entries: [],
                   services: [Whoop5Adapter.service: [Whoop5Adapter.commandToStrap, Whoop5Adapter.commandFromStrap,
                                                      Whoop5Adapter.eventsFromStrap, Whoop5Adapter.dataFromStrap]],
                   endWithDisconnect: false, responder: { _, _ in [] })
    }

    func wrote(_ link: ReplayLink, _ command: AllowedCommand) -> Bool {
        link.writtenCommands.contains { $0.command.command == command }
    }

    /// ARCHITECTURE §7: nothing is computed until a UI scene is active — a Bluetooth relaunch has no scene,
    /// and the platform may not know the application state when the model is created.
    @Test func nothingIsComputedBeforeTheFirstActiveScene() async throws {
        let (model, _, _) = await make()
        #expect(model.today == nil, "screens were computed at launch without an active scene")
        try Adv.ingestHR(try #require(model.liveStore), "P-1", from: Adv.now - 30_000, to: Adv.now, every: 1_000, bpm: 64)
        model.apply(.historyComplete(at: Adv.now, chunks: 1, acknowledged: 0))
        model.apply(.disconnected(reason: "out of range", at: Adv.now))
        try await Task.sleep(nanoseconds: 100_000_000)
        await model.refreshTask?.value
        #expect(model.today == nil)
        #expect(model.autoValidationPending, "validation waits for the foreground")
        await model.sceneBecameActive()
        #expect(model.today?.hasAnyData == true)
    }

    /// COMPATIBILITY: the vendor stream is requested only while "Request live heart-rate stream" is on — a
    /// workout keeps an allowed request in the background but never makes one on its own. A request Forma
    /// made is remembered until the band is told "off".
    @Test func workoutsHonourTheStreamSettingAndRequestsAreRemembered() async throws {
        let platform = AdvPlatform(prefs: ["liveHeartRate": "0"])
        let (model, _, _) = await make(platform: platform)
        await model.selectDevice(band("W-1"))
        await model.sceneBecameActive()
        let link = whoopLink("W-1")
        model.handle(.linkReady(link, services: Self.whoopServices))
        #expect(await eventually { wrote(link, .identify) })
        await model.startWorkout()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!wrote(link, .setRealtimeHeartRate(enabled: true)), "the workout requested the stream with the setting off")
        await model.stopWorkout(save: false)

        await model.setLiveHeartRate(true)
        #expect(await eventually { wrote(link, .setRealtimeHeartRate(enabled: true)) })
        #expect(platform.preference(AppModel.realtimeStreamPreferenceKey) == "1")
        await model.startWorkout()
        model.sceneEnteredBackground()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!wrote(link, .setRealtimeHeartRate(enabled: false)), "a running workout keeps an allowed request")
        await model.stopWorkout(save: false)
        #expect(await eventually { wrote(link, .setRealtimeHeartRate(enabled: false)) })
        #expect(await eventually { platform.preference(AppModel.realtimeStreamPreferenceKey) == nil })
        link.finish()
    }

    /// A stream Forma may have left on (the app was ended while streaming, or a new engine takes over a
    /// connection that stayed up) is switched off by the next connection when nobody wants it; without
    /// such a request nothing is sent, so another app's stream is left alone.
    @Test func aStreamFormaLeftOnIsSwitchedOffByTheNextConnection() async throws {
        let platform = AdvPlatform(prefs: ["liveHeartRate": "0", AppModel.realtimeStreamPreferenceKey: "1"])
        let (model, _, _) = await make(platform: platform)
        await model.selectDevice(band("W-1"))
        let first = whoopLink("W-1")
        model.handle(.linkReady(first, services: Self.whoopServices))
        #expect(await eventually { wrote(first, .setRealtimeHeartRate(enabled: false)) })
        #expect(await eventually { platform.preference(AppModel.realtimeStreamPreferenceKey) == nil })
        let second = whoopLink("W-1")
        model.handle(.linkReady(second, services: Self.whoopServices))
        #expect(await eventually { wrote(second, .identify) })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!second.writtenCommands.contains {
            if case .setRealtimeHeartRate = $0.command.command { return true } else { return false }
        })
        first.finish()
        second.finish()
    }

    /// "Delete all data" keeps the connection for the next engine: a stream nobody wants any more is
    /// switched off first.
    @Test func deleteAllDataSwitchesOffAStreamNobodyWants() async throws {
        let platform = AdvPlatform(prefs: ["liveHeartRate": "1"])
        let (model, _, _) = await make(platform: platform)
        await model.selectDevice(band("W-1"))
        await model.sceneBecameActive()
        let link = whoopLink("W-1")
        model.handle(.linkReady(link, services: Self.whoopServices))
        #expect(await eventually { wrote(link, .setRealtimeHeartRate(enabled: true)) })
        await model.startWorkout()
        model.sceneEnteredBackground()   // a workout keeps the request in the background
        _ = await model.deleteAllData()
        #expect(await eventually { wrote(link, .setRealtimeHeartRate(enabled: false)) })
        link.finish()
    }

    /// The compatibility test promises read-only and stream on/off requests only: it never acknowledges
    /// history, even with the experimental acknowledgement on.
    @Test func theCompatibilityTestNeverAcknowledges() async throws {
        let (model, _, clock) = await make()
        await model.selectDevice(band("W-1"))
        await model.setHistoryAcknowledgement(true)
        #expect(model.syncOptions().acknowledgeHistory)
        let test = Task { await model.runCompatibilityTest(seconds: 5) }
        #expect(await eventually { model.isRunningCompatibilityTest })
        #expect(!model.syncOptions().acknowledgeHistory)
        clock.advance(byMillis: 10_000)
        await test.value
        #expect(!model.isRunningCompatibilityTest)
        #expect(model.syncOptions().acknowledgeHistory, "the setting applies again after the test")
    }

    /// HARDWARE_TEST_CHECKLIST T4.4: the clock reading of the current connection is reported by a test
    /// started while connected; a band that supports clock reads is never called "not supported".
    @Test func theTestReportsTheClockReadingOfTheCurrentConnection() async throws {
        let (model, _, _) = await make()
        await model.selectDevice(band("W-1"))
        model.currentAdapter = Whoop5Adapter()
        model.diagnostics.services = Self.whoopServices
        model.apply(.linkReady(services: [:]))
        model.apply(.clockOffset(millis: 800))
        await model.runCompatibilityTest(seconds: 0)
        let reported = model.diagnostics.checks.first { $0.id == "clock" }
        #expect(reported?.status == .passed && reported?.detail.contains("0.8 s") == true, "\(String(describing: reported))")
        model.apply(.linkReady(services: [:]))
        await model.runCompatibilityTest(seconds: 0)
        let unread = model.diagnostics.checks.first { $0.id == "clock" }
        #expect(unread?.status == .unverified)
        #expect(unread?.detail.contains("not supported") == false, "\(String(describing: unread))")
    }

    /// METHODOLOGY §3: validation runs after a history transfer ends, also when it stopped early (a chunk
    /// with records Forma does not decode ends every real WHOOP 5.0 transfer that way).
    @Test func historyHeartRateIsValidatedAfterAStoppedTransfer() async throws {
        let (model, _, _) = await make()
        await model.selectDevice(band("W-1"))
        model.currentAdapter = Whoop5Adapter()
        await model.sceneBecameActive()
        let store = try #require(model.liveStore)
        try Adv.ingestHR(store, "W-1", from: Adv.now - 30 * Adv.minute, to: Adv.now - 10 * Adv.minute, every: 5_000, bpm: 63,
                         source: .deviceHistory, quality: [.unvalidatedField], adapter: "forma.whoop5")
        try Adv.ingestHR(store, "W-1", from: Adv.now - 30 * Adv.minute, to: Adv.now - 15 * Adv.minute, every: 2_000, bpm: 62,
                         adapter: "forma.whoop5")
        model.apply(.historyStarted(at: Adv.now - Adv.minute))
        model.apply(.historyStopped(reason: "The chunk contained 3 record(s) Forma does not fully decode (kinds 21)", at: Adv.now))
        await model.refreshTask?.value
        #expect(try store.setting(forKey: FieldValidator.historyHeartRateKey(adapterID: "forma.whoop5", firmware: nil)) == "passed")
    }

    /// HARDWARE_TEST_CHECKLIST: the band's battery, the history save counts and the stored record counts
    /// are readable in the app.
    @Test func diagnosticsAndYourDataShowWhatTheChecklistAsksFor() async throws {
        let (model, _, _) = await make()
        model.apply(.battery(percent: 77))
        var counters = SyncCounters()
        counters.historyRecordsSaved = 5
        counters.historyRecordsAlreadyStored = 7
        model.apply(.counters(counters))
        #expect(model.diagnostics.batteryPercent == 77)
        #expect(model.diagnostics.counters.historyRecordsSaved == 5 && model.diagnostics.counters.historyRecordsAlreadyStored == 7)
        try Adv.ingestHR(try #require(model.liveStore), "P-1", from: Adv.now - 30_000, to: Adv.now, every: 1_000, bpm: 64)
        let summary = try #require(await model.storedDataSummary())
        #expect(summary.heartRateSamples == 30 && summary.totalMeasurements == 30)
        #expect(summary.range == TimeRange(start: Adv.now - 30_000, end: Adv.now - 1_000 + 1))
        #expect(model.appVersion == "adversarial")
    }
}

// MARK: - Coverage and unvalidated band history

@Suite("Integration: saved band history awaiting validation")
struct IntegrationAwaitingValidationTests {
    @Test func coverageShowsSavedButUnvalidatedHistoryApartFromGaps() {
        let window = TimeRange(start: 0, end: 100_000)
        // Usable samples 0–20 s; unvalidated history 10–60 s; the band keeps history; synced up to 80 s.
        let t = CoverageTimeline.build(window: window, sampleTimes: stride(from: Int64(0), to: 20_000, by: 1_000).map { $0 },
                                       bandKeepsHistory: true, newestPersistedHistory: 80_000,
                                       awaitingValidationTimes: stride(from: Int64(10_000), to: 60_000, by: 1_000).map { $0 })
        func state(_ at: EpochMillis) -> CoverageTimeline.State? { Adv.state(t, at: at) }
        #expect(state(15_000) == .recorded, "a usable sample always wins")
        #expect(state(30_000) == .awaitingValidation)
        #expect(state(70_000) == .notRecorded)
        #expect(state(90_000) == .pendingSync)
        #expect(t.spans.first?.range.start == window.start && t.spans.last?.range.end == window.end)
        let sum = [CoverageTimeline.State.recorded, .awaitingValidation, .pendingSync, .notRecorded].map(t.fraction(of:)).reduce(0, +)
        #expect(abs(sum - 1) < 1e-9)
        #expect(t.accessibilitySummary == "24% recorded, 40% saved from the band, awaiting validation, 20% waiting to sync from the band, 16% not recorded")
    }

    /// HARDWARE_VALIDATION_HANDOFF 2.5: downloaded history is "saved, awaiting validation" — not a gap, and
    /// not "No heart-rate samples yet" — until band-history heart rate passes validation.
    @Test func todayShowsSavedHistoryAsAwaitingValidationUntilItPasses() throws {
        let store = try Adv.store()
        try Adv.ingestHR(store, "W-1", from: Adv.now - 2 * Adv.hour, to: Adv.now - Adv.hour, every: 1_000, bpm: 63,
                         source: .deviceHistory, quality: [.unvalidatedField], adapter: "forma.whoop5")
        let ctx = Adv.context(store, deviceID: "W-1", bandKeepsHistory: true)
        let before = try ScreenLoader.today(ctx)
        #expect(before.latestHeartRate == nil && before.historyAwaitingValidation)
        #expect(Adv.state(before.coverage24h, at: Adv.now - 90 * Adv.minute) == .awaitingValidation)
        #expect(before.coverage24h.accessibilitySummary.contains("awaiting validation"))

        var validated = ctx
        validated.historyHeartRatePolicy = .validatedBatches(
            passedKeys: [FieldValidator.historyHeartRateKey(adapterID: "forma.whoop5", firmware: nil)], cache: BatchValidationKeyCache())
        let after = try ScreenLoader.today(validated)
        #expect(!after.historyAwaitingValidation)
        #expect(Adv.state(after.coverage24h, at: Adv.now - 90 * Adv.minute) == .recorded)
        #expect(after.latestHeartRate?.bpm == 63)
    }

    /// A band without beat-to-beat intervals shows HRV trends as an unsupported sensor, not as missing data.
    @Test func hrvTrendsOfABandWithoutBeatIntervalsSayUnsupported() throws {
        let store = try Adv.store()
        let unsupported = try ScreenLoader.trends(Adv.context(store, beatIntervalsSupported: false), metric: .hrv, period: .days30)
        #expect(unsupported.availability == .unsupportedSensor(sensor: "beat-to-beat intervals"))
        let supported = try ScreenLoader.trends(Adv.context(store, beatIntervalsSupported: true), metric: .hrv, period: .days30)
        if case .unsupportedSensor = supported.availability { Issue.record("a band with beat intervals is not 'unsupported'") }
    }
}
