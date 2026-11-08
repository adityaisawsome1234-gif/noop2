import SwiftUI
import FormaCore
import FormaFeatures

/// Device, sync and settings hub — opened from the connection control on every tab.
struct DeviceHubView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            List {
                bandSection
                if model.selectedDevice != nil {
                    collectionSection
                    historySection
                }
                Section("Diagnostics") {
                    NavigationLink("Compatibility test and diagnostics") { DiagnosticsView() }
                    NavigationLink("Connection history") { ConnectionHistoryView() }
                }
                Section {
                    NavigationLink("Settings") { SettingsView() }
                }
            }
            .formaListBackground()
            .navigationTitle("Band")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Forget this band?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget band", role: .destructive) { Task { await model.forgetDevice() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Forma stops connecting to it. Recorded data stays on this iPhone. The Bluetooth bond (if any) is managed by iOS Settings and is not changed.")
            }
        }
        // Messages raised while this sheet is open (pairing guidance, a band Forma cannot read, a failed
        // save) are shown here; the root view cannot present over a sheet.
        .modelAlert(model)
    }

    @ViewBuilder
    private var bandSection: some View {
        Section {
            if model.isDemo {
                Label("Demo mode is on. No band is used.", systemImage: "theatermasks")
                    .foregroundStyle(Theme.demo)
                Button("Leave demo mode") { Task { await model.exitDemo() } }
            } else if let device = model.selectedDevice {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.headline)
                    Text(device.family.displayName).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    if let fw = device.firmwareVersion {
                        Text("Firmware \(fw)").font(.subheadline).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("Firmware not read yet").font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                ForEach(Array(model.connection.displayLines(now: model.now, calendar: model.calendar).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.subheadline)
                }
                Button("Forget band", role: .destructive) { confirmForget = true }
            } else {
                Text("No band selected").foregroundStyle(Theme.textSecondary)
                NavigationLink("Choose band") { DevicePickerView() }
            }
        } header: {
            Text("Band")
        } footer: {
            if !model.isDemo {
                Text("Forma connects only to the band you choose. It never asks for an account and sends nothing off this iPhone.")
            }
        }
    }

    private var collectionSection: some View {
        Section {
            Toggle("Collect from band", isOn: Binding(get: { model.collectionEnabled },
                                                       set: { v in Task { await model.setCollectionEnabled(v) } }))
                .tint(Theme.accent)
            Toggle("Request live heart-rate stream", isOn: Binding(get: { model.liveHeartRateEnabled },
                                                                    set: { v in Task { await model.setLiveHeartRate(v) } }))
                .tint(Theme.accent)
                .disabled(!model.collectionEnabled)
        } header: {
            Text("Collection")
        } footer: {
            Text("While collection is on, iOS usually reconnects to the band when it is back in range, also in the background. It does not after Bluetooth is turned off in Settings, after a restart until the iPhone is unlocked once, or after you swipe Forma away in the app switcher; open Forma again then. Heart rate the band sends through the standard heart-rate service is recorded whenever it is connected. “Request live heart-rate stream” asks bands that support Forma's request to stream heart rate as well, only while it is on and Forma is open (a running workout keeps the request in the background until you finish); other bands ignore it. Values from that stream are not validated yet, so they appear only in Diagnostics.")
        }
    }

    private var historySection: some View {
        Section {
            Picker("Band history", selection: Binding(get: { model.historySyncMode },
                                                      set: { m in Task { await model.setHistorySyncMode(m) } })) {
                ForEach(HistorySyncMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if model.historySyncMode != .off {
                Button {
                    Task { await model.syncNow() }
                } label: {
                    Label(model.connection.isSyncing ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.connection.isSyncing || model.connection.link != .connected)
            }
        } header: {
            Text("History")
        } footer: {
            Text(model.historySyncMode.explanation(acknowledging: model.historyAcknowledgementEnabled))
        }
    }
}

/// Filtered, time-boxed scan for bands. Unfiltered scanning is only offered explicitly, in the foreground.
struct DevicePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var includeUnfiltered = false
    @State private var accessorySetup = AccessorySetupController()

    var body: some View {
        if AccessorySetupController.isConfigured {
            accessorySetupPicker
        } else {
            scanList
        }
    }

    /// AccessorySetupKit mode: the system picker chooses the band (see BUILD_AND_INSTALL.md §6).
    private var accessorySetupPicker: some View {
        List {
            Section {
                Button("Choose band with the system picker") {
                    accessorySetup.showPicker { id, name in
                        let device = DiscoveredDevice(id: id, name: name, rssi: nil, family: .unknown, advertisedServiceUUIDs: [],
                                                      manufacturerDataHex: nil, connectedToThisPhone: false, lastSeen: model.now)
                        Task {
                            await model.selectDevice(device)
                            dismiss()
                        }
                    }
                }
                if let error = accessorySetup.lastError {
                    Text(error).font(.footnote).foregroundStyle(Theme.critical)
                }
            } footer: {
                Text("This build uses AccessorySetupKit: iOS shows its own picker and gives Forma access only to the band you choose.")
            }
        }
        .formaListBackground()
        .navigationTitle("Choose band")
    }

    private var scanList: some View {
        List {
            Section {
                if model.isScanning {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView()
                        Text("Looking for bands nearby…")
                    }
                } else {
                    Button("Scan again") { model.startScan(includeUnfiltered: includeUnfiltered) }
                }
                Toggle("Show all nearby Bluetooth devices", isOn: $includeUnfiltered)
                    .tint(Theme.accent)
                    .onChange(of: includeUnfiltered) { _, newValue in model.startScan(includeUnfiltered: newValue) }
            } footer: {
                Text("Keep the band close to the iPhone. If it is connected to another app it may not advertise; Forma also lists bands already connected to this iPhone. Scanning stops automatically after 30 seconds.")
            }
            if let message = model.bluetoothProblemMessage {
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.critical) }
            }
            Section("Found") {
                if model.discoveredDevices.isEmpty {
                    Text(model.isScanning ? "Nothing yet" : "No devices found")
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(orderedDevices) { device in
                    Button {
                        Task {
                            await model.selectDevice(device)
                            dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.displayName).foregroundStyle(Theme.textPrimary)
                            Text(subtitle(device)).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .accessibilityHint("Selects this band and connects to it")
                }
            }
        }
        .formaListBackground()
        .navigationTitle("Choose band")
        .onAppear { model.startScan(includeUnfiltered: includeUnfiltered) }
        .onDisappear { model.stopScan() }
    }

    /// Bands already connected to this iPhone (usually your own, held by another app) come first; the
    /// model's order (known band types, then signal strength) is kept otherwise.
    private var orderedDevices: [DiscoveredDevice] {
        let devices = model.discoveredDevices
        return devices.filter(\.connectedToThisPhone) + devices.filter { !$0.connectedToThisPhone }
    }

    private func subtitle(_ device: DiscoveredDevice) -> String {
        var parts = [device.family.displayName]
        if device.connectedToThisPhone { parts.append("connected to this iPhone") }
        if let rssi = device.rssi { parts.append("signal \(rssi) dBm") }
        return parts.joined(separator: " · ")
    }
}

