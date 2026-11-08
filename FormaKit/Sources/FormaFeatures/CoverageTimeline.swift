import Foundation
import FormaCore

/// Classifies every part of an analysis window as recorded, pending sync, or not recorded.
///
/// - recorded: a usable sample exists within `sampleSpanMillis` before the instant.
/// - pendingSync: no sample here yet, but the band keeps its own history, and this instant is newer
///   than the newest band-history record Forma has persisted — the data may still be on the band.
/// - notRecorded: no sample, and either the band has no history path or Forma already synced past
///   this instant — the data is permanently unavailable to Forma.
public struct CoverageTimeline: Hashable, Sendable {
    public enum State: String, Hashable, Sendable, Codable {
        case recorded, pendingSync, notRecorded
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
    public static func build(window: TimeRange, sampleTimes: [EpochMillis], sampleSpanMillis: Int64 = 5_000,
                             bandKeepsHistory: Bool, newestPersistedHistory: EpochMillis?) -> CoverageTimeline {
        guard !window.isEmpty else { return CoverageTimeline(window: window, spans: []) }
        let span = max(1, sampleSpanMillis)
        // Merge sample coverage intervals.
        var covered: [TimeRange] = []
        for t in sampleTimes.sorted() {
            let r = TimeRange(start: t, end: t + span)
            guard let clipped = r.intersection(window) else { continue }
            if let last = covered.last, clipped.start <= last.end {
                covered[covered.count - 1] = TimeRange(start: last.start, end: max(last.end, clipped.end))
            } else {
                covered.append(clipped)
            }
        }
        var spans: [Span] = []
        var cursor = window.start
        func appendGap(_ gap: TimeRange) {
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

    /// One-sentence summary for VoiceOver and captions.
    public var accessibilitySummary: String {
        let rec = Int((fraction(of: .recorded) * 100).rounded())
        let pend = Int((fraction(of: .pendingSync) * 100).rounded())
        let none = Int((fraction(of: .notRecorded) * 100).rounded())
        var parts = ["\(rec)% recorded"]
        if pend > 0 { parts.append("\(pend)% waiting to sync from the band") }
        if none > 0 { parts.append("\(none)% not recorded") }
        return parts.joined(separator: ", ")
    }
}
