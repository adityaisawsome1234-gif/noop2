// Adversarial tests for FormaFeatures, written from the documented intent (PRD, ARCHITECTURE,
// PRIVACY_AND_DATA, KNOWN_LIMITATIONS and the public doc comments) and the project's non-negotiables:
// never fabricate values, unvalidated fields never reach metrics until validated, history is opt-in and
// acknowledged only after persistence, demo data never mixes with live data, own (selected) band only,
// "pending sync" vs "not recorded" coverage, and no analytics during a background wake.
//
// Tests whose display name starts with "[BUG]" are expected to FAIL against the current implementation:
// each one documents an implementation defect (the comment above it cites the documented intent it
// checks). Every other test is expected to pass and guards an invariant.

import Foundation
import Testing
import FormaCore
import FormaProtocol
import FormaSync
import FormaStore
import FormaAnalytics
@testable import FormaFeatures

// MARK: - Fixtures

enum Adv {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static let london: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    /// 2025-11-08 14:00:00 UTC.
    static let now: EpochMillis = 1_762_610_400_000
    static let second: Int64 = 1_000
    static let minute: Int64 = 60_000
    static let hour: Int64 = 3_600_000
    static let day: Int64 = 86_400_000
    static let everything = TimeRange(start: 0, end: Int64.max / 4)

    static var today: LocalDay { LocalDay(now, calendar: utc) }
    static var yesterday: LocalDay { today.adding(days: -1, calendar: utc) }

    static func store(now: EpochMillis = now) throws -> FormaStore {
        try FormaStore(path: nil, timeSource: ManualTimeSource(now))
    }

    static func provenance(_ device: String, _ source: MeasurementSource, firmware: String? = nil,
                           adapter: String = "forma.test") -> Provenance {
        Provenance(deviceID: device, adapterID: adapter, parserVersion: "adv-1", firmwareVersion: firmware, source: source,
                   syncRunID: nil, createdAt: now)
    }

    static func heartRates(_ device: String, from: EpochMillis, to: EpochMillis, every step: Int64, bpm: Int,
                           source: MeasurementSource = .standardHeartRateService, quality: QualityFlags = []) -> [HeartRateSample] {
        var out: [HeartRateSample] = []
        var t = from
        while t < to {
            out.append(HeartRateSample(deviceID: device, timestamp: t, bpm: bpm, source: source, receivedAt: t, quality: quality))
            t += step
        }
        return out
    }

    @discardableResult
    static func ingestHR(_ store: FormaStore, _ device: String, from: EpochMillis, to: EpochMillis, every: Int64, bpm: Int,
                         source: MeasurementSource = .standardHeartRateService, quality: QualityFlags? = nil,
                         firmware: String? = nil, adapter: String = "forma.test") throws -> IngestResult {
        let flags = quality ?? (source == .standardHeartRateService ? [.phoneReceiveTime] : [])
        let samples = heartRates(device, from: from, to: to, every: every, bpm: bpm, source: source, quality: flags)
        return try store.ingest(IngestBatch(provenance: provenance(device, source, firmware: firmware, adapter: adapter),
                                            heartRates: samples))
    }

    static func context(_ store: FormaStore, now: EpochMillis = now, calendar: Calendar = utc,
                        profile: UserProfile = UserProfile(), zoneModel: HeartRateZoneModel = .percentMax,
                        showReadiness: Bool = false, deviceID: String? = nil, bandKeepsHistory: Bool = false,
                        beatIntervalsSupported: Bool = true, motionSupported: Bool = false,
                        motionNeedsValidation: Bool = false, historyHeartRateValidated: Bool = false,
                        allowUnvalidatedMotion: Bool = false) -> LoaderContext {
        LoaderContext(store: store, calendar: calendar, now: now, profile: profile, zoneModel: zoneModel,
                      showReadiness: showReadiness, deviceID: deviceID, bandKeepsHistory: bandKeepsHistory,
                      beatIntervalsSupported: beatIntervalsSupported, motionSupported: motionSupported,
                      motionNeedsValidation: motionNeedsValidation, historyHeartRateValidated: historyHeartRateValidated,
                      allowUnvalidatedMotion: allowUnvalidatedMotion)
    }

    static func sleepSession(_ range: TimeRange, origin: SessionOrigin = .manual, device: String? = nil) -> Session {
        Session(kind: .sleep, range: range, origin: origin, deviceID: device, createdAt: now, updatedAt: now)
    }

    /// 60-s motion epochs over the noon-to-noon window of the night ending on `day`: quiet 23:00–07:00, active otherwise.
    static func nightMotion(_ device: String, nightEndingOn day: LocalDay, calendar: Calendar = utc, quality: QualityFlags,
                            source: MeasurementSource = .deviceHistory) -> [MotionEpoch] {
        let dayStart: EpochMillis = day.range(calendar: calendar).start
        let quietStart: EpochMillis = dayStart - hour
        let quietEnd: EpochMillis = dayStart + 7 * hour
        var out: [MotionEpoch] = []
        var t: EpochMillis = dayStart - 12 * hour
        while t < dayStart + 12 * hour {
            let activity: Double = (t >= quietStart && t < quietEnd) ? 0.002 : 0.2
            out.append(MotionEpoch(deviceID: device, timestamp: t, epochMillis: minute, activity: activity,
                                   sampleCount: 60, source: source, quality: quality))
            t += minute
        }
        return out
    }

    static func state(_ timeline: CoverageTimeline, at t: EpochMillis) -> CoverageTimeline.State? {
        timeline.spans.first { $0.range.contains(t) }?.state
    }

    /// Standard Heart Rate Measurement notifications (UINT8 bpm 60…64, contact detected, one 1000 ms RR each).
    static func standardHeartRateLink(id: String, start: EpochMillis, count: Int) -> ReplayLink {
        let entries = (0..<count).map { i in
            CaptureEntry(t: start + Int64(i) * 1_000, dir: .rx, c: "2A37", d: "16" + String(format: "%02x", 60 + i % 5) + "0004")
        }
        return ReplayLink(peripheralID: id, entries: entries, services: [UUIDs.heartRateService: [UUIDs.heartRateMeasurement]])
    }

    static let heartRateServices = [GATTServiceSummary(uuid: UUIDs.heartRateService, name: "Heart Rate", characteristics: [])]

    /// Command id of a WHOOP 5.0 command frame (header 8 bytes, payload = [type 35, sequence, id, …]).
    static func whoopCommandID(_ bytes: [UInt8]) -> UInt8? {
        guard bytes.count > 10, bytes[0] == 0xAA, bytes[8] == Whoop5Adapter.PacketType.command.rawValue else { return nil }
        return bytes[10]
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forma-adv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Deterministic generator for property-style tests.
struct AdvRNG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int64>) -> Int64 {
        range.lowerBound + Int64(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }

    mutating func bool() -> Bool { next() & 1 == 1 }
}

final class AdvCentral: BandCentral, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (CentralEvent) -> Void)?
    private var log: [String] = []
    private var saved: String?

    init(saved: String? = nil) { self.saved = saved }

    var calls: [String] { lock.withLock { log } }
    private func record(_ call: String) { lock.withLock { log.append(call) } }

    func connectSelected(profile: GATTProfile) { record("connect") }
    func disconnect() { record("disconnect") }
    func select(peripheralID: String, profile: GATTProfile) {
        lock.withLock { log.append("select:\(peripheralID)"); saved = peripheralID }
    }
    func forgetSelected() { lock.withLock { log.append("forget"); saved = nil } }
    func startScan(includeUnfiltered: Bool) { record("scan") }
    func stopScan() { record("stopScan") }
    var savedPeripheralID: String? { lock.withLock { saved } }
    func setEventHandler(_ handler: @escaping @Sendable (CentralEvent) -> Void) { lock.withLock { self.handler = handler } }
    func fire(_ event: CentralEvent) { lock.withLock { handler }?(event) }
}

final class AdvPlatform: PlatformServices, @unchecked Sendable {
    private let lock = NSLock()
    private var prefs: [String: String]
    private var included: Bool
    private var backupLog: [Bool] = []
    private var protectedLog: [String] = []
    private var protectedNameLog: [String] = []
    let directory: URL?
    let databaseLocationFails: Bool

    init(directory: URL? = nil, prefs: [String: String] = [:], backupsIncluded: Bool = false, databaseLocationFails: Bool = false) {
        self.directory = directory
        self.prefs = prefs
        self.included = backupsIncluded
        self.databaseLocationFails = databaseLocationFails
    }

    var backupCalls: [Bool] { lock.withLock { backupLog } }
    var protectedPaths: [String] { lock.withLock { protectedLog } }
    var protectedNames: [String] { lock.withLock { protectedNameLog } }

    func databasePath(demo: Bool) throws -> String? {
        if databaseLocationFails { throw CocoaError(.fileWriteNoPermission) }
        return directory.map { $0.appendingPathComponent(demo ? "forma-demo.sqlite" : "forma.sqlite").path }
    }
    func protectDatabase(at path: String) { lock.withLock { protectedLog.append(path) } }
    func setIncludedInBackups(_ included: Bool) throws { lock.withLock { backupLog.append(included); self.included = included } }
    func isIncludedInBackups() -> Bool { lock.withLock { included } }
    func makeStagingDirectory() throws -> URL { Adv.temporaryDirectory() }
    func archiveDirectory(_ url: URL) throws -> Data { Data() }
    func runProtected<T: Sendable>(_ name: String, _ body: () throws -> T) rethrows -> T {
        lock.withLock { protectedNameLog.append(name) }
        return try body()
    }
    var appVersion: String { "adversarial" }
    var osVersion: String { "linux" }
    func preference(_ key: String) -> String? { lock.withLock { prefs[key] } }
    func setPreference(_ value: String?, forKey key: String) { lock.withLock { prefs[key] = value } }
}

// MARK: - Coverage timeline

@Suite("Adversarial: coverage timeline")
struct AdversarialCoverageTimelineTests {
    static func tilingProblems(_ t: CoverageTimeline, window: TimeRange) -> [String] {
        var problems: [String] = []
        if window.isEmpty {
            if !t.spans.isEmpty { problems.append("empty window has spans") }
            return problems
        }
        if t.spans.first?.range.start != window.start { problems.append("does not start at the window start") }
        if t.spans.last?.range.end != window.end { problems.append("does not end at the window end") }
        for s in t.spans where s.range.isEmpty { problems.append("empty span \(s.range)") }
        for (a, b) in zip(t.spans, t.spans.dropFirst()) {
            if a.range.end != b.range.start { problems.append("gap/overlap between \(a.range) and \(b.range)") }
            if a.state == b.state { problems.append("unmerged adjacent \(a.state) spans") }
        }
        let sum = t.fraction(of: .recorded) + t.fraction(of: .pendingSync) + t.fraction(of: .notRecorded)
        if abs(sum - 1) > 1e-9 { problems.append("fractions sum to \(sum)") }
        return problems
    }

