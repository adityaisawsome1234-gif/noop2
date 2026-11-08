import Foundation
import Observation
import FormaCore
import FormaProtocol
import FormaSync
import FormaStore
import FormaAnalytics

public enum AppTab: Hashable, Sendable {
    case today, sleep, activity, trends
}

public enum AppModelError: Error, CustomStringConvertible {
    case storeUnavailable

    public var description: String { "The database is not available." }
}

/// The app's single source of truth for UI state and actions. Platform-independent: Bluetooth arrives
/// through `BandCentral`, iOS services through `PlatformServices`, so everything here is unit-tested
/// off-device. Views render its published state; heavy work runs off the main actor.
@MainActor
@Observable
public final class AppModel {
    // MARK: Dependencies
    @ObservationIgnored let central: any BandCentral
    @ObservationIgnored let platform: any PlatformServices
    @ObservationIgnored let timeSource: any TimeSource
    public let calendar: Calendar

    // MARK: Stores (live and demo never mix)
    @ObservationIgnored var liveStore: FormaStore?
    @ObservationIgnored var demoStore: FormaStore?
    var store: FormaStore? { isDemo ? demoStore : liveStore }

    // MARK: Sync
    @ObservationIgnored var engine: SyncEngine?
    @ObservationIgnored var engineTasks: [Task<Void, Never>] = []
    @ObservationIgnored let recorder = CaptureRecorder(maxEntries: 50_000)
    @ObservationIgnored var currentAdapter: (any DeviceAdapter)?
    @ObservationIgnored var tickTask: Task<Void, Never>?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var lastPersistenceAlert: EpochMillis = 0

    // MARK: Published UI state
    public internal(set) var now: EpochMillis
    public var selectedTab: AppTab = .today
    public var showDeviceHub = false
    public var showSettings = false
    public var alertMessage: String?
    public internal(set) var onboardingComplete: Bool
    public internal(set) var isDemo: Bool
    public internal(set) var connection = ConnectionSummary()
    public internal(set) var today: TodayState?
    public internal(set) var sleep: SleepState?
    public internal(set) var activity: ActivityState?
    public internal(set) var trends: TrendsState?
    public internal(set) var trendMetric: TrendMetric = .restingHR
    public internal(set) var trendPeriod: TrendPeriod = .days30
    public internal(set) var diagnostics = DiagnosticsState()
    public internal(set) var discoveredDevices: [DiscoveredDevice] = []
    @ObservationIgnored var advertisements: [String: [String: String]] = [:]
    public internal(set) var isScanning = false
    public internal(set) var bluetoothProblemMessage: String?
    public internal(set) var selectedDevice: DeviceRecord?
    public internal(set) var collectionEnabled: Bool
    public internal(set) var liveHeartRateEnabled: Bool
    public internal(set) var historySyncMode: HistorySyncMode = .off
    public internal(set) var connectionEvents: [ConnectionEvent] = []
    public internal(set) var isRunningCompatibilityTest = false
    public internal(set) var profile = UserProfile()
    public internal(set) var zoneMethod: ZoneMethodChoice = .percentOfMax
    public internal(set) var showExperimentalReadiness = true
    public internal(set) var appearance: AppearancePreference
    public internal(set) var includeInDeviceBackups: Bool
    public internal(set) var rawRetentionDays: Int
    public internal(set) var allowUnvalidatedMotion = false
    public let metricSpecs: [MetricSpec] = MetricCatalog.all

    // Live workout
    public internal(set) var liveWorkoutStart: EpochMillis?
    @ObservationIgnored var liveWorkoutSamples: [HeartRateSample] = []
    @ObservationIgnored var lastLiveSource: MeasurementSource?

    // MARK: Init

