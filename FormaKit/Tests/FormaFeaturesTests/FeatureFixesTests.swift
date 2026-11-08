// Regression tests for the review fixes in FormaFeatures that the adversarial suite does not cover.
// Fixtures (`Adv`, `AdvCentral`, `AdvPlatform`) come from Adversarial_features.swift.

import Foundation
import Testing
import FormaCore
import FormaProtocol
import FormaSync
import FormaStore
import FormaAnalytics
@testable import FormaFeatures

// MARK: - Screen loader

@Suite("Fixes: screen loader")
struct FixesScreenLoaderTests {
    static var dayStart: EpochMillis { Adv.today.range(calendar: Adv.utc).start }

    /// The Diagnostics toggle allows unvalidated motion for proposing windows only; it never measures sleep.
    @Test func unvalidatedMotionProposesWindowsButNeverMeasuresSleep() throws {
        let store = try Adv.store()
        _ = try store.ingest(IngestBatch(provenance: Adv.provenance("band", .deviceHistory),
                                         motion: Adv.nightMotion("band", nightEndingOn: Adv.today, quality: [.unvalidatedField])))
        let night = TimeRange(start: Self.dayStart - Adv.hour, end: Self.dayStart + 7 * Adv.hour)
        try store.insertSession(Adv.sleepSession(night, device: "band"))
        let ctx = Adv.context(store, deviceID: "band", motionSupported: true, motionNeedsValidation: true, allowUnvalidatedMotion: true)

        let card = try #require(try ScreenLoader.today(ctx).cards.first { $0.id == "sleep" })
        #expect(card.title == "Time in sleep window")
        #expect(card.metric.value == 8.0)
        let n = try #require(try ScreenLoader.sleep(ctx).nights.first { $0.session.range == night })
        #expect(n.sleepEstimate.value == nil && n.continuity.value == nil)
        if case .disabled = n.sleepEstimate.availability {} else { Issue.record("expected a 'not validated' reason, got \(n.sleepEstimate.availability)") }
        #expect(try ScreenLoader.trends(ctx, metric: .sleepDuration, period: .days7).daily.last?.value == 8.0)
    }

    /// Overlapping confirmed windows are counted once; an afternoon nap is not "last night".
    @Test func overlappingWindowsCountOnceAndANapIsNotTheNight() throws {
        let store = try Adv.store()
        let night = TimeRange(start: Self.dayStart, end: Self.dayStart + 4 * Adv.hour)           // 00:00–04:00
        let overlapping = TimeRange(start: Self.dayStart + Adv.hour, end: Self.dayStart + 4 * Adv.hour + 30 * Adv.minute)
        let nap = TimeRange(start: Self.dayStart + 5 * Adv.hour, end: Self.dayStart + 13 * Adv.hour) // longer, but not the night
        try Adv.ingestHR(store, "band", from: night.start, to: night.end, every: 5_000, bpm: 50)
        try Adv.ingestHR(store, "band", from: nap.start, to: nap.end, every: 5_000, bpm: 70)
        for r in [night, overlapping, nap] { try store.insertSession(Adv.sleepSession(r, device: "band")) }
        let ctx = Adv.context(store, deviceID: "band")
        let today = try ScreenLoader.today(ctx)
        // Union: 00:00–04:30 and 05:00–13:00 = 12.5 h (not 4 + 3.5 + 8 = 15.5 h).
        #expect(today.cards.first { $0.id == "sleep" }?.metric.value == 12.5)
        #expect(today.cards.first { $0.id == "rhr" }?.metric.value == 50, "the nap was taken for the night")
        #expect(try ScreenLoader.dailyValue(ctx, .sleepMinutes, day: Adv.today) == 750)
    }

