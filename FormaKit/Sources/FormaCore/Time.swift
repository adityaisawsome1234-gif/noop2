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

    public var durationMillis: Int64 { end - start }
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
        let c = calendar.dateComponents([.year, .month, .day], from: t.date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// The `[00:00, next 00:00)` range of this day in the calendar's time zone.
    public func range(calendar: Calendar) -> TimeRange {
        let start = calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return TimeRange(start: EpochMillis(date: start), end: EpochMillis(date: end))
    }

    public func adding(days: Int, calendar: Calendar) -> LocalDay {
        let start = range(calendar: calendar).start.date
        let shifted = calendar.date(byAdding: .day, value: days, to: start) ?? start
        return LocalDay(EpochMillis(date: shifted), calendar: calendar)
    }

    public static func < (a: LocalDay, b: LocalDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}
