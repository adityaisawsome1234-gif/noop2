import Foundation
import FormaCore

/// Classifies every part of an analysis window as recorded, awaiting validation, pending sync, or not
/// recorded.
///
/// - recorded: a usable sample exists within `sampleSpanMillis` before the instant.
/// - awaitingValidation: no usable sample, but band-history heart rate stored on this iPhone covers the
///   instant; it is kept out of metrics only until its field passes validation for the band's adapter and
///   firmware (METHODOLOGY §3), so it is neither missing nor waiting on the band.
/// - pendingSync: no sample here yet, but the band keeps its own history, and this instant is newer
///   than the newest band-history record Forma has persisted — the data may still be on the band.
/// - notRecorded: no sample, and either the band has no history path or Forma already synced past
///   this instant — the data is permanently unavailable to Forma.
public struct CoverageTimeline: Hashable, Sendable {
    public enum State: String, Hashable, Sendable, Codable {
        case recorded, awaitingValidation, pendingSync, notRecorded
    }

    public struct Span: Hashable, Sendable {
        public var range: TimeRange
        public var state: State

        public init(range: TimeRange, state: State) {
            self.range = range
            self.state = state
        }
    }

    public var window: TimeRange
    public var spans: [Span]

    public init(window: TimeRange, spans: [Span]) {
        self.window = window
        self.spans = spans
    }

    /// Builds the timeline.
    /// - Parameters:
    ///   - sampleTimes: timestamps of usable samples (any order; duplicates allowed).
    ///   - sampleSpanMillis: how long one sample counts as coverage (default 5 s, matching analytics).
    ///   - bandKeepsHistory: whether the connected band's adapter supports history backfill.
    ///   - newestPersistedHistory: newest band-history record time already persisted (from the sync cursor).
    ///   - awaitingValidationTimes: timestamps of stored band-history heart rate that would be usable but is
    ///     not validated yet (each covers `sampleSpanMillis` like a sample; never overrides "recorded").
    public static func build(window: TimeRange, sampleTimes: [EpochMillis], sampleSpanMillis: Int64 = 5_000,
                             bandKeepsHistory: Bool, newestPersistedHistory: EpochMillis?,
                             awaitingValidationTimes: [EpochMillis] = []) -> CoverageTimeline {
        guard !window.isEmpty else { return CoverageTimeline(window: window, spans: []) }
        let span = max(1, sampleSpanMillis)
        /// Merged `[t, t + span)` intervals, clipped to `window`.
        func coverage(_ times: [EpochMillis]) -> [TimeRange] {
            var covered: [TimeRange] = []
            for t in times.sorted() {
                let (end, overflow) = t.addingReportingOverflow(span)
                let r = TimeRange(start: t, end: overflow ? Int64.max : end)
                guard let clipped = r.intersection(window) else { continue }
                if let last = covered.last, clipped.start <= last.end {
                    covered[covered.count - 1] = TimeRange(start: last.start, end: max(last.end, clipped.end))
                } else {
                    covered.append(clipped)
                }
            }
            return covered
        }
        let covered = coverage(sampleTimes)
        let awaiting = coverage(awaitingValidationTimes)
        var spans: [Span] = []
        var cursor = window.start
        /// A gap with no stored data: pending sync or not recorded.
        func appendMissing(_ gap: TimeRange) {
            guard !gap.isEmpty else { return }
            guard bandKeepsHistory else {
                spans.append(Span(range: gap, state: .notRecorded))
                return
            }
            // Split the gap at the newest persisted history time.
            let boundary = newestPersistedHistory ?? Int64.min
            if gap.end <= boundary {
                spans.append(Span(range: gap, state: .notRecorded))
            } else if gap.start >= boundary {
                spans.append(Span(range: gap, state: .pendingSync))
            } else {
                spans.append(Span(range: TimeRange(start: gap.start, end: boundary), state: .notRecorded))
                spans.append(Span(range: TimeRange(start: boundary, end: gap.end), state: .pendingSync))
            }
        }
        /// A gap without usable samples: stored-but-unvalidated history first, the rest is missing.
        func appendGap(_ gap: TimeRange) {
            guard !gap.isEmpty else { return }
            var position = gap.start
            for a in awaiting where a.end > gap.start && a.start < gap.end {
                guard let part = a.intersection(gap) else { continue }
                if part.start > position { appendMissing(TimeRange(start: position, end: part.start)) }
                spans.append(Span(range: part, state: .awaitingValidation))
                position = max(position, part.end)
            }
            if position < gap.end { appendMissing(TimeRange(start: position, end: gap.end)) }
        }
        for c in covered {
            if c.start > cursor { appendGap(TimeRange(start: cursor, end: c.start)) }
            spans.append(Span(range: c, state: .recorded))
            cursor = c.end
        }
        if cursor < window.end { appendGap(TimeRange(start: cursor, end: window.end)) }
        return CoverageTimeline(window: window, spans: merged(spans))
    }

    private static func merged(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        for s in spans where !s.range.isEmpty {
            if let last = out.last, last.state == s.state, last.range.end == s.range.start {
                out[out.count - 1] = Span(range: TimeRange(start: last.range.start, end: s.range.end), state: s.state)
            } else {
                out.append(s)
            }
        }
        return out
    }

    public func fraction(of state: State) -> Double {
        guard window.durationMillis > 0 else { return 0 }
        let total = spans.filter { $0.state == state }.reduce(Int64(0)) { $0 + $1.range.durationMillis }
        return Double(total) / Double(window.durationMillis)
    }

    /// One-sentence summary for VoiceOver and captions. Shares are rounded down, so "100% recorded"
    /// always means there is no gap at all, and any non-zero share below 1% reads "<1%" instead of
    /// disappearing.
    public var accessibilitySummary: String {
        func share(_ state: State) -> String? {
            let f = fraction(of: state)
            guard f > 0 else { return nil }
            let whole = (f * 100 + 1e-9).rounded(.down)
            return whole < 1 ? "<1%" : "\(Int(whole))%"
        }
        var parts = ["\(share(.recorded) ?? "0%") recorded"]
        if let saved = share(.awaitingValidation) { parts.append("\(saved) saved from the band, awaiting validation") }
        if let pend = share(.pendingSync) { parts.append("\(pend) waiting to sync from the band") }
        if let none = share(.notRecorded) { parts.append("\(none) not recorded") }
        return parts.joined(separator: ", ")
    }
}
