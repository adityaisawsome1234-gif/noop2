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
    /// The band's motion data is decoded but not validated (raw counts of unpublished scale).
    public var motionNeedsValidation: Bool
    /// The user explicitly allowed unvalidated motion data for proposing sleep windows (Diagnostics).
    /// It is used for nothing else: time asleep, wake bouts and continuity use validated motion only.
    public var allowUnvalidatedMotion: Bool
    /// Which band-history heart rate may enter metrics.
    public var historyHeartRatePolicy: HistoryHeartRatePolicy
    /// Drop records with the `.demo` source and sessions of the demo band (set for the live store, so
    /// synthetic data can never appear as the user's own).
    public var excludesDemoData: Bool
    /// Orders cached-value writes against invalidations; nil writes directly.
    public var cacheGate: DerivedCacheGate?
    /// `cacheGate`'s epoch when this context was made, before any data was read.
    public var cacheEpoch: UInt64

    /// Band-history heart rate may enter metrics (all of it, or the validated batches).
    public var historyHeartRateValidated: Bool {
        get {
            if case .none = historyHeartRatePolicy { return false }
            return true
        }
        set { historyHeartRatePolicy = newValue ? .all : .none }
    }

    public init(store: FormaStore, calendar: Calendar, now: EpochMillis, profile: UserProfile, zoneModel: HeartRateZoneModel,
                showReadiness: Bool, deviceID: String?, bandKeepsHistory: Bool, beatIntervalsSupported: Bool,
                motionSupported: Bool, motionNeedsValidation: Bool, historyHeartRateValidated: Bool, allowUnvalidatedMotion: Bool,
                excludesDemoData: Bool = false, cacheGate: DerivedCacheGate? = nil) {
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
        self.allowUnvalidatedMotion = allowUnvalidatedMotion
        self.historyHeartRatePolicy = historyHeartRateValidated ? .all : .none
        self.excludesDemoData = excludesDemoData
        self.cacheGate = cacheGate
        self.cacheEpoch = cacheGate?.currentEpoch ?? 0
    }
}

/// Computes display state for each screen from the store and the analytics module. Pure apart from
/// reading the store, caching daily metrics in it and (in `proposeSleepCandidates`) nothing else.
public enum ScreenLoader {
    // MARK: Data access with validation filtering

    /// Records with these flags have an uncertain absolute time (next to a band clock jump, reset or
    /// restart) and are kept out of every metric (METHODOLOGY §2).
    static let uncertainTimeFlags: QualityFlags = [.nearClockDiscontinuity]

    static func isExcluded(_ source: MeasurementSource, _ ctx: LoaderContext) -> Bool {
        ctx.excludesDemoData && source == .demo
    }

    /// Heart rate usable for metrics: drops demo records in the live store, records with an uncertain
    /// time, and fields still awaiting validation (band history only from batches whose adapter and
    /// firmware passed validation, see `HistoryHeartRatePolicy`).
    static func heartRates(_ ctx: LoaderContext, in range: TimeRange) throws -> [HeartRateSample] {
        let raw = try ctx.store.heartRates(in: range, deviceID: ctx.deviceID)
        return raw.filter { s in
            guard !isExcluded(s.source, ctx), s.quality.isDisjoint(with: uncertainTimeFlags) else { return false }
            guard s.quality.contains(.unvalidatedField) else { return true }
            return s.source == .deviceHistory && historyAdmitted(batchID: s.batchID, ctx)
        }
    }

    static func historyAdmitted(batchID: Int64?, _ ctx: LoaderContext) -> Bool {
        switch ctx.historyHeartRatePolicy {
        case .none: return false
        case .all: return true
        case .validatedBatches(let keys, let cache):
            guard let key = cache.key(for: batchID, in: ctx.store) else { return false }
            return keys.contains(key)
        }
    }

    static func beats(_ ctx: LoaderContext, in range: TimeRange) throws -> [BeatInterval]? {
        let raw = try ctx.store.beatIntervals(in: range, deviceID: ctx.deviceID).filter {
            !isExcluded($0.source, ctx) && !$0.quality.contains(.unvalidatedField) && $0.quality.isDisjoint(with: uncertainTimeFlags)
        }
        if raw.isEmpty && !ctx.beatIntervalsSupported { return nil }
        return raw
    }

