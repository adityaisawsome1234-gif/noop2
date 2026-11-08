import Foundation
import FormaCore

/// A read of the band's clock: the band reported `deviceSeconds` (+ `subsecondMillis` when known) and
/// the phone received it at `phoneTime`.
public struct DeviceClockReading: Hashable, Sendable {
    public var deviceSeconds: UInt32
    /// Sub-second part in ms, when the adapter knows the field's unit.
    public var subsecondMillis: Int?
    public var phoneTime: EpochMillis

    public init(deviceSeconds: UInt32, subsecondMillis: Int? = nil, phoneTime: EpochMillis) {
        self.deviceSeconds = deviceSeconds
        self.subsecondMillis = subsecondMillis.map { min(max($0, 0), 999) }
        self.phoneTime = phoneTime
    }

    /// Device time in whole seconds, as ms. History records carry whole seconds too, so truncating both
    /// keeps the correction unbiased (the sub-second part is kept for diagnostics only).
    public var deviceMillis: Int64 { Int64(deviceSeconds) * 1_000 }

    /// phone − device, in milliseconds.
    public var offsetMillis: Int64 { phoneTime - deviceMillis }
}

/// Maps device timestamps (Unix seconds from the band's real-time clock) to normalized UTC.
///
/// Rules (documented in METHODOLOGY.md → Time):
/// - Device times outside [2020-01-01, phone now + 1 day] cannot be mapped (`.clockUnmapped`, no timestamp).
///   A band whose clock was lost/reset reports such values; Forma never substitutes arrival time.
/// - With no clock reading, or when the measured offset is within `toleranceMillis`, the device clock is
///   trusted as-is (no correction, no flag).
/// - When a clock reading shows a larger offset (up to `maxCorrectableOffsetMillis`), the offset is
///   applied and records carry `.clockOffsetApplied` plus the applied offset, so the correction is
///   auditable and reversible.
/// - A reading that is implausible (before 2020, or off by more than `maxCorrectableOffsetMillis`) means
///   the band's clock is wrong by days. Forma never sets the band's clock, and a single offset cannot place
///   records written before and after such a reset, so every record is then unmapped (not stored, not
///   acknowledged — the band keeps it) until a plausible reading is seen.
/// - Readings that disagree with each other by more than `toleranceMillis` mark the clock unstable:
///   records are flagged `.nearClockDiscontinuity` until a consistent pair of readings is seen again.
/// - After a clock reset/set event (`markDiscontinuity`) records are flagged until the next reading,
///   which becomes the new baseline.
public struct ClockMapper: Sendable {
    public static let earliestPlausible: EpochMillis = 1_577_836_800_000 // 2020-01-01T00:00:00Z

    public var toleranceMillis: Int64
    public var maxCorrectableOffsetMillis: Int64
    public private(set) var offsetMillis: Int64?
    public private(set) var unstable: Bool = false
    /// The latest reading was implausible: nothing can be mapped until a plausible one arrives.
    public private(set) var implausible: Bool = false
    public private(set) var readings: [DeviceClockReading] = []
    private var awaitingFreshBaseline = false

    public init(toleranceMillis: Int64 = 2_000, maxCorrectableOffsetMillis: Int64 = EpochMillis.millisPerDay) {
        self.toleranceMillis = max(0, toleranceMillis)
        self.maxCorrectableOffsetMillis = max(self.toleranceMillis, maxCorrectableOffsetMillis)
    }

    public enum ReadingOutcome: Equatable, Sendable {
        case accepted(offsetMillis: Int64)
        /// The band's clock is before 2020 or off by more than a day.
        case implausible(offsetMillis: Int64)
    }

    @discardableResult
    public mutating func add(_ reading: DeviceClockReading) -> ReadingOutcome {
        let offset = reading.offsetMillis
        guard reading.deviceMillis >= Self.earliestPlausible, abs(offset) <= maxCorrectableOffsetMillis else {
            implausible = true
            return .implausible(offsetMillis: offset)
        }
        implausible = false
        if awaitingFreshBaseline {
            readings = [reading]
            unstable = false
            awaitingFreshBaseline = false
        } else {
            if let previous = readings.last {
                unstable = abs(offset - previous.offsetMillis) > toleranceMillis
            }
            readings.append(reading)
            if readings.count > 16 { readings.removeFirst(readings.count - 16) }
        }
        offsetMillis = offset
        return .accepted(offsetMillis: offset)
    }

    /// Call when the band reports a clock reset/set event or a restart is detected. Records are flagged
    /// until the next clock reading, which becomes the new baseline.
    public mutating func markDiscontinuity() {
        unstable = true
        awaitingFreshBaseline = true
    }

    public struct Mapped: Hashable, Sendable {
        public var timestamp: EpochMillis?
        public var flags: QualityFlags
        public var appliedOffsetMillis: Int64?
    }

    public func map(deviceSeconds: UInt32, now: EpochMillis) -> Mapped {
        var flags: QualityFlags = []
        if unstable { flags.insert(.nearClockDiscontinuity) }
        if implausible {
            return Mapped(timestamp: nil, flags: flags.union(.clockUnmapped), appliedOffsetMillis: nil)
        }
        let raw = Int64(deviceSeconds) * 1_000
        let (latest, overflow) = now.addingReportingOverflow(EpochMillis.millisPerDay)
        var timestamp = raw
        var applied: Int64?
        if let offset = offsetMillis, abs(offset) > toleranceMillis {
            timestamp = raw + offset
            applied = offset
            flags.insert(.clockOffsetApplied)
        }
        guard timestamp >= Self.earliestPlausible, overflow || timestamp <= latest else {
            return Mapped(timestamp: nil, flags: flags.union(.clockUnmapped), appliedOffsetMillis: applied)
        }
        return Mapped(timestamp: timestamp, flags: flags, appliedOffsetMillis: applied)
    }
}

/// Detects device restarts and clock jumps in a stream of (record counter, device seconds) pairs from
/// band history, tracked separately per record kind (kinds may keep separate counters). A counter that
/// goes backwards indicates a restart or a new storage segment; a time that goes backwards by more
/// than `maxBackwardJumpSeconds` while the counter advances indicates a clock change. Records adjacent
/// to either are flagged so analytics can exclude them. Reset it whenever a new transfer starts: a
/// re-sent transfer legitimately starts again at lower counters.
public struct DiscontinuityDetector: Sendable {
    public var maxBackwardJumpSeconds: UInt32
    private var last: [UInt8: (counter: UInt32, seconds: UInt32)] = [:]

    public init(maxBackwardJumpSeconds: UInt32 = 2) {
        self.maxBackwardJumpSeconds = maxBackwardJumpSeconds
    }

    public enum Finding: Equatable, Sendable {
        case continuous
        case counterRestart
        case clockWentBackwards(seconds: UInt32)
    }

    public mutating func observe(kind: UInt8 = 0, counter: UInt32, deviceSeconds: UInt32) -> Finding {
        defer { last[kind] = (counter, deviceSeconds) }
        guard let previous = last[kind] else { return .continuous }
        if counter < previous.counter { return .counterRestart }
        // Written without addition so all-ones timestamps cannot overflow.
        if previous.seconds > deviceSeconds, previous.seconds - deviceSeconds > maxBackwardJumpSeconds {
            return .clockWentBackwards(seconds: previous.seconds - deviceSeconds)
        }
        return .continuous
    }

    public mutating func reset() { last.removeAll() }
}
