import Foundation
import Testing
import FormaCore
import FormaProtocol
import FormaSync
import FormaStore
@testable import FormaFeatures

final class FakeCentral: BandCentral, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (CentralEvent) -> Void)?
    private(set) var calls: [String] = []
    var saved: String?

    func record(_ c: String) { lock.withLock { calls.append(c) } }
    func connectSelected(profile: GATTProfile) { record("connect") }
    func disconnect() { record("disconnect") }
    func select(peripheralID: String, profile: GATTProfile) { record("select:\(peripheralID)"); saved = peripheralID }
    func forgetSelected() { record("forget"); saved = nil }
    func startScan(includeUnfiltered: Bool) { record("scan:\(includeUnfiltered)") }
    func stopScan() { record("stopScan") }
    var savedPeripheralID: String? { saved }
    func setEventHandler(_ handler: @escaping @Sendable (CentralEvent) -> Void) { lock.withLock { self.handler = handler } }
    func fire(_ e: CentralEvent) { lock.withLock { handler }?(e) }
}

final class TestPlatform: PlatformServices, @unchecked Sendable {
    private let lock = NSLock()
    private var prefs: [String: String] = [:]
    var backupsIncluded = false
    func databasePath(demo: Bool) throws -> String? { nil }
    func protectDatabase(at path: String) {}
    func setIncludedInBackups(_ included: Bool) throws { backupsIncluded = included }
    func isIncludedInBackups() -> Bool { backupsIncluded }
    func makeStagingDirectory() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("forma-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func archiveDirectory(_ url: URL) throws -> Data {
        var out = Data()
        for f in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
            out.append(Data("== \(f)\n".utf8))
            out.append(try Data(contentsOf: url.appendingPathComponent(f)))
        }
        return out
    }
    func runProtected<T: Sendable>(_ name: String, _ body: () throws -> T) rethrows -> T { try body() }
    var appVersion: String { "test" }
    var osVersion: String { "linux" }
    func preference(_ key: String) -> String? { lock.withLock { prefs[key] } }
    func setPreference(_ value: String?, forKey key: String) { lock.withLock { prefs[key] = value } }
}

@MainActor
@Suite(.serialized) struct AppModelTests {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func makeModel(now: EpochMillis = 1_762_596_000_000) -> (AppModel, FakeCentral, TestPlatform, ManualTimeSource) {
        let central = FakeCentral()
        let platform = TestPlatform()
        let clock = ManualTimeSource(now)
        let model = AppModel(central: central, platform: platform, timeSource: clock, calendar: Self.calendar)
        return (model, central, platform, clock)
    }

    @Test func freshInstallShowsEmptyHonestState() async {
        let (model, _, _, _) = makeModel()
        await model.refreshNow()
        #expect(model.connection.link == .noDeviceSelected)
        #expect(model.today?.hasAnyData == false)
        #expect(model.today?.latestHeartRate == nil)
        #expect(model.metricSpecs.count >= 10)
    }

    @Test func demoDataNeverMixesWithLiveData() async {
        let (model, central, _, _) = makeModel()
        await model.enterDemo()
        #expect(model.isDemo && model.connection.isDemo)
        #expect(model.today?.hasAnyData == true)
        #expect(central.calls.contains("disconnect"))
        await model.exitDemo()
        #expect(!model.isDemo)
        #expect(model.today?.hasAnyData == false, "the live store must stay empty after demo mode")
    }

    @Test func liveStandardHeartRateFlowsThroughEngineIntoTheStore() async throws {
        let (model, central, _, clock) = makeModel()
        let device = DiscoveredDevice(id: "P-1", name: "WHOOP 5.0", rssi: -60, family: .whoop5, advertisedServiceUUIDs: [],
                                      manufacturerDataHex: nil, connectedToThisPhone: false, lastSeen: clock.now())
        await model.selectDevice(device)
        #expect(central.calls.contains("select:P-1") && central.calls.contains("connect"))
        let t0 = clock.now()
        let entries = (0..<30).map { i in CaptureEntry(t: t0 - 30_000 + Int64(i) * 1_000, dir: .rx, c: "2A37", d: "16" + String(format: "%02x", 60 + i % 5) + "0004") }
        let link = ReplayLink(peripheralID: "P-1", entries: entries,
                              services: [UUIDs.heartRateService: [UUIDs.heartRateMeasurement]])
        central.fire(.linkReady(link, services: [GATTServiceSummary(uuid: UUIDs.heartRateService, name: "Heart Rate", characteristics: [])]))
        // Let the engine drain the replay.
        for _ in 0..<100 { await Task.yield() }
        try await Task.sleep(nanoseconds: 300_000_000)
        await model.refreshNow()
        #expect(model.today?.hasAnyData == true)
        #expect(model.today?.latestHeartRate.map { (60...64).contains($0.bpm) } == true)
        #expect(model.diagnostics.counters.standardHRNotifications == 30)
        #expect(model.diagnostics.counters.standardHRWithRR == 30)
        #expect(model.diagnostics.checks.first { $0.id == "connect" }?.status == .passed)
    }

    @Test func sleepCorrectionsRecomputeAndRejectsSoftDelete() async throws {
        let (model, _, _, clock) = makeModel()
        let range = TimeRange(start: clock.now() - 9 * 3_600_000, end: clock.now() - 1 * 3_600_000)
        await model.addManualSleep(range: range)
        let night = try #require(model.sleep?.nights.first)
        #expect(night.session.origin == .manual)
        await model.updateSleep(night.session, range: TimeRange(start: range.start + 1_800_000, end: range.end))
        #expect(model.sleep?.nights.first?.session.range.start == range.start + 1_800_000)
        await model.rejectSleep(try #require(model.sleep?.nights.first?.session))
        #expect(model.sleep?.nights.isEmpty == true)
    }

    @Test func backupRoundTripAndDeleteAll() async throws {
        let (model, _, _, _) = makeModel()
        await model.enterDemo()
        let backup = try await model.exportBackup()
        #expect(String(decoding: backup.prefix(200), as: UTF8.self).contains("forma-backup"))
        let csv = try await model.exportCSVArchive()
        #expect(String(decoding: csv, as: UTF8.self).contains("hr_samples.csv"))
        await model.exitDemo()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("forma-\(UUID().uuidString).jsonl")
        try backup.write(to: url)
        let report = await model.importBackup(from: url)
        #expect(report.hasPrefix("Imported"))
        await model.refreshNow()
        #expect(model.today?.hasAnyData == true)
        let again = await model.importBackup(from: url)
        #expect(again.contains("Imported 0 records"), "re-import must not duplicate: \(again)")
        let message = await model.deleteAllData()
        #expect(message.contains("deleted"))
        #expect(model.today?.hasAnyData == false)
    }

    @Test func settingsPersistAndHistoryRequiresExplicitChoice() async {
        let (model, _, platform, _) = makeModel()
        #expect(model.historySyncMode == .off, "history acknowledgement must be opt-in")
        await model.setHistorySyncMode(.manual)
        await model.setProfile(UserProfile(birthYear: 1990, sex: .female, maxHeartRateOverride: 185))
        model.setIncludeInDeviceBackups(true)
        #expect(platform.backupsIncluded)
        #expect(model.profile.maxHeartRateOverride == 185)
    }
}
