import Foundation
import FormaCore
import FormaStore
import FormaAnalytics

/// Snapshot of everything a screen computation needs. Built on the main actor, used off it.
public struct LoaderContext: Sendable {
    public var store: FormaStore
    public var calendar: Calendar
    public var now: EpochMillis
    public var profile: UserProfile
    public var zoneModel: HeartRateZoneModel
    public var showReadiness: Bool
    /// Device whose data to show (nil = all devices in the store, e.g. demo).
    public var deviceID: String?
    /// The selected band can backfill gaps from its own history, and history sync is enabled.
    public var bandKeepsHistory: Bool
    /// The adapter can provide genuine beat-to-beat intervals (else HRV is "unsupported").
    public var beatIntervalsSupported: Bool
    /// The adapter can provide motion data (else sleep candidates are "unsupported").
    public var motionSupported: Bool
    /// Band-history heart rate passed field validation for the current adapter/firmware.
    public var historyHeartRateValidated: Bool
    /// The band's motion data is decoded but not validated (raw counts of unpublished scale).
    public var motionNeedsValidation: Bool
    /// The user explicitly allowed unvalidated motion data for sleep candidates (Diagnostics).
    public var allowUnvalidatedMotion: Bool

    public init(store: FormaStore, calendar: Calendar, now: EpochMillis, profile: UserProfile, zoneModel: HeartRateZoneModel,
                showReadiness: Bool, deviceID: String?, bandKeepsHistory: Bool, beatIntervalsSupported: Bool,
                motionSupported: Bool, motionNeedsValidation: Bool, historyHeartRateValidated: Bool, allowUnvalidatedMotion: Bool) {
        self.store = store
        self.calendar = calendar
        self.now = now
        self.profile = profile
        self.zoneModel = zoneModel
        self.showReadiness = showReadiness
        self.deviceID = deviceID
        self.bandKeepsHistory = bandKeepsHistory
        self.beatIntervalsSupported = beatIntervalsSupported
        self.motionSupported = motionSupported
        self.motionNeedsValidation = motionNeedsValidation
        self.historyHeartRateValidated = historyHeartRateValidated
        self.allowUnvalidatedMotion = allowUnvalidatedMotion
    }
}

/// Computes display state for each screen from the store and the analytics module. Pure apart from
/// reading the store and caching daily metrics in it.
public enum ScreenLoader {
    // MARK: Data access with validation filtering

    /// Heart rate usable for metrics. Samples from a field still awaiting validation are dropped. Band-history
    /// samples are kept once the user validated that field for this adapter and firmware: the flag is cleared
    /// on the copies handed to analytics (storage keeps it as evidence), because analytics exclude it.
    static func heartRates(_ ctx: LoaderContext, in range: TimeRange) throws -> [HeartRateSample] {
        let raw = try ctx.store.heartRates(in: range, deviceID: ctx.deviceID)
        return raw.compactMap { sample in
            guard sample.quality.contains(.unvalidatedField) else { return sample }
            guard sample.source == .deviceHistory, ctx.historyHeartRateValidated else { return nil }
            var usable = sample
            usable.quality.remove(.unvalidatedField)
            return usable
        }
    }

    static func beats(_ ctx: LoaderContext, in range: TimeRange) throws -> [BeatInterval]? {
        let raw = try ctx.store.beatIntervals(in: range, deviceID: ctx.deviceID).filter { !$0.quality.contains(.unvalidatedField) }
        if raw.isEmpty && !ctx.beatIntervalsSupported { return nil }
        return raw
    }

    /// Motion usable for sleep analysis: nil when the band has no motion path ("unsupported");
    /// unvalidated motion is used only after the user allows it.
    static func motion(_ ctx: LoaderContext, in range: TimeRange) throws -> [MotionEpoch]? {
        guard ctx.motionSupported else { return nil }
        let raw = try ctx.store.motion(in: range, deviceID: ctx.deviceID)
        return raw.compactMap { epoch in
            guard epoch.quality.contains(.unvalidatedField) else { return epoch }
            guard ctx.allowUnvalidatedMotion else { return nil }
            var usable = epoch
            usable.quality.remove(.unvalidatedField)
            return usable
        }
    }

    static func maxHeartRate(_ ctx: LoaderContext) -> MaxHeartRate? {
        MaxHeartRateResolver.resolve(profile: ctx.profile, asOf: ctx.now, calendar: ctx.calendar).value
    }

