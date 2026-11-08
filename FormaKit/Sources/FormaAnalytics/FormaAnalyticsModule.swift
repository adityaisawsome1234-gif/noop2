import FormaCore

/// FormaAnalytics: pure, deterministic derived metrics (no I/O, no clock, no global state).
///
/// Every public result is a `MetricValue` (or a struct of them) stamped with the spec ID and version
/// of its ``MetricCatalog`` entry, its availability reason, coverage, confidence, window and the
/// inputs used. Unknown values are `nil` with a reason, never 0.
///
/// - Concurrency: every API is synchronous, nonisolated and works on `Sendable` values only. A night of
///   beats or a day of 1 Hz heart rate takes noticeable time, so call the analyzers off the main actor
///   (for example from a background actor) and hand the results to the UI.
/// - Days: a `LocalDay` is a Gregorian date in the time zone of the `Calendar` passed in; only that time
///   zone is used, whatever calendar system the phone is set to.
/// - Input quality: samples, beats and motion epochs flagged `.unvalidatedField` (like `.outOfRange`,
///   `.noSensorContact` or `.clockUnmapped`) never enter any metric, coverage or zone.
public enum FormaAnalyticsModule {
    public static let name = "FormaAnalytics"
}
