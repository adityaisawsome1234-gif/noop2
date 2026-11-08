import FormaCore

/// Stable identifiers of every metric FormaAnalytics produces.
public enum MetricID {
    public static let heartRateSeries = "forma.hr.series"
    public static let maxHeartRate = "forma.hr.max"
    public static let heartRateZones = "forma.hr.zones"
    public static let workoutSummary = "forma.workout.summary"
    public static let overnightRestingHeartRate = "forma.rhr.overnight"
    public static let hrvRMSSD = "forma.hrv.rmssd"
    /// Natural log of the period RMSSD (unit ln(ms)), reported next to `hrvRMSSD`.
    public static let hrvLnRMSSD = "forma.hrv.lnrmssd"
    public static let hrvRawRMSSD = "forma.hrv.rmssd.raw"
    public static let trends = "forma.trends"
    public static let baseline = "forma.baseline"
    public static let sleepCandidate = "forma.sleep.candidate"
    public static let sleepSummary = "forma.sleep.summary"
    /// Continuity of a confirmed sleep window (a fraction 0…1).
    public static let sleepContinuity = "forma.sleep.continuity"
    /// Mean heart rate inside a confirmed sleep window (bpm).
    public static let sleepHeartRate = "forma.sleep.heartrate"
    public static let edwardsLoad = "forma.load.edwards"
    public static let banisterTRIMP = "forma.load.banister"
    public static let readiness = "forma.readiness.experimental"
}

/// The methodology of every derived metric, rendered by the Methodology screen.
///
/// The texts are built from the same constants and default parameters the code uses, so the
/// documentation states the values the implementation applies. Every `MetricValue` carries the ID and
/// version of the spec that produced it; the spec's `unit` is the unit of that value, and a version
/// changes whenever the method's results can change (cached values must then be recomputed).
public enum MetricCatalog {
    /// Every spec, in Methodology-screen order.
    public static let all: [MetricSpec] = [
        heartRateSeries, maxHeartRate, heartRateZones, workoutSummary, overnightRestingHeartRate, hrvRMSSD, hrvLnRMSSD,
        hrvRawRMSSD, trends, baseline, sleepCandidate, sleepSummary, sleepContinuity, sleepHeartRate, edwardsLoad,
        banisterTRIMP, readiness,
    ]

    /// Specs whose values are diagnostics only (never wellness values): screens and stores can filter them
    /// out mechanically instead of relying on the `diagnosticOnly` input text.
    public static let diagnosticSpecIDs: Set<String> = [MetricID.hrvRawRMSSD]

    /// The spec with `id` (a ``MetricID`` value), or nil.
    public static func spec(for id: String) -> MetricSpec? {
        all.first { $0.id == id }
    }

    // MARK: Formatting helpers

    private static func pct(_ x: Double) -> String { Fmt.percent(x) }
    private static func dur(_ ms: Int64) -> String { Fmt.duration(ms) }
    private static func num(_ x: Double, _ decimals: Int = 1) -> String { Fmt.number(x, decimals: decimals) }
    private static func percents(_ xs: [Double]) -> String { xs.map(pct).joined(separator: ", ") }

    /// Shared by every heart-rate-based spec.
    private static let unvalidatedFieldNote = "unvalidatedField (decoded from a field whose meaning is not yet validated for the firmware)"

    // MARK: Heart rate

    public static let heartRateSeries: MetricSpec = {
        let tolerance = HeartRateSeries.historyPrecedenceMillis / 1_000
        let span = HeartRateSeries.maxSpanMillis / 1_000
        let gap = HeartRateSeries.defaultMaxGapMillis / 1_000
        let plausible = HeartRateSample.plausibleRange
        return MetricSpec(
            id: MetricID.heartRateSeries, name: "Heart rate", version: 2, status: .measured, unit: "bpm",
            requiredInputs: ["HeartRateSample from band history, the live vendor stream, the standard Heart Rate Service or a backup import"],
            qualityGates: [
                "Excluded: samples flagged outOfRange, deviceMarkedInvalid, noSensorContact, clockUnmapped or \(unvalidatedFieldNote); they never enter coverage, zones or any metric",
                "Excluded: bpm outside \(plausible.lowerBound)–\(plausible.upperBound)",
                "Excluded: timestamps more than 2^52 ms from the Unix epoch (malformed)",
            ],
            method: "Usable samples from all sources are merged into one series. Band history wins wherever it exists: any other sample within ±\(tolerance) s (inclusive) of a usable history sample is dropped. Among the remaining samples each whole UTC second keeps only its best source: live vendor stream > backup import > standard Heart Rate Service > demo. The result is sorted with one sample per timestamp (exact ties: history > live > backup > standard > demo, then earliest receive time, then device ID, then the lower bpm). Each sample is assumed to represent the heart rate from its timestamp until the next sample, for at most \(span) s; coverage = covered ms / window ms, and window means are time-weighted over these spans.",
            windowing: "Charts split the series into segments wherever consecutive samples are more than \(gap) s apart; gaps are drawn as gaps and never interpolated.",
            baseline: nil,
            limitations: [
                "The \(span) s span is an assumption based on roughly once-per-second reporting; a silence longer than \(span) s counts as missing data.",
                "Live and standard-service timestamps are phone receive times and can lag the measurement by a few seconds.",
                "Optical heart rate can lock onto movement cadence during exercise.",
                "All samples passed in are treated as one wearer's series, whatever their device ID.",
            ],
            references: ["Bluetooth SIG. Heart Rate Service 1.0 (service 0x180D, characteristic 0x2A37)."])
    }()

