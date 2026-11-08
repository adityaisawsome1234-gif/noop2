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

/// Keys of the settings the app model keeps in the live store's `setting` table.
enum SettingKey {
    static let historySyncMode = "historySyncMode"
    static let zoneMethod = "zoneMethod"
    static let showReadiness = "showReadiness"
    static let allowUnvalidatedMotion = "allowUnvalidatedMotion"
    /// Experimental consent to acknowledge saved history chunks to the band.
    static let historyAcknowledgement = "historyAcknowledgement"

    /// Choices only the person using this iPhone may make — consent to download and acknowledge band
    /// history, opting in to unvalidated motion — and field-validation verdicts drawn from this phone's
    /// own evidence. A backup made elsewhere never sets them.
    static func isPerPhoneChoice(_ key: String) -> Bool {
        key == historySyncMode || key == historyAcknowledgement || key == allowUnvalidatedMotion
            || key.hasPrefix(FieldValidator.keyPrefix)
    }
}

/// Whether the UI scene is in the foreground. `unknown` until the platform reports a scene phase.
enum SceneActivity {
    case unknown, active, background
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
    /// Orders cached-value writes against invalidations, one gate per open store.
    @ObservationIgnored var liveCacheGate = DerivedCacheGate()
    @ObservationIgnored var demoCacheGate = DerivedCacheGate()
    /// Validation key of each band-history ingest batch of the live store.
    @ObservationIgnored var liveBatchKeys = BatchValidationKeyCache()
    var store: FormaStore? { isDemo ? demoStore : liveStore }

    // MARK: Sync
    @ObservationIgnored var engine: SyncEngine?
    @ObservationIgnored var engineTasks: [Task<Void, Never>] = []
    /// Incremented whenever an engine starts or stops: updates from an older engine are dropped.
    @ObservationIgnored var engineGeneration: UInt64 = 0
    /// Counters of earlier engines (each engine counts from zero), so the diagnostics counters only grow.
    @ObservationIgnored var countersBase = DiagnosticsCounters()
    @ObservationIgnored let recorder = CaptureRecorder(maxEntries: 50_000)
    @ObservationIgnored var currentAdapter: (any DeviceAdapter)?
    @ObservationIgnored var tickTask: Task<Void, Never>?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var latestHeartRateTask: Task<Void, Never>?
    @ObservationIgnored var lastLatestHeartRateQuery: EpochMillis?
    @ObservationIgnored var lastPersistenceAlert: EpochMillis = 0
    /// Numbers refreshes in the order they start. A refresh shows its result only if no newer refresh's
    /// result is already shown, so a slow refresh never overwrites newer state.
    @ObservationIgnored var refreshGeneration: UInt64 = 0
    @ObservationIgnored var appliedRefreshGeneration: UInt64 = 0
    /// Incremented by every switch of mode, store or band: results computed for an earlier context are
    /// dropped (so one mode's data never appears under the other mode's label).
    @ObservationIgnored var dataContextEpoch: UInt64 = 0
    /// Cancellation flags of refreshes still computing, by generation.
    @ObservationIgnored var inFlightRefreshes: [UInt64: CancellationFlag] = [:]
    @ObservationIgnored var sceneActivity: SceneActivity = .unknown
    @ObservationIgnored var refreshDeferredUntilActive = false
    /// Phone time of the last plausible live heart-rate update (drives `connection.liveStreaming`).
    @ObservationIgnored var lastLiveUpdateAt: EpochMillis?
    @ObservationIgnored var lastTimeZoneIdentifier: String
    /// Forma's recent overnight resting heart rate, for heart-rate-reserve zones in the live workout.
    @ObservationIgnored var overnightRestingHeartRate: Double?
    /// Span of band-history record times reported by the current transfer, not yet invalidated in the cache.
    @ObservationIgnored var historyRunRange: TimeRange?
    @ObservationIgnored var historyChunksAcknowledged = 0
    /// A history transfer ended: validate history heart rate automatically when next in the foreground.
    @ObservationIgnored var autoValidationPending = false
    /// The clock check of the current connection (the band clock is read once per connection), so a
    /// compatibility test started while connected still reports it.
    @ObservationIgnored var lastClockCheck: (status: CheckStatus, detail: String)?
    // Compatibility test observations
    @ObservationIgnored var testLiveReadingTimes: [EpochMillis] = []
    @ObservationIgnored var testCommandNames: [String] = []

