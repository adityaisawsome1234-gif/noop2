import Foundation
import FormaCore

// Display-ready state for each screen. Views render these and nothing else, so every state
// (disconnected, syncing, partial, calibrating, insufficient quality, unsupported sensor, empty,
// error, demo) is representable — and testable — without a device.

/// A point in a time series. `segment` increments at every gap so charts break the line there.
public struct ChartPoint: Hashable, Sendable, Identifiable {
    public var t: EpochMillis
    public var value: Double
    public var segment: Int
    public var id: EpochMillis { t }

    public init(t: EpochMillis, value: Double, segment: Int) {
        self.t = t
        self.value = value
        self.segment = segment
    }
}

public struct SeriesDisplay: Hashable, Sendable {
    public var points: [ChartPoint]
    public var unit: String
    public var window: TimeRange
    /// Number of gaps longer than the series' gap threshold (shown in captions/accessibility).
    public var gapCount: Int

    public init(points: [ChartPoint], unit: String, window: TimeRange, gapCount: Int) {
        self.points = points
        self.unit = unit
        self.window = window
        self.gapCount = gapCount
    }

    public static func empty(unit: String, window: TimeRange) -> SeriesDisplay {
        SeriesDisplay(points: [], unit: unit, window: window, gapCount: 0)
    }

    public var minValue: Double? { points.map(\.value).min() }
    public var maxValue: Double? { points.map(\.value).max() }
}

/// One metric card.
public struct MetricCardState: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var metric: MetricValue<Double>
    public var unit: String
    /// Pre-formatted value (nil when unavailable).
    public var valueText: String?
    public var status: MetricStatus
    public var footnote: String?

    public init(id: String, title: String, metric: MetricValue<Double>, unit: String, valueText: String?,
                status: MetricStatus, footnote: String? = nil) {
        self.id = id
        self.title = title
        self.metric = metric
        self.unit = unit
        self.valueText = metric.availability.isAvailable ? valueText : nil
        self.status = status
        self.footnote = footnote
    }
}

public struct LatestHeartRate: Hashable, Sendable {
    public var bpm: Int
    public var at: EpochMillis
    public var sourceLabel: String
    /// True when the newest sample is older than the "live" threshold.
    public var isStale: Bool

    public init(bpm: Int, at: EpochMillis, sourceLabel: String, isStale: Bool) {
        self.bpm = bpm
        self.at = at
        self.sourceLabel = sourceLabel
        self.isStale = isStale
    }
}

/// Baseline calibration progress for baseline-relative metrics.
public struct CalibrationProgress: Hashable, Sendable {
    public var eligibleNights: Int
    public var requiredNights: Int
    public var explanation: String

    public init(eligibleNights: Int, requiredNights: Int, explanation: String) {
        self.eligibleNights = eligibleNights
        self.requiredNights = requiredNights
        self.explanation = explanation
    }

    public var isComplete: Bool { eligibleNights >= requiredNights }
}

public struct ReadinessComponentRow: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var valueText: String
    public var baselineText: String
    public var zText: String
    public var weightText: String

    public init(name: String, valueText: String, baselineText: String, zText: String, weightText: String) {
        self.name = name
        self.valueText = valueText
        self.baselineText = baselineText
        self.zText = zText
        self.weightText = weightText
    }
}

public struct ReadinessCardState: Hashable, Sendable {
    /// Composite in SD units relative to the personal baseline.
    public var metric: MetricValue<Double>
    /// "Below your usual range" / "Within your usual range" / "Above your usual range".
    public var bandText: String?
    public var components: [ReadinessComponentRow]

    public init(metric: MetricValue<Double>, bandText: String?, components: [ReadinessComponentRow]) {
        self.metric = metric
        self.bandText = bandText
        self.components = components
    }
}

public struct TodayState: Hashable, Sendable {
    public var day: LocalDay
    public var latestHeartRate: LatestHeartRate?
    public var cards: [MetricCardState]
    /// nil when the experimental index is turned off in Settings.
    public var readiness: ReadinessCardState?
    public var coverage24h: CoverageTimeline
    public var pendingSleepReview: Session?
    public var calibration: CalibrationProgress?
    /// False until any measurement exists in the active store (drives the empty state).
    public var hasAnyData: Bool

    public init(day: LocalDay, latestHeartRate: LatestHeartRate?, cards: [MetricCardState], readiness: ReadinessCardState?,
                coverage24h: CoverageTimeline, pendingSleepReview: Session?, calibration: CalibrationProgress?, hasAnyData: Bool) {
        self.day = day
        self.latestHeartRate = latestHeartRate
        self.cards = cards
        self.readiness = readiness
        self.coverage24h = coverage24h
        self.pendingSleepReview = pendingSleepReview
        self.calibration = calibration
        self.hasAnyData = hasAnyData
    }
}

public struct NightState: Hashable, Sendable, Identifiable {
    public var id: Int64 { session.id ?? session.range.start }
    public var session: Session
    public var timeInBedHours: Double
    public var sleepEstimate: MetricValue<Double>
    public var continuity: MetricValue<Double>
    public var restingHR: MetricValue<Double>
    public var hrv: MetricValue<Double>
    public var heartRate: SeriesDisplay
    public var wakeBouts: [TimeRange]
    public var coverage: CoverageTimeline