    // MARK: Charts

    /// Builds a gap-preserving, down-sampled series for charts (≤ `maxPoints` points).
    public static func series(_ samples: [HeartRateSample], window: TimeRange, maxPoints: Int = 600,
                              maxGapMillis: Int64 = 60_000) -> SeriesDisplay {
        let canonical = HeartRateSeries.canonical(HeartRateSeries.usable(samples)).filter { window.contains($0.timestamp) }
        guard !canonical.isEmpty else { return .empty(unit: "bpm", window: window) }
        let bucket = max(1_000, window.durationMillis / Int64(max(1, maxPoints)))
        var points: [ChartPoint] = []
        var segment = 0
        var gaps = 0
        var previous: EpochMillis?
        var bucketStart: EpochMillis?
        var sum = 0.0, count = 0
        func flush() {
            if let b = bucketStart, count > 0 { points.append(ChartPoint(t: b, value: sum / Double(count), segment: segment)) }
            sum = 0; count = 0; bucketStart = nil
        }
        for s in canonical {
            if let p = previous, s.timestamp - p > maxGapMillis {
                flush()
                segment += 1
                gaps += 1
            }
            let b = window.start + (s.timestamp - window.start) / bucket * bucket
            if bucketStart != b { flush(); bucketStart = b }
            sum += Double(s.bpm); count += 1
            previous = s.timestamp
        }
        flush()
        return SeriesDisplay(points: points, unit: "bpm", window: window, gapCount: gaps)
    }

    // MARK: Daily metrics (cached)

    enum DailyMetric: String, CaseIterable {
        case restingHR = "forma.daily.rhr"
        case hrv = "forma.daily.rmssd"
        case lnHRV = "forma.daily.lnrmssd"
        case sleepMinutes = "forma.daily.sleep-minutes"
        case load = "forma.daily.load"
    }

    /// Version folded into the cache key; bump when any underlying method changes.
    /// Bump whenever a cached daily value would change (it is also mixed with the analytics spec versions).
    static let dailyCacheVersion = 2 * 1_000 + MetricCatalog.overnightRestingHeartRate.version * 100
        + MetricCatalog.hrvRMSSD.version * 10 + MetricCatalog.edwardsLoad.version

    /// The confirmed sleep window that ended on `day` (the main one if several).
    static func confirmedSleep(_ ctx: LoaderContext, endingOn day: LocalDay) throws -> [Session] {
        let range = day.range(calendar: ctx.calendar)
        let sessions = try ctx.store.sessions(kind: .sleep, in: TimeRange(start: range.start - 24 * 3_600_000, end: range.end),
                                              includeCandidates: false, includeDeleted: false)
        return sessions.filter { $0.isConfirmed && range.contains($0.range.end - 1) }
    }

    /// Computes (or reads from cache) one daily value. `nil` = no value for that day.
    static func dailyValue(_ ctx: LoaderContext, _ metric: DailyMetric, day: LocalDay) throws -> Double? {
        let window = day.range(calendar: ctx.calendar)
        let isToday = window.contains(ctx.now)
        if !isToday, let cached = try ctx.store.derived(metricID: metric.rawValue, in: window, specVersion: dailyCacheVersion)
            .first(where: { $0.window == window }) {
            return cached.value
        }
        let value: Double?
        let availability: String
        switch metric {
        case .restingHR, .hrv, .lnHRV:
            let nights = try confirmedSleep(ctx, endingOn: day)
            guard let night = nights.max(by: { $0.range.durationMillis < $1.range.durationMillis }) else {
                value = nil; availability = "no confirmed sleep window"
                break
            }
            if metric == .restingHR {
                let hr = try heartRates(ctx, in: night.range)
                let r = RestingHeartRateEstimator.estimate(sleepWindow: night.range, series: HeartRateSeries(hr))
                value = r.restingHeartRate.value
                availability = r.restingHeartRate.availability.explanation
            } else {
                let analysis = HRVAnalyzer.analyze(beats: try beats(ctx, in: night.range), range: night.range)
                value = metric == .hrv ? analysis.rmssd.value : analysis.lnRMSSD.value
                availability = analysis.rmssd.availability.explanation
            }
        case .sleepMinutes:
            let nights = try confirmedSleep(ctx, endingOn: day)
            if nights.isEmpty {
                value = nil; availability = "no confirmed sleep window"
            } else {
                var total = 0.0
                for n in nights {
                    let summary = SleepSummary.fromConfirmedWindow(n.range, motion: try motion(ctx, in: n.range), heartRate: nil)
                    let ms = summary.sleepDurationEstimate.value ?? summary.timeInBed.value ?? n.range.durationMillis
                    total += Double(ms) / 60_000
                }
                value = total; availability = "available"
            }
        case .load:
            let hr = try heartRates(ctx, in: window)
            let load = TrainingLoad.dailyLoad(day: day, calendar: ctx.calendar, series: HeartRateSeries(hr), hrMax: maxHeartRate(ctx))
            value = load.value
            availability = load.availability.explanation
        }
        if !isToday {
            let record = DerivedMetricRecord(metricID: metric.rawValue, specVersion: dailyCacheVersion, window: window, value: value,
                                             unit: "", availability: availability, coverage: nil, confidence: value == nil ? .none : .moderate,
                                             inputsJSON: "{}", computedAt: ctx.now)
            try? ctx.store.putDerived([record])
        }
        return value
    }