    /// Before noon the whole-day gate cannot pass; today's load is shown "so far" over the elapsed time.
    @Test func todaysLoadIsShownSoFarInTheMorning() throws {
        let morning = Self.dayStart + 6 * Adv.hour
        let store = try Adv.store(now: morning)
        try Adv.ingestHR(store, "band", from: Self.dayStart, to: morning, every: 5_000, bpm: 110)
        let ctx = Adv.context(store, now: morning, profile: UserProfile(maxHeartRateOverride: 200), deviceID: "band")
        let card = try #require(try ScreenLoader.today(ctx).cards.first { $0.id == "load" })
        #expect(card.title == "Forma Load (today so far)")
        #expect(card.metric.value == 360, "6 h at 55 % HRmax = 360 weighted minutes; got \(card.metric.availability)")
    }

    /// Today's partial load is not a trend day; the comparison sentence never depends on the period shown.
    @Test func trendsExcludePartialDaysAndCompareTheSameDaysForEveryPeriod() throws {
        let store = try Adv.store()
        let partial = try ScreenLoader.trends(Adv.context(store, profile: UserProfile(maxHeartRateOverride: 190)), metric: .load, period: .days7)
        #expect(partial.daily.count == 7 && partial.daily.last?.day == Adv.yesterday)

        for k in 0..<35 {
            let start = Adv.today.adding(days: -k, calendar: Adv.utc).range(calendar: Adv.utc).start - Adv.hour
            try store.insertSession(Adv.sleepSession(TimeRange(start: start, end: start + (k < 7 ? 8 : 7) * Adv.hour)))
        }
        let ctx = Adv.context(store)
        let sentences = try TrendPeriod.allCases.map { try ScreenLoader.trends(ctx, metric: .sleepDuration, period: $0).comparison }
        #expect(sentences.allSatisfy { $0 != nil && $0 == sentences.first! }, "\(sentences)")
        #expect(sentences.first??.contains("(28 days)") == true)
    }

    /// The readiness band follows the value the card shows (one decimal).
    @Test func readinessBandMatchesTheShownValue() {
        func card(_ composite: Double) -> ReadinessCardState {
            let value = MetricValue<Double>(value: composite, availability: .available, coverage: nil, confidence: .low, window: nil,
                                            specID: MetricID.readiness, specVersion: 1)
            return ScreenLoader.readinessState(ReadinessResult(day: Adv.today, composite: value, band: composite > 1 ? .aboveUsual : .withinUsual,
                                                               components: [], weights: .default, parameters: .default))
        }
        #expect(DisplayFormat.signed(1.04, digits: 1) == "+1.0")
        #expect(card(1.04).bandText == "Within your usual range")
        #expect(card(1.06).bandText == "Above your usual range")
        #expect(card(-1.04).bandText == "Within your usual range")
        #expect(card(-1.06).bandText == "Below your usual range")
    }

    /// METHODOLOGY §2: records next to a band clock jump are excluded from analytics.
    @Test func recordsNearAClockDiscontinuityAreNotUsed() throws {
        let store = try Adv.store()
        try Adv.ingestHR(store, "band", from: Adv.now - 60_000, to: Adv.now, every: 1_000, bpm: 70, source: .deviceHistory,
                         quality: [.nearClockDiscontinuity])
        let ctx = Adv.context(store, deviceID: "band", historyHeartRateValidated: true)
        #expect(try ScreenLoader.today(ctx).latestHeartRate == nil)
    }

    /// Demo data that reached the live store (e.g. through an old import) is never shown as the user's own.
    @Test func demoRecordsAreInvisibleInTheLiveStore() throws {
        let store = try Adv.store()
        try Adv.ingestHR(store, DemoDataGenerator.deviceID, from: Adv.now - 60_000, to: Adv.now, every: 1_000, bpm: 70, source: .demo)
        let night = TimeRange(start: Self.dayStart - Adv.hour, end: Self.dayStart + 7 * Adv.hour)
        try store.insertSession(Adv.sleepSession(night, origin: .userConfirmed, device: DemoDataGenerator.deviceID))
        var ctx = Adv.context(store)
        #expect(try ScreenLoader.today(ctx).latestHeartRate != nil, "control: visible in the demo store")
        ctx.excludesDemoData = true
        let today = try ScreenLoader.today(ctx)
        #expect(today.latestHeartRate == nil)
        #expect(today.cards.first { $0.id == "sleep" }?.metric.value == nil)
        #expect(try ScreenLoader.sleep(ctx).nights.isEmpty)
    }