    /// Doc comment of `CoverageTimeline`: recorded = a usable sample within `sampleSpanMillis` before the
    /// instant; otherwise pendingSync when the band keeps history and the instant is newer than the newest
    /// persisted band-history record; otherwise notRecorded.
    @Test func everyInstantMatchesTheDocumentedDefinition() {
        var rng = AdvRNG(state: 0xF0_4A)
        var failures: [String] = []
        for index in 0..<200 {
            let start = rng.int(-50_000...50_000)
            let window = TimeRange(start: start, end: start + rng.int(1...30_000))
            let span = rng.int(1...7_000)
            let samples = (0..<Int(rng.int(0...12))).map { _ in rng.int((window.start - 10_000)...(window.end + 10_000)) }
            let keeps = rng.bool()
            let boundary: EpochMillis? = rng.bool() ? nil : rng.int((window.start - 5_000)...(window.end + 5_000))
            let timeline = CoverageTimeline.build(window: window, sampleTimes: samples, sampleSpanMillis: span,
                                                  bandKeepsHistory: keeps, newestPersistedHistory: boundary)
            failures += Self.tilingProblems(timeline, window: window).map { "case \(index): \($0)" }
            var x = window.start
            while x < window.end, failures.count < 20 {
                defer { x += 41 }
                if let b = boundary, x == b { continue } // the boundary instant itself is not specified
                let expected: CoverageTimeline.State
                if samples.contains(where: { $0 <= x && x < $0 + span }) {
                    expected = .recorded
                } else if !keeps {
                    expected = .notRecorded
                } else if let b = boundary {
                    expected = x > b ? .pendingSync : .notRecorded
                } else {
                    expected = .pendingSync
                }
                let actual = Adv.state(timeline, at: x)
                if actual != expected {
                    failures.append("case \(index) at \(x): \(String(describing: actual)) instead of \(expected) (window \(window), span \(span), keeps \(keeps), boundary \(String(describing: boundary)), samples \(samples))")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5).joined(separator: "\n"))")
    }

    @Test func historyBoundaryOutsideTheWindow() {
        let window = TimeRange(start: 100_000, end: 200_000)
        let before = CoverageTimeline.build(window: window, sampleTimes: [150_000], bandKeepsHistory: true,
                                            newestPersistedHistory: 10_000)
        #expect(before.fraction(of: .notRecorded) == 0, "a sync that ended before the window cannot have passed any of it")
        #expect(abs(before.fraction(of: .pendingSync) - 0.95) < 1e-9)
        let after = CoverageTimeline.build(window: window, sampleTimes: [150_000], bandKeepsHistory: true,
                                           newestPersistedHistory: 500_000)
        #expect(after.fraction(of: .pendingSync) == 0, "a sync past the window leaves nothing pending")
        #expect(abs(after.fraction(of: .notRecorded) - 0.95) < 1e-9)
        #expect(after.accessibilitySummary == "5% recorded, 95% not recorded")
    }

    @Test func nonPositiveSampleSpanAndEmptyWindowsStayWellFormed() {
        let window = TimeRange(start: 0, end: 10_000)
        for span: Int64 in [0, -1, -5_000, .min] {
            let t = CoverageTimeline.build(window: window, sampleTimes: [0, 5_000, 9_999], sampleSpanMillis: span,
                                           bandKeepsHistory: true, newestPersistedHistory: 4_000)
            #expect(Self.tilingProblems(t, window: window).isEmpty, "span \(span)")
        }
        let empty = CoverageTimeline.build(window: TimeRange(start: 5, end: 5), sampleTimes: [5], bandKeepsHistory: true,
                                           newestPersistedHistory: nil)
        #expect(empty.spans.isEmpty)
        #expect(empty.fraction(of: .recorded) == 0 && empty.fraction(of: .pendingSync) == 0)
    }
}

// MARK: - Connection summary and relative time

@Suite("Adversarial: connection summary")
struct AdversarialConnectionSummaryTests {
    static let links: [LinkState] = [
        .noDeviceSelected, .bluetoothUnavailable(.poweredOff), .bluetoothUnavailable(.unauthorized),
        .bluetoothUnavailable(.unsupported), .bluetoothUnavailable(.resetting), .bluetoothUnavailable(.unknown),
        .searching, .connecting, .connected, .disconnected(since: nil), .disconnected(since: Adv.now - Adv.hour),
    ]
    static let syncs: [SyncActivity] = [
        .idle, .syncingHistory(recordsReceived: 12, newestRecord: nil), .failed(message: "Saving failed", at: Adv.now - Adv.minute),
    ]