    /// Motion for sleep metrics inside a confirmed window (time asleep, wake bouts, continuity): validated
    /// motion only. nil when the band has no motion path ("unsupported").
    static func motion(_ ctx: LoaderContext, in range: TimeRange) throws -> [MotionEpoch]? {
        try motion(ctx, in: range, allowUnvalidated: false)
    }

    /// Motion for proposing sleep candidates (which the user then confirms): unvalidated motion only
    /// after the user explicitly allowed it.
    static func candidateMotion(_ ctx: LoaderContext, in range: TimeRange) throws -> [MotionEpoch]? {
        try motion(ctx, in: range, allowUnvalidated: ctx.allowUnvalidatedMotion)
    }

    private static func motion(_ ctx: LoaderContext, in range: TimeRange, allowUnvalidated: Bool) throws -> [MotionEpoch]? {
        guard ctx.motionSupported else { return nil }
        return try ctx.store.motion(in: range, deviceID: ctx.deviceID).filter {
            !isExcluded($0.source, ctx) && $0.quality.isDisjoint(with: uncertainTimeFlags)
                && (allowUnvalidated || !$0.quality.contains(.unvalidatedField))
        }
    }

    /// Sessions overlapping `range`; in the live store without the demo band's sessions.
    static func sessions(_ ctx: LoaderContext, kind: SessionKind, in range: TimeRange, includeCandidates: Bool,
                         includeDeleted: Bool = false) throws -> [Session] {
        let all = try ctx.store.sessions(kind: kind, in: range, includeCandidates: includeCandidates, includeDeleted: includeDeleted)
        guard ctx.excludesDemoData else { return all }
        return all.filter { $0.deviceID != DemoDataGenerator.deviceID }
    }

    static func maxHeartRate(_ ctx: LoaderContext) -> MaxHeartRate? {
        MaxHeartRateResolver.resolve(profile: ctx.profile, asOf: ctx.now, calendar: ctx.calendar).value
    }

    /// Newest band-history record time already persisted for the context's device (sync cursor).
    static func newestPersistedHistory(_ ctx: LoaderContext) throws -> EpochMillis? {
        guard let deviceID = ctx.deviceID else { return nil }
        return try ctx.store.syncCursor(deviceID: deviceID)?.newestPersistedRecordTime
    }

    // MARK: Charts

