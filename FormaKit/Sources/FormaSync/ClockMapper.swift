import Foundation
import FormaCore

/// A read of the band's clock: the band reported `deviceSeconds` and the phone received it at `phoneTime`.
public struct DeviceClockReading: Hashable, Sendable {
    public var deviceSeconds: UInt32
    public var phoneTime: EpochMillis

    public init(deviceSeconds: UInt32, phoneTime: EpochMillis) {
        self.deviceSeconds = deviceSeconds
        self.phoneTime = phoneTime
    }

    /// phone − device, in milliseconds.
    public var offsetMillis: Int64 { phoneTime - Int64(deviceSeconds) * 1_000 }
}

/// Maps device timestamps (Unix seconds from the band's real-time clock) to normalized UTC.
///
/// Rules (documented in METHODOLOGY.md → Time):
/// - Device times outside [2020-01-01, phone now + 1 day] cannot be mapped (`.clockUnmapped`, no timestamp).
///   A band whose clock was lost/reset reports such values; Forma never substitutes arrival time.
/// - With no clock reading, or when the measured offset is within `toleranceMillis`, the device clock is
///   trusted as-is (no correction, no flag).
/// - When a clock reading shows a larger offset, the offset is applied and records carry
///   `.clockOffsetApplied` plus the applied offset, so the correction is auditable and reversible.
/// - Readings that disagree with each other by more than `toleranceMillis` mark the clock unstable:
///   records are flagged `.nearClockDiscontinuity` until a consistent pair of readings is seen again.
/// - The band's sub-second field is not used until its unit is verified on hardware.
public struct ClockMapper: Sendable {
    public static let earliestPlausible: EpochMillis = 1_577_836_800_000 // 2020-01-01T00:00:00Z

    public var toleranceMillis: Int64
    public private(set) var offsetMillis: Int64?
    public private(set) var unstable: Bool = false
    public private(set) var readings: [DeviceClockReading] = []

    public init(toleranceMillis: Int64 = 2_000) {
        self.toleranceMillis = max(0, toleranceMillis)
    }

    public mutating func add(_ reading: DeviceClockReading) {
        if let previous = readings.last {
            let disagreement = abs(reading.offsetMillis - previous.offsetMillis)
            unstable = disagreement > toleranceMillis
        }
        readings.append(reading)
        if readings.count > 16 { readings.removeFirst(readings.count - 16) }
        offsetMillis = reading.offsetMillis
    }

    /// Call when the band reports a clock reset/set event or a restart is detected.
    public mutating func markDiscontinuity() {
        unstable = true
    }

    public struct Mapped: Hashable, Sendable {
        public var timestamp: EpochMillis?
        public var flags: QualityFlags
        public var appliedOffsetMillis: Int64?
    }

    public func map(deviceSeconds: UInt32, now: EpochMillis) -> Mapped {
        let raw = Int64(deviceSeconds) * 1_000
        let latest = now + EpochMillis.millisPerDay
        var flags: QualityFlags = []
        if unstable { flags.insert(.nearClockDiscontinuity) }
        var timestamp = raw
        var applied: Int64?
        if let offset = offsetMillis, abs(offset) > toleranceMillis {
            timestamp = raw + offset
            applied = offset
            flags.insert(.clockOffsetApplied)
        }
        guard timestamp >= Self.earliestPlausible, timestamp <= latest else {
            return Mapped(timestamp: nil, flags: flags.union(.clockUnmapped), appliedOffsetMillis: applied)
        }
        return Mapped(timestamp: timestamp, flags: flags, appliedOffsetMillis: applied)
    }
}

/// Detects device restarts and clock jumps in a stream of (record counter, device seconds) pairs from
/// band history. A counter that goes backwards indicates a restart or a new storage segment; a time that
/// goes backwards while the counter advances indicates a clock change. Records adjacent to either are
/// flagged so analytics can exclude them.
public struct DiscontinuityDetector: Sendable {
    public var maxBackwardJumpSeconds: UInt32
    private var last: (counter: UInt32, seconds: UInt32)?

    public init(maxBackwardJumpSeconds: UInt32 = 2) {
        self.maxBackwardJumpSeconds = maxBackwardJumpSeconds
    }

    public enum Finding: Equatable, Sendable {
        case continuous
        case counterRestart
        case clockWentBackwards(seconds: UInt32)
    }

    public mutating func observe(counter: UInt32, deviceSeconds: UInt32) -> Finding {
        defer { last = (counter, deviceSeconds) }
        guard let previous = last else { return .continuous }
        if counter < previous.counter { return .counterRestart }
        if deviceSeconds + maxBackwardJumpSeconds < previous.seconds {
            return .clockWentBackwards(seconds: previous.seconds - deviceSeconds)
        }
        return .continuous
    }

    public mutating func reset() { last = nil }
}