    // MARK: Published UI state
    public internal(set) var now: EpochMillis
    public var selectedTab: AppTab = .today
    public var showDeviceHub = false
    public var showSettings = false
    public var alertMessage: String?
    public internal(set) var onboardingComplete: Bool
    public internal(set) var isDemo: Bool
    /// True while demo data is being generated (a few seconds, off the main actor).
    public internal(set) var isPreparingDemo = false
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
    /// Experimental and off by default; see `setHistoryAcknowledgement(_:)`.
    public internal(set) var historyAcknowledgementEnabled = false
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

    /// Live heart rate is "streaming" while updates arrive at least this often (phone time).
    static let liveStreamTimeoutMillis: Int64 = 15_000
    /// Preference set while Forma may have left the band's real-time stream on (it requested the stream
    /// and has not seen it switched off since), also across launches: the next engine then switches the
    /// stream off when nobody wants it.
    static let realtimeStreamPreferenceKey = "realtimeStreamRequested"

    // MARK: Init

    /// - Parameter calendar: defaults to the auto-updating current calendar, so day boundaries follow
    ///   the phone's time zone after travel (the model refreshes when the zone changes).
    public init(central: any BandCentral, platform: any PlatformServices, timeSource: any TimeSource = SystemTimeSource(),
                calendar: Calendar = .autoupdatingCurrent) {
        self.central = central
        self.platform = platform
        self.timeSource = timeSource
        self.calendar = calendar
        self.lastTimeZoneIdentifier = calendar.timeZone.identifier
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
            connection.link = idleLinkState()
            if collectionEnabled && !isDemo { central.connectSelected(profile: Self.connectionProfile) }
        }
        connection.isDemo = isDemo
        startTicking()
        scheduleRefresh()
    }

    // MARK: Stores & settings

    func openStores() {
        do {
            let path = try platform.databasePath(demo: false)
            liveStore = try FormaStore(path: path, timeSource: timeSource, rawFrameRetention: retention)
            if let path { platform.protectDatabase(at: path) }
            try platform.setIncludedInBackups(includeInDeviceBackups) // re-applied on every open
        } catch {
            alertMessage = "Forma could not open its database: \(error)"
        }
        liveCacheGate = DerivedCacheGate()
        liveBatchKeys = BatchValidationKeyCache()
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
            demoCacheGate = DerivedCacheGate()
        } catch {
            alertMessage = "Demo data could not be opened: \(error)"
        }
    }

    func loadSettingsFromStore() {
        guard let s = liveStore else { return }
        profile = (try? s.userProfile()) ?? UserProfile()
        historySyncMode = HistorySyncMode(rawValue: (try? s.setting(forKey: SettingKey.historySyncMode)) ?? "") ?? .off
        historyAcknowledgementEnabled = ((try? s.setting(forKey: SettingKey.historyAcknowledgement)) ?? nil) == "1"
        zoneMethod = ZoneMethodChoice(rawValue: (try? s.setting(forKey: SettingKey.zoneMethod)) ?? "") ?? .percentOfMax
        showExperimentalReadiness = ((try? s.setting(forKey: SettingKey.showReadiness)) ?? "1") == "1"
        allowUnvalidatedMotion = ((try? s.setting(forKey: SettingKey.allowUnvalidatedMotion)) ?? "0") == "1"
        diagnostics.captureEnabled = (try? s.rawCaptureEnabled()) ?? false
    }

    func setStoreSetting(_ value: String, _ key: String) {
        do { try liveStore?.setSetting(value, forKey: key) } catch { alertMessage = "Saving a setting failed: \(error)" }
    }

    /// Link state while no connection is up: "Searching" only when a connection was actually requested.
    func idleLinkState() -> LinkState {
        guard selectedDevice != nil else { return .noDeviceSelected }
        return collectionEnabled && !isDemo ? .searching : .disconnected(since: nil)
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
        // "Live" depends on when updates last arrived on this phone, not on stored sample times (which a
        // band clock can put in the future).
        if connection.liveStreaming {
            let recent = lastLiveUpdateAt.map { now - $0 <= Self.liveStreamTimeoutMillis } ?? false
            if !recent { connection.liveStreaming = false }
        }
        // The value on Today must never be presented as current once it is old.
        if var state = today, let latest = state.latestHeartRate {
            let stale = now - latest.at > ScreenLoader.liveThresholdMillis
            if stale != latest.isStale {
                state.latestHeartRate?.isStale = stale
                today = state
            }
        }
        if liveWorkoutStart != nil { updateLiveWorkout() }
        let zone = calendar.timeZone.identifier
        if zone != lastTimeZoneIdentifier {
            // Day boundaries moved (travel): recompute every screen in the new zone.
            lastTimeZoneIdentifier = zone
            scheduleRefresh()
        } else if connection.liveStreaming {
            refreshLatestHeartRate()
        }
    }

    /// Keeps Today's heart rate current between full refreshes while the band streams. Reads stored
    /// samples (which carry their quality flags), not the raw live updates.
    func refreshLatestHeartRate() {
        guard sceneActivity != .background, latestHeartRateTask == nil, today != nil else { return }
        if let last = lastLatestHeartRateQuery, now - last < 10_000 { return }
        guard let ctx = loaderContext() else { return }
        lastLatestHeartRateQuery = now
        let epoch = dataContextEpoch
        latestHeartRateTask = Task { [weak self] in
            let latest = await Task.detached(priority: .utility) { try? ScreenLoader.latestHeartRate(ctx) }.value
            // After a context switch the handle may already belong to a newer task.
            guard let self, epoch == self.dataContextEpoch else { return }
            self.latestHeartRateTask = nil
            guard let latest, var state = self.today else { return }
            if latest.at > (state.latestHeartRate?.at ?? Int64.min) {
                state.latestHeartRate = latest
                self.today = state
            }
        }
    }

    /// Recomputes all screens off the main actor. Coalesces overlapping requests. Until a UI scene is
    /// active — in the background, and after a launch before the first scene phase arrives (a Bluetooth
    /// relaunch has no scene at all) — nothing is computed; the refresh runs when the scene becomes active.
    public func scheduleRefresh() {
        refreshTask?.cancel()
        guard sceneActivity == .active else {
            refreshDeferredUntilActive = true
            return
        }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshNow()
        }
    }

    public func refresh(requestSync: Bool) async {
        if requestSync, historySyncMode != .off { await syncNow() }
        await refreshNow()
    }

    /// Starts showing another store, mode or band: refreshes still running are discarded, and nothing
    /// computed for the previous context stays on screen under the new label.
    func beginNewDataContext() {
        dataContextEpoch &+= 1
        for flag in inFlightRefreshes.values { flag.cancel() }
        refreshTask?.cancel()
        refreshTask = nil
        latestHeartRateTask?.cancel()
        latestHeartRateTask = nil
        today = nil
        sleep = nil
        activity = nil
        trends = nil
        overnightRestingHeartRate = nil
    }

    /// - Parameter resolveHistoryValidation: read which band-history heart rate passed validation (a
    ///   small settings read); the live workout, which uses in-memory samples only, skips it.
    func loaderContext(resolveHistoryValidation: Bool = true) -> LoaderContext? {
        guard let store else { return nil }
        let demo = isDemo
        let adapter: (any DeviceAdapter)? = demo ? nil : (currentAdapter ?? selectedDevice.flatMap { AdapterRegistry.adapter(for: $0.family) })
        let caps = adapter?.capabilities ?? [:]
        var ctx = LoaderContext(
            store: store, calendar: calendar, now: timeSource.now(), profile: profile,
            zoneModel: zoneMethod == .heartRateReserve ? .heartRateReserve : .percentMax,
            showReadiness: showExperimentalReadiness, deviceID: demo ? nil : selectedDevice?.id,
            bandKeepsHistory: !demo && historySyncMode != .off && (caps[.history] ?? .unsupported) != .unsupported,
            // Beat intervals: the adapter documents them, or this band demonstrably sent them; with no band
            // selected nothing is claimed to be unsupported.
            beatIntervalsSupported: demo || adapter == nil || (caps[.beatIntervals] ?? .unsupported) != .unsupported
                || diagnostics.counters.standardHRWithRR > 0,
            motionSupported: demo || (caps[.motion] ?? .unsupported) != .unsupported,
            motionNeedsValidation: !demo && caps[.motion] == .candidateUnvalidated,
            historyHeartRateValidated: false,
            allowUnvalidatedMotion: allowUnvalidatedMotion,
            excludesDemoData: !demo,
            cacheGate: demo ? demoCacheGate : liveCacheGate)
        if resolveHistoryValidation, !demo, let adapter, let settings = try? liveStore?.allSettings() {
            let passed = Set(settings.filter { $0.key.hasPrefix(FieldValidator.historyHeartRateKeyPrefix) && $0.value == "passed" }.keys)
            let current = FieldValidator.historyHeartRateKey(adapterID: adapter.adapterID, firmware: selectedDevice?.firmwareVersion)
            // History heart rate is used only while the band's current firmware is validated, and then
            // only values decoded by an adapter and firmware that passed themselves.
            if passed.contains(current) {
                ctx.historyHeartRatePolicy = .validatedBatches(passedKeys: passed, cache: liveBatchKeys)
            }
        }
        return ctx
    }

    private struct RefreshOutput: Sendable {
        var today: TodayState?
        var sleep: SleepState?
        var activity: ActivityState?
        var trends: TrendsState?
        var newestSample: EpochMillis?
        var lastCompleteSync: EpochMillis?
        var overnightRestingHeartRate: Double?
        var error: String?
    }

    public func refreshNow() async {
        guard sceneActivity != .background else {
            refreshDeferredUntilActive = true
            return
        }
        if autoValidationPending { await runAutoValidationIfNeeded() }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let epoch = dataContextEpoch
        let cancellation = CancellationFlag()
        inFlightRefreshes[generation] = cancellation
        defer { inFlightRefreshes[generation] = nil }
        guard let ctx = loaderContext() else { return }
        let metric = trendMetric
        let period = trendPeriod
        let live = liveWorkoutStart.map { start in
            ScreenLoader.liveWorkout(ctx, start: start, recentSamples: liveWorkoutSamples, sourceLabel: lastLiveSource?.description,
                                     overnightRestingHeartRate: overnightRestingHeartRate)
        }
        let selectedID = isDemo ? nil : selectedDevice?.id
        let output = await Task.detached(priority: .userInitiated) { () -> RefreshOutput? in
            do {
                // Sleep candidates for recent nights (only when motion may be used for them).
                for candidate in try ScreenLoader.proposeSleepCandidates(ctx) {
                    if cancellation.isCancelled { return nil }
                    _ = try ctx.store.insertSession(candidate)
                }
                if cancellation.isCancelled { return nil }
                let t = try ScreenLoader.today(ctx)
                if cancellation.isCancelled { return nil }
                let s = try ScreenLoader.sleep(ctx)
                if cancellation.isCancelled { return nil }
                let a = try ScreenLoader.activity(ctx, live: live)
                if cancellation.isCancelled { return nil }
                let tr = try ScreenLoader.trends(ctx, metric: metric, period: period)
                let newest = try ctx.store.newestSampleTime(deviceID: ctx.deviceID)
                let lastSync = try selectedID.flatMap { try ctx.store.syncCursor(deviceID: $0)?.lastCompleteSyncAt }
                let resting = try ScreenLoader.overnightRestingHeartRateIfNeeded(ctx)
                return RefreshOutput(today: t, sleep: s, activity: a, trends: tr, newestSample: newest, lastCompleteSync: lastSync,
                                     overnightRestingHeartRate: resting)
            } catch {
                if cancellation.isCancelled { return nil }
                return RefreshOutput(error: "\(error)")
            }
        }.value
        // Computed for another mode, store or band, or older than what is already shown: drop it.
        guard epoch == dataContextEpoch, generation > appliedRefreshGeneration, !Task.isCancelled, let output else { return }
        if let error = output.error { alertMessage = "Loading data failed: \(error)"; return }
        appliedRefreshGeneration = generation
        today = output.today
        sleep = output.sleep
        activity = output.activity
        trends = output.trends
        overnightRestingHeartRate = output.overnightRestingHeartRate
        let current = timeSource.now()
        if let newest = output.newestSample {
            // A record stamped in the future (band clock) is never reported as newer than now.
            let clamped = min(newest, current)
            connection.lastDeviceSample = max(clamped, connection.lastDeviceSample ?? clamped)
        }
        if let lastSync = output.lastCompleteSync { connection.lastCompletedSync = lastSync }
        now = current
    }

    public func sceneBecameActive() async {
        sceneActivity = .active
        await applyEngineOptions()
        refreshDeferredUntilActive = false
        now = timeSource.now()
        if collectionEnabled, !isDemo, selectedDevice != nil, connection.link != .connected {
            central.connectSelected(profile: Self.connectionProfile)
        }
        if isDemo { await prepareDemoData() }
        await refreshNow()
    }

    /// Nothing heavy in the background: Bluetooth notifications keep being persisted by the engine, but
    /// screens are not recomputed (and sleep candidates and cached values not written) until the scene is
    /// active again.
    public func sceneEnteredBackground() {
        sceneActivity = .background
        // Stop requesting the real-time stream (a running workout keeps it).
        Task { [weak self] in await self?.applyEngineOptions() }
        refreshTask?.cancel()
        for flag in inFlightRefreshes.values { flag.cancel() }
        latestHeartRateTask?.cancel()
        latestHeartRateTask = nil
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

    /// Cached load values carry the HRmax they used, so they are recomputed when it changes (in both
    /// the live and the demo store, whichever is showing).
    public func setProfile(_ p: UserProfile) async {
        profile = p
        do { try liveStore?.setUserProfile(p) } catch { alertMessage = "Saving the profile failed: \(error)" }
        await refreshNow()
    }

    public func setZoneMethod(_ m: ZoneMethodChoice) async {
        zoneMethod = m
        setStoreSetting(m.rawValue, SettingKey.zoneMethod)
        await refreshNow()
    }

    public func setShowExperimentalReadiness(_ on: Bool) async {
        showExperimentalReadiness = on
        setStoreSetting(on ? "1" : "0", SettingKey.showReadiness)
        await refreshNow()
    }

    /// Allows unvalidated motion for proposing sleep windows only (never for durations or other values).
    public func setAllowUnvalidatedMotion(_ on: Bool) async {
        allowUnvalidatedMotion = on
        setStoreSetting(on ? "1" : "0", SettingKey.allowUnvalidatedMotion)
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

    // MARK: Derived-value cache

    /// Deletes cached daily values overlapping `range` in `store`, through that store's gate so no
    /// computation that started earlier writes a stale value back.
    func invalidateDerived(in store: FormaStore, overlapping range: TimeRange) {
        let gate = store === demoStore ? demoCacheGate : liveCacheGate
        _ = try? platform.runProtected("forma.derived") {
            try gate.invalidate(range) { try store.invalidateDerived(overlapping: range) }
        }
    }

    /// Deletes every cached daily value in both stores.
    func invalidateAllDerived() {
        let everything = TimeRange(start: 0, end: Int64.max / 2)
        for s in [liveStore, demoStore].compactMap({ $0 }) { invalidateDerived(in: s, overlapping: everything) }
    }

    /// Range whose cached daily values records in `range` can change: their own days and the next day
    /// (whose overnight values use a sleep window that can start the evening before).
    nonisolated static func affectedByRecords(in range: TimeRange) -> TimeRange {
        let (end, overflow) = range.end.addingReportingOverflow(EpochMillis.millisPerDay)
        return TimeRange(start: range.start, end: overflow ? Int64.max : end)
    }
}
