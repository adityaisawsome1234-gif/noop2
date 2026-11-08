import Foundation
import FormaCore

/// Generates clearly-labelled synthetic data for Demo mode.
///
/// Demo data is written to a SEPARATE database file, every record carries `MeasurementSource.demo`,
/// and the UI shows a persistent "Demo data" label. It exists so the interface can be explored before
/// a band is connected; it is never mixed with live records.
public struct DemoDataGenerator: Sendable {
    public struct Output: Sendable {
        public var device: DeviceRecord
        public var batches: [IngestBatch]
        public var sessions: [Session]
    }

    public static let deviceID = "demo-band"
    public static let adapterID = "forma.demo"
    public static let parserVersion = "demo-1"

    public var seed: UInt64
    public var days: Int
    public var end: EpochMillis
    public var calendar: Calendar
    /// Seconds between demo heart-rate samples (5 s keeps the demo database small).
    public var hrIntervalSeconds: Int

    public init(seed: UInt64 = 0x466F726D61, days: Int = 35, end: EpochMillis, calendar: Calendar, hrIntervalSeconds: Int = 5) {
        self.seed = seed
        self.days = max(1, min(days, 120))
        self.end = end
        self.calendar = calendar
        self.hrIntervalSeconds = max(1, hrIntervalSeconds)
    }