    public static let maxHeartRate: MetricSpec = {
        let o = MaxHeartRateResolver.overrideRange
        let a = MaxHeartRateResolver.ageRange
        return MetricSpec(
            id: MetricID.maxHeartRate, name: "Maximum heart rate", version: 1, status: .estimate, unit: "bpm",
            requiredInputs: ["Your own max heart rate, or your birth year"],
            qualityGates: [
                "Your own value is used only within \(o.lowerBound)–\(o.upperBound) bpm",
                "The age formula is used only for ages \(a.lowerBound)–\(a.upperBound) years",
            ],
            method: "Precedence: (1) your own max heart rate, labelled 'set by you'; (2) Tanaka: \(num(MaxHeartRateResolver.tanakaIntercept, 0)) − \(num(MaxHeartRateResolver.tanakaSlope)) × age, rounded to 0.1 bpm and labelled 'estimated from age', where age = Gregorian year of the analysed date − birth year; (3) otherwise unavailable: '\(MaxHeartRateResolver.missingInputDetail)'. Confidence is high for your own value and low for the age estimate.",
            windowing: "Resolved for the date being analysed.",
            baseline: nil,
            limitations: [
                "Age-predicted maximum heart rate has an individual error of roughly ±10 bpm.",
                "Only the birth year is known, so the age can be one year too high.",
            ],
            references: ["Tanaka H, Monahan KD, Seals DR. Age-predicted maximal heart rate revisited. J Am Coll Cardiol. 2001;37(1):153-156."])
    }()

    public static let heartRateZones: MetricSpec = {
        let r = HeartRateZones.restingHeartRateRange
        return MetricSpec(
            id: MetricID.heartRateZones, name: "Heart-rate zones", version: 2, status: .estimate, unit: "ms per zone",
            requiredInputs: ["Maximum heart rate (forma.hr.max)", "Resting heart rate for heart-rate-reserve zones", "HeartRateSample (canonical series)"],
            qualityGates: [
                "Needs HRmax: '\(MaxHeartRateResolver.missingInputDetail)'",
                "Heart-rate-reserve zones need a resting heart rate of \(num(r.lowerBound, 0))–\(num(r.upperBound, 0)) bpm below HRmax",
                "Boundaries must be strictly increasing fractions in (0, 1], at most 10",
                "Workout time in zones is withheld below \(pct(WorkoutAnalyzer.minimumCoverage)) heart-rate coverage; a missing HRmax or resting heart rate is reported first",
            ],
            method: "%HRmax model (default): zone k starts at boundary k × HRmax, with boundaries \(percents(HeartRateZones.defaultBoundaries)) for zones 1–\(HeartRateZones.defaultBoundaries.count); heart rate below the first boundary is zone 0, '\(HeartRateZones.belowZonesLabel)'. Heart-rate-reserve model (Karvonen): bound = HRrest + boundary × (HRmax − HRrest), with HRrest from your setting or else Forma's overnight estimate. Lower bounds are inclusive. Time in zone = coverage spans of usable heart rate (forma.hr.series) per zone, in ms. Zone bounds have high confidence with your own HRmax and low with the age estimate; time in zone follows coverage and is capped at low when HRmax is estimated from age, the confidence of the estimate itself.",
            windowing: "Per workout (the workout's time range).",
            baseline: nil,
            limitations: [
                "Zone bounds inherit the uncertainty of HRmax (and of resting heart rate for reserve zones).",
                "Minutes without usable heart rate are not assigned to any zone.",
            ],
            references: ["Karvonen MJ, Kentala E, Mustala O. The effects of training on heart rate; a longitudinal study. Ann Med Exp Biol Fenn. 1957;35(3):307-315."])
    }()