    /// PRD §7: demo data carries a persistent "Demo data" label; ConnectionSummary: short status ≤ 3 words,
    /// color is never the only signal; only a connected band can be "Live".
    @Test func shortStatusIsShortAndTheDemoLabelIsPersistent() {
        for link in Self.links {
            for sync in Self.syncs {
                for live in [false, true] {
                    for demo in [false, true] {
                        let s = ConnectionSummary(deviceName: "Band", family: .whoop5, link: link, sync: sync,
                                                  lastDeviceSample: Adv.now, lastCompletedSync: nil, liveStreaming: live, isDemo: demo)
                        let words = s.shortStatus.split(separator: " ")
                        #expect(!words.isEmpty && words.count <= 3, "\(s.shortStatus)")
                        if demo {
                            #expect(s.shortStatus == "Demo data")
                            #expect(s.severity == .attention)
                        } else {
                            #expect(s.shortStatus != "Demo data")
                            if link != .connected { #expect(s.shortStatus != "Live" && s.shortStatus != "Syncing", "\(link)") }
                            if case .bluetoothUnavailable = link { #expect(s.severity == .problem) }
                        }
                        #expect(s.detailLines(now: Adv.now, formatter: RelativeTimeFormatter(calendar: Adv.utc)).count == 3)
                    }
                }
            }
        }
    }

    /// ConnectionSummary: link, last device sample and last sync are separate facts — a connected band can
    /// have stale data and a disconnected band can have fresh history.
    @Test func detailLinesKeepLinkSampleAndSyncSeparate() {
        let f = RelativeTimeFormatter(calendar: Adv.utc)
        let stale = ConnectionSummary(deviceName: "Band", link: .connected, lastDeviceSample: Adv.now - 2 * Adv.day)
        let a = stale.detailLines(now: Adv.now, formatter: f)
        #expect(a[0] == "Connected to Band")
        #expect(a[1] == "Last device sample 2025-11-06 14:00", "\(a[1])")
        #expect(a[2] == "History not synced yet")

        let fresh = ConnectionSummary(deviceName: "Band", link: .disconnected(since: Adv.now - Adv.hour),
                                      lastDeviceSample: Adv.now - 30_000, lastCompletedSync: Adv.now - 60_000)
        let b = fresh.detailLines(now: Adv.now, formatter: f)
        #expect(b[0] == "Disconnected 1 h ago")
        #expect(b[1] == "Last device sample just now")
        #expect(b[2] == "Last complete sync 1 min ago")

        let nothing = ConnectionSummary(deviceName: nil, link: .searching)
        #expect(nothing.detailLines(now: Adv.now, formatter: f) == ["Waiting for band to come into range", "No samples recorded yet", "History not synced yet"])
    }

    @Test func relativeTimeBoundaries() {
        let f = RelativeTimeFormatter(calendar: Adv.utc)
        let n = Adv.now
        #expect(f.string(from: n, now: n) == "just now")
        #expect(f.string(from: n - 59_999, now: n) == "just now")
        #expect(f.string(from: n - 60_000, now: n) == "1 min ago")
        #expect(f.string(from: n - 3_599_999, now: n) == "59 min ago")
        #expect(f.string(from: n - Adv.hour, now: n) == "1 h ago")
        #expect(f.string(from: n - (5 * Adv.hour + 59 * Adv.minute), now: n) == "5 h 59 min ago")
        #expect(f.string(from: n - 6 * Adv.hour, now: n) == "today 08:00")
        #expect(f.string(from: n - 15 * Adv.hour, now: n) == "yesterday 23:00")
        #expect(f.string(from: n - 3 * Adv.day, now: n) == "2025-11-05 14:00")
    }
}

// MARK: - Display formatting

@Suite("Adversarial: display formatting")
struct AdversarialDisplayFormatTests {
    /// DisplayFormat: fixed-point with `digits` decimals clamped to 0…3, "." separator, true minus sign,
    /// never a negative zero, and the text must round-trip to the value within half a unit of the last digit.
    @Test func fixedPointShapeAndRoundTrip() {
        var rng = AdvRNG(state: 0xD15)
        var failures: [String] = []
        for _ in 0..<3_000 {
            let magnitude = pow(10.0, Double(rng.int(-4...9)))
            let v = Double(rng.int(-1_000_000...1_000_000)) / 1_000_000 * magnitude
            for digits in -2...6 {
                let text = DisplayFormat.number(v, digits: digits)
                let d = max(0, min(3, digits))
                let negative = text.hasPrefix("\u{2212}")
                let body = negative ? String(text.dropFirst()) : text
                let parts = body.split(separator: ".", omittingEmptySubsequences: false)
                let shapeOK = text.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789.\u{2212}").contains($0) }
                    && (d == 0 ? parts.count == 1 : (parts.count == 2 && parts[1].count == d))
                    && parts.allSatisfy { !$0.isEmpty }
                let parsed = Double(text.replacingOccurrences(of: "\u{2212}", with: "-")) ?? .nan
                let tolerance = 0.5 * pow(10, -Double(d)) + 1e-9 * max(1, abs(v))
                if !shapeOK || !(abs(parsed - v) <= tolerance) || (negative && parsed == 0) {
                    failures.append("number(\(v), digits: \(digits)) = \"\(text)\"")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    @Test func signedZeroAndNonFinite() {
        #expect(DisplayFormat.signed(0.04, digits: 1) == "0.0")
        #expect(DisplayFormat.signed(-0.04, digits: 1) == "0.0")
        #expect(DisplayFormat.signed(0.05, digits: 1) == "+0.1")
        #expect(DisplayFormat.signed(-0.05, digits: 1) == "\u{2212}0.1")
        #expect(DisplayFormat.number(-0.0, digits: 2) == "0.00")
        #expect(DisplayFormat.number(.infinity, digits: 1) == "—")
        #expect(DisplayFormat.signed(-.infinity, digits: 1) == "—")
        #expect(DisplayFormat.percent(.nan) == "—")
        let unavailable = MetricValue<Double>.unavailable(.insufficientData(detail: "x"), specID: "s", specVersion: 1)
        #expect(DisplayFormat.metric(unavailable, digits: 0) == nil)
    }

    @Test func durationsAndTimersAreNeverNegative() {
        #expect(DisplayFormat.duration(millis: -5) == "0 min")
        #expect(DisplayFormat.duration(millis: 59 * Adv.minute + 31_000) == "1 h")
        #expect(DisplayFormat.duration(millis: 25 * Adv.hour) == "25 h")
        #expect(DisplayFormat.timer(millis: -5_000) == "0:00")
        #expect(DisplayFormat.timer(millis: 59_999) == "0:59")
        #expect(DisplayFormat.timer(millis: Adv.hour) == "1:00:00")
    }

    @Test func clockUsesTheCalendarsTimeZone() {
        var kolkata = Calendar(identifier: .gregorian)
        kolkata.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        #expect(DisplayFormat.clock(0, calendar: kolkata) == "05:30")
        // 2025-07-01 12:00 UTC is 13:00 in London (BST); 2025-11-08 14:00 UTC is 14:00 (GMT).
        #expect(DisplayFormat.clock(1_751_371_200_000, calendar: Adv.london) == "13:00")
        #expect(DisplayFormat.clock(Adv.now, calendar: Adv.london) == "14:00")
        #expect(DisplayFormat.dayLabel(LocalDay(year: 2025, month: 11, day: 8), calendar: Adv.london) == "Sat 8 Nov")
    }

    // [BUG][low] DisplayFormat.number: "Fixed-point number with `digits` decimals (0…3). Non-finite input
    // yields '—'." A finite value larger than Int64 traps (`Int64(rounded)`) instead of being formatted.
    // Not reachable from today's metric ranges, but the formatter is the single path for every number on screen.
    @Test("[BUG] Huge finite numbers are formatted instead of crashing the app")
    func hugeFiniteNumbersAreFormattedNotTrapped() async {
        await #expect(processExitsWith: .success) {
            _ = DisplayFormat.number(1e20, digits: 0)
            _ = DisplayFormat.number(-9.5e18, digits: 2)
            _ = DisplayFormat.percent(1e18)
        }
    }
}

// MARK: - Field validation

@Suite("Adversarial: field validation")
struct AdversarialFieldValidationTests {
    /// Two readings per minute for `count` minutes.
    static func minutes(_ count: Int, from start: EpochMillis = Adv.now - Adv.hour, bpm: Int, source: MeasurementSource,
                        quality: QualityFlags = [], device: String = "band") -> [HeartRateSample] {
        (0..<count).flatMap { m -> [HeartRateSample] in
            [Int64(10_000), Int64(40_000)].map { offset in
                let t: EpochMillis = start + Int64(m) * Adv.minute + offset
                return HeartRateSample(deviceID: device, timestamp: t, bpm: bpm, source: source, receivedAt: t, quality: quality)
            }
        }
    }

    static func agreement(_ history: [HeartRateSample], _ live: [HeartRateSample]) -> FieldValidationResult {
        FieldValidator.historyHeartRateAgreement(history: history, live: live)
    }

    /// KNOWN_LIMITATIONS: history heart rate stays out of metrics until it agrees with live heart rate for at
    /// least 10 minutes; FieldValidator: ≥ 10 overlapping minutes and median |difference| ≤ 3 bpm.
    @Test func needsTenOverlappingMinutes() {
        let h9 = Self.minutes(9, bpm: 62, source: .deviceHistory, quality: [.unvalidatedField])
        let l9 = Self.minutes(9, bpm: 62, source: .standardHeartRateService, quality: [.phoneReceiveTime])
        #expect(Self.agreement(h9, l9).status == .unverified)
        let h10 = Self.minutes(10, bpm: 62, source: .deviceHistory, quality: [.unvalidatedField])
        let l10 = Self.minutes(10, bpm: 62, source: .standardHeartRateService, quality: [.phoneReceiveTime])
        let r = Self.agreement(h10, l10)
        #expect(r.status == .passed)
        #expect(r.overlappingMinutes == 10)
        // Thirty minutes of each that never overlap prove nothing.
        let apart = Self.agreement(Self.minutes(30, from: Adv.now - 2 * Adv.hour, bpm: 62, source: .deviceHistory),
                                   Self.minutes(30, from: Adv.now - Adv.hour, bpm: 62, source: .standardHeartRateService))
        #expect(apart.status == .unverified && apart.overlappingMinutes == 0)
    }

    @Test func disagreementFailsAndTheThresholdIsInclusive() {
        let live = Self.minutes(12, bpm: 60, source: .standardHeartRateService)
        let bogus = Self.agreement(Self.minutes(12, bpm: 151, source: .deviceHistory), live)
        #expect(bogus.status == .failed)
        #expect(bogus.medianAbsoluteDifference == 91)
        #expect(Self.agreement(Self.minutes(12, bpm: 63, source: .deviceHistory), live).status == .passed)
        #expect(Self.agreement(Self.minutes(12, bpm: 64, source: .deviceHistory), live).status == .failed)
    }

    /// FieldValidator: the reference must be an independent, documented source (Bluetooth SIG Heart Rate
    /// Service). The vendor's own live stream, backups and demo data are not independent evidence.
    @Test func onlyTheStandardHeartRateServiceIsIndependentEvidence() {
        let history = Self.minutes(15, bpm: 62, source: .deviceHistory, quality: [.unvalidatedField])
        for source in [MeasurementSource.liveVendorStream, .backupImport, .demo, .deviceHistory] {
            let r = Self.agreement(history, Self.minutes(15, bpm: 62, source: source))
            #expect(r.status == .unverified, "\(source) must not validate band history")
        }
        // Something that is not band history is not what is being validated.
        let notHistory = Self.agreement(Self.minutes(15, bpm: 62, source: .liveVendorStream, quality: [.unvalidatedField]),
                                        Self.minutes(15, bpm: 62, source: .standardHeartRateService))
        #expect(notHistory.status == .unverified)
    }

    @Test func readingsWithoutContactOrTrustworthyTimeAreNotEvidence() {
        let live = Self.minutes(15, bpm: 62, source: .standardHeartRateService)
        for flag in [QualityFlags.clockUnmapped, .noSensorContact] {
            let r = Self.agreement(Self.minutes(15, bpm: 62, source: .deviceHistory, quality: [.unvalidatedField, flag]), live)
            #expect(r.status == .unverified, "history flagged \(flag.rawValue)")
            let r2 = Self.agreement(Self.minutes(15, bpm: 62, source: .deviceHistory, quality: [.unvalidatedField]),
                                    Self.minutes(15, bpm: 62, source: .standardHeartRateService, quality: flag))
            #expect(r2.status == .unverified, "live flagged \(flag.rawValue)")
        }
    }

    // [BUG][low, latent] A reading the device itself marked invalid is unusable everywhere else in Forma
    // (HeartRateSeries.excludedFlags, HRV, sleep), yet FieldValidator counts it as evidence that the history
    // field is heart rate. Today no decoder sets the flag, so this is latent.
    @Test("[BUG] Readings the device marked invalid are not evidence for validation")
    func readingsTheDeviceMarkedInvalidAreNotEvidence() {
        let invalidHistory = Self.minutes(15, bpm: 62, source: .deviceHistory, quality: [.unvalidatedField, .deviceMarkedInvalid])
        let live = Self.minutes(15, bpm: 62, source: .standardHeartRateService)
        #expect(Self.agreement(invalidHistory, live).status != .passed)
        let invalidLive = Self.minutes(15, bpm: 62, source: .standardHeartRateService, quality: [.deviceMarkedInvalid])
        #expect(Self.agreement(Self.minutes(15, bpm: 62, source: .deviceHistory), invalidLive).status != .passed)
    }

    @Test func validationKeyChangesWithAdapterAndFirmware() {
        let a = FieldValidator.historyHeartRateKey(adapterID: "forma.whoop5", firmware: "1.0")
        #expect(a != FieldValidator.historyHeartRateKey(adapterID: "forma.whoop5", firmware: "1.1"))
        #expect(a != FieldValidator.historyHeartRateKey(adapterID: "forma.standard-hr", firmware: "1.0"))
        #expect(a != FieldValidator.historyHeartRateKey(adapterID: "forma.whoop5", firmware: nil))
    }
}

// MARK: - Screen loader

@Suite("Adversarial: screen loader")
struct AdversarialScreenLoaderTests {
    // [BUG] ARCHITECTURE §7: "The coverage timeline marks such periods 'pending sync' until then, and 'not
    // recorded' once a sync has passed them." ScreenLoader.sleep builds each night's timeline with
    // `newestPersistedHistory: nil`, so every gap in every past night stays "waiting to sync from the band"
    // forever, while Today's timeline (which reads the sync cursor) says the same hours were not recorded.
    @Test("[BUG] A night's gaps are 'not recorded' once a history sync has passed them")
    func pastNightsAreNotRecordedOnceASyncHasPassedThem() throws {
        let store = try Adv.store()
        let night = TimeRange(start: Adv.now - 12 * Adv.hour, end: Adv.now - 4 * Adv.hour) // 02:00–10:00
        try Adv.ingestHR(store, "band", from: night.start, to: night.start + 4 * Adv.hour, every: 5_000, bpm: 55)
        try store.insertSession(Adv.sleepSession(night, device: "band"))
        let synced = Adv.now - Adv.hour
        _ = try store.ingest(IngestBatch(provenance: Adv.provenance("band", .deviceHistory, adapter: "forma.whoop5"),
                                         cursor: SyncCursor(deviceID: "band", adapterID: "forma.whoop5", opaque: nil,
                                                            newestPersistedRecordTime: synced, lastCompleteSyncAt: synced,
                                                            updatedAt: synced)))
        let ctx = Adv.context(store, deviceID: "band", bandKeepsHistory: true)

        // Control: the 24-hour timeline on Today already treats these hours as not recorded.
        let today = try ScreenLoader.today(ctx)
        #expect(Adv.state(today.coverage24h, at: night.start + 6 * Adv.hour) == .notRecorded)

        let sleep = try ScreenLoader.sleep(ctx)
        let n = try #require(sleep.nights.first { $0.session.range == night })
        #expect(n.coverage.fraction(of: .pendingSync) == 0,
                "history was synced up to \(synced), past the whole night, yet the night says: \(n.coverage.accessibilitySummary)")
        #expect(abs(n.coverage.fraction(of: .notRecorded) - 0.5) < 0.01)
    }

    // [BUG] LiveWorkoutState: "True when no heart-rate sample arrived recently — the UI must not present a
    // stale value as live" (PRD §6.1: "When nothing is arriving, the screen says so instead of showing a stale
    // number as live"). currentHR is withheld when stale, but currentZone is still derived from the stale sample.
    @Test("[BUG] A stale live signal shows neither a heart rate nor a zone")
    func staleLiveSignalShowsNoZone() throws {
        let store = try Adv.store()
        let ctx = Adv.context(store, profile: UserProfile(maxHeartRateOverride: 190))
        let start = Adv.now - 10 * Adv.minute
        let fresh = Adv.heartRates("band", from: start, to: Adv.now - 2_000, every: 1_000, bpm: 150)
        let ok = ScreenLoader.liveWorkout(ctx, start: start, recentSamples: fresh, sourceLabel: "standard heart-rate service")
        #expect(!ok.signalStale && ok.currentHR == 150 && ok.currentZone == 3, "control: a live signal shows HR and zone")

        let stale = Adv.heartRates("band", from: start, to: Adv.now - 30_000, every: 1_000, bpm: 150)
        let live = ScreenLoader.liveWorkout(ctx, start: start, recentSamples: stale, sourceLabel: "standard heart-rate service")
        #expect(live.signalStale)
        #expect(live.currentHR == nil)
        #expect(live.currentZone == nil, "the last sample is 30 s old, yet the live workout shows zone \(String(describing: live.currentZone))")
    }

    // [BUG] ZoneMethodChoice.heartRateReserve.explanation: "Needs a resting heart rate (entered, or Forma's
    // overnight estimate)." ScreenLoader.activity/liveWorkout always pass `overnightRestingHeartRate: nil`, so
    // heart-rate-reserve zones stay unavailable even when Forma has an overnight resting estimate.
    @Test("[BUG] Heart-rate-reserve zones use Forma's overnight resting estimate")
    func heartRateReserveZonesUseFormasOvernightRestingEstimate() throws {
        let store = try Adv.store()
        let night = TimeRange(start: Adv.now - 14 * Adv.hour, end: Adv.now - 6 * Adv.hour) // 00:00–08:00
        try Adv.ingestHR(store, "band", from: night.start, to: night.end, every: 5_000, bpm: 50)
        try store.insertSession(Adv.sleepSession(night, device: "band"))
        let workout = TimeRange(start: Adv.now - 3 * Adv.hour, end: Adv.now - 2 * Adv.hour)
        try Adv.ingestHR(store, "band", from: workout.start, to: workout.end, every: 5_000, bpm: 140)
        try store.insertSession(Session(kind: .workout, range: workout, origin: .manual, label: "Run", deviceID: "band",
                                        createdAt: Adv.now, updatedAt: Adv.now))
        let ctx = Adv.context(store, profile: UserProfile(maxHeartRateOverride: 190), zoneModel: .heartRateReserve, deviceID: "band")

        let rhr = try #require(try ScreenLoader.today(ctx).cards.first { $0.id == "rhr" })
        try #require(rhr.metric.value != nil, "precondition: Forma has an overnight resting estimate for last night")

        let activity = try ScreenLoader.activity(ctx, live: nil)
        #expect(activity.zonesAvailability.isAvailable, "\(activity.zonesAvailability.explanation)")
        #expect(activity.workouts.first?.zonesAvailability.isAvailable == true)
    }

    // [BUG] ChartPoint is Identifiable by `t`; SwiftUI/Charts require unique ids. When a gap falls inside one
    // down-sampling bucket, the points before and after the gap get the same `t` (the bucket start).
    @Test("[BUG] Chart points have unique ids even when a gap falls inside one bucket")
    func chartPointIDsAreUnique() {
        let window = TimeRange(start: 0, end: Adv.day) // 600 points → 144 s buckets
        var samples = Adv.heartRates("d", from: 0, to: 61_000, every: 5_000, bpm: 60, source: .demo)
        samples += Adv.heartRates("d", from: 125_000, to: 144_000, every: 5_000, bpm: 70, source: .demo) // 65 s gap
        let series = ScreenLoader.series(samples, window: window)
        #expect(series.gapCount == 1)
        #expect(Set(series.points.map(\.id)).count == series.points.count,
                "duplicate chart ids: \(series.points.map { "\($0.t)/seg\($0.segment)" })")
    }

    // [BUG][low] ScreenLoader.series: "Builds a gap-preserving, down-sampled series for charts (≤ `maxPoints`
    // points)." Integer bucket sizing yields maxPoints + 1 buckets when the window is not a multiple of maxPoints.
    @Test("[BUG] Chart series never exceed maxPoints")
    func chartSeriesNeverExceedMaxPoints() {
        let window = TimeRange(start: 0, end: 600_599)
        let samples = Adv.heartRates("d", from: 0, to: 600_001, every: 1_000, bpm: 60, source: .demo)
        let series = ScreenLoader.series(samples, window: window, maxPoints: 600)
        #expect(series.points.count <= 600, "got \(series.points.count) points")
    }

    /// Validation applies to band history only: the vendor live stream's unvalidated field is never used.
    @Test func unvalidatedLiveVendorHeartRateIsNeverUsed() throws {
        let store = try Adv.store()
        try Adv.ingestHR(store, "band", from: Adv.now - 60_000, to: Adv.now, every: 1_000, bpm: 75,
                         source: .liveVendorStream, quality: [.unvalidatedField])
        let ctx = Adv.context(store, deviceID: "band", historyHeartRateValidated: true)
        let today = try ScreenLoader.today(ctx)
        #expect(today.latestHeartRate == nil)
        #expect(today.coverage24h.fraction(of: .recorded) == 0)
    }

    /// KNOWN_LIMITATIONS: motion values are raw counts on an unpublished scale; sleep candidates from motion
    /// need the user's explicit opt-in. Candidates are never counted until confirmed.
    @Test func unvalidatedMotionNeedsAnExplicitOptIn() throws {
        let store = try Adv.store()
        _ = try store.ingest(IngestBatch(provenance: Adv.provenance("band", .deviceHistory),
                                         motion: Adv.nightMotion("band", nightEndingOn: Adv.today, quality: [.unvalidatedField])))
        let base = Adv.context(store, deviceID: "band", motionSupported: true, motionNeedsValidation: true)
        #expect(try ScreenLoader.proposeSleepCandidate(base, nightEndingOn: Adv.today) == nil)
        if case .disabled = try ScreenLoader.sleep(base).motionAvailability {} else {
            Issue.record("unvalidated motion must be reported as disabled until the user allows it")
        }
        var allowed = base
        allowed.allowUnvalidatedMotion = true
        let candidate = try #require(try ScreenLoader.proposeSleepCandidate(allowed, nightEndingOn: Adv.today))
        #expect(candidate.origin == .detectedCandidate && !candidate.isConfirmed)
        #expect(try ScreenLoader.sleep(allowed).motionAvailability == .available)
    }

    /// PRD §6.2: sleep candidates require motion data and are never inferred from heart rate alone.
    @Test func noSleepCandidateFromHeartRateAlone() throws {
        let store = try Adv.store()
        let window = TimeRange(start: Adv.today.range(calendar: Adv.utc).start - 12 * Adv.hour,
                               end: Adv.today.range(calendar: Adv.utc).start + 12 * Adv.hour)
        try Adv.ingestHR(store, "band", from: window.start, to: window.end, every: 5_000, bpm: 52)
        let noMotionPath = Adv.context(store, deviceID: "band", motionSupported: false)
        #expect(try ScreenLoader.proposeSleepCandidate(noMotionPath, nightEndingOn: Adv.today) == nil)
        #expect(try ScreenLoader.sleep(noMotionPath).motionAvailability == .unsupportedSensor(sensor: SleepDetector.motionSensorName))
        let noMotionData = Adv.context(store, deviceID: "band", motionSupported: true)
        #expect(try ScreenLoader.proposeSleepCandidate(noMotionData, nightEndingOn: Adv.today) == nil)
    }

    /// LoaderContext.deviceID: "Device whose data to show"; PRD: own device only, device identity everywhere.
    @Test func anotherBandsDataIsNotShownForTheSelectedBand() throws {
        let store = try Adv.store()
        try Adv.ingestHR(store, "other", from: Adv.now - 90_000, to: Adv.now - 30_000, every: 1_000, bpm: 88)
        let selected = try ScreenLoader.today(Adv.context(store, deviceID: "band"))
        #expect(selected.latestHeartRate == nil)
        #expect(selected.coverage24h.fraction(of: .recorded) == 0)
        #expect(try ScreenLoader.today(Adv.context(store, deviceID: nil)).latestHeartRate?.bpm == 88)
    }

    /// PRD §6.1: when nothing is arriving the screen says so instead of showing a stale number as live.
    @Test func latestHeartRateIsMarkedStale() throws {
        let store = try Adv.store()
        try Adv.ingestHR(store, "band", from: Adv.now - 200_000, to: Adv.now - 121_000, every: 1_000, bpm: 70)
        #expect(try ScreenLoader.today(Adv.context(store, deviceID: "band")).latestHeartRate?.isStale == true)
        try Adv.ingestHR(store, "band", from: Adv.now - 60_000, to: Adv.now - 59_000, every: 1_000, bpm: 71)
        let fresh = try #require(try ScreenLoader.today(Adv.context(store, deviceID: "band")).latestHeartRate)
        #expect(!fresh.isStale && fresh.bpm == 71)
    }

    /// PRD §6.1: trends are shown only when minimum days are met (4/7, 14/30, 45/90), with no causal language.
    @Test func trendsGateOnMinimumDaysAndUseNoCausalLanguage() throws {
        func store(nightsEndingDaysAgo offsets: [Int], hours: (Int) -> Double = { _ in 7.5 }) throws -> FormaStore {
            let s = try Adv.store()
            for k in offsets {
                let dayStart = Adv.today.adding(days: -k, calendar: Adv.utc).range(calendar: Adv.utc).start
                let start = dayStart - Adv.hour
                try s.insertSession(Adv.sleepSession(TimeRange(start: start, end: start + Int64(hours(k) * 3_600_000))))
            }
            return s
        }
        let three = try ScreenLoader.trends(Adv.context(try store(nightsEndingDaysAgo: [0, 2, 4])), metric: .sleepDuration, period: .days7)
        #expect(three.daily.count == 7)
        #expect(three.daysWithData == 3)
        #expect(!three.availability.isAvailable && three.summary.isEmpty && three.comparison == nil)
        #expect(three.daily.allSatisfy { ($0.value == nil) == $0.valueText.isEmpty })

        let four = try ScreenLoader.trends(Adv.context(try store(nightsEndingDaysAgo: [0, 2, 4, 6])), metric: .sleepDuration, period: .days7)
        #expect(four.availability.isAvailable)
        #expect(four.summary.first { $0.label == "Days with a value" }?.value == "4 of 7")

        let month = try ScreenLoader.trends(Adv.context(try store(nightsEndingDaysAgo: Array(0..<35), hours: { $0 < 7 ? 8 : 7.5 })),
                                            metric: .sleepDuration, period: .days30)
        let sentence = try #require(month.comparison)
        #expect(sentence.contains("8.0 h") && sentence.contains("7.5 h"), "\(sentence)")
        for word in ["because", "due to", "caused", "result of", "led to", "improv", "worse", "better", "should", "recommend"] {
            #expect(!sentence.lowercased().contains(word), "causal or advisory wording '\(word)' in: \(sentence)")
        }
    }

    @Test func trendRowsAreConsecutiveLocalDaysAcrossDaylightSavingChanges() throws {
        // 2026-03-31 12:00 UTC: the last 7 London days include the 29 March change to BST.
        let now: EpochMillis = 1_774_958_400_000
        let s = try Adv.store(now: now)
        let trend = try ScreenLoader.trends(Adv.context(s, now: now, calendar: Adv.london), metric: .sleepDuration, period: .days7)
        #expect(trend.daily.count == 7)
        #expect(trend.daily.last?.day == LocalDay(now, calendar: Adv.london))
        for (a, b) in zip(trend.daily, trend.daily.dropFirst()) {
            #expect(a.day.adding(days: 1, calendar: Adv.london) == b.day)
            #expect(a.dayStart < b.dayStart)
        }
    }

    /// PRD §6.2 / readiness spec: an experimental, baseline-relative index in SD units that never gives advice.
    @Test func readinessCopyIsDescriptiveOnly() {
        let day = Adv.today
        var ln: [LocalDay: Double?] = [:], rhr: [LocalDay: Double?] = [:], sleep: [LocalDay: Double?] = [:]
        for i in 1...28 {
            let d = day.adding(days: -i, calendar: Adv.utc)
            ln[d] = 4.0 + (i % 3 == 0 ? 0.05 : -0.03)
            rhr[d] = 52 + Double(i % 2)
            sleep[d] = 450 + Double(i % 4) * 10
        }
        ln[day] = 3.5
        rhr[day] = 60
        sleep[day] = 300
        let result = ReadinessCalculator.compute(day: day, calendar: Adv.utc, lnRMSSD: ln, restingHeartRate: rhr, sleepDurationMinutes: sleep)
        let card = ScreenLoader.readinessState(result)
        #expect(card.metric.availability.isAvailable)
        #expect(card.bandText == "Below your usual range")
        let texts = [card.bandText ?? ""] + card.components.flatMap { [$0.name, $0.valueText, $0.baselineText, $0.zText, $0.weightText] }
        for text in texts {
            for word in ["should", "recommend", "advice", "take it easy", "train", "rest day", "recovery"] {
                #expect(!text.lowercased().contains(word), "advisory wording in '\(text)'")
            }
        }
        ln[day] = nil
        let noHRV = ScreenLoader.readinessState(ReadinessCalculator.compute(day: day, calendar: Adv.utc, lnRMSSD: ln,
                                                                            restingHeartRate: rhr, sleepDurationMinutes: sleep))
        #expect(noHRV.bandText == nil && noHRV.metric.value == nil)
    }

    /// PRD §3: unavailable means nil, never 0; every card renders from Availability.
    @Test func unavailableCardsNeverCarryAValue() throws {
        let store = try Adv.store()
        let night = TimeRange(start: Adv.now - 13 * Adv.hour, end: Adv.now - 5 * Adv.hour)
        try store.insertSession(Adv.sleepSession(night))
        try Adv.ingestHR(store, "band", from: night.start, to: night.start + 30 * Adv.minute, every: 5_000, bpm: 54)
        let today = try ScreenLoader.today(Adv.context(store, showReadiness: true, beatIntervalsSupported: true))
        for card in today.cards {
            if card.metric.availability.isAvailable {
                #expect(card.valueText != nil && card.metric.value != nil, "\(card.id)")
            } else {
                #expect(card.valueText == nil && card.metric.value == nil, "\(card.id) shows a value while unavailable")
            }
        }
        #expect(today.cards.first { $0.id == "rhr" }?.metric.availability.isAvailable == false, "30 min of HR is not a resting estimate")
        #expect(today.cards.first { $0.id == "load" }?.metric.value == nil, "no HRmax, no load")
        #expect(today.readiness?.metric.value == nil && today.readiness?.bandText == nil)
    }
}

// MARK: - Demo data

@Suite("Adversarial: demo data")
struct AdversarialDemoDataTests {
    // [BUG][low] Demo data is generated up to `end` (= "now" when Demo mode starts). Heart rate stops before
    // `end`, but the beat-interval loop appends the beat that crosses `end`, so demo nights opened during the
    // night contain beats timestamped in the future.
    @Test("[BUG] Demo data never contains records after its end time")
    func demoNeverProducesRecordsAfterEnd() {
        let midnight = Adv.today.range(calendar: Adv.utc).start
        var late: [String] = []
        for q in 0..<20 {
            let end = midnight + 30 * Adv.minute + Int64(q) * 15 * Adv.minute // 00:30 … 05:15
            let out = DemoDataGenerator(days: 2, end: end, calendar: Adv.utc).generate()
            let hr = out.batches.flatMap(\.heartRates).filter { $0.timestamp >= end }.count
            let beats = out.batches.flatMap(\.beatIntervals).filter { $0.timestamp > end }
            let motion = out.batches.flatMap(\.motion).filter { $0.timestamp >= end }.count
            let sessions = out.sessions.filter { $0.range.end > end }.count
            if hr + beats.count + motion + sessions > 0 {
                late.append("end \(end): \(hr) hr, \(beats.count) beats (up to +\((beats.map(\.timestamp).max() ?? end) - end) ms), \(motion) motion, \(sessions) sessions")
            }
        }
        #expect(late.isEmpty, "\(late.joined(separator: "; "))")
    }

    /// Demo data is labelled (`.demo` source, demo device, demo adapter) and its records never collide on
    /// the store's dedup keys, so nothing silently disappears on ingest.
    @Test func demoRecordsAreLabelledAndHaveUniqueDedupKeys() {
        let out = DemoDataGenerator(days: 6, end: Adv.now, calendar: Adv.london).generate()
        #expect(out.device.id == DemoDataGenerator.deviceID && out.device.name.contains("Demo"))
        #expect(out.batches.allSatisfy { $0.provenance.source == .demo && $0.provenance.adapterID == DemoDataGenerator.adapterID })
        let beats = out.batches.flatMap(\.beatIntervals)
        let motion = out.batches.flatMap(\.motion)
        #expect(beats.allSatisfy { $0.source == .demo && $0.deviceID == DemoDataGenerator.deviceID })
        #expect(motion.allSatisfy { $0.source == .demo && $0.deviceID == DemoDataGenerator.deviceID })
        #expect(Set(beats.map { "\($0.recordKey)/\($0.indexInRecord)" }).count == beats.count)
        #expect(Set(motion.map { "\($0.timestamp)/\($0.epochMillis)" }).count == motion.count)
        #expect(out.sessions.allSatisfy { !$0.range.isEmpty && $0.range.durationMillis < Adv.day && $0.range.end <= Adv.now })
        #expect(out.sessions.filter { $0.origin == .detectedCandidate }.count == 1)
        let latestSleep = out.sessions.filter { $0.kind == .sleep }.max { $0.range.end < $1.range.end }
        #expect(latestSleep?.origin == .detectedCandidate, "the most recent night is the one left for review")
    }

    @Test func demoDayCountIsClampedAndSeedsMatter() {
        #expect(DemoDataGenerator(days: 0, end: Adv.now, calendar: Adv.utc).generate().batches.count == 1)
        #expect(DemoDataGenerator(days: -7, end: Adv.now, calendar: Adv.utc).days == 1)
        #expect(DemoDataGenerator(days: 10_000, end: Adv.now, calendar: Adv.utc).days == 120)
        let a = DemoDataGenerator(seed: 1, days: 2, end: Adv.now, calendar: Adv.utc).generate().batches.flatMap(\.heartRates)
        let b = DemoDataGenerator(seed: 2, days: 2, end: Adv.now, calendar: Adv.utc).generate().batches.flatMap(\.heartRates)
        #expect(a.map(\.bpm) != b.map(\.bpm))
    }
}

// MARK: - App model

@MainActor
@Suite("Adversarial: app model", .serialized)
struct AdversarialAppModelTests {
    func make(now: EpochMillis = Adv.now, platform: AdvPlatform = AdvPlatform(),
              central: AdvCentral = AdvCentral()) async -> (AppModel, AdvCentral, AdvPlatform, ManualTimeSource) {
        let clock = ManualTimeSource(now)
        let model = AppModel(central: central, platform: platform, timeSource: clock, calendar: Adv.utc)
        await model.refreshTask?.value
        return (model, central, platform, clock)
    }

    func band(_ id: String, _ family: DeviceFamily = .whoop5, name: String = "WHOOP 5.0") -> DiscoveredDevice {
        DiscoveredDevice(id: id, name: name, rssi: -60, family: family, advertisedServiceUUIDs: [], manufacturerDataHex: nil,
                         connectedToThisPhone: false, lastSeen: Adv.now)
    }

    func eventually(_ timeoutMillis: Int = 3_000, _ condition: () throws -> Bool) async rethrows -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMillis) / 1_000)
        while Date() < deadline {
            if try condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return try condition()
    }

    func trendValue(_ model: AppModel, _ day: LocalDay) -> Double? {
        model.trends?.daily.first { $0.day == day }?.value
    }

    // MARK: History opt-in

    /// PRD/KNOWN_LIMITATIONS: history sync is opt-in; with it off Forma never requests or acknowledges band
    /// history. Positive control: after the user opts in, "Sync now" does request it.
    @Test func historySyncIsOptInAndOffNeverRequestsOrAcknowledgesHistory() async throws {
        let (model, _, _, _) = await make()
        #expect(model.historySyncMode == .off)
        await model.selectDevice(band("W-1"))
        let link = ReplayLink(peripheralID: "W-1", entries: [],
                              services: [Whoop5Adapter.service: [Whoop5Adapter.commandToStrap, Whoop5Adapter.commandFromStrap,
                                                                 Whoop5Adapter.eventsFromStrap, Whoop5Adapter.dataFromStrap]],
                              endWithDisconnect: false, responder: { _, _ in [] })
        model.handle(.linkReady(link, services: [GATTServiceSummary(uuid: Whoop5Adapter.service, name: "Vendor", characteristics: [])]))
        #expect(await eventually { !link.writtenCommands.isEmpty }, "the read-only identify request is written after connecting")
        await model.syncNow()
        await model.refresh(requestSync: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        let history: Set<UInt8> = [Whoop5Adapter.CommandID.sendHistoricalData.rawValue, Whoop5Adapter.CommandID.historicalDataResult.rawValue,
                                   Whoop5Adapter.CommandID.getDataRange.rawValue, Whoop5Adapter.CommandID.abortHistoricalTransmits.rawValue]
        let whileOff = link.writtenCommands.compactMap { Adv.whoopCommandID($0.bytes) }
        #expect(!whileOff.contains { history.contains($0) }, "history commands written while history sync is off: \(whileOff)")

        await model.setHistorySyncMode(.manual)
        await model.syncNow()
        #expect(await eventually {
            link.writtenCommands.compactMap { Adv.whoopCommandID($0.bytes) }.contains(Whoop5Adapter.CommandID.sendHistoricalData.rawValue)
        }, "control: after opting in, Sync now requests history")
        #expect(!link.writtenCommands.compactMap { Adv.whoopCommandID($0.bytes) }.contains(Whoop5Adapter.CommandID.historicalDataResult.rawValue),
                "nothing was received, so nothing may be acknowledged")
        link.finish()
    }