    /// History persisted later for a past day reaches its cached daily value (ingest invalidates the cache).
    @Test func historyIngestedLaterRecomputesThePastDay() throws {
        let store = try Adv.store()
        let d2 = Adv.today.adding(days: -2, calendar: Adv.utc)
        let start = d2.range(calendar: Adv.utc).start - Adv.hour
        let night = TimeRange(start: start, end: start + 8 * Adv.hour)
        try store.insertSession(Adv.sleepSession(night, device: "band"))
        let ctx = Adv.context(store, deviceID: "band")
        #expect(try ScreenLoader.dailyValue(ctx, .restingHR, day: d2) == nil)
        let sink = ProtectedSink(store: store, platform: AdvPlatform(), cacheGate: DerivedCacheGate())
        let samples = Adv.heartRates("band", from: night.start, to: night.end, every: 5_000, bpm: 57)
        _ = try sink.ingest(IngestBatch(provenance: Adv.provenance("band", .standardHeartRateService), heartRates: samples))
        #expect(try ScreenLoader.dailyValue(ctx, .restingHR, day: d2) == 57)
    }

    /// A cached day computed with one HRmax is recomputed for another (e.g. a profile changed while the
    /// other store was showing), and back.
    @Test func cachedLoadFollowsTheProfile() throws {
        let store = try Adv.store()
        let y = Adv.yesterday.range(calendar: Adv.utc)
        try Adv.ingestHR(store, "band", from: y.start + 8 * Adv.hour, to: y.start + 18 * Adv.hour, every: 5_000, bpm: 130)
        let high = Adv.context(store, profile: UserProfile(maxHeartRateOverride: 200), deviceID: "band")
        let low = Adv.context(store, profile: UserProfile(maxHeartRateOverride: 150), deviceID: "band")
        #expect(try ScreenLoader.dailyValue(high, .load, day: Adv.yesterday) == 1_200)
        #expect(try ScreenLoader.dailyValue(low, .load, day: Adv.yesterday) == 2_400)
        #expect(try ScreenLoader.dailyValue(high, .load, day: Adv.yesterday) == 1_200)
    }

    /// A computation that started before an invalidation never writes its (stale) value afterwards.
    @Test func theCacheGateBlocksStaleWrites() {
        let gate = DerivedCacheGate()
        let before = gate.currentEpoch
        let day = Adv.yesterday.range(calendar: Adv.utc)
        gate.invalidate(TimeRange(start: day.start + Adv.hour, end: day.start + 2 * Adv.hour)) {}
        #expect(!gate.write(window: day, computedAt: before) {})
        #expect(gate.write(window: Adv.today.range(calendar: Adv.utc), computedAt: before) {}, "other days are unaffected")
        #expect(gate.write(window: day, computedAt: gate.currentEpoch) {})
    }

    @Test func coverageSummaryNeverRoundsAGapAway() {
        let window = TimeRange(start: 0, end: 100_000)
        // Covered [0, 99_600): a 400 ms (0.4 %) gap at the end.
        let samples = stride(from: Int64(0), through: 94_000, by: 1_000).map { $0 } + [94_600]
        let t = CoverageTimeline.build(window: window, sampleTimes: samples, bandKeepsHistory: false, newestPersistedHistory: nil)
        #expect(t.accessibilitySummary == "99% recorded, <1% not recorded")
        let full = CoverageTimeline.build(window: window, sampleTimes: stride(from: Int64(0), to: 100_000, by: 1_000).map { $0 },
                                          bandKeepsHistory: false, newestPersistedHistory: nil)
        #expect(full.accessibilitySummary == "100% recorded")
    }
}

// MARK: - Field validation

