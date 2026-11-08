import Foundation
import Testing
import FormaCore
@testable import FormaFeatures

@Suite struct CoverageTimelineTests {
    let window = TimeRange(start: 0, end: 100_000)

    @Test func recordedSpansMergeAndGapsAreClassifiedByHistoryBoundary() {
        // Samples every 5 s for the first 30 s, then nothing.
        let samples: [EpochMillis] = stride(from: 0, to: 30_000, by: 5_000).map { $0 }
        let t = CoverageTimeline.build(window: window, sampleTimes: samples, bandKeepsHistory: true, newestPersistedHistory: 60_000)
        #expect(t.spans.map(\.state) == [.recorded, .notRecorded, .pendingSync])
        #expect(t.spans[0].range == TimeRange(start: 0, end: 30_000))
        #expect(t.spans[1].range == TimeRange(start: 30_000, end: 60_000))
        #expect(t.spans[2].range == TimeRange(start: 60_000, end: 100_000))
        #expect(abs(t.fraction(of: .recorded) - 0.3) < 1e-9)
        #expect(abs(t.fraction(of: .pendingSync) - 0.4) < 1e-9)
    }

    @Test func withoutHistoryEveryGapIsNotRecorded() {
        let t = CoverageTimeline.build(window: window, sampleTimes: [50_000], bandKeepsHistory: false, newestPersistedHistory: nil)
        #expect(t.spans.map(\.state) == [.notRecorded, .recorded, .notRecorded])
        #expect(t.fraction(of: .pendingSync) == 0)
    }

    @Test func historyNeverSyncedMeansWholeGapIsPending() {
        let t = CoverageTimeline.build(window: window, sampleTimes: [], bandKeepsHistory: true, newestPersistedHistory: nil)
        #expect(t.spans == [CoverageTimeline.Span(range: window, state: .pendingSync)])
        #expect(t.accessibilitySummary.contains("100% waiting to sync"))
    }

    @Test func samplesOutsideWindowAndDuplicatesAreHandled() {
        let t = CoverageTimeline.build(window: window, sampleTimes: [-4_000, 10_000, 10_000, 99_000, 200_000],
                                       bandKeepsHistory: false, newestPersistedHistory: nil)
        // -4000 covers [0,1000); 10_000 covers [10_000,15_000); 99_000 covers [99_000,100_000).
        #expect(abs(t.fraction(of: .recorded) - 0.07) < 1e-9)
        let total = t.spans.reduce(Int64(0)) { $0 + $1.range.durationMillis }
        #expect(total == window.durationMillis)
    }
}

@Suite struct ConnectionSummaryTests {
    @Test func statusSeparatesLinkSampleAndSync() {
        var s = ConnectionSummary(deviceName: "Band", family: .whoop5, link: .connected, sync: .idle,
                                  lastDeviceSample: 1_000, lastCompletedSync: nil, liveStreaming: true)
        #expect(s.shortStatus == "Live")
        let lines = s.detailLines(now: 1_000 + 120_000)
        #expect(lines.count == 3)
        #expect(lines[1] == "Last device sample 2 min ago")
        #expect(lines[2] == "History not synced yet")
        s.isDemo = true
        #expect(s.shortStatus == "Demo data")
        s.isDemo = false
        s.link = .bluetoothUnavailable(.poweredOff)
        #expect(s.severity == .problem)
    }
}

@Suite struct DemoDataGeneratorTests {
    @Test func demoIsDeterministicLabelledAndSeparated() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let end: EpochMillis = 1_762_560_000_000 // 2025-11-08T00:00:00Z
        let a = DemoDataGenerator(days: 5, end: end, calendar: cal).generate()
        let b = DemoDataGenerator(days: 5, end: end, calendar: cal).generate()
        #expect(a.batches.count == 5)
        #expect(a.batches.flatMap(\.heartRates) == b.batches.flatMap(\.heartRates))
        #expect(a.batches.allSatisfy { $0.provenance.source == .demo })
        #expect(a.batches.flatMap(\.heartRates).allSatisfy { $0.source == .demo && $0.deviceID == DemoDataGenerator.deviceID })
        #expect(a.batches.flatMap(\.beatIntervals).allSatisfy { $0.source == .demo && BeatInterval.plausibleMillis.contains($0.intervalMillis) })
        #expect(a.batches.flatMap(\.heartRates).allSatisfy { $0.timestamp < end })
        // Timestamps are unique per source so the store's dedup keys never collapse demo samples.
        let ts = a.batches.flatMap(\.heartRates).map(\.timestamp)
        #expect(Set(ts).count == ts.count)
        #expect(a.sessions.contains { $0.kind == .sleep && $0.origin == .detectedCandidate })
    }
}
