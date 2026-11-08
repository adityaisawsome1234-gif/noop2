import Foundation
import Testing
import FormaCore
import FormaAnalytics

/// The Methodology screen renders `MetricCatalog`; these tests pin the documented parameters to the
/// values the implementation uses (and to the product specification).
@Suite("Metric catalog")
struct CatalogTests {
    func text(_ spec: MetricSpec) -> String {
        ([spec.name, spec.method, spec.windowing, spec.baseline ?? ""] + spec.qualityGates + spec.limitations
            + spec.requiredInputs).joined(separator: "\n")
    }

    func expectMentions(_ spec: MetricSpec, _ fragments: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let all = text(spec)
        for f in fragments {
            #expect(all.contains(f), "\(spec.id) does not mention “\(f)”", sourceLocation: sourceLocation)
        }
    }

    @Test func everyMetricHasExactlyOneSpec() {
        let ids = MetricCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        let expected = [MetricID.heartRateSeries, MetricID.maxHeartRate, MetricID.heartRateZones, MetricID.workoutSummary,
                        MetricID.overnightRestingHeartRate, MetricID.hrvRMSSD, MetricID.hrvLnRMSSD, MetricID.hrvRawRMSSD,
                        MetricID.trends, MetricID.baseline, MetricID.sleepCandidate, MetricID.sleepSummary,
                        MetricID.sleepContinuity, MetricID.sleepHeartRate, MetricID.edwardsLoad, MetricID.banisterTRIMP,
                        MetricID.readiness]
        #expect(Set(ids) == Set(expected))
        #expect(ids.count == expected.count)
        for spec in MetricCatalog.all {
            #expect(spec.version >= 1)
            #expect(!spec.method.isEmpty && !spec.unit.isEmpty && !spec.qualityGates.isEmpty && !spec.limitations.isEmpty)
            #expect(MetricCatalog.spec(for: spec.id) == spec)
        }
        #expect(MetricCatalog.spec(for: "forma.unknown") == nil)
        #expect(MetricID.hrvRMSSD == "forma.hrv.rmssd")
        #expect(MetricID.readiness == "forma.readiness.experimental")
        #expect(MetricID.edwardsLoad == "forma.load.edwards")
    }

    @Test func statuses() {
        #expect(MetricCatalog.heartRateSeries.status == .measured)
        #expect(MetricCatalog.sleepCandidate.status == .estimate)
        #expect(MetricCatalog.readiness.status == .experimental)
        #expect(MetricCatalog.edwardsLoad.name == "Forma Load (Edwards TRIMP)")
        #expect(MetricCatalog.readiness.unit == "SD (z-score)")
    }