@Suite("Fixes: field validation")
struct FixesFieldValidationTests {
    static func minutes(_ values: [Int], source: MeasurementSource) -> [HeartRateSample] {
        values.enumerated().flatMap { m, bpm in
            [Int64(10_000), Int64(40_000)].map { offset -> HeartRateSample in
                let t = Adv.now - Adv.hour + Int64(m) * Adv.minute + offset
                return HeartRateSample(deviceID: "band", timestamp: t, bpm: bpm, source: source, receivedAt: t)
            }
        }
    }

    /// A field grossly wrong in 4 of 10 minutes (one record kind read from the wrong byte) must not pass.
    @Test func aFieldWrongInManyMinutesDoesNotPass() {
        let live = Self.minutes(Array(repeating: 60, count: 10), source: .standardHeartRateService)
        let mixed = Self.minutes([61, 151, 61, 151, 61, 151, 61, 151, 61, 61], source: .deviceHistory)
        let r = FieldValidator.historyHeartRateAgreement(history: mixed, live: live)
        #expect(r.medianAbsoluteDifference == 1)
        #expect(r.status == .failed, "\(r.detail)")
        let oneOff = Self.minutes([61, 61, 61, 61, 151, 61, 61, 61, 61, 61], source: .deviceHistory)
        #expect(FieldValidator.historyHeartRateAgreement(history: oneOff, live: live).status == .passed, "9 of 10 minutes agree")
    }
}

// MARK: - App model

@MainActor
@Suite("Fixes: app model", .serialized)
struct FixesAppModelTests {
    func make(platform: AdvPlatform = AdvPlatform(), central: AdvCentral = AdvCentral(), now: EpochMillis = Adv.now) async
        -> (AppModel, AdvCentral, ManualTimeSource) {
        let clock = ManualTimeSource(now)
        let model = AppModel(central: central, platform: platform, timeSource: clock, calendar: Adv.utc)
        await model.refreshTask?.value
        return (model, central, clock)
    }

    func band(_ id: String, _ family: DeviceFamily = .standardHeartRate) -> DiscoveredDevice {
        DiscoveredDevice(id: id, name: id, rssi: -60, family: family, advertisedServiceUUIDs: [], manufacturerDataHex: nil,
                         connectedToThisPhone: false, lastSeen: Adv.now)
    }

    /// History sync is opt-in on each iPhone: a backup never switches it (or unvalidated motion) on, and
    /// never carries field-validation verdicts. Ordinary preferences from the backup apply at once.
    @Test func importNeverTakesOverPerPhoneChoices() async throws {
        let backupURL = Adv.temporaryDirectory().appendingPathComponent("backup.jsonl")
        let verdictKey = FieldValidator.historyHeartRateKey(adapterID: "forma.whoop5", firmware: "1.0")
        do {
            let (a, _, _) = await make()
            await a.setHistorySyncMode(.automatic)
            await a.setAllowUnvalidatedMotion(true)
            await a.setZoneMethod(.heartRateReserve)
            try #require(a.liveStore).setSetting("passed", forKey: verdictKey)
            try await a.exportBackup().write(to: backupURL)
        }
        let dir = Adv.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let platform = AdvPlatform(directory: dir)
        do {
            let (b, _, _) = await make(platform: platform)
            let report = await b.importBackup(from: backupURL)
            #expect(report.contains("were not applied"), "\(report)")
            #expect(b.historySyncMode == .off && !b.allowUnvalidatedMotion)
            #expect(b.zoneMethod == .heartRateReserve, "ordinary preferences from the backup take effect at once")
        }
        let (relaunched, _, _) = await make(platform: platform)
        #expect(relaunched.historySyncMode == .off, "the next launch must not start acknowledging band history")
        #expect(!relaunched.allowUnvalidatedMotion)
        #expect(try #require(relaunched.liveStore).setting(forKey: verdictKey) == nil)
    }