    // MARK: Own band only

    // [BUG] PRD §3 "Own device only: the user explicitly selects a device … The device identity is shown
    // everywhere data appears." startEngine() never checks `link.peripheralID` against the selected band and
    // labels the link's data with the *selected* band's id. (BLECentral's willRestoreState can hand back a
    // peripheral other than the saved one, so this is reachable.)
    @Test("[BUG] Data from a peripheral other than the selected band is never collected or attributed to it")
    func linkFromAnotherPeripheralIsNeverAttributedToTheSelectedBand() async throws {
        let (model, _, _, _) = await make()
        await model.selectDevice(band("P-1", .standardHeartRate, name: "Strap 1"))
        let store = try #require(model.liveStore)
        model.handle(.linkReady(Adv.standardHeartRateLink(id: "P-2", start: Adv.now - 30_000, count: 30), services: Adv.heartRateServices))
        _ = await eventually(2_000) { ((try? store.heartRates(in: Adv.everything)) ?? []).isEmpty == false }
        let stored = try store.heartRates(in: Adv.everything)
        #expect(!stored.contains { $0.deviceID == "P-1" }, "\(stored.count) samples from peripheral P-2 were stored as band P-1")
        #expect(stored.isEmpty, "a band the user did not select must not be collected")
        #expect(model.selectedDevice?.id == "P-1")
    }

