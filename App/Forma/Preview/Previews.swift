#if DEBUG
import SwiftUI
import FormaCore
import FormaProtocol
import FormaFeatures

/// No-op central for previews.
final class PreviewCentral: BandCentral, @unchecked Sendable {
    func connectSelected(profile: GATTProfile) {}
    func disconnect() {}
    func select(peripheralID: String, profile: GATTProfile) {}
    func forgetSelected() {}
    func startScan(includeUnfiltered: Bool) {}
    func stopScan() {}
    var savedPeripheralID: String? { nil }
    func setEventHandler(_ handler: @escaping @Sendable (CentralEvent) -> Void) {}
}

/// In-memory platform for previews (no files, no backups).
final class PreviewPlatform: PlatformServices, @unchecked Sendable {
    private var prefs: [String: String] = ["onboardingComplete": "1"]
    func databasePath(demo: Bool) throws -> String? { nil }
    func protectDatabase(at path: String) {}
    func setIncludedInBackups(_ included: Bool) throws {}
    func isIncludedInBackups() -> Bool { false }
    func makeStagingDirectory() throws -> URL { FileManager.default.temporaryDirectory }
    func archiveDirectory(_ url: URL) throws -> Data { Data() }
    func runProtected<T: Sendable>(_ name: String, _ body: () throws -> T) rethrows -> T { try body() }
    var appVersion: String { "preview" }
    var osVersion: String { "preview" }
    func preference(_ key: String) -> String? { prefs[key] }
    func setPreference(_ value: String?, forKey key: String) { prefs[key] = value }
}

@MainActor
enum PreviewModels {
    static func empty() -> AppModel {
        AppModel(central: PreviewCentral(), platform: PreviewPlatform())
    }

    static func demo() -> AppModel {
        let model = empty()
        Task { await model.enterDemo() }
        return model
    }
}

/// Hand-built screen states for previews that a model cannot reach without a band.
enum PreviewStates {
    static var liveWorkout: LiveWorkoutState {
        let now = EpochMillis(date: Date())
        let start = now - 754_000
        let points = (0..<60).map { i in
            ChartPoint(t: start + Int64(i) * 12_000, value: 120 + Double(i % 20), segment: i < 40 ? 0 : 1)
        }
        return LiveWorkoutState(
            start: start, now: now, currentHR: 152, currentZone: 3, signalStale: false,
            zones: [ZoneTimeDisplay(zone: 2, label: "Zone 2", rangeText: "114–133 bpm", millis: 300_000, fraction: 0.4),
                    ZoneTimeDisplay(zone: 3, label: "Zone 3", rangeText: "133–152 bpm", millis: 454_000, fraction: 0.6)],
            heartRate: SeriesDisplay(points: points, unit: "bpm", window: TimeRange(start: start, end: now), gapCount: 1),
            sourceLabel: "standard heart-rate service")
    }
}

#Preview("Today · demo") {
    TodayView().environment(PreviewModels.demo()).environment(AppLock())
}

#Preview("Today · empty, no band") {
    TodayView().environment(PreviewModels.empty()).environment(AppLock())
}

#Preview("Today · dark, large type") {
    TodayView().environment(PreviewModels.demo()).environment(AppLock())
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}

#Preview("Sleep · demo") {
    SleepView().environment(PreviewModels.demo()).environment(AppLock())
}

#Preview("Sleep · demo, accessibility size") {
    SleepView().environment(PreviewModels.demo()).environment(AppLock())
        .dynamicTypeSize(.accessibility3)
}

#Preview("Activity · demo") {
    ActivityView().environment(PreviewModels.demo()).environment(AppLock())
}

#Preview("Activity · live workout, dark, accessibility size") {
    ScrollView {
        LiveWorkoutCard(live: PreviewStates.liveWorkout, calendar: .current, onStop: {})
            .padding()
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility3)
}

#Preview("Trends · demo") {
    TrendsView().environment(PreviewModels.demo()).environment(AppLock())
}

#Preview("Band hub") {
    DeviceHubView().environment(PreviewModels.empty()).environment(AppLock())
}

#Preview("Diagnostics") {
    NavigationStack { DiagnosticsView() }.environment(PreviewModels.empty()).environment(AppLock())
}