    static func dailySeries(_ ctx: LoaderContext, _ metric: DailyMetric, endingOn last: LocalDay, days: Int) throws -> [LocalDay: Double?] {
        var out: [LocalDay: Double?] = [:]
        for offset in 0..<max(1, days) {
            let day = last.adding(days: -offset, calendar: ctx.calendar)
            out[day] = try dailyValue(ctx, metric, day: day)
        }
        return out
    }

    // MARK: Today

    public static func today(_ ctx: LoaderContext) throws -> TodayState {
        let day = LocalDay(ctx.now, calendar: ctx.calendar)
        let last24 = TimeRange(start: ctx.now - EpochMillis.millisPerDay, end: ctx.now)
        let hr24 = try heartRates(ctx, in: last24)
        let hasAnyData = try ctx.store.dataBounds() != nil

        var latest: LatestHeartRate?
        if let s = HeartRateSeries.usable(hr24).max(by: { $0.timestamp < $1.timestamp }) {
            latest = LatestHeartRate(bpm: s.bpm, at: s.timestamp, sourceLabel: s.source.description, isStale: ctx.now - s.timestamp > 120_000)
        }

        var cards: [MetricCardState] = []
        let nights = try confirmedSleep(ctx, endingOn: day)
        let mainNight = nights.max(by: { $0.range.durationMillis < $1.range.durationMillis })

        // Resting heart rate (overnight)
        if let night = mainNight {
            let rhr = RestingHeartRateEstimator.estimate(sleepWindow: night.range, series: HeartRateSeries(try heartRates(ctx, in: night.range)))
            cards.append(MetricCardState(id: "rhr", title: "Resting HR (overnight)", metric: rhr.restingHeartRate, unit: "bpm",
                                         valueText: DisplayFormat.metric(rhr.restingHeartRate, digits: 0), status: .estimate,
                                         footnote: RestingHeartRateEstimator.label))
        } else {
            cards.append(MetricCardState(id: "rhr", title: "Resting HR (overnight)",
                                         metric: .unavailable(.insufficientData(detail: "Needs a confirmed sleep window for last night"),
                                                              specID: MetricID.overnightRestingHeartRate, specVersion: MetricCatalog.overnightRestingHeartRate.version),
                                         unit: "bpm", valueText: nil, status: .estimate))
        }

        // HRV (RMSSD) from genuine beat intervals only
        if let night = mainNight {
            let analysis = HRVAnalyzer.analyze(beats: try beats(ctx, in: night.range), range: night.range)
            cards.append(MetricCardState(id: "hrv", title: "HRV (RMSSD)", metric: analysis.rmssd, unit: "ms",
                                         valueText: DisplayFormat.metric(analysis.rmssd, digits: 0), status: .estimate,
                                         footnote: analysis.rmssd.availability.isAvailable ? "\(analysis.validWindows) of \(analysis.totalWindows) five-minute windows valid" : nil))
        } else {
            let availability: Availability = ctx.beatIntervalsSupported
                ? .insufficientData(detail: "Needs a confirmed sleep window with beat-to-beat intervals")
                : .unsupportedSensor(sensor: "beat-to-beat intervals")
            cards.append(MetricCardState(id: "hrv", title: "HRV (RMSSD)", metric: .unavailable(availability, specID: MetricID.hrvRMSSD, specVersion: MetricCatalog.hrvRMSSD.version),
                                         unit: "ms", valueText: nil, status: .estimate))
        }

        // Sleep duration (confirmed windows only)
        if nights.isEmpty {
            cards.append(MetricCardState(id: "sleep", title: "Sleep",
                                         metric: .unavailable(.insufficientData(detail: "No confirmed sleep window ending today"),
                                                              specID: MetricID.sleepSummary, specVersion: MetricCatalog.sleepSummary.version),
                                         unit: "h", valueText: nil, status: .estimate))
        } else {
            var totalMs: Int64 = 0
            var usedMotion = false
            for n in nights {
                let summary = SleepSummary.fromConfirmedWindow(n.range, motion: try motion(ctx, in: n.range), heartRate: nil)
                if let est = summary.sleepDurationEstimate.value { totalMs += est; usedMotion = true }
                else { totalMs += summary.timeInBed.value ?? n.range.durationMillis }
            }
            let hours = Double(totalMs) / 3_600_000
            let metric = MetricValue<Double>(value: hours, availability: .available, coverage: nil,
                                             confidence: usedMotion ? .moderate : .low, window: mainNight?.range,
                                             specID: MetricID.sleepSummary, specVersion: MetricCatalog.sleepSummary.version,
                                             inputs: ["basis": usedMotion ? "sleep estimate from motion" : "time in confirmed window"])
            cards.append(MetricCardState(id: "sleep", title: usedMotion ? "Sleep (estimate)" : "Time in sleep window", metric: metric,
                                         unit: "h", valueText: DisplayFormat.number(hours, digits: 1), status: .estimate,
                                         footnote: usedMotion ? nil : "No motion data: this is the confirmed window length, not measured sleep."))
        }

        // Forma Load today
        let load = TrainingLoad.dailyLoad(day: day, calendar: ctx.calendar, series: HeartRateSeries(try heartRates(ctx, in: day.range(calendar: ctx.calendar))),
                                          hrMax: maxHeartRate(ctx))
        cards.append(MetricCardState(id: "load", title: "Forma Load (today)", metric: load, unit: "TRIMP",
                                     valueText: DisplayFormat.metric(load, digits: 0), status: .estimate))

        // Readiness (experimental) with calibration progress
        var readinessCard: ReadinessCardState?
        var calibration: CalibrationProgress?
        if ctx.showReadiness {
            let ln = try dailySeries(ctx, .lnHRV, endingOn: day, days: 29)
            let rhr = try dailySeries(ctx, .restingHR, endingOn: day, days: 29)
            let sleep = try dailySeries(ctx, .sleepMinutes, endingOn: day, days: 29)
            let result = ReadinessCalculator.compute(day: day, calendar: ctx.calendar, lnRMSSD: ln, restingHeartRate: rhr, sleepDurationMinutes: sleep)
            readinessCard = readinessState(result)
            if let hrvComponent = result.component(.hrv) {
                calibration = CalibrationProgress(eligibleNights: hrvComponent.calibrationHave, requiredNights: hrvComponent.calibrationNeed,
                                                  explanation: ctx.beatIntervalsSupported
                                                    ? "The readiness index compares tonight with your own previous 28 nights; it needs enough nights with valid HRV first."
                                                    : "This band does not provide beat-to-beat intervals, so the HRV-based readiness index cannot calibrate.")
            }
        }

        let coverage = CoverageTimeline.build(window: last24, sampleTimes: HeartRateSeries.usable(hr24).map(\.timestamp),
                                              bandKeepsHistory: ctx.bandKeepsHistory,
                                              newestPersistedHistory: try ctx.deviceID.flatMap { try ctx.store.syncCursor(deviceID: $0)?.newestPersistedRecordTime })

        let candidates = try ctx.store.sessions(kind: .sleep, in: TimeRange(start: ctx.now - 36 * 3_600_000, end: ctx.now),
                                                includeCandidates: true, includeDeleted: false)
            .filter { $0.origin == .detectedCandidate }
        return TodayState(day: day, latestHeartRate: latest, cards: cards, readiness: readinessCard, coverage24h: coverage,
                          pendingSleepReview: candidates.max(by: { $0.range.end < $1.range.end }), calibration: calibration,
                          hasAnyData: hasAnyData)
    }

