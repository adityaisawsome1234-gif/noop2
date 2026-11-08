import Foundation
import Testing
import FormaCore
import FormaAnalytics

/// Daily values keyed by day, `count` days ending on `last` (oldest first), using `value(i)` (nil = no entry).
func dailyValues(endingOn last: LocalDay, count: Int, calendar: Calendar = Fixture.utc,
                 value: (Int) -> Double?) -> [LocalDay: Double?] {
    var out: [LocalDay: Double?] = [:]
    for i in 0..<count {
        let day = last.adding(days: -(count - 1 - i), calendar: calendar)
        if let v = value(i) { out[day] = v }
    }
    return out
}

@Suite("Trends")
struct TrendTests {
    let end = LocalDay(year: 2026, month: 3, day: 31)
    let cal = Fixture.utc

    @Test func sevenDayStatisticsNeedFourDays() throws {
        let three = dailyValues(endingOn: end, count: 7) { $0 < 3 ? 50 : nil }
        let s3 = TrendAnalyzer.summary(of: three, period: .days7, endingOn: end, calendar: cal)
        expectInvariants(s3.statistics)
        #expect(s3.daysWithData == 3)
        #expect(s3.statistics.availability == .insufficientData(detail: "Needs at least 4 of 7 days with data; have 3"))

        var four = three
        four[end] = 54
        // Explicit nils and non-finite values are not data.
        four[end.adding(days: -1, calendar: cal)] = .some(nil)
        four[end.adding(days: -2, calendar: cal)] = Double.nan
        let s4 = TrendAnalyzer.summary(of: four, period: .days7, endingOn: end, calendar: cal)
        expectInvariants(s4.statistics)
        let stats = try #require(s4.statistics.value)
        #expect(stats.daysWithData == 4)
        #expect(stats.mean == 51)
        #expect(s4.statistics.coverage == 4.0 / 7.0)
        #expect(s4.firstDay == LocalDay(year: 2026, month: 3, day: 25))
        #expect(s4.lastDay == end)
    }

    @Test func thirtyAndNinetyDayMinimums() {
        let thirteen = dailyValues(endingOn: end, count: 30) { $0 % 2 == 0 && $0 < 26 ? 1 : nil }
        #expect(TrendAnalyzer.summary(of: thirteen, period: .days30, endingOn: end, calendar: cal).statistics.value == nil)
        let fourteen = dailyValues(endingOn: end, count: 30) { $0 % 2 == 0 && $0 < 28 ? 1 : nil }
        #expect(TrendAnalyzer.summary(of: fourteen, period: .days30, endingOn: end, calendar: cal).statistics.value != nil)

        let fortyFour = dailyValues(endingOn: end, count: 90) { $0 % 2 == 0 && $0 < 88 ? 1 : nil }
        #expect(TrendAnalyzer.summary(of: fortyFour, period: .days90, endingOn: end, calendar: cal).statistics.value == nil)
        let fortyFive = dailyValues(endingOn: end, count: 90) { $0 % 2 == 0 ? 1 : nil }
        let s = TrendAnalyzer.summary(of: fortyFive, period: .days90, endingOn: end, calendar: cal)
        #expect(s.statistics.value?.daysWithData == 45)
        #expect(TrendPeriod.allCases.map(\.minimumDaysWithData) == [4, 14, 45])
    }

    @Test func descriptiveStatistics() throws {
        let values = dailyValues(endingOn: end, count: 7) { Double([3, 1, 7, 4, 6, 2, 5][$0]) }
        let stats = try #require(TrendAnalyzer.summary(of: values, period: .days7, endingOn: end, calendar: cal).statistics.value)
        #expect(stats.mean == 4)
        #expect(stats.median == 4)
        #expect(stats.minimum == 1)
        #expect(stats.maximum == 7)
        let sd = try #require(stats.standardDeviation)
        #expect(abs(sd - (28.0 / 6.0).squareRoot()) < 1e-12)   // sample SD
        // Values outside the period are ignored.
        var withOld = values
        withOld[end.adding(days: -7, calendar: cal)] = 1_000
        #expect(TrendAnalyzer.summary(of: withOld, period: .days7, endingOn: end, calendar: cal).statistics.value == stats)
        #expect(TrendAnalyzer.summaries(of: values, endingOn: end, calendar: cal).map(\.period) == [.days7, .days30, .days90])
    }

