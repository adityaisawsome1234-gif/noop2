import Foundation
import FormaCore

/// Whether Forma downloads the band's stored history.
///
/// Downloading never changes the band: Forma saves the data and, by default, does not acknowledge it,
/// so the band keeps its copy (and another app, such as the official app, still receives it). Confirming
/// receipt to the band is a separate, experimental setting (`AppModel.setHistoryAcknowledgement`).
public enum HistorySyncMode: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    /// Live data only. Forma never requests band history.
    case off
    /// Download history only when the user taps "Sync now".
    case manual
    /// Download history automatically after each (re)connection.
    case automatic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off (live data only)"
        case .manual: return "When I tap Sync"
        case .automatic: return "Automatically"
        }
    }

    public var explanation: String {
        switch self {
        case .off:
            return "Forma records only what the band sends live while connected. Gaps cannot be recovered later, and the band's stored history is left untouched."
        case .manual, .automatic:
            return "Forma downloads the band's stored history and saves it on this iPhone. It does not confirm receipt to the band, so the band keeps its copy and may send the same period again next time; Forma skips what it already has."
        }
    }
}

/// A peripheral seen during a user-initiated, filtered, time-boxed scan.
public struct DiscoveredDevice: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var rssi: Int?
    public var family: DeviceFamily
    public var advertisedServiceUUIDs: [String]
    public var manufacturerDataHex: String?
    /// Found through `retrieveConnectedPeripherals` (already connected to this iPhone by some app).
    public var connectedToThisPhone: Bool
    public var lastSeen: EpochMillis

    public init(id: String, name: String?, rssi: Int?, family: DeviceFamily, advertisedServiceUUIDs: [String],
                manufacturerDataHex: String?, connectedToThisPhone: Bool, lastSeen: EpochMillis) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.family = family
        self.advertisedServiceUUIDs = advertisedServiceUUIDs
        self.manufacturerDataHex = manufacturerDataHex
        self.connectedToThisPhone = connectedToThisPhone
        self.lastSeen = lastSeen
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Unnamed device"
    }
}

/// One step of the compatibility test. "unverified" means the step ran but the result cannot yet be
/// interpreted with confidence (for example, a decoded field without independent agreement).
public enum CheckStatus: String, Hashable, Sendable, Codable {
    case pending, running, passed, failed, unverified, notApplicable
}

public struct CompatibilityCheck: Hashable, Sendable, Identifiable, Codable {
    public var id: String
    public var title: String
    public var status: CheckStatus
    public var detail: String

    public init(id: String, title: String, status: CheckStatus, detail: String) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
    }

    /// The fixed list of checks shown before a test starts.
    public static let plan: [CompatibilityCheck] = [
        CompatibilityCheck(id: "connect", title: "Connect without any account", status: .pending,
                           detail: "Direct Bluetooth link to the selected band."),
        CompatibilityCheck(id: "gatt", title: "Read service layout", status: .pending,
                           detail: "Discover services and characteristics; record which data paths exist."),
        CompatibilityCheck(id: "standardHR", title: "Standard heart-rate service", status: .pending,
                           detail: "Receive Heart Rate Measurement notifications; record whether beat intervals are present."),
        CompatibilityCheck(id: "vendorFrames", title: "Vendor data path", status: .pending,
                           detail: "Receive frames on the vendor characteristics and validate their checksums."),
        CompatibilityCheck(id: "hello", title: "Identify band", status: .pending,
                           detail: "Read-only identification request and response."),
        CompatibilityCheck(id: "liveHR", title: "Live heart rate", status: .pending,
                           detail: "Plausible heart-rate values arrive at least every few seconds."),
        CompatibilityCheck(id: "history", title: "Stored history", status: .pending,
                           detail: "Only runs if you enabled history sync: transfer, save, then acknowledge."),
        CompatibilityCheck(id: "clock", title: "Band clock", status: .pending,
                           detail: "Compare the band's clock with this iPhone's clock (read-only)."),
        CompatibilityCheck(id: "fieldAgreement", title: "Field validation", status: .pending,
                           detail: "Decoded history heart rate must agree with live heart rate from the same minutes before Forma uses it."),
    ]
}