#Preview("Settings") {
    NavigationStack { SettingsView() }.environment(PreviewModels.empty()).environment(AppLock())
}

#Preview("Onboarding") {
    let model = AppModel(central: PreviewCentral(), platform: {
        let p = PreviewPlatform()
        p.setPreference(nil, forKey: "onboardingComplete")
        return p
    }())
    return OnboardingView().environment(model).environment(AppLock())
}

#Preview("Metric states") {
    ScrollView {
        VStack(spacing: Theme.Space.m) {
            Card {
                MetricTile(title: "Resting HR (overnight)", valueText: "52", unit: "bpm", status: .estimate,
                           availability: .available, coverage: 0.94, confidence: .high, onExplain: {})
            }
            Card {
                MetricTile(title: "HRV (RMSSD)", valueText: nil, unit: "ms", status: .estimate,
                           availability: .unsupportedSensor(sensor: "beat-to-beat intervals"))
            }
            Card {
                MetricTile(title: "Readiness index", valueText: nil, unit: "SD", status: .experimental,
                           availability: .calibrating(have: 9, need: 14, unit: "nights"))
            }
            Card {
                MetricTile(title: "Forma Load", valueText: nil, unit: "TRIMP", status: .estimate,
                           availability: .lowQuality(detail: "Heart-rate coverage today is 18% (needs 30%)"))
            }
            Card {
                MetricTile(title: "Sleep", valueText: nil, unit: "h", status: .estimate,
                           availability: .notYetSynced(detail: "Last night may still be on the band — sync to fill it"))
            }
            Card {
                MetricTile(title: "Skin temperature", valueText: nil, unit: "°C", status: .estimate,
                           availability: .disabled(reason: "Not validated for this band yet"))
            }
            StateMessage(systemImage: "exclamationmark.triangle", title: "Bluetooth is off",
                         message: "Turn on Bluetooth in Control Center to reconnect to your band.")
            DemoBanner()
            CoverageBar(segments: [
                .init(id: 0, fractionStart: 0, fractionEnd: 0.45, kind: .recorded),
                .init(id: 1, fractionStart: 0.45, fractionEnd: 0.55, kind: .awaitingValidation),
                .init(id: 2, fractionStart: 0.55, fractionEnd: 0.7, kind: .notRecorded),
                .init(id: 3, fractionStart: 0.7, fractionEnd: 1, kind: .pendingSync),
            ], accessibilitySummary: "45% recorded, 10% saved from the band, awaiting validation, 30% waiting to sync from the band, 15% not recorded")
            CoverageLegend()
        }
        .padding()
    }
    .background(Theme.background)
}

#Preview("Problem, loading and lock states") {
    ScrollView {
        VStack(spacing: Theme.Space.m) {
            BluetoothProblemMessage(reason: .unauthorized)
            BluetoothProblemMessage(reason: .poweredOff)
            LoadingPlaceholder {}
            StateMessage(systemImage: "exclamationmark.triangle", title: "Your data has not loaded",
                         message: "Loading is taking much longer than usual, or it failed.",
                         actionTitle: "Try again", action: {})
            LockScreen(onUnlock: {})
                .frame(height: 260)
        }
        .padding()
    }
    .background(Theme.background)
    .environment(AppLock())
    .preferredColorScheme(.dark)
}

#Preview("Connection control states") {
    VStack(alignment: .leading, spacing: Theme.Space.m) {
        ConnectionControl(summary: ConnectionSummary(deviceName: "WHOOP", link: .connected, liveStreaming: true)) {}
        ConnectionControl(summary: ConnectionSummary(deviceName: "WHOOP", link: .searching)) {}
        ConnectionControl(summary: ConnectionSummary(deviceName: "WHOOP", link: .connected, sync: .syncingHistory(recordsReceived: 120, newestRecord: nil))) {}
        ConnectionControl(summary: ConnectionSummary(deviceName: "WHOOP", link: .disconnected(since: nil))) {}
        ConnectionControl(summary: ConnectionSummary(link: .bluetoothUnavailable(.poweredOff))) {}
        ConnectionControl(summary: ConnectionSummary(link: .noDeviceSelected)) {}
        ConnectionControl(summary: ConnectionSummary(isDemo: true)) {}
    }
    .padding()
    .background(Theme.background)
}
#endif
