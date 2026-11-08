import Foundation
import FormaCore

/// Why Bluetooth cannot be used right now.
public enum BluetoothUnavailableReason: String, Hashable, Sendable {
    case poweredOff
    case unauthorized
    case unsupported
    case resetting
    case unknown
}

/// Link-level state of the selected band, independent of data freshness.
public enum LinkState: Hashable, Sendable {
    case noDeviceSelected
    case bluetoothUnavailable(BluetoothUnavailableReason)
    /// Waiting for the selected band to come into range (a pending connection request).
    case searching
    case connecting
    /// Connected and services ready.
    case connected
    case disconnected(since: EpochMillis?)
}

/// History-transfer activity, shown separately from the link state.
public enum SyncActivity: Hashable, Sendable {
    case idle
    case syncingHistory(recordsReceived: Int, newestRecord: EpochMillis?)
    case failed(message: String, at: EpochMillis)
}

/// The facts the connection control and status lines render. "Last device sample", "last sync" and
/// "connection status" are deliberately separate fields: a connected band can have stale data, and a
/// disconnected band can have fresh history.
public struct ConnectionSummary: Hashable, Sendable {
    public var deviceName: String?
    public var family: DeviceFamily?
    public var link: LinkState
    public var sync: SyncActivity
    /// Newest measurement time stored for this device (any source).
    public var lastDeviceSample: EpochMillis?
    /// Last time a history transfer completed (band reported no more data).
    public var lastCompletedSync: EpochMillis?
    /// True while live heart-rate notifications are arriving.
    public var liveStreaming: Bool
    public var isDemo: Bool

    public init(deviceName: String? = nil, family: DeviceFamily? = nil, link: LinkState = .noDeviceSelected,
                sync: SyncActivity = .idle, lastDeviceSample: EpochMillis? = nil, lastCompletedSync: EpochMillis? = nil,
                liveStreaming: Bool = false, isDemo: Bool = false) {
        self.deviceName = deviceName
        self.family = family
        self.link = link
        self.sync = sync
        self.lastDeviceSample = lastDeviceSample
        self.lastCompletedSync = lastCompletedSync
        self.liveStreaming = liveStreaming
        self.isDemo = isDemo
    }

    /// Short status for the toolbar control (≤ 3 words).
    public var shortStatus: String {
        if isDemo { return "Demo data" }
        switch link {
        case .noDeviceSelected: return "No band"
        case .bluetoothUnavailable(let r):
            switch r {
            case .poweredOff: return "Bluetooth off"
            case .unauthorized: return "No permission"
            case .unsupported: return "Unsupported"
            case .resetting, .unknown: return "Bluetooth…"
            }
        case .searching: return "Searching"
        case .connecting: return "Connecting"
        case .connected:
            if case .syncingHistory = sync { return "Syncing" }
            return liveStreaming ? "Live" : "Connected"
        case .disconnected: return "Disconnected"
        }
    }

    /// Severity drives the icon/color of the control; color is never the only signal.
    public enum Severity: Hashable, Sendable { case normal, active, attention, problem }

    public var severity: Severity {
        if isDemo { return .attention }
        switch link {
        case .connected: return liveStreaming || isSyncing ? .active : .normal
        case .searching, .connecting: return .normal
        case .disconnected, .noDeviceSelected: return .attention
        case .bluetoothUnavailable: return .problem
        }
    }

    public var isSyncing: Bool {
        if case .syncingHistory = sync { return true }
        return false
    }

    /// Three separate lines for detail views: link, last device sample, last sync.
    public func detailLines(now: EpochMillis, formatter: RelativeTimeFormatter = RelativeTimeFormatter()) -> [String] {
        var lines: [String] = []
        switch link {
        case .noDeviceSelected: lines.append("No band selected")
        case .bluetoothUnavailable(let r): lines.append("Bluetooth unavailable (\(r.rawValue))")
        case .searching: lines.append("Waiting for \(deviceName ?? "band") to come into range")
        case .connecting: lines.append("Connecting to \(deviceName ?? "band")")
        case .connected: lines.append("Connected to \(deviceName ?? "band")")
        case .disconnected(let since):
            if let since { lines.append("Disconnected \(formatter.string(from: since, now: now))") }
            else { lines.append("Disconnected") }
        }
        if let t = lastDeviceSample {
            lines.append("Last device sample \(formatter.string(from: t, now: now))")
        } else {
            lines.append("No samples recorded yet")
        }
        switch sync {
        case .syncingHistory(let n, _): lines.append("Syncing band history (\(n) records so far)")
        case .failed(let message, let at): lines.append("Last sync failed \(formatter.string(from: at, now: now)): \(message)")
        case .idle:
            if let t = lastCompletedSync { lines.append("Last complete sync \(formatter.string(from: t, now: now))") }
            else { lines.append("History not synced yet") }
        }
        return lines
    }
}

/// Deterministic, locale-independent relative time ("2 min ago", "3 h ago", "yesterday 23:10").
/// Kept simple and testable; the UI may substitute system formatters where localization matters.
public struct RelativeTimeFormatter: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = Calendar.current) {
        self.calendar = calendar
    }

    public func string(from t: EpochMillis, now: EpochMillis) -> String {
        let delta = now - t
        if delta < 0 { return "just now" }
        if delta < 60_000 { return "just now" }
        if delta < 3_600_000 { return "\(delta / 60_000) min ago" }
        if delta < 6 * 3_600_000 {
            let h = delta / 3_600_000
            let m = (delta % 3_600_000) / 60_000
            return m == 0 ? "\(h) h ago" : "\(h) h \(m) min ago"
        }
        let day = LocalDay(t, calendar: calendar)
        let today = LocalDay(now, calendar: calendar)
        let hm = clock(t)
        if day == today { return "today \(hm)" }
        if day == today.adding(days: -1, calendar: calendar) { return "yesterday \(hm)" }
        return "\(day) \(hm)"
    }

    private func clock(_ t: EpochMillis) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: t.date)
        let h = c.hour ?? 0
        let m = c.minute ?? 0
        return (h < 10 ? "0" : "") + "\(h):" + (m < 10 ? "0" : "") + "\(m)"
    }
}