    public static let workoutSummary = MetricSpec(
        id: MetricID.workoutSummary, name: "Workout heart-rate summary", version: 2, status: .estimate, unit: "bpm",
        requiredInputs: ["Workout time range", "HeartRateSample (canonical series)", "HRmax for zones and load"],
        qualityGates: [
            "No usable samples inside the workout: insufficient data",
            "Heart-rate coverage below \(pct(WorkoutAnalyzer.minimumCoverage)): low quality; mean, max, time in zones and load are withheld",
        ],
        method: "Usable heart rate as in forma.hr.series. Coverage = covered ms / workout ms (forma.hr.series spans). Mean heart rate = time-weighted mean over the coverage spans inside the workout, rounded to 0.1 bpm. Max heart rate = highest usable sample inside the workout (the observed peak, not HRmax). Time in zones per forma.hr.zones; load per forma.load.edwards. Confidence: coverage ≥ 90% high, ≥ 70% moderate, otherwise low.",
        windowing: "The workout's own time range; a sample shortly before the start can cover up to its first \(HeartRateSeries.maxSpanMillis / 1_000) s.",
        baseline: nil,
        limitations: [
            "Max heart rate is a single sample and is sensitive to optical artifacts such as cadence lock.",
            "Minutes without usable heart rate contribute nothing; nothing is extrapolated.",
        ],
        references: [])

    public static let overnightRestingHeartRate: MetricSpec = {
        let p = RestingHeartRateParameters.default
        return MetricSpec(
            id: MetricID.overnightRestingHeartRate, name: "Overnight resting heart rate (personal estimate)", version: 2,
            status: .estimate, unit: "bpm",
            requiredInputs: ["One sleep window", "HeartRateSample (canonical series)"],
            qualityGates: [
                "Sleep window from \(dur(p.windowMillis)) to \(dur(p.maximumSleepWindowMillis))",
                "Needs at least \(dur(p.minimumCoveredMillis)) of covered heart rate inside the sleep window, or at least \(pct(p.shortWindowMinimumCoverage)) coverage when the window is shorter than \(dur(p.shortWindowThresholdMillis)); otherwise insufficient data stating have and need",
                "At least one eligible window; otherwise low quality",
            ],
            method: "Usable heart rate as in forma.hr.series. \(dur(p.windowMillis)) windows slide by \(dur(p.stepMillis)) across the sleep window (each must end inside it). A window is eligible when usable heart rate covers at least \(pct(p.minimumWindowCoverage)) of it. The estimate is the lowest time-weighted mean among eligible windows (ties: the earliest), rounded to 0.1 bpm. Confidence follows the sleep window's coverage.",
            windowing: "One sleep window (confirmed by the user or entered manually).",
            baseline: nil,
            limitations: [
                RestingHeartRateEstimator.label + ": a clinical resting heart rate is measured awake and at rest.",
                "It is the lowest sustained \(dur(p.windowMillis)), not an average of the night.",
                "Optical heart rate can drop out during sleep with poor contact.",
            ],
            references: [])
    }()

    // MARK: HRV

