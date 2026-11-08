import FormaCore

/// Time per heart-rate zone.
public struct ZoneDurations: Hashable, Sendable, Codable {
    /// Milliseconds per zone: index 0 = "below zones", index k = zone k.
    public var millis: [Int64]

    public init(millis: [Int64]) {
        self.millis = millis
    }

    /// Milliseconds in `zone`, or nil for a zone index that does not exist.
    public func millis(inZone zone: Int) -> Int64? {
        millis.indices.contains(zone) ? millis[zone] : nil
    }

    /// Sum over all zones (equals the covered time of the workout).
    public var totalMillis: Int64 { millis.reduce(0, +) }
}

/// Heart-rate summary of one workout (spec `forma.workout.summary`).
public struct WorkoutSummary: Hashable, Sendable, Codable {
    /// The workout's time range (epoch ms, half-open).
    public var range: TimeRange
    /// Workout length, ms; nil only for an invalid range.
    public var durationMillis: Int64?
    /// Covered ms / workout ms (0…1); nil for an empty or invalid range.
    public var coverage: Double?
    /// Usable canonical samples inside the workout.
    public var usableSampleCount: Int
    /// Time-weighted mean over coverage spans, bpm, rounded to 0.1.
    public var meanHeartRate: MetricValue<Double>
    /// Highest usable sample inside the workout, bpm (single-sample statistic: artifact-sensitive).
    public var maxHeartRate: MetricValue<Int>
    /// Zone bounds used (available even when the workout has no heart rate).
    public var zoneThresholds: MetricValue<ZoneThresholds>
    /// Time in each zone from coverage spans (spec `forma.hr.zones`).
    public var timeInZones: MetricValue<ZoneDurations>
    /// Forma Load (Edwards TRIMP) of the workout (spec `forma.load.edwards`).
    public var edwardsTRIMP: MetricValue<Double>

    public init(range: TimeRange, durationMillis: Int64?, coverage: Double?, usableSampleCount: Int,
                meanHeartRate: MetricValue<Double>, maxHeartRate: MetricValue<Int>,
                zoneThresholds: MetricValue<ZoneThresholds>, timeInZones: MetricValue<ZoneDurations>,
                edwardsTRIMP: MetricValue<Double>) {
        self.range = range
        self.durationMillis = durationMillis
        self.coverage = coverage
        self.usableSampleCount = usableSampleCount
        self.meanHeartRate = meanHeartRate
        self.maxHeartRate = maxHeartRate
        self.zoneThresholds = zoneThresholds
        self.timeInZones = timeInZones
        self.edwardsTRIMP = edwardsTRIMP
    }
}

/// Summarises the heart rate of a workout.
///
/// Every optional value is withheld (nil, with the reason) when the workout has no usable samples
/// (`insufficientData`) or when usable heart rate covers less than 50 % of it (`lowQuality`).
/// Confidence follows coverage (≥ 90 % high, ≥ 70 % moderate, otherwise low); zone time and load are
/// further capped at `.moderate` when HRmax is estimated from age.
public enum WorkoutAnalyzer {
    /// Minimum heart-rate coverage of the workout for any heart-rate value.
    public static let minimumCoverage = TrainingLoad.workoutMinimumCoverage

    /// Summarises `range` from raw samples of any source (canonicalised internally; samples just before
    /// the start may cover its first seconds). `zones` supplies the zone model and HRmax (also used for load).
    public static func summarize(range: TimeRange, samples: [HeartRateSample], zones: HeartRateZones) -> WorkoutSummary {
        summarize(range: range, series: HeartRateSeries(samples), zones: zones)
    }

    /// As ``summarize(range:samples:zones:)`` for an already canonical series.
    public static func summarize(range: TimeRange, series: HeartRateSeries, zones: HeartRateZones) -> WorkoutSummary {
        let spec = MetricCatalog.workoutSummary
        let zoneSpec = MetricCatalog.heartRateZones
        let thresholds = zones.thresholds()
        let edwards = TrainingLoad.workoutLoad(range: range, series: series, hrMax: zones.maxHeartRate)

        guard let gate = TrainingLoad.coverageGate(range: range, series: series, minimumCoverage: minimumCoverage,
                                                   scope: "workout") else {
            let reason = Availability.insufficientData(detail: "The workout time range is empty or invalid")
            let valid = Sanity.isSane(range)
            return WorkoutSummary(range: range, durationMillis: valid ? range.durationMillis : nil, coverage: nil,
                                  usableSampleCount: 0,
                                  meanHeartRate: spec.unavailable(reason, window: nil),
                                  maxHeartRate: spec.unavailable(reason, window: nil),
                                  zoneThresholds: thresholds,
                                  timeInZones: zoneSpec.unavailable(reason, window: nil),
                                  edwardsTRIMP: edwards)
        }
        let inside = series.samples(in: range)
        let coverage = gate.coverage
        let inputs = gate.inputs
        let duration = range.durationMillis

        let mean: MetricValue<Double>
        let maxHR: MetricValue<Int>
        let timeInZones: MetricValue<ZoneDurations>
        if let failure = gate.failure {
            mean = spec.unavailable(failure, coverage: coverage, window: range, inputs: inputs)
            maxHR = spec.unavailable(failure, coverage: coverage, window: range, inputs: inputs)
            timeInZones = zoneSpec.unavailable(failure, coverage: coverage, window: range, inputs: inputs)
        } else {
            let confidence = Confidence.forAvailable(coverage: coverage)
            let (covered, weighted) = series.index.integrate(range)
            var meanInputs = inputs
            meanInputs["method"] = "time-weighted mean over coverage spans (each sample covers up to 5 s)"
            mean = spec.number(Stats.rounded(Double(weighted) / Double(covered), decimals: 1), coverage: coverage,
                               confidence: confidence, window: range, inputs: meanInputs)
            var highest = Int.min
            for s in inside { highest = max(highest, s.bpm) }
            var maxInputs = inputs
            maxInputs["method"] = "highest usable sample; a single optical artifact can inflate it"
            maxHR = spec.available(highest, coverage: coverage, confidence: confidence, window: range, inputs: maxInputs)

            if let t = thresholds.value {
                var ms = [Int64](repeating: 0, count: t.lowerBoundsBPM.count + 1)
                series.index.forEachOverlap(range) { i, start, end in
                    ms[t.zone(forBPM: Double(series.index.bpms[i]))] += end - start
                }
                var zoneInputs = inputs.merging(thresholds.inputs) { a, _ in a }
                zoneInputs["lowerBoundsBPM"] = t.lowerBoundsBPM.map { Fmt.number($0, decimals: 1) }.joined(separator: ", ")
                timeInZones = zoneSpec.available(ZoneDurations(millis: ms), coverage: coverage,
                                                 confidence: min(confidence, t.maxHeartRate.confidenceCap),
                                                 window: range, inputs: zoneInputs)
            } else {
                timeInZones = zoneSpec.unavailable(thresholds.availability, coverage: coverage, window: range,
                                                   inputs: inputs.merging(thresholds.inputs) { a, _ in a })
            }
        }
        return WorkoutSummary(range: range, durationMillis: duration, coverage: coverage, usableSampleCount: inside.count,
                              meanHeartRate: mean, maxHeartRate: maxHR, zoneThresholds: thresholds,
                              timeInZones: timeInZones, edwardsTRIMP: edwards)
    }
}