    static func readinessState(_ r: ReadinessResult) -> ReadinessCardState {
        let bandText: String?
        switch r.band {
        case .belowUsual?: bandText = "Below your usual range"
        case .withinUsual?: bandText = "Within your usual range"
        case .aboveUsual?: bandText = "Above your usual range"
        case nil: bandText = nil
        }
        let rows = r.components.map { c -> ReadinessComponentRow in
            let name: String
            let digits: Int
            switch c.kind {
            case .hrv: name = "HRV (ln RMSSD)"; digits = 2
            case .restingHeartRate: name = "Resting heart rate"; digits = 1
            case .sleepDuration: name = "Sleep duration"; digits = 0
            }
            let baseline = c.baseline.value.map { "\(DisplayFormat.number($0.mean, digits: digits)) (n=\($0.n))" } ?? c.baseline.availability.explanation
            return ReadinessComponentRow(name: name,
                                         valueText: c.value.map { "\(DisplayFormat.number($0, digits: digits)) \(c.unit)" } ?? "no value",
                                         baselineText: baseline,
                                         zText: c.z.map { DisplayFormat.signed($0, digits: 2) } ?? "—",
                                         weightText: c.isIncluded ? DisplayFormat.number(c.weight, digits: 2) : "not included")
        }
        return ReadinessCardState(metric: r.composite, bandText: bandText, components: rows)
    }