    /// Builds a gap-preserving, down-sampled series for charts (≤ `maxPoints` points while there are
    /// fewer gaps than points). Each point sits at the time of its first sample, so ids stay unique even
    /// when a gap splits a bucket.
    public static func series(_ samples: [HeartRateSample], window: TimeRange, maxPoints: Int = 600,
                              maxGapMillis: Int64 = 60_000) -> SeriesDisplay {
        let canonical = HeartRateSeries.canonical(HeartRateSeries.usable(samples)).filter { window.contains($0.timestamp) }
        guard !canonical.isEmpty else { return .empty(unit: "bpm", window: window) }
        // Each gap can split one bucket in two, so the bucket budget leaves room for them.
        var gaps = 0
        for (a, b) in zip(canonical, canonical.dropFirst()) where b.timestamp - a.timestamp > maxGapMillis { gaps += 1 }
        let budget = Int64(max(1, maxPoints - gaps))
        let duration = max(1, window.durationMillis)
        let bucket = max(1_000, duration / budget + (duration % budget == 0 ? 0 : 1))
        var points: [ChartPoint] = []
        var segment = 0
        var previous: EpochMillis?
        var bucketIndex: Int64?
        var partStart: EpochMillis = 0
        var sum = 0.0, count = 0
        func flush() {
            if count > 0 { points.append(ChartPoint(t: partStart, value: sum / Double(count), segment: segment)) }
            sum = 0; count = 0; bucketIndex = nil
        }
        for s in canonical {
            if let p = previous, s.timestamp - p > maxGapMillis {
                flush()
                segment += 1
            }
            let b = (s.timestamp - window.start) / bucket
            if bucketIndex != b {
                flush()
                bucketIndex = b
                partStart = s.timestamp
            }
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

    /// Spec version of the cache rows. Rows are also checked against `dailyFingerprint`, which carries
    /// everything else a value depends on.
    static let dailyCacheVersion = 1
    /// Bump when the filters or the computation of the daily values change.
    static let dailyCacheFormat = "daily-v2"

    /// Everything a cached daily value depends on apart from the data in its window (whose changes
    /// invalidate it explicitly): device filter, demo exclusion, which history heart rate is admitted,
    /// the analytics spec versions and, for load, HRmax. A cached row with another fingerprint is
    /// recomputed, so switching bands or changing the profile never shows values computed for other inputs.
    static func dailyFingerprint(_ ctx: LoaderContext, _ metric: DailyMetric) -> String {
        var parts = [dailyCacheFormat, "device=\(ctx.deviceID ?? "*")", ctx.excludesDemoData ? "no-demo" : "any-source",
                     "history=\(ctx.historyHeartRatePolicy.fingerprint)", "hr@\(MetricCatalog.heartRateSeries.version)"]
        switch metric {
        case .restingHR:
            parts.append("rhr@\(MetricCatalog.overnightRestingHeartRate.version)")
        case .hrv, .lnHRV:
            parts.append("hrv@\(MetricCatalog.hrvRMSSD.version)")
        case .sleepMinutes:
            parts.append("sleep-window@\(MetricCatalog.sleepSummary.version)")
        case .load:
            parts.append("load@\(MetricCatalog.edwardsLoad.version)")
            if let m = maxHeartRate(ctx) {
                parts.append("hrmax=\(DisplayFormat.number(m.bpm, digits: 2))/\(m.basis.rawValue)")
            } else {
                parts.append("hrmax=none")
            }
        }
        let object = ["fingerprint": parts.joined(separator: ";")]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The confirmed sleep windows that ended on `day`.
    static func confirmedSleep(_ ctx: LoaderContext, endingOn day: LocalDay) throws -> [Session] {
        let range = day.range(calendar: ctx.calendar)
        return try sessions(ctx, kind: .sleep, in: TimeRange(start: range.start - 24 * 3_600_000, end: range.end),
                            includeCandidates: false)
            .filter { $0.isConfirmed && range.contains($0.range.end - 1) }
    }

    /// The window used for a day's overnight values (resting HR, HRV): the one covering most of
    /// 00:00–05:00 of that day, so an afternoon nap is not taken for the night; the longest if none does.
    static func mainNight(_ nights: [Session], day: LocalDay, calendar: Calendar) -> Session? {
        let dayStart = day.range(calendar: calendar).start
        let core = TimeRange(start: dayStart, end: dayStart + 5 * 3_600_000)
        func coreOverlap(_ s: Session) -> Int64 { s.range.intersection(core)?.durationMillis ?? 0 }
        return nights.max { a, b in
            let (oa, ob) = (coreOverlap(a), coreOverlap(b))
            return oa != ob ? oa < ob : a.range.durationMillis < b.range.durationMillis
        }
    }

    /// The ranges with overlaps merged, in time order (so overlapping windows are never counted twice).
    static func union(_ ranges: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        for r in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.start < $1.start }) {
            if let last = out.last, r.start <= last.end {
                out[out.count - 1] = TimeRange(start: last.start, end: max(last.end, r.end))
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Computes (or reads from cache) one daily value. `nil` = no value for that day. Only completed days
    /// are cached; a value is cached only if nothing overlapping its day was invalidated meanwhile.
    static func dailyValue(_ ctx: LoaderContext, _ metric: DailyMetric, day: LocalDay) throws -> Double? {
        let window = day.range(calendar: ctx.calendar)
        let isComplete = window.end <= ctx.now
        let fingerprint = dailyFingerprint(ctx, metric)
        if isComplete, let cached = try ctx.store.derived(metricID: metric.rawValue, in: window, specVersion: dailyCacheVersion)
            .first(where: { $0.window == window }), cached.inputsJSON == fingerprint {
            return cached.value
        }
        let value: Double?
        let availability: String
        switch metric {
        case .restingHR, .hrv, .lnHRV:
            guard let night = mainNight(try confirmedSleep(ctx, endingOn: day), day: day, calendar: ctx.calendar) else {
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
            // One definition for every night: time in the confirmed window(s), overlaps merged. (A motion
            // estimate is shown per night where validated motion exists, but a series that switched
            // definitions from night to night would show the switch rather than a change in sleep.)
            let nights = try confirmedSleep(ctx, endingOn: day)
            if nights.isEmpty {
                value = nil; availability = "no confirmed sleep window"
            } else {
                let total = union(nights.map(\.range)).reduce(Int64(0)) { $0 + $1.durationMillis }
                value = Double(total) / 60_000; availability = "available (time in confirmed sleep windows)"
            }
        case .load:
            let hr = try heartRates(ctx, in: window)
            let load = TrainingLoad.dailyLoad(day: day, calendar: ctx.calendar, series: HeartRateSeries(hr), hrMax: maxHeartRate(ctx))
            value = load.value
            availability = load.availability.explanation
        }
        if isComplete {
            let record = DerivedMetricRecord(metricID: metric.rawValue, specVersion: dailyCacheVersion, window: window, value: value,
                                             unit: "", availability: availability, coverage: nil, confidence: value == nil ? .none : .moderate,
                                             inputsJSON: fingerprint, computedAt: ctx.now)
            if let gate = ctx.cacheGate {
                gate.write(window: window, computedAt: ctx.cacheEpoch) { try? ctx.store.putDerived([record]) }
            } else {
                try? ctx.store.putDerived([record])
            }
        }
        return value
    }

    static func days(endingOn last: LocalDay, count: Int, calendar: Calendar) -> [LocalDay] {
        (0..<max(1, count)).map { last.adding(days: -$0, calendar: calendar) }.reversed()
    }

    static func dailySeries(_ ctx: LoaderContext, _ metric: DailyMetric, endingOn last: LocalDay, days count: Int) throws -> [LocalDay: Double?] {
        var out: [LocalDay: Double?] = [:]
        for day in days(endingOn: last, count: count, calendar: ctx.calendar) {
            out[day] = try dailyValue(ctx, metric, day: day)
        }
        return out
    }

    // MARK: Today

    /// A heart-rate value older than this is not presented as current.
    public static let liveThresholdMillis: Int64 = 120_000

    static func latestHeartRate(_ usable: [HeartRateSample], now: EpochMillis) -> LatestHeartRate? {
        guard let s = usable.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
        return LatestHeartRate(bpm: s.bpm, at: s.timestamp, sourceLabel: s.source.description,
                               isStale: now - s.timestamp > liveThresholdMillis)
    }

    /// The newest usable heart rate of the last `lookback` ms (cheap: keeps Today's value current between
    /// full refreshes while the band streams).
    public static func latestHeartRate(_ ctx: LoaderContext, lookback: Int64 = 5 * 60_000) throws -> LatestHeartRate? {
        let hr = try heartRates(ctx, in: TimeRange(start: ctx.now - lookback, end: ctx.now))
        return latestHeartRate(HeartRateSeries.usable(hr), now: ctx.now)
    }

    public static func today(_ ctx: LoaderContext) throws -> TodayState {
        let day = LocalDay(ctx.now, calendar: ctx.calendar)
        let dayRange = day.range(calendar: ctx.calendar)
        let last24 = TimeRange(start: ctx.now - EpochMillis.millisPerDay, end: ctx.now)
        let hr24 = try heartRates(ctx, in: last24)
        let usable24 = HeartRateSeries.usable(hr24)
        let hasAnyData = try ctx.store.dataBounds() != nil
        let latest = latestHeartRate(usable24, now: ctx.now)

        var cards: [MetricCardState] = []
        let nights = try confirmedSleep(ctx, endingOn: day)
        let mainNight = mainNight(nights, day: day, calendar: ctx.calendar)

        // Resting heart rate (overnight)
        if let night = mainNight {
            let rhr = RestingHeartRateEstimator.estimate(sleepWindow: night.range, series: HeartRateSeries(try heartRates(ctx, in: night.range)))
            cards.append(MetricCardState(id: "rhr", title: "Resting HR (overnight)", metric: rhr.restingHeartRate, unit: "bpm",
                                         valueText: DisplayFormat.metric(rhr.restingHeartRate, digits: 0), status: .estimate,
                                         footnote: RestingHeartRateEstimator.label))
        } else {
            cards.append(MetricCardState(id: "rhr", title: "Resting HR (overnight)",
                                         metric: .unavailable(.insufficientData(detail: "Needs a confirmed sleep window for last night"),
                                                              specID: MetricID.overnightRestingHeartRate, specVersion: 1),
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
            cards.append(MetricCardState(id: "hrv", title: "HRV (RMSSD)", metric: .unavailable(availability, specID: MetricID.hrvRMSSD, specVersion: 1),
                                         unit: "ms", valueText: nil, status: .estimate))
        }

        // Sleep (confirmed windows only; overlapping windows merged so nothing is counted twice)
        if nights.isEmpty {
            cards.append(MetricCardState(id: "sleep", title: "Sleep",
                                         metric: .unavailable(.insufficientData(detail: "No confirmed sleep window ending today"),
                                                              specID: MetricID.sleepSummary, specVersion: 1),
                                         unit: "h", valueText: nil, status: .estimate))
        } else {
            let windows = union(nights.map(\.range))
            var estimateMs: Int64 = 0
            var allEstimated = true
            for w in windows {
                let summary = SleepSummary.fromConfirmedWindow(w, motion: try motion(ctx, in: w), heartRate: nil)
                if let est = summary.sleepDurationEstimate.value { estimateMs += est } else { allEstimated = false }
            }
            let inWindowMs = windows.reduce(Int64(0)) { $0 + $1.durationMillis }
            let usedMotion = allEstimated
            let hours = Double(usedMotion ? estimateMs : inWindowMs) / 3_600_000
            let metric = MetricValue<Double>(value: hours, availability: .available, coverage: nil,
                                             confidence: usedMotion ? .moderate : .low, window: mainNight?.range,
                                             specID: MetricID.sleepSummary, specVersion: 1,
                                             inputs: ["basis": usedMotion ? "sleep estimate from motion" : "time in confirmed window"])
            let footnote: String? = usedMotion ? nil
                : (ctx.motionNeedsValidation
                    ? "Motion data from this band is not validated: this is the confirmed window length, not measured sleep."
                    : "No usable motion data: this is the confirmed window length, not measured sleep.")
            cards.append(MetricCardState(id: "sleep", title: usedMotion ? "Sleep (estimate)" : "Time in sleep window", metric: metric,
                                         unit: "h", valueText: DisplayFormat.number(hours, digits: 1), status: .estimate,
                                         footnote: footnote))
        }

        // Forma Load today: the day is not over, so this is the load so far.
        let todaySeries = HeartRateSeries(try heartRates(ctx, in: dayRange))
        let dayInProgress = ctx.now < dayRange.end
        cards.append(loadSoFarCard(day: day, dayRange: dayRange, series: todaySeries, dayInProgress: dayInProgress, ctx))

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

        let coverage = CoverageTimeline.build(window: last24, sampleTimes: usable24.map(\.timestamp),
                                              bandKeepsHistory: ctx.bandKeepsHistory,
                                              newestPersistedHistory: try newestPersistedHistory(ctx))

        let recent = try sessions(ctx, kind: .sleep, in: TimeRange(start: ctx.now - 36 * 3_600_000, end: ctx.now),
                                  includeCandidates: true)
        let confirmedRecent = recent.filter(\.isConfirmed)
        let candidates = recent.filter { c in
            c.origin == .detectedCandidate && !confirmedRecent.contains { $0.range.overlaps(c.range) }
        }
        return TodayState(day: day, latestHeartRate: latest, cards: cards, readiness: readinessCard, coverage24h: coverage,
                          pendingSleepReview: candidates.max(by: { $0.range.end < $1.range.end }), calibration: calibration,
                          hasAnyData: hasAnyData)
    }

    /// Today's Forma Load. The daily gate needs heart rate for 30 % of the whole day, which a morning
    /// cannot have; while the day is in progress the load of `[00:00, now)` is also accepted when heart
    /// rate covers at least half of that elapsed time (the workout gate), and the card says "so far".
    static func loadSoFarCard(day: LocalDay, dayRange: TimeRange, series: HeartRateSeries, dayInProgress: Bool,
                              _ ctx: LoaderContext) -> MetricCardState {
        let hrMax = maxHeartRate(ctx)
        var load = TrainingLoad.dailyLoad(day: day, calendar: ctx.calendar, series: series, hrMax: hrMax)
        let elapsed = TimeRange(start: dayRange.start, end: min(ctx.now, dayRange.end))
        if dayInProgress, !load.availability.isAvailable, hrMax != nil, !elapsed.isEmpty, case .lowQuality = load.availability {
            let soFar = TrainingLoad.workoutLoad(range: elapsed, series: series, hrMax: hrMax)
            if soFar.availability.isAvailable {
                load = soFar
            } else {
                let covered = series.coverage(in: elapsed) ?? 0
                load = .unavailable(.lowQuality(detail: "Heart rate covers \(DisplayFormat.percent(covered)) of today so far; a value appears once it covers \(DisplayFormat.percent(TrainingLoad.workoutMinimumCoverage)) of the day so far or \(DisplayFormat.percent(TrainingLoad.dailyMinimumCoverage)) of the whole day"),
                                    specID: MetricID.edwardsLoad, specVersion: MetricCatalog.edwardsLoad.version,
                                    window: elapsed, coverage: covered)
            }
        }
        return MetricCardState(id: "load", title: dayInProgress ? "Forma Load (today so far)" : "Forma Load (today)", metric: load,
                               unit: "TRIMP", valueText: DisplayFormat.metric(load, digits: 0), status: .estimate)
    }

    static func readinessState(_ r: ReadinessResult) -> ReadinessCardState {
        // The card shows the composite with one decimal; the band follows that shown value, so "+1.0 SD"
        // never reads "Above your usual range" (the documented band is −1.0…+1.0 inclusive).
        var bandText: String?
        if let composite = r.composite.value, r.composite.availability.isAvailable {
            let shown = (abs(composite) * 10).rounded() / 10 * (composite < 0 ? -1 : 1)
            let threshold = r.parameters.bandThreshold
            bandText = shown > threshold ? "Above your usual range"
                : (shown < -threshold ? "Below your usual range" : "Within your usual range")
        }
        let rows = r.components.map { c -> ReadinessComponentRow in
            let name: String
            let digits: Int
            switch c.kind {
            case .hrv: name = "HRV (ln RMSSD)"; digits = 2
            case .restingHeartRate: name = "Resting heart rate"; digits = 1
            case .sleepDuration: name = "Time in sleep window"; digits = 0
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

    static let unvalidatedMotionReason = "Motion data from this band is not validated yet, so Forma does not estimate time asleep or wake bouts within the window."

    public static func sleep(_ ctx: LoaderContext, nights: Int = 14) throws -> SleepState {
        let range = TimeRange(start: ctx.now - Int64(nights) * EpochMillis.millisPerDay, end: ctx.now)
        let all = try sessions(ctx, kind: .sleep, in: range, includeCandidates: true)
        let confirmed = all.filter(\.isConfirmed)
        // A candidate the user already covered with a window of their own is not offered again.
        let visible = all.filter { s in s.isConfirmed || !confirmed.contains { $0.range.overlaps(s.range) } }
            .sorted { $0.range.end > $1.range.end }
        let newestHistory = try newestPersistedHistory(ctx)
        var states: [NightState] = []
        for s in visible {
            let hr = try heartRates(ctx, in: s.range)
            let mot = try motion(ctx, in: s.range)
            let summary = SleepSummary.fromConfirmedWindow(s.range, motion: mot, heartRate: hr)
            let motionWithheld = ctx.motionNeedsValidation && summary.sleepDurationEstimate.value == nil
            let sleepEst: MetricValue<Double> = summary.sleepDurationEstimate.value.map {
                MetricValue(value: Double($0) / 3_600_000, availability: .available, coverage: summary.motionCoverage,
                            confidence: summary.sleepDurationEstimate.confidence, window: s.range, specID: MetricID.sleepSummary, specVersion: 1)
            } ?? .unavailable(motionWithheld ? .disabled(reason: unvalidatedMotionReason)
                                : (mot == nil ? .unsupportedSensor(sensor: SleepDetector.motionSensorName) : summary.sleepDurationEstimate.availability),
                              specID: MetricID.sleepSummary, specVersion: 1, window: s.range)
            let continuity: MetricValue<Double> = motionWithheld
                ? .unavailable(.disabled(reason: unvalidatedMotionReason), specID: summary.continuity.specID,
                               specVersion: summary.continuity.specVersion, window: s.range)
                : summary.continuity
            let rhr = RestingHeartRateEstimator.estimate(sleepWindow: s.range, series: HeartRateSeries(hr)).restingHeartRate
            let hrv = HRVAnalyzer.analyze(beats: try beats(ctx, in: s.range), range: s.range).rmssd
            let coverage = CoverageTimeline.build(window: s.range, sampleTimes: HeartRateSeries.usable(hr).map(\.timestamp),
                                                  bandKeepsHistory: ctx.bandKeepsHistory, newestPersistedHistory: newestHistory)
            states.append(NightState(session: s, timeInBedHours: Double(s.range.durationMillis) / 3_600_000, sleepEstimate: sleepEst,
                                     continuity: continuity, restingHR: rhr, hrv: hrv,
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
    /// a sleep session (including a rejected one) already overlaps that night or detection is unavailable.
    public static func proposeSleepCandidate(_ ctx: LoaderContext, nightEndingOn day: LocalDay) throws -> Session? {
        guard ctx.motionSupported, !(ctx.motionNeedsValidation && !ctx.allowUnvalidatedMotion) else { return nil }
        guard let window = SleepDetector.window(nightEndingOn: day, calendar: ctx.calendar), window.end <= ctx.now else { return nil }
        let existing = try sessions(ctx, kind: .sleep, in: window, includeCandidates: true, includeDeleted: true)
        guard existing.isEmpty else { return nil }
        let result = SleepDetector.detect(nightEndingOn: day, calendar: ctx.calendar, motion: try candidateMotion(ctx, in: window),
                                          heartRate: try heartRates(ctx, in: window))
        guard let c = result.value else { return nil }
        return Session(kind: .sleep, range: c.range, origin: .detectedCandidate, deviceID: ctx.deviceID,
                       detector: "\(MetricID.sleepCandidate)@v\(result.specVersion)", confidence: c.confidence,
                       createdAt: ctx.now, updatedAt: ctx.now)
    }

    /// Candidates for the nights ending today and the `nights - 1` days before, whose (noon-to-noon)
    /// detection window has ended — so a night is still proposed when the app is first opened the next
    /// morning, not only after noon of the day it ended.
    public static func proposeSleepCandidates(_ ctx: LoaderContext, nights: Int = 3) throws -> [Session] {
        guard ctx.motionSupported, !(ctx.motionNeedsValidation && !ctx.allowUnvalidatedMotion) else { return [] }
        let today = LocalDay(ctx.now, calendar: ctx.calendar)
        return try (0..<max(1, nights)).compactMap { offset in
            try proposeSleepCandidate(ctx, nightEndingOn: today.adding(days: -offset, calendar: ctx.calendar))
        }
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

    /// Forma's recent overnight resting heart rate: the median of the last `nights` nights' estimates.
    public static func recentOvernightRestingHeartRate(_ ctx: LoaderContext, nights: Int = 7) throws -> Double? {
        let today = LocalDay(ctx.now, calendar: ctx.calendar)
        let values = try dailySeries(ctx, .restingHR, endingOn: today, days: nights).values.compactMap { $0 }.sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        return values.count % 2 == 1 ? values[mid] : (values[mid - 1] + values[mid]) / 2
    }

    /// The overnight resting heart rate heart-rate-reserve zones use when the profile has none (nil when
    /// the zone model does not need it).
    public static func overnightRestingHeartRateIfNeeded(_ ctx: LoaderContext) throws -> Double? {
        guard ctx.zoneModel == .heartRateReserve else { return nil }
        if let entered = ctx.profile.restingHeartRateOverride, HeartRateZones.restingHeartRateRange.contains(Double(entered)) { return nil }
        return try recentOvernightRestingHeartRate(ctx)
    }

    public static func activity(_ ctx: LoaderContext, live: LiveWorkoutState?, days: Int = 60) throws -> ActivityState {
        let zones = HeartRateZones.resolve(profile: ctx.profile, asOf: ctx.now, calendar: ctx.calendar, model: ctx.zoneModel,
                                           overnightRestingHeartRate: try overnightRestingHeartRateIfNeeded(ctx))
        let thresholds = zones.thresholds()
        let range = TimeRange(start: ctx.now - Int64(days) * EpochMillis.millisPerDay, end: ctx.now)
        let sessions = try sessions(ctx, kind: .workout, in: range, includeCandidates: false)
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

    /// Live workout state from the samples recorded since `start`. When no sample arrived recently,
    /// neither a heart rate nor a zone is presented as current.
    public static func liveWorkout(_ ctx: LoaderContext, start: EpochMillis, recentSamples: [HeartRateSample], sourceLabel: String?,
                                   overnightRestingHeartRate: Double? = nil) -> LiveWorkoutState {
        let window = TimeRange(start: start, end: max(start + 60_000, ctx.now))
        let usable = HeartRateSeries.usable(recentSamples).filter { window.contains($0.timestamp) }
        let latest = usable.max(by: { $0.timestamp < $1.timestamp })
        let zones = HeartRateZones.resolve(profile: ctx.profile, asOf: ctx.now, calendar: ctx.calendar, model: ctx.zoneModel,
                                           overnightRestingHeartRate: overnightRestingHeartRate)
        let summary = WorkoutAnalyzer.summarize(range: TimeRange(start: start, end: ctx.now), samples: usable, zones: zones)
        let stale = latest.map { ctx.now - $0.timestamp > 15_000 } ?? true
        return LiveWorkoutState(start: start, now: ctx.now, currentHR: stale ? nil : latest?.bpm,
                                currentZone: stale ? nil : latest.flatMap { zones.zone(forBPM: Double($0.bpm)) },
                                signalStale: stale, zones: zoneDisplays(summary.timeInZones, thresholds: summary.zoneThresholds),
                                heartRate: series(usable, window: window, maxPoints: 300, maxGapMillis: 15_000), sourceLabel: sourceLabel)
    }

    // MARK: Trends

    public static func trends(_ ctx: LoaderContext, metric: TrendMetric, period: TrendPeriod) throws -> TrendsState {
        let today = LocalDay(ctx.now, calendar: ctx.calendar)
        let daily: DailyMetric
        switch metric {
        case .restingHR: daily = .restingHR
        case .hrv: daily = .hrv
        case .sleepDuration: daily = .sleepMinutes
        case .load: daily = .load
        }
        // Forma Load accumulates over the day, so today's value is partial: the series ends yesterday
        // (today's load so far is on the Today screen). Overnight values for today are complete.
        let last = metric == .load ? today.adding(days: -1, calendar: ctx.calendar) : today
        // The 7-vs-28-day comparison always uses its own 35 days, whatever period is shown.
        let span = max(period.days, TrendAnalyzer.recentDays + TrendAnalyzer.priorDays)
        let values = try dailySeries(ctx, daily, endingOn: last, days: span)
        // Sleep is shown in hours.
        let display: [LocalDay: Double?] = values.mapValues { v in v.map { metric == .sleepDuration ? $0 / 60 : $0 } }
        let digits = metric == .sleepDuration ? 1 : 0
        let rows = days(endingOn: last, count: period.days, calendar: ctx.calendar).map { day -> DailyValue in
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
