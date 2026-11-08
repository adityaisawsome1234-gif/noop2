import Foundation
import FormaCore

// Internal helpers shared by the analyzers. Everything here is pure, total (never traps on any
// input) and deterministic: no locale, no wall clock, no global mutable state.

// MARK: - Input sanity

/// Bounds applied to externally supplied timestamps before any arithmetic.
///
/// Every timestamp the analytics accept lies within ±2^52 ms of the Unix epoch (about ±142,000
/// years). Sums and differences of accepted timestamps, and the bpm × ms products used for
/// time-weighting, therefore always fit in `Int64` and can never trap.
enum Sanity {
    static let maxAbsTimestamp: Int64 = 1 << 52

    static func isSane(_ t: EpochMillis) -> Bool {
        t >= -maxAbsTimestamp && t <= maxAbsTimestamp
    }

    static func isSane(_ range: TimeRange) -> Bool {
        isSane(range.start) && isSane(range.end)
    }
}

// MARK: - Integer helpers

enum IntMath {
    /// Floor division for a positive divisor (Swift's `/` truncates toward zero).
    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && a < 0) ? q - 1 : q
    }

    /// Sum that saturates at the type's bounds instead of trapping. Used for totals of public, Codable
    /// fields, which may hold corrupted values after decoding.
    static func saturatingSum<T: FixedWidthInteger>(_ xs: [T]) -> T {
        var total: T = 0
        for x in xs {
            let (sum, overflow) = total.addingReportingOverflow(x)
            total = overflow ? (x > 0 ? .max : .min) : sum
        }
        return total
    }
}

// MARK: - Binary search on ascending arrays

enum Search {
    /// Index of the first element `>= value` (`array.count` when none).
    static func lowerBound(_ array: [Int64], _ value: Int64) -> Int {
        var lo = 0
        var hi = array.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if array[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Index of the first element `> value` (`array.count` when none).
    static func upperBound(_ array: [Int64], _ value: Int64) -> Int {
        var lo = 0
        var hi = array.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if array[mid] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: - Statistics

/// Descriptive statistics. Callers pass finite values only.
enum Stats {
    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        var sum = 0.0
        for x in xs { sum += x }
        return sum / Double(xs.count)
    }

    /// Median; the mean of the two middle values for an even count.
    static func median(_ xs: [Double]) -> Double? {
        medianOfSorted(xs.sorted())
    }

    static func medianOfSorted(_ sorted: [Double]) -> Double? {
        let n = sorted.count
        guard n > 0 else { return nil }
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// Sample standard deviation (n − 1 denominator); nil for fewer than two values.
    static func sampleStandardDeviation(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        var ss = 0.0
        for x in xs {
            let d = x - m
            ss += d * d
        }
        return (ss / Double(xs.count - 1)).squareRoot()
    }

    /// Percentile `p` (0…1) by linear interpolation between order statistics (Hyndman–Fan type 7,
    /// the default of R and NumPy).
    static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty, p.isFinite else { return nil }
        let s = xs.sorted()
        let q = min(max(p, 0), 1)
        let h = Double(s.count - 1) * q
        let lo = Int(h.rounded(.down))
        let hi = min(lo + 1, s.count - 1)
        return s[lo] + (h - Double(lo)) * (s[hi] - s[lo])
    }

    /// Unscaled median absolute deviation: median(|x − median(x)|).
    static func medianAbsoluteDeviation(_ xs: [Double], median m: Double) -> Double? {
        median(xs.map { abs($0 - m) })
    }

    /// Rounds half away from zero to `decimals` places (0…6).
    static func rounded(_ x: Double, decimals: Int) -> Double {
        guard x.isFinite else { return x }
        let scale = Fmt.powerOfTen(decimals)
        return (x * scale).rounded() / scale
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), hi)
    }
}

/// Fraction tests with a tiny relative tolerance, so inputs that sit exactly on a documented
/// threshold (e.g. 240 000 of 300 000 ms at 80 %) pass regardless of binary floating-point
/// representation.
enum Threshold {
    static func meets(_ part: Double, of whole: Double, fraction: Double) -> Bool {
        part >= fraction * whole - 1e-9 * max(1, abs(whole))
    }
}

// MARK: - Deterministic formatting (no locale, identical on Linux and Apple platforms)

enum Fmt {
    static func powerOfTen(_ decimals: Int) -> Double {
        switch max(0, min(decimals, 6)) {
        case 0: return 1
        case 1: return 10
        case 2: return 100
        case 3: return 1_000
        case 4: return 10_000
        case 5: return 100_000
        default: return 1_000_000
        }
    }

