import Foundation
import Testing
import FormaCore
import FormaStore
import FormaAnalytics
@testable import FormaFeatures

/// Timings for `docs/TEST_REPORT.md` §Performance. Off by default (it takes a minute and only prints):
///
///     FORMA_BENCH=1 swift test --filter BenchmarkTests
///
/// Each line reads `BENCH <operation>: <duration>`. The figures depend on the machine and on the build
/// configuration (debug for `swift test`), so they are evidence of scale, not targets.
@Suite(.serialized) struct BenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["FORMA_BENCH"] != nil

    @Test(.enabled(if: BenchmarkTests.enabled)) func timings() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? TimeZone(secondsFromGMT: 0)!
        let end: EpochMillis = 1_770_000_000_000

        func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let start = ContinuousClock.now
            let value = try body()
            print("BENCH \(label): \(ContinuousClock.now - start)")
            return value
        }

        let output = time("generate 35 days of demo data") { DemoDataGenerator(days: 35, end: end, calendar: calendar).generate() }
        let hr = output.batches.reduce(0) { $0 + $1.heartRates.count }
        let rr = output.batches.reduce(0) { $0 + $1.beatIntervals.count }
        let motion = output.batches.reduce(0) { $0 + $1.motion.count }
        print("BENCH records: \(hr) HR, \(rr) beat intervals, \(motion) motion epochs, \(output.sessions.count) sessions")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forma-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FormaStore(path: dir.appendingPathComponent("forma.sqlite").path, timeSource: ManualTimeSource(end))
        try time("ingest into file-backed SQLite") {
            for batch in output.batches { _ = try store.ingest(batch) }
            for session in output.sessions { _ = try store.insertSession(session) }
        }

        let ctx = LoaderContext(store: store, calendar: calendar, now: end, profile: UserProfile(birthYear: 1985),
                                zoneModel: .percentMax, showReadiness: true, deviceID: DemoDataGenerator.deviceID,
                                bandKeepsHistory: false, beatIntervalsSupported: true, motionSupported: true,
                                motionNeedsValidation: false, historyHeartRateValidated: true, allowUnvalidatedMotion: false)
        _ = try time("Today screen, cold cache") { try ScreenLoader.today(ctx) }
        _ = try time("Today screen, warm cache") { try ScreenLoader.today(ctx) }
        _ = try time("Sleep screen (14 nights)") { try ScreenLoader.sleep(ctx, nights: 14) }
        _ = try time("Trends, 90 days, resting HR") { try ScreenLoader.trends(ctx, metric: .restingHR, period: .days90) }
        _ = try time("Trends, 90 days, load") { try ScreenLoader.trends(ctx, metric: .load, period: .days90) }

        let backup = dir.appendingPathComponent("forma-backup.jsonl")
        _ = try time("full backup export") { try store.exportBackup(to: backup) }
        let restored = try FormaStore(path: dir.appendingPathComponent("restored.sqlite").path, timeSource: ManualTimeSource(end))
        _ = try time("full backup import into an empty store") { try restored.importBackup(from: backup) }
        _ = try time("re-import of the same backup (all duplicates)") { try restored.importBackup(from: backup) }
    }
}