    // MARK: Sleep

    public static func sleep(_ ctx: LoaderContext, nights: Int = 14) throws -> SleepState {
        let range = TimeRange(start: ctx.now - Int64(nights) * EpochMillis.millisPerDay, end: ctx.now)
        let sessions = try ctx.store.sessions(kind: .sleep, in: range, includeCandidates: true, includeDeleted: false)
            .sorted { $0.range.end > $1.range.end }
        var states: [NightState] = []
        for s in sessions {
            let hr = try heartRates(ctx, in: s.range)
            let mot = try motion(ctx, in: s.range)
            let summary = SleepSummary.fromConfirmedWindow(s.range, motion: mot, heartRate: hr)
            let sleepEst: MetricValue<Double> = summary.sleepDurationEstimate.value.map {
                MetricValue(value: Double($0) / 3_600_000, availability: .available, coverage: summary.motionCoverage,
                            confidence: summary.sleepDurationEstimate.confidence, window: s.range, specID: MetricID.sleepSummary, specVersion: MetricCatalog.sleepSummary.version)
            } ?? .unavailable(mot == nil ? .unsupportedSensor(sensor: SleepDetector.motionSensorName) : summary.sleepDurationEstimate.availability,
                              specID: MetricID.sleepSummary, specVersion: MetricCatalog.sleepSummary.version, window: s.range)
            let rhr = RestingHeartRateEstimator.estimate(sleepWindow: s.range, series: HeartRateSeries(hr)).restingHeartRate
            let hrv = HRVAnalyzer.analyze(beats: try beats(ctx, in: s.range), range: s.range).rmssd
            let coverage = CoverageTimeline.build(window: s.range, sampleTimes: HeartRateSeries.usable(hr).map(\.timestamp),
                                                  bandKeepsHistory: ctx.bandKeepsHistory, newestPersistedHistory: nil)
            states.append(NightState(session: s, timeInBedHours: Double(s.range.durationMillis) / 3_600_000, sleepEstimate: sleepEst,
                                     continuity: summary.continuity, restingHR: rhr, hrv: hrv,
                                     heartRate: series(hr, window: s.range), wakeBouts: summary.wakeBouts ?? [], coverage: coverage))
        }
        let motionAvailability: Availability
        if !ctx.motionSupported {
            motionAvailability = .unsupportedSensor(sensor: SleepDetector.motionSensorName)
        } else if ctx.motionNeedsValidation && !ctx.allowUnvalidatedMotion {
            motionAvailability = .disabled(reason: "Motion data from this band is not validated yet, so detected sleep windows are off. You can allow it in Diagnostics.")
        } else {
            motionAvailability = .available
        }
        return SleepState(nights: states, motionAvailability: motionAvailability)
    }