    // [BUG] PRD §3: "The user explicitly selects a device. The app never auto-connects to unknown bands."
    // With no band selected (fresh install, or right after "Forget band"), a link that becomes ready is
    // adopted as the user's band ("Band") and its data is collected.
    @Test("[BUG] A ready link is never adopted as the user's band without an explicit selection")
    func linkWithNoSelectedBandIsNotAdopted() async throws {
        let (model, _, _, _) = await make()
        let store = try #require(model.liveStore)
        model.handle(.linkReady(Adv.standardHeartRateLink(id: "P-9", start: Adv.now - 30_000, count: 30), services: Adv.heartRateServices))
        _ = await eventually(2_000) { ((try? store.heartRates(in: Adv.everything)) ?? []).isEmpty == false }
        #expect(model.selectedDevice == nil, "an unselected peripheral became the selected band: \(String(describing: model.selectedDevice))")
        #expect(try store.heartRates(in: Adv.everything).isEmpty)
        #expect(try store.devices().isEmpty)
    }

    /// PRD §3: never auto-connect to unknown bands; a band the user selected earlier reconnects at launch
    /// (pending connect), but not while collection is off or in Demo mode.
    @Test func launchReconnectsOnlyToTheBandTheUserSelected() async throws {
        let dir = Adv.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let platform = AdvPlatform(directory: dir)
        do {
            let central = AdvCentral(saved: "X-unknown")
            let (model, _, _, _) = await make(platform: platform, central: central)
            #expect(!central.calls.contains("connect"), "a saved identifier Forma never stored as the user's band")
            #expect(model.selectedDevice == nil && model.connection.link == .noDeviceSelected)
        }
        do {
            let (model, central, _, _) = await make(platform: platform)
            await model.selectDevice(band("W-1"))
            #expect(central.calls.contains("select:W-1") && central.calls.contains("connect"))
        }
        do {
            let central = AdvCentral(saved: "W-1")
            let (model, _, _, _) = await make(platform: platform, central: central)
            #expect(model.selectedDevice?.id == "W-1")
            #expect(central.calls.contains("connect"))
        }
        platform.setPreference("1", forKey: "demo")
        do {
            let central = AdvCentral(saved: "W-1")
            let (model, _, _, _) = await make(platform: platform, central: central)
            #expect(model.isDemo && model.connection.isDemo)
            #expect(!central.calls.contains("connect"), "Demo mode never connects")
        }
        platform.setPreference("0", forKey: "demo")
        platform.setPreference("0", forKey: "collectionEnabled")
        do {
            let central = AdvCentral(saved: "W-1")
            let (model, _, _, _) = await make(platform: platform, central: central)
            #expect(!central.calls.contains("connect"), "collection is off")
            await model.sceneBecameActive()
            #expect(!central.calls.contains("connect"), "collection is off")
        }
    }