    public static let hrvRMSSD: MetricSpec = {
        let p = HRVParameters.default
        let r = BeatInterval.plausibleMillis
        return MetricSpec(
            id: MetricID.hrvRMSSD, name: "Overnight HRV (RMSSD)", version: 2, status: .estimate, unit: "ms",
            requiredInputs: ["BeatInterval records provided by the device (never derived from heart rate)", "Analysis period (typically the confirmed sleep window)"],
            qualityGates: [
                "Rule A: intervals outside \(num(r.lowerBound, 0))–\(num(r.upperBound, 0)) ms (or non-finite, or flagged outOfRange) are rejected",
                "Rule B: an interval deviating more than \(pct(p.ruleBMaximumDeviation)) from the median of the last ≤ \(p.ruleBReferenceBeats) accepted intervals of its segment is rejected; applied once ≥ \(p.ruleBMinimumReferences) accepted references exist",
                "Beats flagged deviceMarkedInvalid, noSensorContact, clockUnmapped or \(unvalidatedFieldNote) are rejected (counted as flagged)",
                "A window is valid when ≥ \(pct(p.windowMinimumAcceptedFraction)) of its beats are accepted, its accepted intervals sum to ≥ \(num(p.windowMinimumAcceptedMillis / 1_000, 0)) s and it has ≥ \(p.windowMinimumPairs) successive pairs",
                "At least \(p.minimumValidWindows) valid windows are required; otherwise insufficient data",
                "A period median RMSSD of 0 ms (no beat-to-beat variation, suggesting quantised or synthetic data) is reported as low quality, never as a value",
                "Analysis period up to \(dur(p.maximumAnalysisMillis))",
            ],
            method: "Beats in the analysis period are used; exact duplicates (same device, source, record key and index in record) count once. Source precedence: a usable beat (finite interval within \(num(r.lowerBound, 0))–\(num(r.upperBound, 0)) ms, no exclusion flag) claims the span from its interval's start to its timestamp; sources rank band history > live vendor stream > backup import > standard Heart Rate Service > demo, and a beat whose span midpoint lies inside a span claimed by a kept usable beat of a higher-ranked source is dropped as a copy of the same beats (a beat that is not usable is also dropped inside a span claimed by any other source), so two streams of one night never interleave. The remaining beats are sorted by timestamp (ties: source rank, device ID, record key, index in record, then the interval). A new segment starts when the time since the previous beat is zero or negative, exceeds the beat's own interval + \(num(p.dropoutToleranceMillis, 0)) ms (dropout), or is less than half of the beat's own plausible interval (overlapping timestamps), or when the source or device changes; an implausible interval value alone never starts a segment. Successive differences are formed only between two accepted adjacent beats of the same segment whose timestamps fall in the same window; window RMSSD = sqrt(mean(diff²)). Period RMSSD = median of the valid-window RMSSDs, rounded to 0.1 ms; lnRMSSD (forma.hrv.lnrmssd) = natural log of the unrounded period RMSSD in ms, rounded to 0.001. Coverage = valid / total windows. Confidence: high when coverage ≥ \(pct(p.highConfidenceMinimumCoverage)) and the artifact rate ≤ \(pct(p.highConfidenceMaximumArtifactRate)); moderate when ≥ \(pct(p.moderateConfidenceMinimumCoverage)) and ≤ \(pct(p.moderateConfidenceMaximumArtifactRate)); otherwise low. Reported with the accepted-beat percentage, artifact counts per rule, valid/total windows and the number of duplicate or overlapping beats dropped.",
            windowing: "Non-overlapping \(dur(p.windowMillis)) windows aligned to the start of the analysis period; a trailing partial window is not analysed.",
            baseline: nil,
            limitations: [
                "WHOOP provides optical pulse-to-pulse intervals (PPG), not ECG R-R intervals. Pulse arrival time varies with blood pressure and vascular tone, and motion or poor contact add error, so values can differ from ECG-based RMSSD, especially when HRV is high.",
                "Interval timestamps may be reconstructed from record or phone receive times.",
                "The first \(p.ruleBMinimumReferences) accepted beats of each segment are not checked by rule B.",
                "A single missed beat that leaves no gap above interval + \(num(p.dropoutToleranceMillis / 1_000, 0)) s is not detected by timing.",
                "After a sustained heart-rate change of more than \(pct(p.ruleBMaximumDeviation)) within a few beats (for example an arousal), rule B keeps rejecting beats until the rate returns or a dropout starts a new segment; those windows become invalid, so the period value leans towards the time before the change.",
            ],
            references: [
                "Task Force of the European Society of Cardiology and the North American Society of Pacing and Electrophysiology. Heart rate variability: standards of measurement, physiological interpretation and clinical use. Circulation. 1996;93(5):1043-1065.",
                "Shaffer F, Ginsberg JP. An overview of heart rate variability metrics and norms. Front Public Health. 2017;5:258.",
                "Schäfer A, Vagedes J. How accurate is pulse rate variability as an estimate of heart rate variability? Int J Cardiol. 2013;166(1):15-29.",
                "Plews DJ, Laursen PB, Stanley J, Kilding AE, Buchheit M. Training adaptation and heart rate variability in elite endurance athletes: opening the door to effective monitoring. Sports Med. 2013;43(9):773-781.",
            ])
    }()

    public static let hrvLnRMSSD = MetricSpec(
        id: MetricID.hrvLnRMSSD, name: "Overnight HRV (lnRMSSD)", version: 1, status: .estimate, unit: "ln(ms)",
        requiredInputs: ["Period RMSSD (forma.hrv.rmssd)"],
        qualityGates: ["Available exactly when forma.hrv.rmssd is available; otherwise unavailable for the same reason"],
        method: "Natural log of the unrounded period RMSSD in ms (the median of the valid-window RMSSDs of forma.hrv.rmssd), rounded to 0.001. Coverage and confidence are those of forma.hrv.rmssd.",
        windowing: "As forma.hrv.rmssd.",
        baseline: nil,
        limitations: [
            "Inherits every limitation of forma.hrv.rmssd.",
            "A logarithm: differences are relative changes of RMSSD, and a percentage change of lnRMSSD has no meaning.",
        ],
        references: ["Plews DJ, Laursen PB, Stanley J, Kilding AE, Buchheit M. Training adaptation and heart rate variability in elite endurance athletes: opening the door to effective monitoring. Sports Med. 2013;43(9):773-781."])