    /// Runs sleep detection for the night ending `day` and returns a candidate session to store, unless
    /// a sleep session already overlaps that night or detection is unavailable.
    public static func proposeSleepCandidate(_ ctx: LoaderContext, nightEndingOn day: LocalDay) throws -> Session? {
        guard ctx.motionSupported else { return nil }
        guard let window = SleepDetector.window(nightEndingOn: day, calendar: ctx.calendar), window.end <= ctx.now else { return nil }
        let existing = try ctx.store.sessions(kind: .sleep, in: window, includeCandidates: true, includeDeleted: true)
        guard existing.isEmpty else { return nil }
        let result = SleepDetector.detect(nightEndingOn: day, calendar: ctx.calendar, motion: try motion(ctx, in: window),
                                          heartRate: try heartRates(ctx, in: window))
        guard let c = result.value else { return nil }
        return Session(kind: .sleep, range: c.range, origin: .detectedCandidate, deviceID: ctx.deviceID,
                       detector: "\(MetricID.sleepCandidate)@v\(result.specVersion)", confidence: c.confidence,
                       createdAt: ctx.now, updatedAt: ctx.now)
    }

    // MARK: Activity

    public static func zoneDisplays(_ zones: MetricValue<ZoneDurations>, thresholds: MetricValue<ZoneThresholds>) -> [ZoneTimeDisplay] {
        guard let durations = zones.value, let t = thresholds.value else { return [] }
        let total = Double(max(1, durations.totalMillis))
        return (1...5).compactMap { zone -> ZoneTimeDisplay? in
            guard let ms = durations.millis(inZone: zone) else { return nil }
            let lower = zone - 1 < t.lowerBoundsBPM.count ? t.lowerBoundsBPM[zone - 1] : nil
            let upper = zone < t.lowerBoundsBPM.count ? t.lowerBoundsBPM[zone] : t.maxHeartRate.bpm
            let rangeText = lower.map { "\(Int($0.rounded()))–\(Int(upper.rounded())) bpm" } ?? ""
            return ZoneTimeDisplay(zone: zone, label: HeartRateZones.label(forZone: zone), rangeText: rangeText, millis: ms,
                                   fraction: Double(ms) / total)
        }
    }

    public static func activity(_ ctx: LoaderContext, live: LiveWorkoutState?, days: Int = 60) throws -> ActivityState {
        let zones = HeartRateZones.resolve(profile: ctx.profile, asOf: ctx.now, calendar: ctx.calendar, model: ctx.zoneModel,
                                           overnightRestingHeartRate: nil)
        let thresholds = zones.thresholds()
        let range = TimeRange(start: ctx.now - Int64(days) * EpochMillis.millisPerDay, end: ctx.now)
        let sessions = try ctx.store.sessions(kind: .workout, in: range, includeCandidates: false, includeDeleted: false)
            .sorted { $0.range.start > $1.range.start }
        var workouts: [WorkoutState] = []
        for s in sessions {
            let hr = try heartRates(ctx, in: s.range)
            let summary = WorkoutAnalyzer.summarize(range: s.range, series: HeartRateSeries(hr), zones: zones)
            let maxHR: MetricValue<Double> = summary.maxHeartRate.value.map {
                MetricValue(value: Double($0), availability: .available, coverage: summary.coverage, confidence: summary.maxHeartRate.confidence,
                            window: s.range, specID: summary.maxHeartRate.specID, specVersion: summary.maxHeartRate.specVersion)
            } ?? .unavailable(summary.maxHeartRate.availability, specID: summary.maxHeartRate.specID, specVersion: summary.maxHeartRate.specVersion)
            workouts.append(WorkoutState(session: s, averageHR: summary.meanHeartRate, maxHR: maxHR, load: summary.edwardsTRIMP,
                                         zones: zoneDisplays(summary.timeInZones, thresholds: summary.zoneThresholds),
                                         zonesAvailability: summary.timeInZones.availability,
                                         heartRate: series(hr, window: s.range), coverage: summary.coverage))
        }
        return ActivityState(live: live, workouts: workouts, zonesAvailability: thresholds.availability)
    }