    // [BUG] LinkState.searching = "Waiting for the selected band to come into range (a pending connection
    // request)", and apply(.disconnected) already shows `.disconnected` when collection is off. But selecting a
    // band or relaunching with collection off shows "Searching" ("Waiting for … to come into range") although no
    // connection request was ever made, and nothing will ever correct it. (exitDemo() has the same pattern.)
    @Test("[BUG] Status never says 'Searching' while collection is off")
    func statusNeverSaysSearchingWhileCollectionIsOff() async throws {
        let dir = Adv.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let platform = AdvPlatform(directory: dir)
        do {
            let (model, central, _, _) = await make(platform: platform)
            await model.setCollectionEnabled(false)
            await model.selectDevice(band("W-1"))
            #expect(!central.calls.contains("connect"))
            #expect(model.connection.link != .searching, "selected with collection off: \(model.connection.shortStatus)")
        }
        do {
            let central = AdvCentral(saved: "W-1")
            let (model, _, _, _) = await make(platform: platform, central: central)
            #expect(!central.calls.contains("connect"))
            #expect(model.connection.link != .searching, "relaunched with collection off: \(model.connection.shortStatus)")
        }
    }

    /// PRD §3: the user explicitly selects a device; scanning lists known families first, stronger signal first.
    @Test func discoveryNeverConnectsAndListsKnownBandsFirst() async {
        let (model, central, _, _) = await make()
        model.startScan(includeUnfiltered: false)
        func found(_ id: String, _ family: DeviceFamily, _ rssi: Int?, connected: Bool = false) {
            model.handle(.discovered(DiscoveredDevice(id: id, name: id, rssi: rssi, family: family, advertisedServiceUUIDs: [],
                                                      manufacturerDataHex: nil, connectedToThisPhone: connected, lastSeen: Adv.now),
                                     advertisement: ["name": id]))
        }
        found("speaker", .unknown, -30)
        found("w-weak", .whoop5, -90)
        found("w-retrieved", .whoop5, nil, connected: true)
        found("w-strong", .whoop5, -50)
        found("w-retrieved", .whoop5, nil, connected: false) // re-advertised: keeps "connected to this iPhone"
        #expect(model.discoveredDevices.map(\.id) == ["w-strong", "w-weak", "w-retrieved", "speaker"])
        #expect(model.discoveredDevices.first { $0.id == "w-retrieved" }?.connectedToThisPhone == true)
        #expect(!central.calls.contains("connect") && !central.calls.contains { $0.hasPrefix("select:") })
    }

    /// PRIVACY: "Forget band stops Forma from connecting and keeps recorded data."
    @Test func forgetBandKeepsRecordedData() async throws {
        let (model, central, _, _) = await make()
        await model.selectDevice(band("P-1", .standardHeartRate))
        let store = try #require(model.liveStore)
        try Adv.ingestHR(store, "P-1", from: Adv.now - 120_000, to: Adv.now - 60_000, every: 1_000, bpm: 70)
        await model.forgetDevice()
        #expect(central.calls.contains("forget"))
        #expect(model.selectedDevice == nil && model.connection.link == .noDeviceSelected)
        #expect(try store.heartRates(in: Adv.everything).count == 60)
        #expect(model.today?.hasAnyData == true)
    }

    // MARK: Demo