    public func generate() -> Output {
        var rng = SplitMix64(seed: seed)
        let today = LocalDay(end, calendar: calendar)
        let firstDay = today.adding(days: -(days - 1), calendar: calendar)
        let device = DeviceRecord(id: Self.deviceID, family: .unknown, name: "Demo band",
                                  firmwareVersion: "demo", hardwareRevision: nil,
                                  firstSeen: firstDay.range(calendar: calendar).start, lastConnected: end)

        // Night k ends on the morning of day k (k = 0...days; night `days` ends tomorrow morning).
        struct Night { var window: TimeRange; var resting: Double; var hrv: Double }
        var nights: [Night] = []
        var restingTrend = 52.0
        var hrvTrend = 55.0
        for k in 0...days {
            let dayStart = firstDay.adding(days: k, calendar: calendar).range(calendar: calendar).start
            let start = dayStart - 60 * 60_000 + Int64(rng.gaussian(mean: 0, sd: 25)) * 60_000
            let stop = dayStart + 7 * 3_600_000 + Int64(rng.gaussian(mean: 0, sd: 25)) * 60_000
            restingTrend = min(60, max(46, restingTrend + rng.gaussian(mean: 0, sd: 0.8)))
            hrvTrend = min(80, max(32, hrvTrend + rng.gaussian(mean: 0, sd: 3)))
            nights.append(Night(window: TimeRange(start: start, end: stop), resting: restingTrend, hrv: hrvTrend))
        }

        var batches: [IngestBatch] = []
        var sessions: [Session] = []

        for d in 0..<days {
            let dayRange = firstDay.adding(days: d, calendar: calendar).range(calendar: calendar)
            let morningNight = nights[d]       // ends this morning
            let eveningNight = nights[d + 1]   // starts this evening
            let hasWorkout = d % 2 == 1
            let workoutStart = dayRange.start + 18 * 3_600_000 + Int64(rng.uniform(0, 40)) * 60_000
            let workout = TimeRange(start: workoutStart, end: workoutStart + 45 * 60_000)
            // Some days include a band-off gap to demonstrate visible gaps and coverage.
            let offGap: TimeRange? = d % 6 == 2
                ? TimeRange(start: dayRange.start + 13 * 3_600_000, end: dayRange.start + 15 * 3_600_000) : nil
            let generationEnd = min(dayRange.end, end)

            func night(at t: EpochMillis) -> Night? {
                if morningNight.window.contains(t) { return morningNight }
                if eveningNight.window.contains(t) { return eveningNight }
                return nil
            }

            var hr: [HeartRateSample] = []
            var drift = 0.0
            var t = dayRange.start
            while t < generationEnd {
                defer { t += Int64(hrIntervalSeconds) * 1_000 }
                if let g = offGap, g.contains(t) { continue }
                drift = 0.98 * drift + rng.gaussian(mean: 0, sd: 0.9)
                let bpm: Double
                if let n = night(at: t) {
                    let progress = Double(t - n.window.start) / Double(max(1, n.window.durationMillis))
                    bpm = n.resting + 4 - 3.0 * sin(progress * .pi) + drift * 0.5
                } else if hasWorkout && workout.contains(t) {
                    let p = Double(t - workout.start) / Double(workout.durationMillis)
                    let effort = p < 0.1 ? p / 0.1 : (p > 0.9 ? (1 - p) / 0.1 : 1)
                    bpm = 95 + 60 * effort + drift
                } else {
                    bpm = 72 + drift * 2
                }
                let value = Int(bpm.rounded())
                guard HeartRateSample.plausibleRange.contains(value) else { continue }
                hr.append(HeartRateSample(deviceID: Self.deviceID, timestamp: t, bpm: value, source: .demo,
                                          receivedAt: t, quality: []))
            }

            // Beat intervals for the night ending this morning: 3 h mid-sleep, respiratory modulation,
            // occasional premature beats (the artifact rules are expected to reject those).
            var beats: [BeatInterval] = []
            let rrStart = morningNight.window.start + 2 * 3_600_000
            let rrEnd = min(rrStart + 3 * 3_600_000, end)
            if d > 0, rrStart < rrEnd {
                let meanRR = 60_000 / (morningNight.resting + 3)
                let rsaAmplitude = morningNight.hrv * 0.6
                var bt = rrStart
                var index = 0
                var phase = 0.0
                while bt < rrEnd {
                    phase += 2 * .pi * 0.25 * meanRR / 1_000
                    var rr = meanRR + rsaAmplitude * sin(phase) + rng.gaussian(mean: 0, sd: morningNight.hrv * 0.35)
                    if rng.uniform(0, 1) < 0.002 { rr *= 0.65 }
                    rr = min(1_900, max(320, rr))
                    bt += Int64(rr.rounded())
                    beats.append(BeatInterval(deviceID: Self.deviceID, timestamp: bt, intervalMillis: rr, source: .demo,
                                              recordKey: rrStart, indexInRecord: index, receivedAt: bt,
                                              timingBasis: .reconstructedFromRecordTime))
                    index += 1
                }
            }

            // Motion epochs (60 s): quiet during sleep with brief awakenings.
            var motion: [MotionEpoch] = []
            var mt = dayRange.start
            while mt < generationEnd {
                defer { mt += 60_000 }
                if let g = offGap, g.contains(mt) { continue }
                let activity: Double
                if night(at: mt) != nil {
                    activity = rng.uniform(0, 1) < 0.03 ? rng.uniform(0.05, 0.15) : abs(rng.gaussian(mean: 0.004, sd: 0.002))
                } else if hasWorkout && workout.contains(mt) {
                    activity = rng.uniform(0.25, 0.6)
                } else {
                    activity = abs(rng.gaussian(mean: 0.06, sd: 0.04))
                }
                motion.append(MotionEpoch(deviceID: Self.deviceID, timestamp: mt, epochMillis: 60_000, activity: activity,
                                          sampleCount: 60, source: .demo))
            }

            let provenance = Provenance(deviceID: Self.deviceID, adapterID: Self.adapterID, parserVersion: Self.parserVersion,
                                        firmwareVersion: "demo", source: .demo, syncRunID: nil, createdAt: end,
                                        note: "Synthetic demo data")
            batches.append(IngestBatch(provenance: provenance, heartRates: hr, beatIntervals: beats, motion: motion))

            // Sleep session for the night ending this morning (night 0 is only partially generated).
            if d > 0, morningNight.window.end <= end {
                sessions.append(Session(kind: .sleep, range: morningNight.window, origin: .userConfirmed,
                                        deviceID: Self.deviceID, createdAt: end, updatedAt: end))
            }
            if hasWorkout && workout.end <= end {
                sessions.append(Session(kind: .workout, range: workout, origin: .manual, label: "Run",
                                        deviceID: Self.deviceID, createdAt: end, updatedAt: end))
            }
        }
        // The most recent completed night is left as an unconfirmed candidate to demonstrate review.
        if let i = sessions.lastIndex(where: { $0.kind == .sleep }) {
            sessions[i].origin = .detectedCandidate
            sessions[i].detector = "demo"
            sessions[i].confidence = 0.8
        }
        return Output(device: device, batches: batches, sessions: sessions)
    }
}

/// Small, fast, deterministic PRNG (SplitMix64) for reproducible demo data.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in [lower, upper).
    mutating func uniform(_ lower: Double, _ upper: Double) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return lower + (upper - lower) * unit
    }

    /// Gaussian via Box–Muller.
    mutating func gaussian(mean: Double, sd: Double) -> Double {
        let u1 = max(uniform(0, 1), 1e-12)
        let u2 = uniform(0, 1)
        return mean + sd * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