    @Test func recentVersusPriorNeedsFourOfSevenAndFourteenOfTwentyEight() throws {
        // Prior 28 days (oldest first: indexes 0…27) at 50, last 7 days (28…34) at 55.
        let full = dailyValues(endingOn: end, count: 35) { $0 < 28 ? 50 : 55 }
        let c = TrendAnalyzer.recentVersusPrior(of: full, endingOn: end, calendar: cal, metricID: MetricID.overnightRestingHeartRate)
        expectInvariants(c)
        let r = try #require(c.value)
        #expect(r.recentMean == 55)
        #expect(r.priorMean == 50)
        #expect(r.difference == 5)
        #expect(r.percentDifference == 10)
        #expect(r.recentDays == 7)
        #expect(r.priorDays == 28)
        #expect(c.inputs["metric"] == MetricID.overnightRestingHeartRate)

        let minimal = dailyValues(endingOn: end, count: 35) { i in i < 28 ? (i < 14 ? 50 : nil) : (i < 32 ? 55 : nil) }
        #expect(TrendAnalyzer.recentVersusPrior(of: minimal, endingOn: end, calendar: cal).value != nil)

        let fewRecent = dailyValues(endingOn: end, count: 35) { i in i < 28 ? 50 : (i < 31 ? 55 : nil) }
        let a = TrendAnalyzer.recentVersusPrior(of: fewRecent, endingOn: end, calendar: cal)
        expectInvariants(a)
        #expect(a.availability.isInsufficientData)

        let fewPrior = dailyValues(endingOn: end, count: 35) { i in i < 28 ? (i < 13 ? 50 : nil) : 55 }
        #expect(TrendAnalyzer.recentVersusPrior(of: fewPrior, endingOn: end, calendar: cal).value == nil)
    }

    @Test func percentDifferenceIsUndefinedForAZeroPriorMean() throws {
        let values = dailyValues(endingOn: end, count: 35) { $0 < 28 ? 0 : 2 }
        let r = try #require(TrendAnalyzer.recentVersusPrior(of: values, endingOn: end, calendar: cal).value)
        #expect(r.difference == 2)
        #expect(r.percentDifference == nil)
    }

    @Test func invalidDaysAndHugeValuesNeverCrash() {
        let bad = LocalDay(year: 2026, month: 2, day: 31)
        let s = TrendAnalyzer.summary(of: [:], period: .days7, endingOn: bad, calendar: cal)
        expectInvariants(s.statistics)
        #expect(s.firstDay == nil)
        #expect(TrendAnalyzer.recentVersusPrior(of: [:], endingOn: LocalDay(year: Int.max, month: 1, day: 1), calendar: cal).value == nil)
        let huge = dailyValues(endingOn: end, count: 7) { _ in Double.greatestFiniteMagnitude }
        let h = TrendAnalyzer.summary(of: huge, period: .days7, endingOn: end, calendar: cal)
        expectInvariants(h.statistics)
        #expect(h.statistics.availability.isLowQuality)
    }

    @Test func daysFollowTheLocalCalendarAcrossDST() throws {
        let berlin = try #require(Fixture.calendar("Europe/Berlin"))
        // 2026-03-29 has 23 hours in Berlin; seven daily values must still map to seven distinct days.
        let values = dailyValues(endingOn: end, count: 7, calendar: berlin) { Double($0) }
        let s = TrendAnalyzer.summary(of: values, period: .days7, endingOn: end, calendar: berlin)
        #expect(s.daysWithData == 7)
        #expect(s.firstDay == LocalDay(year: 2026, month: 3, day: 25))
        #expect(s.statistics.window?.durationMillis == 7 * 24 * Fixture.hour - Fixture.hour)
    }

    @Test func wordingIsDescriptiveOnly() {
        let values = dailyValues(endingOn: end, count: 35) { $0 < 28 ? 50 : 55 }
        let c = TrendAnalyzer.recentVersusPrior(of: values, endingOn: end, calendar: cal)
        let texts = Array(c.inputs.values) + [MetricCatalog.trends.method] + MetricCatalog.trends.qualityGates
        for word in ["because", "due to", "caused", "improv", "worse", "better", "should", "recommend"] {
            #expect(!texts.joined(separator: " ").lowercased().contains(word), "\(word)")
        }
    }
}