    public init(session: Session, timeInBedHours: Double, sleepEstimate: MetricValue<Double>, continuity: MetricValue<Double>,
                restingHR: MetricValue<Double>, hrv: MetricValue<Double>, heartRate: SeriesDisplay, wakeBouts: [TimeRange],
                coverage: CoverageTimeline) {
        self.session = session
        self.timeInBedHours = timeInBedHours
        self.sleepEstimate = sleepEstimate
        self.continuity = continuity
        self.restingHR = restingHR
        self.hrv = hrv
        self.heartRate = heartRate
        self.wakeBouts = wakeBouts
        self.coverage = coverage
    }

    public var isCandidate: Bool { session.origin == .detectedCandidate }
}

public struct SleepState: Hashable, Sendable {
    public var nights: [NightState]
    /// Whether the band provides motion data (needed for detected candidates and wake estimates).
    public var motionAvailability: Availability

    public init(nights: [NightState], motionAvailability: Availability) {
        self.nights = nights
        self.motionAvailability = motionAvailability
    }
}

public struct ZoneTimeDisplay: Hashable, Sendable, Identifiable {
    public var id: Int { zone }
    public var zone: Int
    public var label: String
    public var rangeText: String
    public var millis: Int64
    public var fraction: Double

    public init(zone: Int, label: String, rangeText: String, millis: Int64, fraction: Double) {
        self.zone = zone
        self.label = label
        self.rangeText = rangeText
        self.millis = millis
        self.fraction = fraction
    }
}

public struct WorkoutState: Hashable, Sendable, Identifiable {
    public var id: Int64 { session.id ?? session.range.start }
    public var session: Session
    public var averageHR: MetricValue<Double>
    public var maxHR: MetricValue<Double>
    public var load: MetricValue<Double>
    public var zones: [ZoneTimeDisplay]
    public var zonesAvailability: Availability
    public var heartRate: SeriesDisplay
    public var coverage: Double?

    public init(session: Session, averageHR: MetricValue<Double>, maxHR: MetricValue<Double>, load: MetricValue<Double>,
                zones: [ZoneTimeDisplay], zonesAvailability: Availability, heartRate: SeriesDisplay, coverage: Double?) {
        self.session = session
        self.averageHR = averageHR
        self.maxHR = maxHR
        self.load = load
        self.zones = zones
        self.zonesAvailability = zonesAvailability
        self.heartRate = heartRate
        self.coverage = coverage
    }
}

public struct LiveWorkoutState: Hashable, Sendable {
    public var start: EpochMillis
    public var now: EpochMillis
    public var currentHR: Int?
    public var currentZone: Int?
    /// True when no heart-rate sample arrived recently — the UI must not present a stale value as live.
    public var signalStale: Bool
    public var zones: [ZoneTimeDisplay]
    public var heartRate: SeriesDisplay
    public var sourceLabel: String?

    public init(start: EpochMillis, now: EpochMillis, currentHR: Int?, currentZone: Int?, signalStale: Bool,
                zones: [ZoneTimeDisplay], heartRate: SeriesDisplay, sourceLabel: String?) {
        self.start = start
        self.now = now
        self.currentHR = currentHR
        self.currentZone = currentZone
        self.signalStale = signalStale
        self.zones = zones
        self.heartRate = heartRate
        self.sourceLabel = sourceLabel
    }

    public var elapsedMillis: Int64 { max(0, now - start) }
}

public struct ActivityState: Hashable, Sendable {
    public var live: LiveWorkoutState?
    public var workouts: [WorkoutState]
    public var zonesAvailability: Availability

    public init(live: LiveWorkoutState?, workouts: [WorkoutState], zonesAvailability: Availability) {
        self.live = live
        self.workouts = workouts
        self.zonesAvailability = zonesAvailability
    }
}

public enum TrendMetric: String, Hashable, Sendable, CaseIterable, Identifiable {
    case restingHR, hrv, sleepDuration, load

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .restingHR: return "Resting HR (overnight)"
        case .hrv: return "HRV (RMSSD)"
        case .sleepDuration: return "Sleep duration"
        case .load: return "Forma Load"
        }
    }

    public var unit: String {
        switch self {
        case .restingHR: return "bpm"
        case .hrv: return "ms"
        case .sleepDuration: return "h"
        case .load: return "TRIMP"
        }
    }
}

public enum TrendPeriod: Int, Hashable, Sendable, CaseIterable, Identifiable {
    case week = 7, month = 30, quarter = 90

    public var id: Int { rawValue }
    public var title: String { "\(rawValue) days" }
}

public struct DailyValue: Hashable, Sendable, Identifiable {
    public var id: LocalDay { day }
    public var day: LocalDay
    public var dayStart: EpochMillis
    public var value: Double?
    public var valueText: String

    public init(day: LocalDay, dayStart: EpochMillis, value: Double?, valueText: String) {
        self.day = day
        self.dayStart = dayStart
        self.value = value
        self.valueText = valueText
    }
}

public struct TrendSummaryRow: Hashable, Sendable, Identifiable {
    public var id: String { label }
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct TrendsState: Hashable, Sendable {
    public var metric: TrendMetric
    public var period: TrendPeriod
    public var daily: [DailyValue]
    public var availability: Availability
    public var summary: [TrendSummaryRow]
    /// Descriptive comparison sentence (no causal wording), nil when minimums are not met.
    public var comparison: String?

    public init(metric: TrendMetric, period: TrendPeriod, daily: [DailyValue], availability: Availability,
                summary: [TrendSummaryRow], comparison: String?) {
        self.metric = metric
        self.period = period
        self.daily = daily
        self.availability = availability
        self.summary = summary
        self.comparison = comparison
    }

    public var daysWithData: Int { daily.filter { $0.value != nil }.count }
}