/// Summary of the GATT layout seen on the connected band.
public struct GATTServiceSummary: Hashable, Sendable, Identifiable, Codable {
    public var id: String { uuid }
    public var uuid: String
    public var name: String
    public var characteristics: [GATTCharacteristicSummary]

    public init(uuid: String, name: String, characteristics: [GATTCharacteristicSummary]) {
        self.uuid = uuid
        self.name = name
        self.characteristics = characteristics
    }
}

public struct GATTCharacteristicSummary: Hashable, Sendable, Identifiable, Codable {
    public var id: String { uuid }
    public var uuid: String
    public var name: String
    public var properties: [String]
    public var notifying: Bool

    public init(uuid: String, name: String, properties: [String], notifying: Bool) {
        self.uuid = uuid
        self.name = name
        self.properties = properties
        self.notifying = notifying
    }
}

/// One line in the diagnostics frame log (hex is truncated for display; full bytes go to the capture).
public struct FrameLogLine: Hashable, Sendable, Identifiable {
    public var id: Int
    public var at: EpochMillis
    public var direction: String
    public var characteristic: String
    public var summary: String
    public var hexPreview: String

    public init(id: Int, at: EpochMillis, direction: String, characteristic: String, summary: String, hexPreview: String) {
        self.id = id
        self.at = at
        self.direction = direction
        self.characteristic = characteristic
        self.summary = summary
        self.hexPreview = hexPreview
    }
}

public struct DiagnosticsCounters: Hashable, Sendable, Codable {
    public var framesValid: Int = 0
    public var framesMalformed: Int = 0
    public var bytesDiscarded: Int = 0
    public var unknownPackets: Int = 0
    public var standardHRNotifications: Int = 0
    public var standardHRWithRR: Int = 0
    public var commandsSent: Int = 0
    public var historyRecords: Int = 0

    public init() {}
}

public struct DiagnosticsState: Hashable, Sendable {
    public var checks: [CompatibilityCheck]
    public var services: [GATTServiceSummary]
    public var advertisement: [String: String]
    public var counters: DiagnosticsCounters
    public var recentFrames: [FrameLogLine]
    public var captureEnabled: Bool
    public var capturedEntries: Int
    public var firmware: String?
    public var adapterID: String?
    public var parserVersion: String?

    public init(checks: [CompatibilityCheck] = CompatibilityCheck.plan, services: [GATTServiceSummary] = [],
                advertisement: [String: String] = [:], counters: DiagnosticsCounters = DiagnosticsCounters(),
                recentFrames: [FrameLogLine] = [], captureEnabled: Bool = false, capturedEntries: Int = 0,
                firmware: String? = nil, adapterID: String? = nil, parserVersion: String? = nil) {
        self.checks = checks
        self.services = services
        self.advertisement = advertisement
        self.counters = counters
        self.recentFrames = recentFrames
        self.captureEnabled = captureEnabled
        self.capturedEntries = capturedEntries
        self.firmware = firmware
        self.adapterID = adapterID
        self.parserVersion = parserVersion
    }
}

/// User-facing choice of heart-rate zone method (mapped to the analytics zone configuration).
public enum ZoneMethodChoice: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    /// Zones as % of maximum heart rate (50/60/70/80/90 %).
    case percentOfMax
    /// Zones as % of heart-rate reserve (Karvonen); needs a resting heart rate.
    case heartRateReserve

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .percentOfMax: return "% of max heart rate"
        case .heartRateReserve: return "% of heart-rate reserve"
        }
    }

    public var explanation: String {
        switch self {
        case .percentOfMax:
            return "Zone 1 starts at 50% of your max heart rate; each zone spans 10%. Uses your entered max heart rate, or an age-based estimate if you entered only a birth year."
        case .heartRateReserve:
            return "Karvonen method: zones are percentages of (max − resting) added to resting heart rate. Needs a resting heart rate (entered, or Forma's overnight estimate)."
        }
    }
}