    /// A refresh computed in Demo mode that finishes after leaving Demo mode is dropped.
    @Test func aDemoRefreshLandingAfterLeavingDemoIsDropped() async throws {
        let (model, _, _) = await make()
        await model.enterDemo()
        let pending = Task { await model.refreshNow() }
        await Task.yield()
        await model.exitDemo()
        await pending.value
        #expect(!model.isDemo && !model.connection.isDemo)
        #expect(model.today?.hasAnyData == false, "demo screens shown without the demo label")
        #expect(model.connection.lastDeviceSample == nil)
    }

    /// Delete all data in Demo mode erases the live data too, and Demo mode ends.
    @Test func deleteAllInDemoModeErasesEverythingAndLeavesDemo() async throws {
        let (model, _, _) = await make()
        try Adv.ingestHR(try #require(model.liveStore), "P-1", from: Adv.now - 60_000, to: Adv.now, every: 1_000, bpm: 70)
        await model.enterDemo()
        let message = await model.deleteAllData()
        #expect(message.contains("was deleted") && message.contains("Demo mode was turned off"), "\(message)")
        #expect(!model.isDemo && !model.connection.isDemo)
        #expect(try #require(model.liveStore).heartRates(in: Adv.everything).isEmpty)
        #expect(model.today?.hasAnyData == false)
    }

    /// The compatibility test of a band that is already connected reports the existing link.
    @Test func compatibilityTestOfAConnectedBandReportsTheLink() async throws {
        let (model, _, _) = await make()
        await model.selectDevice(band("P-1"))
        model.diagnostics.services = Adv.heartRateServices
        model.handle(.stateChanged(.connected))
        await model.runCompatibilityTest(seconds: 0)
        #expect(model.diagnostics.checks.first { $0.id == "connect" }?.status == .passed)
        #expect(model.diagnostics.checks.first { $0.id == "gatt" }?.status == .passed)
        #expect(model.diagnostics.checks.first { $0.id == "vendorFrames" }?.status == .notApplicable)
    }

    /// With "Collect from band" off, the test connects only for itself and the off state is restored.
    @Test func compatibilityTestRestoresCollectionOff() async throws {
        let (model, central, _) = await make()
        await model.selectDevice(band("P-1"))
        await model.setCollectionEnabled(false)
        let mark = central.calls.count
        await model.runCompatibilityTest(seconds: 0)
        let calls = Array(central.calls.dropFirst(mark))
        #expect(calls.first == "connect" && calls.last == "disconnect", "\(calls)")
        #expect(model.connection.link != .searching && model.connection.link != .connected)
    }

    /// A link that becomes ready while collection is off is released, and nothing is recorded.
    @Test func aLinkReadyWhileCollectionIsOffIsReleased() async throws {
        let (model, central, _) = await make()
        await model.selectDevice(band("P-1"))
        await model.setCollectionEnabled(false)
        model.handle(.linkReady(Adv.standardHeartRateLink(id: "P-1", start: Adv.now - 30_000, count: 30), services: Adv.heartRateServices))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(central.calls.last == "disconnect")
        #expect(model.engine == nil)
        #expect(try #require(model.liveStore).heartRates(in: Adv.everything).isEmpty)
    }

    /// A value that stops updating is not presented as current; implausible live values never mean "Live".
    @Test func staleAndImplausibleValuesAreNeverLive() async throws {
        let (model, _, clock) = await make()
        await model.selectDevice(band("P-1"))
        try Adv.ingestHR(try #require(model.liveStore), "P-1", from: Adv.now - 30_000, to: Adv.now, every: 1_000, bpm: 66)
        await model.refreshNow()
        #expect(model.today?.latestHeartRate?.isStale == false)
        clock.advance(byMillis: 3 * Adv.minute)
        model.tick()
        #expect(model.today?.latestHeartRate?.isStale == true)
        model.apply(.liveHeartRate(bpm: 0, at: clock.now(), source: .standardHeartRateService))
        #expect(!model.connection.liveStreaming)
    }

    /// A band-history record stamped in the future is never reported as the last device sample "just now".
    @Test func futureRecordsDoNotMoveTheLastDeviceSamplePastNow() async throws {
        let (model, _, _) = await make()
        await model.selectDevice(band("P-1"))
        try Adv.ingestHR(try #require(model.liveStore), "P-1", from: Adv.now + Adv.hour, to: Adv.now + Adv.hour + 5_000, every: 1_000, bpm: 66)
        await model.refreshNow()
        #expect((model.connection.lastDeviceSample ?? 0) <= Adv.now)
    }

    /// Diagnostics counters only grow across reconnections (each engine counts from zero).
    @Test func countersAccumulateAcrossEngines() async throws {
        let (model, _, _) = await make()
        var first = SyncCounters()
        first.standardHRNotifications = 40
        model.apply(.counters(first))
        model.stopEngine()
        var second = SyncCounters()
        second.standardHRNotifications = 10
        model.apply(.counters(second))
        #expect(model.diagnostics.counters.standardHRNotifications == 50)
    }

    /// Stopping the engine mid-transfer never leaves the status at "Syncing".
    @Test func stoppingTheEngineEndsSyncing() async throws {
        let (model, _, _) = await make()
        await model.selectDevice(band("W-1", .whoop5))
        model.handle(.stateChanged(.connected))
        model.apply(.historyStarted(at: Adv.now))
        #expect(model.connection.shortStatus == "Syncing")
        await model.setCollectionEnabled(false)
        #expect(!model.connection.isSyncing)
    }

    /// Diagnostics promises history heart rate "is validated automatically": a completed transfer triggers it
    /// for an adapter and firmware without a verdict, and a pass releases the values on the next refresh.
    @Test func historyHeartRateIsValidatedAutomaticallyAfterATransfer() async throws {
        let (model, _, _) = await make()
        await model.selectDevice(band("W-1", .whoop5))
        model.currentAdapter = Whoop5Adapter()
        let store = try #require(model.liveStore)
        try Adv.ingestHR(store, "W-1", from: Adv.now - 30 * Adv.minute, to: Adv.now - 10 * Adv.minute, every: 5_000, bpm: 63,
                         source: .deviceHistory, quality: [.unvalidatedField], adapter: "forma.whoop5")
        try Adv.ingestHR(store, "W-1", from: Adv.now - 30 * Adv.minute, to: Adv.now - 15 * Adv.minute, every: 2_000, bpm: 62,
                         adapter: "forma.whoop5")
        await model.refreshNow()
        #expect(model.today?.latestHeartRate?.bpm == 62)
        model.apply(.historyStarted(at: Adv.now - Adv.minute))
        model.apply(.historyComplete(at: Adv.now))
        await model.refreshTask?.value
        let key = FieldValidator.historyHeartRateKey(adapterID: "forma.whoop5", firmware: nil)
        #expect(try store.setting(forKey: key) == "passed")
        #expect(model.today?.latestHeartRate?.bpm == 63)
    }

    /// Confirming or adding a window of one's own supersedes the detected candidate for that night.
    @Test func aManualWindowSupersedesTheCandidate() async throws {
        let (model, _, _) = await make()
        await model.selectDevice(band("W-1", .whoop5))
        _ = try #require(model.liveStore).ingest(IngestBatch(provenance: Adv.provenance("W-1", .deviceHistory, adapter: "forma.whoop5"),
                                                            motion: Adv.nightMotion("W-1", nightEndingOn: Adv.today, quality: [.unvalidatedField])))
        await model.setAllowUnvalidatedMotion(true)
        let candidate = try #require(model.sleep?.nights.first { $0.isCandidate }?.session)
        await model.addManualSleep(range: TimeRange(start: candidate.range.start + Adv.minute, end: candidate.range.end))
        #expect(model.sleep?.nights.allSatisfy { !$0.isCandidate } == true)
        #expect(model.today?.pendingSleepReview == nil)
        await model.refreshNow()
        #expect(model.sleep?.nights.count == 1, "the superseded candidate was proposed again")
    }
}