    @Test func heartRateSeriesParameters() {
        #expect(HeartRateSeries.maxSpanMillis == 5_000)
        #expect(HeartRateSeries.historyPrecedenceMillis == 5_000)
        #expect(HeartRateSeries.defaultMaxGapMillis == 10_000)
        #expect(HeartRateSeries.excludedFlags == [.outOfRange, .deviceMarkedInvalid, .noSensorContact, .clockUnmapped,
                                                  .unvalidatedField])
        expectMentions(MetricCatalog.heartRateSeries, ["±5 s", "for at most 5 s", "more than 10 s apart", "25–240",
                                                       "live vendor stream > backup import > standard Heart Rate Service",
                                                       "clockUnmapped or unvalidatedField"])
    }

    @Test func zoneAndMaxHeartRateParameters() {
        #expect(HeartRateZones.defaultBoundaries == [0.5, 0.6, 0.7, 0.8, 0.9])
        #expect(MaxHeartRateResolver.tanakaIntercept == 208 && MaxHeartRateResolver.tanakaSlope == 0.7)
        expectMentions(MetricCatalog.heartRateZones, ["50%, 60%, 70%, 80%, 90%", "zones 1–5", "'below zones'", "Karvonen",
                                                      "inclusive", "below 50% heart-rate coverage"])
        expectMentions(MetricCatalog.maxHeartRate, ["208 − 0.7 × age", "'estimated from age'", "'set by you'",
                                                    "'Set your max heart rate or birth year'"])
    }

    @Test func workoutAndLoadParameters() {
        #expect(WorkoutAnalyzer.minimumCoverage == 0.5)
        #expect(TrainingLoad.dailyMinimumCoverage == 0.3)
        #expect(TrainingLoad.edwardsWeights == [1, 2, 3, 4, 5])
        #expect(TrainingLoad.edwardsBandLowerBounds == [0.5, 0.6, 0.7, 0.8, 0.9])
        #expect(TrainingLoad.banisterFemaleExponent == 1.67 && TrainingLoad.banisterMaleExponent == 1.92)
        expectMentions(MetricCatalog.workoutSummary, ["below 50%", "time-weighted mean", "highest usable sample"])
        expectMentions(MetricCatalog.edwardsLoad, ["weights 1, 2, 3, 4, 5", "below 30%", "below 50% coverage",
                                                   "50–60, 60–70, 70–80, 80–90 and ≥ 90%"])
        expectMentions(MetricCatalog.banisterTRIMP, ["women a = 0.86, b = 1.67", "men a = 0.64, b = 1.92", "never assumed"])
    }

    @Test func restingHeartRateParameters() {
        let p = RestingHeartRateParameters.default
        #expect(p.windowMillis == 300_000 && p.stepMillis == 60_000 && p.minimumWindowCoverage == 0.8)
        #expect(p.minimumCoveredMillis == 3 * 3_600_000 && p.shortWindowThresholdMillis == 5 * 3_600_000)
        #expect(p.shortWindowMinimumCoverage == 0.6)
        expectMentions(MetricCatalog.overnightRestingHeartRate, ["5 min windows slide by 1 min", "at least 80%",
                                                                 "at least 3 h of covered", "at least 60% coverage",
                                                                 "shorter than 5 h;", "0.1 bpm", "not a clinical"])
    }

    @Test func hrvParameters() {
        let p = HRVParameters.default
        #expect(p.windowMillis == 300_000)
        #expect(p.dropoutToleranceMillis == 2_000)
        #expect(p.ruleBMaximumDeviation == 0.20 && p.ruleBReferenceBeats == 5 && p.ruleBMinimumReferences == 3)
        #expect(p.windowMinimumAcceptedFraction == 0.80 && p.windowMinimumAcceptedMillis == 180_000 && p.windowMinimumPairs == 100)
        #expect(p.minimumValidWindows == 6)
        #expect(BeatInterval.plausibleMillis == 300...2_000)
        expectMentions(MetricCatalog.hrvRMSSD, [
            "300–2000 ms", "more than 20%", "last ≤ 5 accepted", "≥ 3 accepted references", "≥ 80% of its beats",
            "≥ 180 s", "≥ 100 successive pairs", "At least 6 valid windows", "interval + 2000 ms", "5 min windows",
            "median of the valid-window RMSSDs", "natural log", "never derived from heart rate", "optical pulse-to-pulse",
        ])
        expectMentions(MetricCatalog.hrvRawRMSSD, ["Diagnostic only", "no artifact rejection"])
    }

    @Test func trendAndBaselineParameters() {
        #expect(TrendAnalyzer.recentDays == 7 && TrendAnalyzer.priorDays == 28)
        #expect(TrendAnalyzer.recentMinimumDays == 4 && TrendAnalyzer.priorMinimumDays == 14)
        expectMentions(MetricCatalog.trends, ["7-day statistics need ≥ 4", "30-day statistics need ≥ 14",
                                              "90-day statistics need ≥ 45", "≥ 4 of 7 and ≥ 14 of 28", "sample SD (n − 1)"])
        let b = BaselineParameters.default
        #expect(b.windowDays == 28 && b.outlierMADMultiplier == 3 && b.madScale == 1.4826)
        expectMentions(MetricCatalog.baseline, ["28 calendar days before the target day", "3 × 1.4826 × MAD",
                                                "target day itself is excluded", "MAD = 0 no value is excluded"])
    }

    @Test func sleepParameters() {
        let p = SleepDetectorParameters.default
        #expect(p.epochMillis == 60_000 && p.rollingMedianEpochs == 5 && p.thresholdPercentile == 0.10)
        #expect(p.thresholdMultiplier == 2 && p.mergeGapMillis == 600_000 && p.minimumCandidateMillis == 3 * 3_600_000)
        #expect(p.minimumWakeBoutEpochs == 2 && p.minimumMotionCoverage == 0.7 && p.minimumHeartRateCoverage == 0.5)
        #expect(p.windowStartHour == 12)
        expectMentions(MetricCatalog.sleepCandidate, [
            "1 min epochs", "noon-to-noon", "clamp(2 × P10(activity), 0.0100, 0.0400)", "5-epoch rolling median",
            "≤ 10 min", "at least 3 h (ties", "≥ 2 epochs", "at least 70%", "≥ 50% of the candidate",
            "never inferred from heart rate alone", "need calibration", "No sleep stages",
        ])
        expectMentions(MetricCatalog.sleepSummary, ["Time in bed = length of the confirmed window", "≥ 70%",
                                                    "Without motion only time in bed"])
    }

    @Test func readinessParameters() {
        let p = ReadinessParameters.default
        #expect(p.baselineDays == 28 && p.hrvMinimumNights == 14 && p.restingHeartRateMinimumNights == 14 && p.sleepMinimumNights == 7)
        #expect(p.lnRMSSDStandardDeviationFloor == 0.05 && p.restingHeartRateStandardDeviationFloor == 1.0)
        #expect(p.sleepStandardDeviationFloorMinutes == 30)
        #expect(p.weights == ReadinessWeights(hrv: 0.5, restingHeartRate: 0.3, sleepDuration: 0.2))
        #expect(p.bandThreshold == 1.0)
        expectMentions(MetricCatalog.readiness, [
            "HRV 0.5, resting heart rate 0.3, sleep 0.2", "floors 0.05 for lnRMSSD, 1.0 bpm", "30 min for sleep",
            "≥ 14 retained nights for HRV", "≥ 7 for sleep", "sign is inverted", "below usual (< −1.0)",
            "within usual (−1.0 to +1.0)", "above usual (> +1.0)", "not a 0–100 score", "no training or treatment advice",
        ])
    }

    @Test func noParityClaimsWithProprietaryScores() {
        for spec in MetricCatalog.all {
            let all = text(spec).lowercased()
            #expect(!all.contains("equivalent to whoop"), "\(spec.id)")
            #expect(!all.contains("matches whoop"), "\(spec.id)")
        }
        expectMentions(MetricCatalog.edwardsLoad, ["not comparable with WHOOP Strain"])
        expectMentions(MetricCatalog.readiness, ["Not comparable with WHOOP Recovery"])
    }
}