    /// Fixed-point decimal string, rounded half away from zero, "." separator.
    static func number(_ x: Double, decimals: Int = 1) -> String {
        guard x.isFinite else { return x.isNaN ? "n/a" : (x > 0 ? "inf" : "-inf") }
        let d = max(0, min(decimals, 6))
        let scale = powerOfTen(d)
        guard let r = Int64(exactly: (x * scale).rounded()) else { return "\(x)" }
        let magnitude = r.magnitude
        let unit = UInt64(scale)
        var s = r < 0 ? "-" : ""
        s += String(magnitude / unit)
        if d > 0 {
            var frac = String(magnitude % unit)
            while frac.count < d { frac = "0" + frac }
            s += "." + frac
        }
        return s
    }

    /// "80%" for 0.8.
    static func percent(_ fraction: Double, decimals: Int = 0) -> String {
        number(fraction * 100, decimals: decimals) + "%"
    }

    static func bpm(_ x: Double, decimals: Int = 1) -> String {
        number(x, decimals: decimals) + " bpm"
    }

    /// "3 h", "2 h 30 min", "45 min" or "30 s" (whole units, truncated).
    static func duration(_ ms: Int64) -> String {
        let seconds = ms.magnitude / 1_000
        let body: String
        if seconds < 60 {
            body = "\(seconds) s"
        } else {
            let minutes = seconds / 60
            if minutes < 60 {
                body = "\(minutes) min"
            } else {
                body = minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
            }
        }
        return ms < 0 ? "-" + body : body
    }

    /// Signed number with an explicit "+" for positive values.
    static func signed(_ x: Double, decimals: Int = 2) -> String {
        x > 0 ? "+" + number(x, decimals: decimals) : number(x, decimals: decimals)
    }
}

// MARK: - Calendar days

/// Local-day arithmetic that validates its inputs instead of trusting Foundation's lenient
/// normalisation (which would silently turn 31 February into 3 March).
///
/// **`LocalDay` is a Gregorian date in the calendar's time zone.** Only the time zone of the `Calendar`
/// passed in is used: a phone set to the Buddhist, Japanese, Hebrew, Islamic, Persian or ROC calendar
/// (`Calendar.current`) gets the same days, trends and baselines as a Gregorian one. Every day this
/// module creates is Gregorian, so build the `LocalDay` keys you pass in from Gregorian dates too.
enum DayMath {
    static let plausibleYears: ClosedRange<Int> = 1900...2200

    /// A Gregorian calendar in `calendar`'s time zone (`calendar` itself when it is already Gregorian).
    static func gregorian(_ calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        return g
    }

    /// Start instant of `day` (its first local instant: 01:00 where a DST change skips midnight), or nil
    /// for a malformed or non-existent day.
    static func start(of day: LocalDay, calendar: Calendar) -> Date? {
        let calendar = gregorian(calendar)
        guard plausibleYears.contains(day.year), (1...12).contains(day.month), (1...31).contains(day.day),
              let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
        else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard c.year == day.year, c.month == day.month, c.day == day.day else { return nil }
        return date
    }

    /// `[start of day, start of the next day)`: 23 or 25 h on DST changes, and consecutive days always
    /// tile the timeline (also where a DST change skips midnight and the day starts at 01:00).
    static func range(of day: LocalDay, calendar: Calendar) -> TimeRange? {
        let calendar = gregorian(calendar)
        guard let s = start(of: day, calendar: calendar),
              let next = self.day(day, offsetBy: 1, calendar: calendar),
              let e = start(of: next, calendar: calendar),
              let sm = millis(s), let em = millis(e), em > sm
        else { return nil }
        return TimeRange(start: sm, end: em)
    }