    /// PRD §7 / PRIVACY: demo data lives in a separate database, is permanently labelled, and is never mixed
    /// with live records; Demo mode never connects to or records from the band.
    @Test func demoModeNeverConnectsCollectsOrMixes() async throws {
        let (model, central, _, _) = await make()
        await model.selectDevice(band("P-1", .standardHeartRate))
        await model.enterDemo()
        #expect(central.calls.contains("disconnect"))
        let mark = central.calls.count
        await model.setCollectionEnabled(true)
        await model.sceneBecameActive()
        model.handle(.linkReady(Adv.standardHeartRateLink(id: "P-1", start: Adv.now - 30_000, count: 30), services: Adv.heartRateServices))
        model.handle(.connectionEvent(ConnectionEvent(deviceID: "P-1", timestamp: Adv.now, kind: .connected)))
        model.handle(.stateChanged(.connected))
        await model.startWorkout()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!central.calls.dropFirst(mark).contains("connect"))
        #expect(model.liveWorkoutStart == nil)
        #expect(model.connection.isDemo && model.connection.shortStatus == "Demo data")
        let live = try #require(model.liveStore)
        #expect(try live.heartRates(in: Adv.everything).isEmpty)
        #expect(try live.connectionEvents(limit: 50).isEmpty)
        #expect(model.today?.hasAnyData == true)
        await model.exitDemo()
        #expect(!model.connection.isDemo)
        #expect(model.today?.hasAnyData == false)
    }

    // MARK: Delete all data

    /// PRD §7: every view has an error state; an unopenable database is reported, never a crash or fake data.
    @Test func anUnavailableDatabaseIsReportedNotHidden() async throws {
        let (model, _, _, _) = await make(platform: AdvPlatform(databaseLocationFails: true))
        #expect(model.alertMessage?.contains("could not open its database") == true)
        await model.refreshNow()
        #expect(model.today == nil)
        await #expect(throws: AppModelError.self) { _ = try await model.exportBackup() }
        #expect(await model.importBackup(from: URL(fileURLWithPath: "/nonexistent.jsonl")) == "The database is not open.")
    }

    // [BUG] PRIVACY: "Delete all data … erases every table and removes the database files." When the live
    // database cannot be opened (corrupt file, newer schema), deleteAllData() skips the files (it only knows the
    // path through the open store) yet returns "All Forma data on this iPhone was deleted." — the file with the
    // health data is still on disk. Either remove it or do not claim to have.
    @Test("[BUG] Delete all data never reports success while the database file is still on disk")
    func deleteAllDataNeverClaimsSuccessWhileTheFileRemains() async throws {
        let dir = Adv.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("forma.sqlite")
        try Data(repeating: 0x5A, count: 8_192).write(to: file)
        let (model, _, _, _) = await make(platform: AdvPlatform(directory: dir))
        try #require(model.alertMessage != nil, "precondition: the damaged database could not be opened")
        let message = await model.deleteAllData()
        let stillThere = FileManager.default.fileExists(atPath: file.path)
        #expect(!(stillThere && message.contains("was deleted")), "\"\(message)\" while \(file.lastPathComponent) is still on disk")
    }

    // [BUG] Settings → Your data: "Delete all data — Erases every measurement, session, setting and capture
    // stored by Forma on this iPhone" (PRIVACY: "erases every table and removes the database files"). In Demo
    // mode deleteAllData() wipes only the demo database, keeps every live measurement, and still answers
    // "All Forma data on this iPhone was deleted."
    @Test("[BUG] In Demo mode, Delete all data does not claim to have erased live data it kept")
    func deleteAllDataInDemoModeDoesNotKeepLiveDataBehindASuccessMessage() async throws {
        let (model, _, _, _) = await make()
        let live = try #require(model.liveStore)
        try Adv.ingestHR(live, "P-1", from: Adv.now - 120_000, to: Adv.now - 60_000, every: 1_000, bpm: 70)
        await model.enterDemo()
        let message = await model.deleteAllData()
        let remaining = try #require(model.liveStore).heartRates(in: Adv.everything).count
        #expect(remaining == 0 || !message.contains("All Forma data"), "\"\(message)\" — yet \(remaining) live heart-rate samples remain")
    }

    // [BUG] ConnectionSummary.lastDeviceSample = "Newest measurement time stored for this device". After
    // "Delete all data" nothing is stored, but refreshNow() only ever raises the value, so the status line keeps
    // saying "Last device sample 1 min ago" for data that no longer exists.
    @Test("[BUG] After Delete all data no deleted sample is reported as the last device sample")
    func deleteAllDataClearsTheLastDeviceSample() async throws {
        let (model, _, _, _) = await make()
        try Adv.ingestHR(try #require(model.liveStore), "P-1", from: Adv.now - 120_000, to: Adv.now - 60_000, every: 1_000, bpm: 70)
        await model.refreshNow()
        try #require(model.connection.lastDeviceSample != nil && model.today?.hasAnyData == true)
        let message = await model.deleteAllData()
        #expect(message.contains("deleted"))
        #expect(model.today?.hasAnyData == false)
        #expect(model.connection.lastDeviceSample == nil,
                "still shows: \(model.connection.detailLines(now: Adv.now, formatter: RelativeTimeFormatter(calendar: Adv.utc))[1])")
    }

    // [BUG] PRIVACY: "Delete all data … erases every table". The last-complete-sync line (read from the erased
    // sync cursor) keeps saying a sync completed, and the Diagnostics "Captured entries" count keeps the old value
    // although the capture was cleared (so "Export capture" stays enabled for an empty capture).
    @Test("[BUG] After Delete all data no sync time or capture count from before remains")
    func deleteAllDataLeavesNoStaleHistory() async throws {
        let (model, _, _, _) = await make()
        model.handle(.connectionEvent(ConnectionEvent(deviceID: "P-1", timestamp: Adv.now - Adv.minute, kind: .connected)))
        try #require(try #require(model.liveStore).connectionEvents(limit: 10).count == 1)
        model.recorder.record(CaptureEntry(t: Adv.now, dir: .rx, c: "2A37", d: "0640"))
        model.apply(.counters(SyncCounters()))
        model.apply(.historyComplete(at: Adv.now - Adv.hour))
        await model.refreshTask?.value
        try #require(model.diagnostics.capturedEntries == 1 && model.connection.lastCompletedSync != nil && model.connectionEvents.count == 1)
        _ = await model.deleteAllData()
        #expect(try #require(model.liveStore).connectionEvents(limit: 10).isEmpty)
        #expect(model.connection.lastCompletedSync == nil, "still says the last complete sync was 1 h ago")
        #expect(model.diagnostics.capturedEntries == 0, "the capture was cleared but the count still says 1")
    }

    /// PRD: history acknowledgement is opt-in; after "Delete all data" the opt-in, the motion opt-in and the
    /// profile are gone with the settings table. Settings otherwise survive a relaunch.
    @Test func settingsSurviveRelaunchAndDeleteAllResetsTheOptIns() async throws {
        let dir = Adv.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let platform = AdvPlatform(directory: dir)
        let profile = UserProfile(birthYear: 1990, sex: .female, maxHeartRateOverride: 185, restingHeartRateOverride: 50)
        do {
            let (model, _, _, _) = await make(platform: platform)
            await model.setHistorySyncMode(.automatic)
            await model.setZoneMethod(.heartRateReserve)
            await model.setShowExperimentalReadiness(false)
            await model.setAllowUnvalidatedMotion(true)
            await model.setProfile(profile)
            model.setRawRetentionDays(100)
            #expect(model.rawRetentionDays == 30)
            model.setRawRetentionDays(0)
            #expect(model.rawRetentionDays == 1)
            model.setRawRetentionDays(14)
        }
        let (model, _, _, _) = await make(platform: platform)
        #expect(model.historySyncMode == .automatic)
        #expect(model.zoneMethod == .heartRateReserve)
        #expect(model.showExperimentalReadiness == false)
        #expect(model.allowUnvalidatedMotion == true)
        #expect(model.profile == profile)
        #expect(model.rawRetentionDays == 14)
        let message = await model.deleteAllData()
        #expect(message.contains("deleted"))
        #expect(model.historySyncMode == .off, "history acknowledgement must be opted into again")
        #expect(model.allowUnvalidatedMotion == false)
        #expect(model.profile == UserProfile())
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("forma.sqlite").path))
    }

    // MARK: Derived-value cache

    // [BUG] ARCHITECTURE §7: missed periods "are recovered from the band's own history on the next sync".
    // Daily values for past days are cached (even when nil) and the app invalidates the cache only after
    // corrections, imports and settings changes — never after a history sync — so recovered data never reaches
    // that day's trend.
    @Test("[BUG] History recovered for a past day reaches that day's trend value")
    func historyRecoveredForAPastDayReachesItsDailyTrend() async throws {
        let (model, _, _, _) = await make()
        await model.selectDevice(band("W-1"))
        await model.setHistorySyncMode(.manual)
        await model.setProfile(UserProfile(maxHeartRateOverride: 190))
        let store = try #require(model.liveStore)
        // Band-history heart rate has passed field validation for this adapter and (unknown) firmware.
        try store.setSetting("passed", forKey: FieldValidator.historyHeartRateKey(adapterID: Whoop5Adapter().adapterID, firmware: nil))
        await model.setTrend(period: .days7)
        await model.setTrend(metric: .load)
        try #require(model.trends?.daily.contains { $0.day == Adv.yesterday } == true)
        try #require(trendValue(model, Adv.yesterday) == nil, "nothing was recorded yesterday before the sync")

        // A history sync persists yesterday's records (as SyncEngine does), then reports progress and completion.
        let y = Adv.yesterday.range(calendar: Adv.utc)
        try Adv.ingestHR(store, "W-1", from: y.start + 8 * Adv.hour, to: y.start + 18 * Adv.hour, every: 5_000, bpm: 130,
                         source: .deviceHistory, quality: [.unvalidatedField, .clockOffsetApplied], adapter: "forma.whoop5")
        model.apply(.historyStarted(at: Adv.now - Adv.minute))
        model.apply(.historyProgress(records: 7_200, newestRecord: y.start + 18 * Adv.hour))
        model.apply(.historyChunkSaved(inserted: 7_200, duplicates: 0, acknowledged: true))
        model.apply(.historyComplete(at: Adv.now))
        await model.refreshTask?.value
        await model.refreshNow()
        #expect(trendValue(model, Adv.yesterday) != nil, "the recovered day still shows no value (stale cached nil)")

        // Control: with the cache for that day cleared, the same data does produce a value.
        _ = try store.invalidateDerived(overlapping: y)
        await model.refreshNow()
        #expect(trendValue(model, Adv.yesterday) != nil)
    }

    // [BUG] LoaderContext.deviceID = "Device whose data to show"; PRD: own device only. Cached daily values
    // are keyed by metric and day only, so after switching bands the new band's trend shows the previous band's
    // values for past days.
    @Test("[BUG] After switching bands, past trend values are not the previous band's")
    func switchingBandsNeverShowsThePreviousBandsCachedValues() async throws {
        let (model, _, _, _) = await make()
        await model.selectDevice(band("A-1", .standardHeartRate, name: "Strap A"))
        await model.setProfile(UserProfile(maxHeartRateOverride: 190))
        let y = Adv.yesterday.range(calendar: Adv.utc)
        try Adv.ingestHR(try #require(model.liveStore), "A-1", from: y.start + 8 * Adv.hour, to: y.start + 18 * Adv.hour,
                         every: 5_000, bpm: 130)
        await model.setTrend(period: .days7)
        await model.setTrend(metric: .load)
        try #require(trendValue(model, Adv.yesterday) != nil, "band A's load for yesterday")
        await model.selectDevice(band("B-1", .standardHeartRate, name: "Strap B"))
        #expect(model.today?.latestHeartRate == nil, "control: live screens already show only band B")
        #expect(trendValue(model, Adv.yesterday) == nil,
                "band B recorded nothing yesterday, but its trend shows \(String(describing: trendValue(model, Adv.yesterday)))")
    }

    // MARK: Background

    // [BUG] ARCHITECTURE §7: on a background wake Forma "parses the frames, commits one short SQLite transaction
    // inside beginBackgroundTask, and returns … Analytics never run on a background wake." After
    // sceneEnteredBackground(), sync updates (disconnect, history stopped/complete) still schedule a full
    // recomputation of every screen (including derived-cache writes).
    @Test("[BUG] No screen recomputation runs after the scene entered the background")
    func noAnalyticsAfterEnteringTheBackground() async throws {
        let (model, _, _, _) = await make()
        await model.refreshNow()
        try #require(model.today?.latestHeartRate == nil)
        try Adv.ingestHR(try #require(model.liveStore), "P-1", from: Adv.now - 30_000, to: Adv.now, every: 1_000, bpm: 64)
        model.sceneEnteredBackground()
        model.apply(.disconnected(reason: "out of range", at: Adv.now))
        model.apply(.historyStopped(reason: "Disconnected during history transfer", at: Adv.now))
        model.apply(.historyComplete(at: Adv.now))
        try await Task.sleep(nanoseconds: 300_000_000)
        await model.refreshTask?.value
        #expect(model.today?.latestHeartRate == nil, "screens were recomputed while in the background")
        await model.sceneBecameActive()
        #expect(model.today?.latestHeartRate?.bpm == 64, "control: returning to the foreground recomputes")
    }

    // MARK: Field validation in the app

    /// KNOWN_LIMITATIONS: history HR stays out of metrics until it agrees with live HR for ≥ 10 minutes on
    /// your firmware; a firmware change requires validating again.
    @Test func historyHeartRateIsUsedOnlyAfterItAgreesOnThisFirmware() async throws {
        let (model, _, _, _) = await make()
        await model.selectDevice(band("W-1"))
        model.apply(.deviceInformation(field: "firmware", value: "2.0"))
        model.currentAdapter = Whoop5Adapter()
        let store = try #require(model.liveStore)
        try Adv.ingestHR(store, "W-1", from: Adv.now - 30 * Adv.minute, to: Adv.now - 10 * Adv.minute, every: 5_000, bpm: 63,
                         source: .deviceHistory, quality: [.unvalidatedField], firmware: "2.0", adapter: "forma.whoop5")
        try Adv.ingestHR(store, "W-1", from: Adv.now - 30 * Adv.minute, to: Adv.now - 15 * Adv.minute, every: 2_000, bpm: 62,
                         firmware: "2.0", adapter: "forma.whoop5")
        await model.refreshNow()
        #expect(model.today?.latestHeartRate?.bpm == 62, "unvalidated band history must not be shown")
        await model.validateHistoryHeartRate()
        #expect(model.diagnostics.checks.first { $0.id == "fieldAgreement" }?.status == .passed)
        await model.refreshNow()
        #expect(model.today?.latestHeartRate?.bpm == 63)
        model.apply(.deviceInformation(field: "firmware", value: "2.1"))
        await model.refreshNow()
        #expect(model.today?.latestHeartRate?.bpm == 62, "a firmware update requires validating again")
    }

    @Test func disagreeingHistoryIsKeptOutOfMetrics() async throws {
        let (model, _, _, _) = await make()
        await model.selectDevice(band("W-1"))
        model.currentAdapter = Whoop5Adapter()
        let store = try #require(model.liveStore)
        try Adv.ingestHR(store, "W-1", from: Adv.now - 30 * Adv.minute, to: Adv.now - 10 * Adv.minute, every: 5_000, bpm: 151,
                         source: .deviceHistory, quality: [.unvalidatedField], adapter: "forma.whoop5")
        try Adv.ingestHR(store, "W-1", from: Adv.now - 30 * Adv.minute, to: Adv.now - 15 * Adv.minute, every: 2_000, bpm: 60)
        await model.validateHistoryHeartRate()
        #expect(model.diagnostics.checks.first { $0.id == "fieldAgreement" }?.status == .failed)
        await model.refreshNow()
        #expect(model.today?.latestHeartRate?.bpm == 60)
    }

    // [BUG] FieldValidator: a passed validation is recorded "per adapter and firmware: a firmware change requires
    // validating again"; CONTEXT: unvalidated decoded fields are never used in metrics until validated. Once
    // firmware 2.0 passes, ScreenLoader admits *all* band-history heart rate of the device, including values
    // decoded under firmware 1.0, which never passed (here a bogus 151 bpm "resting" night).
    @Test("[BUG] Passing validation on new firmware does not release values decoded under old firmware")
    func validationOnNewFirmwareDoesNotReleaseOldFirmwareValues() async throws {
        let (model, _, _, _) = await make()
        await model.selectDevice(band("W-1"))
        model.apply(.deviceInformation(field: "firmware", value: "2.0"))
        model.currentAdapter = Whoop5Adapter()
        let store = try #require(model.liveStore)
        let old = TimeRange(start: Adv.now - 6 * Adv.hour, end: Adv.now - 5 * Adv.hour)
        try Adv.ingestHR(store, "W-1", from: old.start, to: old.end, every: 5_000, bpm: 151,
                         source: .deviceHistory, quality: [.unvalidatedField], firmware: "1.0", adapter: "forma.whoop5")
        try Adv.ingestHR(store, "W-1", from: Adv.now - 30 * Adv.minute, to: Adv.now - 10 * Adv.minute, every: 5_000, bpm: 62,
                         source: .deviceHistory, quality: [.unvalidatedField], firmware: "2.0", adapter: "forma.whoop5")
        try Adv.ingestHR(store, "W-1", from: Adv.now - 30 * Adv.minute, to: Adv.now - 10 * Adv.minute, every: 2_000, bpm: 62,
                         firmware: "2.0", adapter: "forma.whoop5")
        await model.validateHistoryHeartRate()
        try #require(model.diagnostics.checks.first { $0.id == "fieldAgreement" }?.status == .passed)
        await model.addManualSleep(range: old)
        let night = try #require(model.sleep?.nights.first { $0.session.range == old })
        #expect(night.heartRate.points.isEmpty, "firmware-1.0 values are charted: \(night.heartRate.points.prefix(3).map(\.value))")
        #expect(night.restingHR.value == nil, "resting HR \(String(describing: night.restingHR.value)) from never-validated firmware-1.0 data")
    }

    // MARK: Diagnostics honesty

    /// PRD: raw-frame capture is off by default; the compatibility test captures only while it runs and runs
    /// history only if the user enabled it.
    @Test func rawCaptureIsOffByDefaultAndRestoredAfterTheCompatibilityTest() async throws {
        let (model, _, _, _) = await make()
        #expect(model.diagnostics.captureEnabled == false)
        #expect(try #require(model.liveStore).rawCaptureEnabled() == false)
        await model.selectDevice(band("W-1"))
        await model.runCompatibilityTest(seconds: 0)
        #expect(model.diagnostics.captureEnabled == false)
        #expect(try #require(model.liveStore).rawCaptureEnabled() == false)
        let history = try #require(model.diagnostics.checks.first { $0.id == "history" })
        #expect(history.status == .notApplicable && history.detail.contains("off"))
        let connect = try #require(model.diagnostics.checks.first { $0.id == "connect" })
        #expect(connect.status == .failed, "no connection happened in the window")
        #expect(!model.isRunningCompatibilityTest)
    }

    // [BUG][low] finishChecks() always writes "The identification request was sent; …" for the "Identify band"
    // check, also when no command was sent at all (status notApplicable). Diagnostics are the hardware-validation
    // record, so they must not claim a command was written when it was not.
    @Test("[BUG] The compatibility test does not claim the identify request was sent when nothing was sent")
    func compatibilityTestDoesNotClaimAnUnsentCommand() async throws {
        let (model, _, _, _) = await make()
        await model.selectDevice(band("W-1"))
        await model.runCompatibilityTest(seconds: 0)
        #expect(model.diagnostics.counters.commandsSent == 0)
        let hello = try #require(model.diagnostics.checks.first { $0.id == "hello" })
        #expect(!hello.detail.lowercased().contains("was sent"), "\(hello.status): \(hello.detail)")
    }

    // [BUG][low] apply(.historyComplete) always records "History transferred, saved, then acknowledged.", also for a
    // transfer in which the band sent nothing and nothing was acknowledged (SyncEngine emits historyComplete for a
    // bare complete marker). The hardware checklist relies on this line to learn whether acknowledgement works.
    @Test("[BUG] An empty history transfer is not reported as saved and acknowledged")
    func emptyHistoryTransferIsNotReportedAsAcknowledged() async throws {
        let (model, _, _, _) = await make()
        model.apply(.historyStarted(at: Adv.now - 5_000))
        model.apply(.historyComplete(at: Adv.now))
        let check = try #require(model.diagnostics.checks.first { $0.id == "history" })
        #expect(!check.detail.contains("saved, then acknowledged"), "\(check.status): \(check.detail)")
    }

    /// PRD §3: never defeat pairing — a pairing requirement is surfaced to the user, not worked around.
    @Test func pairingRequirementIsSurfacedNeverWorkedAround() async throws {
        let (model, central, _, _) = await make()
        await model.selectDevice(band("W-1"))
        let before = central.calls
        model.apply(.pairingRequired)
        #expect(model.alertMessage?.contains("pairing") == true)
        model.handle(.pairingProblem("Pairing was declined."))
        #expect(model.alertMessage == "Pairing was declined.")
        #expect(central.calls == before, "no reconnect/forget/scan to get around pairing")
    }

    // MARK: Persistence plumbing

    /// ARCHITECTURE §4/§7: writes run inside the platform's protected (background-task) helper, and a failed
    /// write propagates so SyncEngine never acknowledges unsaved history.
    @Test func protectedSinkWrapsWritesAndPropagatesFailures() throws {
        let platform = AdvPlatform()
        let store = try Adv.store()
        let sink = ProtectedSink(store: store, platform: platform)
        let batch = IngestBatch(provenance: Adv.provenance("band", .standardHeartRateService),
                                heartRates: Adv.heartRates("band", from: Adv.now - 10_000, to: Adv.now, every: 1_000, bpm: 60))
        #expect(try sink.ingest(batch).inserted == 10)
        try sink.upsertDevice(DeviceRecord(id: "band", family: .standardHeartRate, name: "Band", firstSeen: Adv.now))
        try sink.recordConnectionEvent(ConnectionEvent(deviceID: "band", timestamp: Adv.now, kind: .connected))
        try sink.recordRawFrame(RawFrameRecord(deviceID: "band", receivedAt: Adv.now, characteristic: "2A37", bytes: Data([6, 60]), parseStatus: "ok"))
        let runID = try sink.beginSyncRun(SyncRunRecord(deviceID: "band", startedAt: Adv.now, status: .running))
        try sink.finishSyncRun(SyncRunRecord(id: runID, deviceID: "band", startedAt: Adv.now, endedAt: Adv.now, status: .completed))
        #expect(Set(platform.protectedNames).isSuperset(of: ["forma.ingest", "forma.device", "forma.event", "forma.raw", "forma.run"]))
        store.close()
        #expect(throws: (any Error).self) { try sink.ingest(batch) }
    }

    /// PRIVACY: local-only by default — the exclusion is re-applied every time the database is opened, and the
    /// database files are protected.
    @Test func backupsAreExcludedAndFilesProtectedOnOpen() async throws {
        let dir = Adv.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let platform = AdvPlatform(directory: dir, backupsIncluded: true)
        let (model, _, _, _) = await make(platform: platform)
        #expect(platform.backupCalls.first == false)
        #expect(!platform.isIncludedInBackups())
        #expect(!model.includeInDeviceBackups)
        #expect(platform.protectedPaths.contains(dir.appendingPathComponent("forma.sqlite").path))
    }

    // MARK: Live signal

    /// PRD §6.1: the screen says so when nothing is arriving instead of showing a stale number as live;
    /// short workouts are not saved; link, sync and live state stay separate.
    @Test func liveSignalStalenessDisconnectAndWorkouts() async throws {
        let (model, _, _, clock) = await make()
        await model.selectDevice(band("P-1", .standardHeartRate))
        model.handle(.stateChanged(.connected))
        model.apply(.liveHeartRate(bpm: 71, at: clock.now(), source: .standardHeartRateService))
        #expect(model.connection.liveStreaming && model.connection.shortStatus == "Live")
        clock.advance(byMillis: 16_000)
        model.tick()
        #expect(!model.connection.liveStreaming && model.connection.shortStatus == "Connected")

        await model.startWorkout()
        model.apply(.liveHeartRate(bpm: 150, at: clock.now(), source: .standardHeartRateService))
        model.tick()
        #expect(model.activity?.live?.currentHR == 150)
        clock.advance(byMillis: 20_000)
        model.tick()
        #expect(model.activity?.live?.currentHR == nil && model.activity?.live?.signalStale == true)
        clock.advance(byMillis: 20_000)
        await model.stopWorkout(save: true) // 40 s: too short to save
        let store = try #require(model.liveStore)
        #expect(try store.sessions(kind: .workout).isEmpty)
        await model.startWorkout()
        clock.advance(byMillis: 10 * Adv.minute)
        await model.stopWorkout(save: true)
        #expect(try store.sessions(kind: .workout).map(\.origin) == [.manual])

        model.apply(.historyStarted(at: clock.now()))
        #expect(model.connection.shortStatus == "Syncing")
        model.apply(.disconnected(reason: "out of range", at: clock.now()))
        #expect(model.connection.link == .searching && model.connection.sync == .idle && !model.connection.liveStreaming)
    }

    // MARK: Sleep review

    /// PRD §4/§6.2: candidates come from motion (unvalidated motion only after the user allows it), and a
    /// candidate the user rejected is never proposed again for the same night.
    @Test func rejectedCandidateIsNeverProposedAgain() async throws {
        let (model, _, _, _) = await make()
        await model.selectDevice(band("W-1"))
        let store = try #require(model.liveStore)
        _ = try store.ingest(IngestBatch(provenance: Adv.provenance("W-1", .deviceHistory, adapter: "forma.whoop5"),
                                         motion: Adv.nightMotion("W-1", nightEndingOn: Adv.today, quality: [.unvalidatedField])))
        await model.refreshNow()
        #expect(model.sleep?.nights.isEmpty == true, "no candidate from unvalidated motion without the opt-in")
        await model.setAllowUnvalidatedMotion(true)
        let candidate = try #require(model.sleep?.nights.first { $0.isCandidate }?.session)
        #expect(model.today?.pendingSleepReview?.id == candidate.id)
        await model.rejectSleep(candidate)
        #expect(model.sleep?.nights.isEmpty == true)
        await model.refreshNow()
        await model.refreshNow()
        #expect(model.sleep?.nights.isEmpty == true, "a rejected night was proposed again")
        #expect(model.today?.pendingSleepReview == nil)
    }
}
