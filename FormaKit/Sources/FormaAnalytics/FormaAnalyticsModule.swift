import FormaCore

/// FormaAnalytics: pure, deterministic derived metrics (no I/O, no clock, no global state).
///
/// Every public result is a `MetricValue` (or a struct of them) stamped with the spec ID and version
/// of its ``MetricCatalog`` entry, its availability reason, coverage, confidence, window and the
/// inputs used. Unknown values are `nil` with a reason, never 0.
public enum FormaAnalyticsModule {
    public static let name = "FormaAnalytics"
}