    public static let hrvRawRMSSD = MetricSpec(
        id: MetricID.hrvRawRMSSD, name: "Unfiltered RMSSD (diagnostic only)", version: 2, status: .estimate, unit: "ms",
        requiredInputs: ["BeatInterval records provided by the device"],
        qualityGates: ["Needs at least one adjacent in-segment pair; pairs with non-finite intervals are skipped"],
        method: "sqrt(mean(diff²)) over every adjacent pair of beats in the same segment (duplicate removal, source precedence and segmentation as forma.hrv.rmssd) across the whole analysis period, with no artifact rejection and no windowing. Rounded to 0.1 ms. Confidence is always low. Listed in MetricCatalog.diagnosticSpecIDs.",
        windowing: "The whole analysis period.",
        baseline: nil,
        limitations: [
            "Diagnostic only: not a wellness value; shown only to compare with the filtered RMSSD.",
            "Ectopic beats and artifacts inflate it.",
        ],
        references: [])

    // MARK: Trends and baselines

    public static let trends = MetricSpec(
        id: MetricID.trends, name: "Trends", version: 2, status: .estimate, unit: "unit of the summarised metric",
        requiredInputs: ["One value per local day (missing days allowed)"],
        qualityGates: [
            TrendPeriod.allCases.map { "\($0.days)-day statistics need ≥ \($0.minimumDaysWithData) days with data" }.joined(separator: "; ") + "; otherwise insufficient data",
            "The last-\(TrendAnalyzer.recentDays) vs prior-\(TrendAnalyzer.priorDays) comparison needs ≥ \(TrendAnalyzer.recentMinimumDays) of \(TrendAnalyzer.recentDays) and ≥ \(TrendAnalyzer.priorMinimumDays) of \(TrendAnalyzer.priorDays) days with data",
            "Missing, nil and non-finite daily values count as no data",
        ],
        method: "For the \(TrendPeriod.allCases.map { "\($0.days)" }.joined(separator: ", ")) days ending on (and including) the selected day: days with data, mean, median, sample SD (n − 1), minimum and maximum of the daily values. Comparison: mean of the last \(TrendAnalyzer.recentDays) days (selected day included) minus the mean of the \(TrendAnalyzer.priorDays) days before them, and that difference as a percentage of the prior mean, given only for values on a ratio scale: when the prior mean is positive and the recent mean is not negative, and never for the readiness composite (SD units) or lnRMSSD (a logarithm). Confidence follows the share of days with data.",
        windowing: "Local calendar days (Gregorian dates) in the user's time zone; each day runs from its first local instant to the start of the next day, so days tile the timeline across daylight-saving changes.",
        baseline: nil,
        limitations: [
            "Descriptive statistics only: differences are not tested for significance and say nothing about causes.",
            "A day counts once it has a value, however much data produced it.",
        ],
        references: [])

    public static let baseline: MetricSpec = {
        let p = BaselineParameters.default
        return MetricSpec(
            id: MetricID.baseline, name: "Personal baseline", version: 2, status: .estimate, unit: "unit of the underlying metric",
            requiredInputs: ["One value per local day or night"],
            qualityGates: [
                "At least \(p.minimumDays) retained values by default (readiness uses its own minimums); otherwise calibrating (have/need), where have counts the values retained after outlier exclusion and the inputs list how many were excluded",
                "Missing, nil and non-finite values are ignored",
                "With MAD = 0 no value is excluded",
            ],
            method: "Values from the \(p.windowDays) calendar days before the target day (the target day itself is excluded). Median and MAD (median absolute deviation) of the eligible values; when MAD > 0, values with |x − median| > \(num(p.outlierMADMultiplier, 0)) × \(num(p.madScale, 4)) × MAD are excluded. Reported: mean, sample SD (n − 1), n retained and the number excluded. Coverage = eligible days / \(p.windowDays); confidence follows coverage.",
            windowing: "The \(p.windowDays) days before the target day (Gregorian dates in the user's time zone).",
            baseline: "Rolling, recomputed for every target day.",
            limitations: ["A baseline describes your recent typical values, not a healthy or normal range."],
            references: ["Leys C, Ley C, Klein O, Bernard P, Licata L. Detecting outliers: do not use standard deviation around the mean, use absolute deviation around the median. J Exp Soc Psychol. 2013;49(4):764-766."])
    }()

    // MARK: Sleep

