import Foundation

/// Milliseconds since the Unix epoch (UTC). All normalized timestamps in Forma use this unit.
public typealias EpochMillis = Int64

public extension EpochMillis {
    static let millisPerSecond: Int64 = 1_000
    static let millisPerMinute: Int64 = 60_000
    static let millisPerHour: Int64 = 3_600_000
    static let millisPerDay: Int64 = 86_400_000

    init(date: Date) {
        self = Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    var date: Date { Date(timeIntervalSince1970: TimeInterval(self) / 1_000) }
}

/// Half-open time interval `[start, end)` in epoch milliseconds.
public struct TimeRange: Hashable, Sendable, Codable, CustomStringConvertible {
    public let start: EpochMillis
    public let end: EpochMillis

    /// Creates a range. If `end < start` the range is clamped to be empty at `start`
    /// (never crashes on bad input from a device or an import).
    public init(start: EpochMillis, end: EpochMillis) {
        self.start = start
        self.end = max(start, end)
    }

    /// Saturates at `Int64.max` for ranges wider than Int64 can represent (never traps).
    public var durationMillis: Int64 {
        let (d, overflow) = end.subtractingReportingOverflow(start)
        return overflow ? .max : d
    }
    public var durationSeconds: Double { Double(durationMillis) / 1_000 }
    public var isEmpty: Bool { end <= start }

    public func contains(_ t: EpochMillis) -> Bool { t >= start && t < end }

    public func overlaps(_ other: TimeRange) -> Bool { start < other.end && other.start < end }

    public func intersection(_ other: TimeRange) -> TimeRange? {
        let s = max(start, other.start)
        let e = min(end, other.end)
        return e > s ? TimeRange(start: s, end: e) : nil
    }

    public var description: String { "[\(start), \(end))" }
}

/// A time-source abstraction so tests and replays never depend on wall time.
/// (Named `TimeSource` to avoid clashing with the standard library's `Clock`.)
public protocol TimeSource: Sendable {
    func now() -> EpochMillis
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public func now() -> EpochMillis { EpochMillis(date: Date()) }
}

/// A manually advanced time source for deterministic tests and replays.
public final class ManualTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: EpochMillis

    public init(_ start: EpochMillis) { current = start }

    public func now() -> EpochMillis {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(byMillis delta: Int64) {
        lock.lock(); defer { lock.unlock() }
        current += delta
    }

    public func set(_ value: EpochMillis) {
        lock.lock(); defer { lock.unlock() }
        current = value
    }
}

/// Calendar helpers that work on local days, which is how people read sleep and daily totals.
///
/// Days are always Gregorian dates in the given calendar's time zone, whatever calendar system the
/// user has chosen, and a day runs from its first instant to the first instant of the next day — so a
/// day where daylight saving time skips midnight neither overlaps nor gaps with its neighbours.
public struct LocalDay: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ t: EpochMillis, calendar: Calendar) {
        let c = Self.gregorian(like: calendar).dateComponents([.year, .month, .day], from: t.date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// The range from this day's first instant to the next day's first instant, in the calendar's time zone.
    public func range(calendar: Calendar) -> TimeRange {
        let g = Self.gregorian(like: calendar)
        let noon = self.noon(in: g)
        let start = g.startOfDay(for: noon)
        let nextNoon = g.date(byAdding: .day, value: 1, to: noon) ?? noon.addingTimeInterval(86_400)
        let end = g.startOfDay(for: nextNoon)
        return TimeRange(start: EpochMillis(date: start), end: EpochMillis(date: end))
    }

    public func adding(days: Int, calendar: Calendar) -> LocalDay {
        let g = Self.gregorian(like: calendar)
        let noon = self.noon(in: g)
        let shifted = g.date(byAdding: .day, value: days, to: noon) ?? noon
        return LocalDay(EpochMillis(date: shifted), calendar: g)
    }

    /// Noon is never skipped or repeated by a daylight-saving change, so day arithmetic starts there.
    private func noon(in g: Calendar) -> Date {
        g.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 0)
    }

    private static func gregorian(like calendar: Calendar) -> Calendar {
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        return g
    }

    public static func < (a: LocalDay, b: LocalDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}
