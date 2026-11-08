import Foundation
import Testing
import FormaCore
import FormaStore
import FormaAnalytics
@testable import FormaFeatures

@Suite struct ScreenLoaderTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    /// 2026-11-08 10:00 London.
    static let now: EpochMillis = 1_762_596_000_000

    static func demoStore() throws -> FormaStore {
        let store = try FormaStore(path: nil, timeSource: ManualTimeSource(now))
        let demo = DemoDataGenerator(days: 35, end: now, calendar: calendar).generate()
        try store.upsertDevice(demo.device)
        for b in demo.batches { _ = try store.ingest(b) }
        for s in demo.sessions { _ = try store.insertSession(s) }
        return store
    }

    static func context(_ store: FormaStore, readiness: Bool = true) -> LoaderContext {
        LoaderContext(store: store, calendar: calendar, now: now,
                      profile: UserProfile(birthYear: 1988, sex: .unspecified, maxHeartRateOverride: 188),
                      zoneModel: .percentMax, showReadiness: readiness, deviceID: nil, bandKeepsHistory: false,
                      beatIntervalsSupported: true, motionSupported: true, motionNeedsValidation: false,
                      historyHeartRateValidated: false, allowUnvalidatedMotion: false)
    }

    @Test func todayIsHonestBeforeAndAfterConfirmingLastNight() throws {
        let store = try Self.demoStore()
        var today = try ScreenLoader.today(Self.context(store))
        #expect(today.hasAnyData)
        #expect(today.latestHeartRate != nil)
        #expect(today.pendingSleepReview != nil, "the latest demo night is an unconfirmed candidate")
        let rhr = try #require(today.cards.first { $0.id == "rhr" })
        #expect(!rhr.metric.availability.isAvailable && rhr.valueText == nil, "no resting HR without a confirmed window")
        for card in today.cards where !card.metric.availability.isAvailable {
            #expect(card.valueText == nil && card.metric.value == nil, "unavailable card \(card.id) must not show a value")
        }

        // Confirm the candidate night, then reload.
        var candidate = try #require(today.pendingSleepReview)
        candidate.origin = .userConfirmed
        let affected = try store.updateSession(candidate)
        _ = try store.invalidateDerived(overlapping: affected)
        today = try ScreenLoader.today(Self.context(store))
        #expect(today.pendingSleepReview == nil)
        let rhr2 = try #require(today.cards.first { $0.id == "rhr" })
        let rhrValue = try #require(rhr2.metric.value)
        #expect((40...70).contains(rhrValue), "demo resting HR ≈ 46–60 bpm, got \(rhrValue)")
        let hrv = try #require(today.cards.first { $0.id == "hrv" })
        #expect(hrv.metric.availability.isAvailable, "demo nights include beat intervals: \(hrv.metric.availability)")
        #expect((hrv.metric.value ?? 0) > 5)
        let sleep = try #require(today.cards.first { $0.id == "sleep" })
        #expect(sleep.metric.availability.isAvailable)
        #expect((5...10).contains(sleep.metric.value ?? 0))

        // Readiness is experimental, calibrated after ≥ 14 eligible nights, and reported in SD units.
        let readiness = try #require(today.readiness)
        #expect(readiness.metric.availability.isAvailable, "\(readiness.metric.availability)")
        #expect(abs(readiness.metric.value ?? 99) < 6)
        #expect(readiness.components.count == 3)
        #expect(today.calibration?.isComplete == true)
    }

    @Test func hrvIsUnsupportedWithoutBeatIntervals() throws {
        let store = try FormaStore(path: nil, timeSource: ManualTimeSource(Self.now))
        let demo = DemoDataGenerator(days: 3, end: Self.now, calendar: Self.calendar).generate()
        for var b in demo.batches { b.beatIntervals = []; _ = try store.ingest(b) }
        for var s in demo.sessions { if s.origin == .detectedCandidate { s.origin = .userConfirmed }; _ = try store.insertSession(s) }
        var ctx = Self.context(store, readiness: false)
        ctx.beatIntervalsSupported = false
        let today = try ScreenLoader.today(ctx)
        let hrv = try #require(today.cards.first { $0.id == "hrv" })
        #expect(hrv.metric.availability == .unsupportedSensor(sensor: "beat-to-beat intervals") || {
            if case .unsupportedSensor = hrv.metric.availability { return true } else { return false }
        }())
        #expect(hrv.valueText == nil)
    }

    @Test func unvalidatedHistoryHeartRateIsExcludedUntilValidated() throws {
        let store = try FormaStore(path: nil, timeSource: ManualTimeSource(Self.now))
        let prov = Provenance(deviceID: "band", adapterID: "forma.whoop5", parserVersion: "t", firmwareVersion: nil,
                              source: .deviceHistory, syncRunID: nil, createdAt: Self.now)
        let samples = (0..<60).map { i in
            HeartRateSample(deviceID: "band", timestamp: Self.now - 3_600_000 + Int64(i) * 60_000, bpm: 151, source: .deviceHistory,
                            receivedAt: Self.now, quality: [.unvalidatedField])
        }
        _ = try store.ingest(IngestBatch(provenance: prov, heartRates: samples))
        var ctx = Self.context(store, readiness: false)
        ctx.deviceID = "band"
        #expect(try ScreenLoader.today(ctx).latestHeartRate == nil, "unvalidated history must not be shown as heart rate")
        ctx.historyHeartRateValidated = true
        #expect(try ScreenLoader.today(ctx).latestHeartRate?.bpm == 151)
    }

    @Test func sleepActivityAndTrendsFromDemo() throws {
        let store = try Self.demoStore()
        let ctx = Self.context(store)
        let sleep = try ScreenLoader.sleep(ctx)
        #expect(sleep.nights.count >= 12)
        #expect(sleep.nights.allSatisfy { !$0.heartRate.points.isEmpty })
        #expect(sleep.nights.first?.isCandidate == true)
        #expect(sleep.motionAvailability == .available)

        let activity = try ScreenLoader.activity(ctx, live: nil)
        #expect(activity.workouts.count >= 15)
        let w = try #require(activity.workouts.first)
        #expect(w.averageHR.availability.isAvailable)
        #expect((120...170).contains(w.averageHR.value ?? 0))
        #expect(!w.zones.isEmpty)
        #expect(w.load.availability.isAvailable)

        let trends = try ScreenLoader.trends(ctx, metric: .restingHR, period: .days30)
        #expect(trends.daily.count == 30)
        #expect(trends.daysWithData >= 20)
        #expect(trends.availability.isAvailable)
        #expect(trends.comparison != nil)
        #expect(trends.daily.filter { $0.value == nil }.allSatisfy { $0.valueText.isEmpty })

        let load = try ScreenLoader.trends(ctx, metric: .load, period: .days7)
        #expect(load.daily.count == 7)
    }

    @Test func chartSeriesBreaksAtGaps() {
        let window = TimeRange(start: 0, end: 3_600_000)
        var samples: [HeartRateSample] = []
        for t in stride(from: Int64(0), to: 600_000, by: 5_000) { samples.append(.init(deviceID: "d", timestamp: t, bpm: 60, source: .demo, receivedAt: t)) }
        for t in stride(from: Int64(1_800_000), to: 2_400_000, by: 5_000) { samples.append(.init(deviceID: "d", timestamp: t, bpm: 70, source: .demo, receivedAt: t)) }
        let s = ScreenLoader.series(samples, window: window)
        #expect(s.gapCount == 1)
        #expect(Set(s.points.map(\.segment)) == [0, 1])
        #expect(s.points.count <= 600)
    }
}