    /// Live workout state from the samples recorded since `start`.
    public static func liveWorkout(_ ctx: LoaderContext, start: EpochMillis, recentSamples: [HeartRateSample], sourceLabel: String?) -> LiveWorkoutState {
        let window = TimeRange(start: start, end: max(start + 60_000, ctx.now))
        let usable = HeartRateSeries.usable(recentSamples).filter { window.contains($0.timestamp) }
        let latest = usable.max(by: { $0.timestamp < $1.timestamp })
        let zones = HeartRateZones.resolve(profile: ctx.profile, asOf: ctx.now, calendar: ctx.calendar, model: ctx.zoneModel)
        let summary = WorkoutAnalyzer.summarize(range: TimeRange(start: start, end: ctx.now), samples: usable, zones: zones)
        let stale = latest.map { ctx.now - $0.timestamp > 15_000 } ?? true
        return LiveWorkoutState(start: start, now: ctx.now, currentHR: stale ? nil : latest?.bpm,
                                currentZone: latest.flatMap { zones.zone(forBPM: Double($0.bpm)) },
                                signalStale: stale, zones: zoneDisplays(summary.timeInZones, thresholds: summary.zoneThresholds),
                                heartRate: series(usable, window: window, maxPoints: 300, maxGapMillis: 15_000), sourceLabel: sourceLabel)
    }

    // MARK: Trends

    public static func trends(_ ctx: LoaderContext, metric: TrendMetric, period: TrendPeriod) throws -> TrendsState {
        let last = LocalDay(ctx.now, calendar: ctx.calendar)
        let daily: DailyMetric
        switch metric {
        case .restingHR: daily = .restingHR
        case .hrv: daily = .hrv
        case .sleepDuration: daily = .sleepMinutes
        case .load: daily = .load
        }
        let values = try dailySeries(ctx, daily, endingOn: last, days: period.days)
        // Sleep is shown in hours.
        let display: [LocalDay: Double?] = values.mapValues { v in v.map { metric == .sleepDuration ? $0 / 60 : $0 } }
        let digits = metric == .sleepDuration ? 1 : 0
        let rows = display.keys.sorted().map { day -> DailyValue in
            let v = display[day] ?? nil
            return DailyValue(day: day, dayStart: day.range(calendar: ctx.calendar).start, value: v,
                              valueText: v.map { DisplayFormat.number($0, digits: digits) } ?? "")
        }
        let summary = TrendAnalyzer.summary(of: display, period: period, endingOn: last, calendar: ctx.calendar, metricID: daily.rawValue)
        var summaryRows: [TrendSummaryRow] = []
        if let st = summary.statistics.value {
            let unit = metric.unit
            summaryRows = [
                TrendSummaryRow(label: "Days with a value", value: "\(st.daysWithData) of \(period.days)"),
                TrendSummaryRow(label: "Mean", value: "\(DisplayFormat.number(st.mean, digits: digits)) \(unit)"),
                TrendSummaryRow(label: "Median", value: "\(DisplayFormat.number(st.median, digits: digits)) \(unit)"),
                TrendSummaryRow(label: "Range", value: "\(DisplayFormat.number(st.minimum, digits: digits))–\(DisplayFormat.number(st.maximum, digits: digits)) \(unit)"),
            ]
            if let sd = st.standardDeviation {
                summaryRows.append(TrendSummaryRow(label: "Standard deviation", value: "\(DisplayFormat.number(sd, digits: digits)) \(unit)"))
            }
        }
        var comparison: String?
        let rvp = TrendAnalyzer.recentVersusPrior(of: display, endingOn: last, calendar: ctx.calendar, metricID: daily.rawValue)
        if let c = rvp.value {
            comparison = "Last 7 days averaged \(DisplayFormat.number(c.recentMean, digits: digits)) \(metric.unit) (\(c.recentDays) days), compared with \(DisplayFormat.number(c.priorMean, digits: digits)) \(metric.unit) over the 28 days before (\(c.priorDays) days): a difference of \(DisplayFormat.signed(c.difference, digits: digits)) \(metric.unit)."
        }
        return TrendsState(metric: metric, period: period, daily: rows, availability: summary.statistics.availability,
                           summary: summaryRows, comparison: comparison)
    }

    public static func specID(for metric: TrendMetric) -> String {
        switch metric {
        case .restingHR: return MetricID.overnightRestingHeartRate
        case .hrv: return MetricID.hrvRMSSD
        case .sleepDuration: return MetricID.sleepSummary
        case .load: return MetricID.edwardsLoad
        }
    }
}
