import Foundation
import Testing
import FormaCore
import FormaAnalytics

/// Shared deterministic fixtures: fixed calendars, a fixed epoch, builders and a seeded PRNG.
enum Fixture {
    /// 2026-01-05T00:00:00Z (a Monday), a whole second and a whole minute.
    static let t0: EpochMillis = 1_767_571_200_000
    static let second: Int64 = 1_000
    static let minute: Int64 = 60_000
    static let hour: Int64 = 3_600_000

    static func calendar(_ identifier: String) -> Calendar? {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    /// Gregorian calendar in UTC (falls back to a fixed zero offset).
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? c.timeZone
        return c
    }()

    static func hr(_ t: EpochMillis, _ bpm: Int, source: MeasurementSource = .deviceHistory, quality: QualityFlags = [],
                   receivedAt: EpochMillis? = nil, device: String = "band-1") -> HeartRateSample {
        HeartRateSample(deviceID: device, timestamp: t, bpm: bpm, source: source, receivedAt: receivedAt ?? t,
                        quality: quality)
    }

    /// `count` samples every `step` ms from `start`, bpm given by index.
    static func hrRun(from start: EpochMillis, count: Int, step: Int64 = 1_000, source: MeasurementSource = .deviceHistory,
                      bpm: (Int) -> Int) -> [HeartRateSample] {
        (0..<count).map { hr(start + Int64($0) * step, bpm($0), source: source) }
    }

    /// Constant heart rate from `start` (inclusive) to `end` (exclusive), one sample every `step` ms.
    static func hrConstant(from start: EpochMillis, to end: EpochMillis, bpm: Int, step: Int64 = 1_000) -> [HeartRateSample] {
        guard end > start else { return [] }
        return hrRun(from: start, count: Int((end - start + step - 1) / step), step: step) { _ in bpm }
    }

    static func beat(_ t: EpochMillis, _ interval: Double, source: MeasurementSource = .deviceHistory,
                     quality: QualityFlags = [], index: Int = 0, device: String = "band-1") -> BeatInterval {
        BeatInterval(deviceID: device, timestamp: t, intervalMillis: interval, source: source, recordKey: t,
                     indexInRecord: index, receivedAt: t, timingBasis: .reconstructedFromRecordTime, quality: quality)
    }

    /// Beats whose timestamps are `origin` + the running sum of `intervals` (each beat closes its interval).
    static func beats(origin: EpochMillis, intervals: [Double], source: MeasurementSource = .deviceHistory) -> [BeatInterval] {
        var t = Double(origin)
        return intervals.enumerated().map { i, x in
            t += x
            return beat(EpochMillis(t.rounded()), x, source: source, index: i)
        }
    }

    /// One group of 300 beats per 5-min window: intervals alternate 1000 − a, 1000 + a (sum 300 s), so
    /// every within-window successive difference is ±2a and the window RMSSD is exactly 2a. The first
    /// beat lands 500 − a ms after the window start, the last 500 ms before the window end.
    static func alternatingWindows(start: EpochMillis, amplitudes: [Double]) -> [BeatInterval] {
        var intervals: [Double] = []
        for a in amplitudes {
            for i in 0..<300 { intervals.append(i % 2 == 0 ? 1_000 - a : 1_000 + a) }
        }
        return beats(origin: start - 500, intervals: intervals)
    }

    static func motion(_ t: EpochMillis, _ activity: Double, samples: Int = 100, epoch: Int64 = 60_000,
                       quality: QualityFlags = []) -> MotionEpoch {
        MotionEpoch(deviceID: "band-1", timestamp: t, epochMillis: epoch, activity: activity, sampleCount: samples,
                    source: .deviceHistory, quality: quality)
    }

    /// One 60 s motion epoch per minute in `[start, end)`, activity chosen per epoch start (nil = no epoch).
    static func motionMinutes(from start: EpochMillis, to end: EpochMillis, activity: (EpochMillis) -> Double?) -> [MotionEpoch] {
        stride(from: start, to: end, by: Int(minute)).compactMap { t in activity(t).map { motion(t, $0) } }
    }
}

/// SplitMix64: a tiny, fully deterministic PRNG for reproducible randomised tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Checks the honesty invariants every MetricValue must satisfy.
func expectInvariants<V>(_ m: MetricValue<V>, sourceLocation: SourceLocation = #_sourceLocation) {
    if m.availability.isAvailable {
        #expect(m.value != nil, "available result without a value", sourceLocation: sourceLocation)
        #expect(m.confidence != .none, "available result with confidence .none", sourceLocation: sourceLocation)
    } else {
        #expect(m.value == nil, "unavailable result carries a value", sourceLocation: sourceLocation)
        #expect(m.confidence == .none, "unavailable result carries confidence", sourceLocation: sourceLocation)
    }
    let spec = MetricCatalog.spec(for: m.specID)
    #expect(spec != nil, "unknown spec \(m.specID)", sourceLocation: sourceLocation)
    #expect(spec?.version == m.specVersion, sourceLocation: sourceLocation)
    if let c = m.coverage {
        #expect(c.isFinite && c >= 0 && c <= 1 + 1e-9, "coverage \(c) out of range", sourceLocation: sourceLocation)
    }
    if let d = m.value as? Double {
        #expect(d.isFinite, "non-finite value", sourceLocation: sourceLocation)
    }
}

extension Availability {
    var isInsufficientData: Bool {
        if case .insufficientData = self { return true }
        return false
    }

    var isLowQuality: Bool {
        if case .lowQuality = self { return true }
        return false
    }

    var isUnsupportedSensor: Bool {
        if case .unsupportedSensor = self { return true }
        return false
    }

    var detailText: String { explanation }
}