@Suite("Baselines")
struct BaselineTests {
    let target = LocalDay(year: 2026, month: 2, day: 10)
    let cal = Fixture.utc

    @Test func usesThePrevious28DaysAndExcludesTheTargetDay() throws {
        var values = dailyValues(endingOn: target.adding(days: -1, calendar: cal), count: 28) { _ in 50 }
        values[target] = 1_000                                 // target day: excluded
        values[target.adding(days: -29, calendar: cal)] = 1_000 // outside the window
        let b = BaselineCalculator.baseline(values: values, targetDay: target, calendar: cal)
        expectInvariants(b)
        let stats = try #require(b.value)
        #expect(stats.mean == 50)
        #expect(stats.n == 28)
        #expect(stats.excluded == 0)
        #expect(stats.standardDeviation == 0)
        #expect(b.coverage == 1)
        // 2026-01-13 … 2026-02-09 inclusive.
        #expect(b.window == TimeRange(start: Fixture.t0 + 8 * 86_400_000, end: Fixture.t0 + 36 * 86_400_000))
    }

    @Test func madOutlierExclusion() throws {
        let raw: [Double] = [60, 61, 59, 60, 62, 58, 60, 61, 59, 60, 60, 61, 59, 60, 90]
        let values = dailyValues(endingOn: target.adding(days: -1, calendar: cal), count: raw.count) { raw[$0] }
        let stats = try #require(BaselineCalculator.baseline(values: values, targetDay: target, calendar: cal).value)
        // median 60, MAD 1 → limit 3 × 1.4826 × 1 = 4.45: only 90 is excluded.
        #expect(stats.median == 60)
        #expect(stats.medianAbsoluteDeviation == 1)
        #expect(stats.excluded == 1)
        #expect(stats.n == 14)
        #expect(stats.mean == 60)
        let sd = try #require(stats.standardDeviation)
        #expect(abs(sd - (14.0 / 13.0).squareRoot()) < 1e-12)
    }

    @Test func zeroMADExcludesNothing() throws {
        let raw = Array(repeating: 60.0, count: 15) + [90]
        let stats = try #require(BaselineCalculator.robustStatistics(raw))
        #expect(stats.medianAbsoluteDeviation == 0)
        #expect(stats.excluded == 0)
        #expect(stats.n == 16)
        #expect(stats.mean == 61.875)
    }

    @Test func calibratingUntilTheMinimumIsRetained() {
        let yesterday = target.adding(days: -1, calendar: cal)
        let thirteen = dailyValues(endingOn: yesterday, count: 13) { _ in 50 }
        let b = BaselineCalculator.baseline(values: thirteen, targetDay: target, calendar: cal,
                                            parameters: BaselineParameters(unit: "nights"))
        expectInvariants(b)
        #expect(b.availability == .calibrating(have: 13, need: 14, unit: "nights"))
        #expect(b.availability.explanation == "Calibrating: 13 of 14 nights")

        // 14 values, one of them an outlier: 13 retained → still calibrating.
        let withOutlier = dailyValues(endingOn: yesterday, count: 14) { [50, 51, 49, 50, 52, 48, 50, 51, 49, 50, 51, 49, 50, 99][$0] }
        let c = BaselineCalculator.baseline(values: withOutlier, targetDay: target, calendar: cal)
        #expect(c.availability == .calibrating(have: 13, need: 14, unit: "days"))

        let none = BaselineCalculator.baseline(values: [:], targetDay: target, calendar: cal)
        #expect(none.availability == .calibrating(have: 0, need: 14, unit: "days"))
    }

    @Test func degenerateInputs() {
        #expect(BaselineCalculator.robustStatistics([]) == nil)
        #expect(BaselineCalculator.robustStatistics([.nan, .infinity]) == nil)
        #expect(BaselineCalculator.robustStatistics([.greatestFiniteMagnitude, .greatestFiniteMagnitude]) == nil)
        let invalid = BaselineCalculator.baseline(values: [:], targetDay: LocalDay(year: 2026, month: 13, day: 1), calendar: cal)
        expectInvariants(invalid)
        #expect(invalid.value == nil)
        let badParameters = BaselineCalculator.baseline(values: [:], targetDay: target, calendar: cal,
                                                        parameters: BaselineParameters(windowDays: 0))
        #expect(badParameters.value == nil)
    }
}