    public static let sleepCandidate: MetricSpec = {
        let p = SleepDetectorParameters.default
        let outside = p.minimumOutsideHeartRateMillis > 0
            ? "and ≥ \(dur(p.minimumOutsideHeartRateMillis)) outside it"
            : "and some usable heart rate lies outside it in the window"
        return MetricSpec(
            id: MetricID.sleepCandidate, name: "Sleep candidate (motion-based)", version: 2, status: .estimate, unit: "time range",
            requiredInputs: [
                "MotionEpoch (accelerometer summary): required; sleep is never inferred from heart rate alone",
                "HeartRateSample: optional, adjusts confidence only",
            ],
            qualityGates: [
                "No motion input: not provided by this band: \(SleepDetector.motionSensorName)",
                "No usable motion epoch in the window: insufficient data",
                "Motion epochs flagged deviceMarkedInvalid, noSensorContact, clockUnmapped, outOfRange or \(unvalidatedFieldNote), with no samples, or with non-finite or negative activity count as missing",
                "The main candidate must last at least \(dur(p.minimumCandidateMillis))",
                "Motion data must cover at least \(pct(p.minimumMotionCoverage)) of the candidate's epochs; otherwise low quality",
                "The user must confirm a candidate before it counts",
            ],
            method: "Motion is re-binned onto \(dur(p.epochMillis)) epochs over the local noon-to-noon window ending on the morning of the selected day (mean activity weighted by sample count and overlap). θ = clamp(\(num(p.thresholdMultiplier, 0)) × P\(num(p.thresholdPercentile * 100, 0))(activity), \(num(p.thresholdLowerBound, 4)), \(num(p.thresholdUpperBound, 4))) over the window's epochs with data (percentile by linear interpolation). An epoch with data is quiet when the centred \(p.rollingMedianEpochs)-epoch rolling median of activity (over neighbours with data) is below θ, otherwise active; epochs without data are missing. Quiet runs separated by ≤ \(dur(p.mergeGapMillis)) of active or missing epochs are merged; the main candidate is the longest merged run of at least \(dur(p.minimumCandidateMillis)) (ties: the earliest). Wake bouts are non-quiet runs (active epochs or epochs without motion data) of ≥ \(p.minimumWakeBoutEpochs) epochs inside it, so unobserved time is never counted as sleep; sleep-duration estimate = length − wake bouts; continuity = 1 − WASO / length. Heart-rate support is used only when usable heart rate covers ≥ \(pct(p.minimumHeartRateCoverage)) of the candidate \(outside): a time-weighted mean inside below the median of the window's samples outside supports the candidate, otherwise it contradicts it. Confidence = clamp(\(num(p.confidenceMotionWeight)) × motion coverage + \(num(p.confidenceContinuityWeight)) × continuity + \(num(p.confidenceHeartRateSupport)) if heart rate supports, − \(num(p.confidenceHeartRateContradiction)) if it contradicts, 0 otherwise; 0…1): ≥ 0.75 high, ≥ 0.5 moderate, otherwise low.",
            windowing: "Local noon to noon (23 or 25 h across daylight-saving changes) in \(dur(p.epochMillis)) epochs.",
            baseline: nil,
            limitations: [
                "Default activity thresholds are uncalibrated placeholders in MotionEpoch.activity units (g, ENMO-like) and need calibration against the band's accelerometer output.",
                "Lying still while awake is counted as sleep.",
                "A single epoch without motion data between quiet epochs is bridged like a single active epoch; \(p.minimumWakeBoutEpochs) or more such epochs in a row count as wake, and the inputs state how much wake time had no motion data.",
                "A band lying still off the wrist looks like sleep unless its epochs are flagged noSensorContact; heart-rate support and the user's confirmation guard against this.",
                "No sleep stages are estimated.",
            ],
            references: [
                "Cole RJ, Kripke DF, Gruen W, Mullaney DJ, Gillin JC. Automatic sleep/wake identification from wrist activity. Sleep. 1992;15(5):461-469.",
                "van Hees VT, Sabia S, Jones SE, et al. Estimating sleep parameters using an accelerometer without sleep diary. Sci Rep. 2018;8:12975.",
            ])
    }()

    public static let sleepSummary: MetricSpec = {
        let p = SleepDetectorParameters.default
        return MetricSpec(
            id: MetricID.sleepSummary, name: "Sleep summary (confirmed window)", version: 2, status: .estimate, unit: "ms",
            requiredInputs: ["A sleep window confirmed or entered by the user", "MotionEpoch (optional)", "HeartRateSample (optional)"],
            qualityGates: [
                "Window at most \(dur(p.maximumConfirmedWindowMillis))",
                "Wake, sleep estimate and continuity need motion data covering ≥ \(pct(p.minimumMotionCoverage)) of the window's epochs",
                "Mean heart rate needs usable heart rate covering ≥ \(pct(p.minimumHeartRateCoverage)) of the window",
                "Motion-derived values have at most moderate confidence",
            ],
            method: "Time in bed = length of the confirmed window. With motion data, epochs inside the window are classified as for forma.sleep.candidate, with θ computed over the window's own epochs; wake = non-quiet runs (active epochs or epochs without motion data) of ≥ \(p.minimumWakeBoutEpochs) epochs anywhere in the window (including before sleep onset), so unobserved time is never counted as sleep; sleep estimate = time in bed − wake. Continuity (forma.sleep.continuity) = 1 − wake / time in bed. Without motion only time in bed is reported. Mean heart rate (forma.sleep.heartrate) = time-weighted mean over coverage spans, rounded to 0.1 bpm.",
            windowing: "The confirmed window, in \(dur(p.epochMillis)) epochs aligned to its start.",
            baseline: nil,
            limitations: ["Wrist motion cannot detect quiet wakefulness.", "No sleep stages are estimated."],
            references: [])
    }()

