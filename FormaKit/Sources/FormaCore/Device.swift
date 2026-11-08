import Foundation

/// The protocol family of a connected peripheral. Each family is handled by its own adapter.
public enum DeviceFamily: String, Sendable, Codable, CaseIterable {
    /// WHOOP 5.0 / MG generation (vendor service family documented by public interoperability work).
    case whoop5
    /// WHOOP 4.0 generation (vendor service family documented by public interoperability work).
    case whoop4
    /// Any peripheral exposing only the Bluetooth SIG Heart Rate Service.
    case standardHeartRate
    case unknown

    public var displayName: String {
        switch self {
        case .whoop5: return "WHOOP 5.0 / MG"
        case .whoop4: return "WHOOP 4.0"
        case .standardHeartRate: return "Standard heart-rate sensor"
        case .unknown: return "Unknown device"
        }
    }
}

/// What Forma knows about a device the user explicitly selected.
public struct DeviceRecord: Hashable, Sendable, Codable, Identifiable {
    /// Stable local identifier. On iOS this is the CBPeripheral identifier, which is per-phone and per-app.
    public var id: String
    public var family: DeviceFamily
    public var name: String
    public var firmwareVersion: String?
    public var hardwareRevision: String?
    public var firstSeen: EpochMillis
    public var lastConnected: EpochMillis?

    public init(id: String, family: DeviceFamily, name: String, firmwareVersion: String? = nil,
                hardwareRevision: String? = nil, firstSeen: EpochMillis, lastConnected: EpochMillis? = nil) {
        self.id = id
        self.family = family
        self.name = name
        self.firmwareVersion = firmwareVersion
        self.hardwareRevision = hardwareRevision
        self.firstSeen = firstSeen
        self.lastConnected = lastConnected
    }
}

/// Provenance stamped on every ingest batch (one per live session chunk or history transfer).
public struct Provenance: Hashable, Sendable, Codable {
    public var deviceID: String
    public var adapterID: String
    public var parserVersion: String
    public var firmwareVersion: String?
    public var source: MeasurementSource
    public var syncRunID: Int64?
    public var createdAt: EpochMillis
    public var note: String?

    public init(deviceID: String, adapterID: String, parserVersion: String, firmwareVersion: String?,
                source: MeasurementSource, syncRunID: Int64?, createdAt: EpochMillis, note: String? = nil) {
        self.deviceID = deviceID
        self.adapterID = adapterID
        self.parserVersion = parserVersion
        self.firmwareVersion = firmwareVersion
        self.source = source
        self.syncRunID = syncRunID
        self.createdAt = createdAt
        self.note = note
    }
}

/// Connection lifecycle events, kept for the connection-history view and diagnostics.
public enum ConnectionEventKind: String, Sendable, Codable {
    case scanStarted, scanStopped, connecting, connected, servicesDiscovered, disconnected,
         connectFailed, restoredByOS, bluetoothOff, bluetoothOn, unauthorized, reconnectScheduled
}

public struct ConnectionEvent: Hashable, Sendable, Codable {
    public var deviceID: String?
    public var timestamp: EpochMillis
    public var kind: ConnectionEventKind
    public var detail: String?

    public init(deviceID: String?, timestamp: EpochMillis, kind: ConnectionEventKind, detail: String? = nil) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.kind = kind
        self.detail = detail
    }
}