    public init(central: any BandCentral, platform: any PlatformServices, timeSource: any TimeSource = SystemTimeSource(),
                calendar: Calendar = .current) {
        self.central = central
        self.platform = platform
        self.timeSource = timeSource
        self.calendar = calendar
        self.now = timeSource.now()
        self.onboardingComplete = platform.preference("onboardingComplete") == "1"
        self.isDemo = platform.preference("demo") == "1"
        self.collectionEnabled = platform.preference("collectionEnabled") != "0"
        self.liveHeartRateEnabled = platform.preference("liveHeartRate") != "0"
        self.appearance = AppearancePreference(rawValue: platform.preference("appearance") ?? "") ?? .system
        self.includeInDeviceBackups = platform.preference("includeInBackups") == "1"
        self.rawRetentionDays = Int(platform.preference("rawRetentionDays") ?? "") ?? 7
        openStores()
        loadSettingsFromStore()
        central.setEventHandler { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        if let id = central.savedPeripheralID, let device = try? liveStore?.device(id: id) {
            selectedDevice = device
            connection.deviceName = device.name
            connection.family = device.family
            connection.link = .searching
            if collectionEnabled && !isDemo { central.connectSelected(profile: Self.connectionProfile) }
        }
        connection.isDemo = isDemo
        startTicking()
        scheduleRefresh()
    }

    // MARK: Stores & settings

    func openStores() {
        do {
            if let path = try platform.databasePath(demo: false) {
                liveStore = try FormaStore(path: path, timeSource: timeSource, rawFrameRetention: retention)
                platform.protectDatabase(at: path)
            } else {
                liveStore = try FormaStore(path: nil, timeSource: timeSource, rawFrameRetention: retention)
            }
            try platform.setIncludedInBackups(includeInDeviceBackups) // re-applied on every open
        } catch {
            alertMessage = "Forma could not open its database: \(error)"
        }
        if isDemo { openDemoStore() }
    }

    var retention: RawFrameRetention {
        RawFrameRetention(maxAgeMillis: Int64(rawRetentionDays) * EpochMillis.millisPerDay, maxFrames: 200_000, maxTotalBytes: 64 * 1_024 * 1_024)
    }

    func openDemoStore() {
        guard demoStore == nil else { return }
        do {
            let path = try platform.databasePath(demo: true)
            demoStore = try FormaStore(path: path, timeSource: timeSource)
            if let path { platform.protectDatabase(at: path) }
        } catch {
            alertMessage = "Demo data could not be opened: \(error)"
        }
    }

    func loadSettingsFromStore() {
        guard let s = liveStore else { return }
        profile = (try? s.userProfile()) ?? UserProfile()
        historySyncMode = HistorySyncMode(rawValue: (try? s.setting(forKey: "historySyncMode")) ?? "" ) ?? .off
        zoneMethod = ZoneMethodChoice(rawValue: (try? s.setting(forKey: "zoneMethod")) ?? "") ?? .percentOfMax
        showExperimentalReadiness = ((try? s.setting(forKey: "showReadiness")) ?? "1") == "1"
        allowUnvalidatedMotion = ((try? s.setting(forKey: "allowUnvalidatedMotion")) ?? "0") == "1"
        diagnostics.captureEnabled = (try? s.rawCaptureEnabled()) ?? false
    }

    func setStoreSetting(_ value: String, _ key: String) {
        do { try liveStore?.setSetting(value, forKey: key) } catch { alertMessage = "Saving a setting failed: \(error)" }
    }

    /// Union GATT profile used to connect before the band's family is confirmed: discover everything,
    /// subscribe to every characteristic any adapter needs; the adapter is chosen from discovered services.
    public static var connectionProfile: GATTProfile {
        let adapters = AdapterRegistry.all
        var subscribe: [String] = []
        for a in adapters { for c in a.gatt.subscribeCharacteristics where !subscribe.contains(c) { subscribe.append(c) } }
        return GATTProfile(vendorService: nil, discoverServices: [], subscribeCharacteristics: subscribe,
                           commandCharacteristic: nil, commandWriteWithResponse: true,
                           scanServiceFilter: adapters.flatMap { $0.gatt.scanServiceFilter }, nameHints: ["WHOOP"])
    }

    // MARK: Ticking & refresh

    func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await MainActor.run(body: { () -> UInt64? in
                    guard let self else { return nil }
                    return self.liveWorkoutStart == nil ? 15 : 1
                }) else { return }
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                await MainActor.run { self?.tick() }
            }
        }
    }

    func tick() {
        now = timeSource.now()
        if let last = connection.lastDeviceSample, now - last > 15_000, connection.liveStreaming {
            connection.liveStreaming = false
        }
        if liveWorkoutStart != nil { updateLiveWorkout() }
    }

    /// Recomputes all screens off the main actor. Coalesces overlapping requests.
    public func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshNow()
        }
    }

    public func refresh(requestSync: Bool) async {
        if requestSync, historySyncMode != .off { await syncNow() }
        await refreshNow()
    }

    func loaderContext() -> LoaderContext? {
        guard let store else { return nil }
        let adapter = currentAdapter ?? selectedDevice.flatMap { AdapterRegistry.adapter(for: $0.family) }
        let caps = adapter?.capabilities ?? [:]
        let demo = isDemo
        let validatedKey = FieldValidator.historyHeartRateKey(adapterID: adapter?.adapterID ?? "none", firmware: selectedDevice?.firmwareVersion)
        let historyValidated = ((try? liveStore?.setting(forKey: validatedKey)) ?? nil) == "passed"
        return LoaderContext(
            store: store, calendar: calendar, now: timeSource.now(), profile: profile,
            zoneModel: zoneMethod == .heartRateReserve ? .heartRateReserve : .percentMax,
            showReadiness: showExperimentalReadiness, deviceID: demo ? nil : selectedDevice?.id,
            bandKeepsHistory: !demo && historySyncMode != .off && (caps[.history] ?? .unsupported) != .unsupported,
            beatIntervalsSupported: demo || (caps[.beatIntervals] ?? .unsupported) != .unsupported
                || (caps[.standardHeartRate] ?? .unsupported) != .unsupported,
            motionSupported: demo || (caps[.motion] ?? .unsupported) != .unsupported,
            motionNeedsValidation: !demo && caps[.motion] == .candidateUnvalidated,
            historyHeartRateValidated: historyValidated,
            allowUnvalidatedMotion: allowUnvalidatedMotion)
    }

    public func refreshNow() async {
        guard let ctx = loaderContext() else { return }
        let metric = trendMetric
        let period = trendPeriod
        let live = liveWorkoutStart.map { start in
            ScreenLoader.liveWorkout(ctx, start: start, recentSamples: liveWorkoutSamples, sourceLabel: lastLiveSource?.description)
        }
        let selected = selectedDevice
        // Propose a sleep candidate for last night (only when motion data may be used).
        if let candidate = try? ScreenLoader.proposeSleepCandidate(ctx, nightEndingOn: LocalDay(ctx.now, calendar: calendar)) {
            _ = try? ctx.store.insertSession(candidate)
        }
        let result = await Task.detached(priority: .userInitiated) { () -> (TodayState?, SleepState?, ActivityState?, TrendsState?, String?, EpochMillis?, EpochMillis?) in
            do {
                let t = try ScreenLoader.today(ctx)
                let s = try ScreenLoader.sleep(ctx)
                let a = try ScreenLoader.activity(ctx, live: live)
                let tr = try ScreenLoader.trends(ctx, metric: metric, period: period)
                let newest = try ctx.store.newestSampleTime(deviceID: ctx.deviceID)
                let lastSync = try selected.flatMap { try ctx.store.syncCursor(deviceID: $0.id)?.lastCompleteSyncAt }
                return (t, s, a, tr, nil, newest, lastSync)
            } catch {
                return (nil, nil, nil, nil, "\(error)", nil, nil)
            }
        }.value
        if Task.isCancelled { return }
        if let error = result.4 { alertMessage = "Loading data failed: \(error)"; return }
        today = result.0
        sleep = result.1
        activity = result.2
        trends = result.3
        if let newest = result.5 { connection.lastDeviceSample = max(newest, connection.lastDeviceSample ?? newest) }
        if let lastSync = result.6 { connection.lastCompletedSync = lastSync }
        now = timeSource.now()
    }

    public func sceneBecameActive() async {
        now = timeSource.now()
        if collectionEnabled, !isDemo, selectedDevice != nil, connection.link != .connected {
            central.connectSelected(profile: Self.connectionProfile)
        }
        await refreshNow()
    }

    public func sceneEnteredBackground() {
        // Nothing heavy in the background: Bluetooth notifications keep being persisted by the engine.
    }

    // MARK: Onboarding & preferences

    public func completeOnboarding() {
        onboardingComplete = true
        platform.setPreference("1", forKey: "onboardingComplete")
        scheduleRefresh()
    }

    /// Creating the central triggers the system Bluetooth prompt on first use; a scan re-checks state.
    public func requestBluetooth() {
        central.startScan(includeUnfiltered: false)
        central.stopScan()
    }

    public func setAppearance(_ value: AppearancePreference) {
        appearance = value
        platform.setPreference(value.rawValue, forKey: "appearance")
    }

    public func setProfile(_ p: UserProfile) async {
        profile = p
        do { try liveStore?.setUserProfile(p) } catch { alertMessage = "Saving the profile failed: \(error)" }
        invalidateAllDerived()
        await refreshNow()
    }

    public func setZoneMethod(_ m: ZoneMethodChoice) async {
        zoneMethod = m
        setStoreSetting(m.rawValue, "zoneMethod")
        await refreshNow()
    }

    public func setShowExperimentalReadiness(_ on: Bool) async {
        showExperimentalReadiness = on
        setStoreSetting(on ? "1" : "0", "showReadiness")
        await refreshNow()
    }

    public func setAllowUnvalidatedMotion(_ on: Bool) async {
        allowUnvalidatedMotion = on
        setStoreSetting(on ? "1" : "0", "allowUnvalidatedMotion")
        invalidateAllDerived()
        await refreshNow()
    }

    public func setIncludeInDeviceBackups(_ on: Bool) {
        do {
            try platform.setIncludedInBackups(on)
            includeInDeviceBackups = on
            platform.setPreference(on ? "1" : "0", forKey: "includeInBackups")
        } catch {
            alertMessage = "Changing the backup setting failed: \(error)"
        }
    }

    public func setRawRetentionDays(_ days: Int) {
        rawRetentionDays = max(1, min(30, days))
        platform.setPreference(String(rawRetentionDays), forKey: "rawRetentionDays")
    }

    public func setTrend(metric: TrendMetric) async {
        trendMetric = metric
        await refreshNow()
    }

    public func setTrend(period: TrendPeriod) async {
        trendPeriod = period
        await refreshNow()
    }

    public func specID(for metric: TrendMetric) -> String { ScreenLoader.specID(for: metric) }

    func invalidateAllDerived() {
        _ = try? store?.invalidateDerived(overlapping: TimeRange(start: 0, end: Int64.max / 2))
    }
}