    public static let sleepContinuity: MetricSpec = {
        let p = SleepDetectorParameters.default
        return MetricSpec(
            id: MetricID.sleepContinuity, name: "Sleep continuity (confirmed window)", version: 1, status: .estimate,
            unit: "fraction (0–1)",
            requiredInputs: ["A sleep window confirmed or entered by the user", "MotionEpoch"],
            qualityGates: [
                "Needs motion data covering ≥ \(pct(p.minimumMotionCoverage)) of the window's epochs",
                "At most moderate confidence",
            ],
            method: "1 − wake / time in bed, with wake as in forma.sleep.summary (non-quiet runs of ≥ \(p.minimumWakeBoutEpochs) epochs, including epochs without motion data). Confidence follows motion coverage, capped at moderate.",
            windowing: "The confirmed window, in \(dur(p.epochMillis)) epochs aligned to its start.",
            baseline: nil,
            limitations: ["Wrist motion cannot detect quiet wakefulness, so continuity can be overstated.", "No sleep stages are estimated."],
            references: [])
    }()

    public static let sleepHeartRate: MetricSpec = {
        let p = SleepDetectorParameters.default
        return MetricSpec(
            id: MetricID.sleepHeartRate, name: "Mean heart rate in a confirmed sleep window", version: 1, status: .estimate,
            unit: "bpm",
            requiredInputs: ["A sleep window confirmed or entered by the user", "HeartRateSample (canonical series)"],
            qualityGates: ["Needs usable heart rate (forma.hr.series) covering ≥ \(pct(p.minimumHeartRateCoverage)) of the window"],
            method: "Time-weighted mean over the coverage spans of usable heart rate (forma.hr.series) inside the window, rounded to 0.1 bpm. Confidence follows coverage.",
            windowing: "The confirmed window.",
            baseline: nil,
            limitations: ["An average of the whole window, including time awake in bed; not a resting heart rate (see forma.rhr.overnight)."],
            references: [])
    }()

    // MARK: Load and readiness

    public static let edwardsLoad = MetricSpec(
        id: MetricID.edwardsLoad, name: "Forma Load (Edwards TRIMP)", version: 2, status: .estimate, unit: "AU (weighted minutes)",
        requiredInputs: ["HeartRateSample (canonical series)", "Maximum heart rate (forma.hr.max)"],
        qualityGates: [
            "Unavailable without HRmax: '\(MaxHeartRateResolver.missingInputDetail)' (reported before any coverage reason)",
            "Daily load is withheld when heart-rate coverage of the local day is below \(pct(TrainingLoad.dailyMinimumCoverage))",
            "Workout load is withheld below \(pct(TrainingLoad.workoutMinimumCoverage)) coverage of the workout",
            "No usable samples: insufficient data",
        ],
        method: "Σ minutes in the %HRmax bands 50–60, 60–70, 70–80, 80–90 and ≥ 90% (including above 100%) × weights \(TrainingLoad.edwardsWeights.map { num($0, 0) }.joined(separator: ", ")) (band lower bounds \(percents(TrainingLoad.edwardsBandLowerBounds)), inclusive); time below \(pct(TrainingLoad.edwardsBandLowerBounds.first ?? 0.5)) scores 0. Minutes come from coverage spans of usable heart rate (forma.hr.series). Rounded to 0.1. Edwards bands always use %HRmax, whatever zone model is displayed. Confidence follows coverage and is capped at low when HRmax is estimated from age.",
        windowing: "Daily: the local day in the user's time zone, from its first local instant to the start of the next day (23 or 25 h across daylight-saving changes). Workout: the workout's time range.",
        baseline: nil,
        limitations: [
            "Minutes without usable heart rate contribute nothing; the value is not extrapolated to the full day.",
            "Strongly depends on HRmax.",
            "Forma's own estimate; not comparable with WHOOP Strain or any proprietary score.",
        ],
        references: ["Edwards S. The Heart Rate Monitor Book. Sacramento, CA: Fleet Feet Press; 1993."])