struct ConnectionHistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.connectionEvents.isEmpty {
                Text("No connection events yet").foregroundStyle(Theme.textSecondary)
            }
            ForEach(Array(model.connectionEvents.enumerated()), id: \.offset) { _, event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(for: event.kind))
                        .font(.subheadline.weight(.medium))
                    Text(RelativeTimeFormatter(calendar: model.calendar).string(from: event.timestamp, now: model.now)
                         + (event.detail.map { " · \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .formaListBackground()
        .navigationTitle("Connection history")
        .task { await model.loadConnectionEvents() }
    }

    static func title(for kind: ConnectionEventKind) -> String {
        switch kind {
        case .scanStarted: return "Started looking for bands"
        case .scanStopped: return "Stopped looking for bands"
        case .connecting: return "Waiting for the band"
        case .connected: return "Connected"
        case .servicesDiscovered: return "Ready: band services found"
        case .disconnected: return "Disconnected"
        case .connectFailed: return "Connection failed"
        case .restoredByOS: return "Reconnected by iOS after a relaunch"
        case .bluetoothOff: return "Bluetooth turned off"
        case .bluetoothOn: return "Bluetooth on"
        case .unauthorized: return "Bluetooth unavailable to Forma"
        case .reconnectScheduled: return "Reconnecting soon"
        @unknown default: return kind.rawValue
        }
    }
}