    /// The local wall-clock time `hour`:00 on `day`, or nil when the day is invalid.
    static func time(hour: Int, on day: LocalDay, calendar: Calendar) -> EpochMillis? {
        let calendar = gregorian(calendar)
        guard (0...23).contains(hour), start(of: day, calendar: calendar) != nil,
              let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour))
        else { return nil }
        return millis(date)
    }

    static func millis(_ date: Date) -> EpochMillis? {
        guard let m = Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded()), Sanity.isSane(m) else { return nil }
        return m
    }

    /// The (Gregorian) day `offset` calendar days away from `day`.
    static func day(_ day: LocalDay, offsetBy offset: Int, calendar: Calendar) -> LocalDay? {
        let calendar = gregorian(calendar)
        guard let s = start(of: day, calendar: calendar),
              let d = calendar.date(byAdding: .day, value: offset, to: s)
        else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        guard let y = c.year, let m = c.month, let dd = c.day else { return nil }
        return LocalDay(year: y, month: m, day: dd)
    }

    /// `count` consecutive (Gregorian) days ending with `last` (inclusive), oldest first.
    static func days(endingOn last: LocalDay, count: Int, calendar: Calendar) -> [LocalDay]? {
        let calendar = gregorian(calendar)
        guard count >= 0, count <= 3_660, let s = start(of: last, calendar: calendar) else { return nil }
        var out: [LocalDay] = []
        out.reserveCapacity(count)
        var k = count - 1
        while k >= 0 {
            guard let d = calendar.date(byAdding: .day, value: -k, to: s) else { return nil }
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            guard let y = c.year, let m = c.month, let dd = c.day else { return nil }
            out.append(LocalDay(year: y, month: m, day: dd))
            k -= 1
        }
        return out
    }

    /// Finite values recorded for `days` (missing keys, explicit nil and non-finite values are skipped).
    static func values(for days: [LocalDay], in map: [LocalDay: Double?]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(days.count)
        for d in days {
            if let entry = map[d], let v = entry, v.isFinite { out.append(v) }
        }
        return out
    }
}

// MARK: - Result construction

extension Confidence {
    /// Coverage-based confidence for a value that is available (never `.none`).
    static func forAvailable(coverage: Double?) -> Confidence {
        max(.low, fromCoverage(coverage))
    }
}

extension MetricSpec {
    /// An available value stamped with this spec. Confidence is at least `.low`.
    func available<V: Hashable & Sendable & Codable>(_ value: V, coverage: Double?, confidence: Confidence,
                                                      window: TimeRange?, inputs: [String: String]) -> MetricValue<V> {
        MetricValue(value: value, availability: .available, coverage: coverage, confidence: max(.low, confidence),
                    window: window, specID: id, specVersion: version, inputs: inputs)
    }

    /// Like `available`, but refuses non-finite numbers (reported as low quality instead).
    func number(_ value: Double, coverage: Double?, confidence: Confidence, window: TimeRange?,
                inputs: [String: String]) -> MetricValue<Double> {
        guard value.isFinite else {
            return unavailable(.lowQuality(detail: "The computation did not produce a finite value"),
                               coverage: coverage, window: window, inputs: inputs)
        }
        return available(value, coverage: coverage, confidence: confidence, window: window, inputs: inputs)
    }

    /// An unavailable value stamped with this spec (value nil, confidence `.none`).
    func unavailable<V: Hashable & Sendable & Codable>(_ availability: Availability, coverage: Double? = nil,
                                                        window: TimeRange?, inputs: [String: String] = [:]) -> MetricValue<V> {
        MetricValue<V>.unavailable(availability, specID: id, specVersion: version, window: window,
                                   coverage: coverage, inputs: inputs)
    }
}