    public static let banisterTRIMP = MetricSpec(
        id: MetricID.banisterTRIMP, name: "Banister TRIMP (workouts)", version: 2, status: .estimate, unit: "AU",
        requiredInputs: ["Workout time range", "HeartRateSample", "Maximum heart rate", "Resting heart rate", "Sex (female or male; never assumed)"],
        qualityGates: [
            "Computed only when HRmax, resting heart rate (\(num(HeartRateZones.restingHeartRateRange.lowerBound, 0))–\(num(HeartRateZones.restingHeartRateRange.upperBound, 0)) bpm, below HRmax) and sex are known; a missing one is reported before any coverage reason",
            "Withheld below \(pct(TrainingLoad.workoutMinimumCoverage)) heart-rate coverage of the workout",
        ],
        method: "Σ minutes × x × a·e^(b·x) over coverage spans of usable heart rate (forma.hr.series), with x = (HR − HRrest) / (HRmax − HRrest) clamped to 0…1; women a = \(num(TrainingLoad.banisterFemaleCoefficient, 2)), b = \(num(TrainingLoad.banisterFemaleExponent, 2)); men a = \(num(TrainingLoad.banisterMaleCoefficient, 2)), b = \(num(TrainingLoad.banisterMaleExponent, 2)). Rounded to 0.1. Confidence follows coverage and is capped at low when HRmax is estimated from age.",
        windowing: "The workout's time range.",
        baseline: nil,
        limitations: [
            "The sex-specific weighting comes from small historical samples.",
            "Clamping at HRmax limits the effect of an underestimated HRmax.",
        ],
        references: [
            "Banister EW. Modeling elite athletic performance. In: MacDougall JD, Wenger HA, Green HJ, eds. Physiological Testing of the High-Performance Athlete. Champaign, IL: Human Kinetics; 1991:403-424.",
            "Morton RH, Fitz-Clarke JR, Banister EW. Modeling human performance in running. J Appl Physiol. 1990;69(3):1171-1177.",
        ])

    public static let readiness: MetricSpec = {
        let p = ReadinessParameters.default
        let w = p.weights
        let t = num(p.bandThreshold)
        return MetricSpec(
            id: MetricID.readiness, name: "Readiness (experimental)", version: 2, status: .experimental, unit: "SD (z-score)",
            requiredInputs: [
                "Overnight lnRMSSD (forma.hrv.lnrmssd): required",
                "Overnight resting heart rate (forma.rhr.overnight): optional",
                "Confirmed sleep duration in minutes: optional",
            ],
            qualityGates: [
                "Unavailable without the target night's HRV component",
                "Baselines need ≥ \(p.hrvMinimumNights) retained nights for HRV, ≥ \(p.restingHeartRateMinimumNights) for resting heart rate and ≥ \(p.sleepMinimumNights) for sleep; otherwise that component is calibrating. Retained nights are the eligible nights minus any excluded as outliers; the inputs say how many were excluded",
                "Components that are missing or calibrating are left out",
            ],
            method: "For each component z = (value − baseline mean) / max(baseline SD, floor), with floors \(num(p.lnRMSSDStandardDeviationFloor, 2)) for lnRMSSD, \(num(p.restingHeartRateStandardDeviationFloor)) bpm for resting heart rate and \(num(p.sleepStandardDeviationFloorMinutes, 0)) min for sleep; the resting-heart-rate sign is inverted so lower than usual is positive; each z is shown rounded to 0.01. Composite = Σ wᵢzᵢ / Σ wᵢ over the available components using the unrounded z values, with default weights HRV \(num(w.hrv)), resting heart rate \(num(w.restingHeartRate)), sleep \(num(w.sleepDuration)), rounded once to 0.01 SD (a z-score, not a 0–100 score). Band of the rounded composite: below usual (< −\(t)), within usual (−\(t) to +\(t)), above usual (> +\(t)). Confidence: high with all three components and ≥ \(p.highConfidenceMinimumHRVNights) HRV baseline nights; moderate with two or more components (three with fewer than \(p.highConfidenceMinimumHRVNights) HRV baseline nights); low with HRV only. Coverage = included weight / total weight.",
            windowing: "The target night against the previous \(p.baselineDays) nights (target night excluded).",
            baseline: "Robust baselines as in forma.baseline (\(p.baselineDays) nights, MAD outlier exclusion).",
            limitations: [
                "Experimental Forma-defined composite, not validated against outcomes.",
                "It describes how this night compares with your own recent nights; it gives no training or treatment advice.",
                "Not comparable with WHOOP Recovery or any proprietary score.",
            ],
            references: ["Plews DJ, Laursen PB, Stanley J, Kilding AE, Buchheit M. Training adaptation and heart rate variability in elite endurance athletes: opening the door to effective monitoring. Sports Med. 2013;43(9):773-781."])
    }()
}
