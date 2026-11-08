import Foundation
import FormaCore

// MARK: - GATT profile

/// What to discover, subscribe to and write for one device family. UUID strings are uppercase,
/// 128-bit canonical form (see `UUIDs.normalize`).
public struct GATTProfile: Hashable, Sendable {
    /// Vendor service, if the family has one.
    public var vendorService: String?
    /// Services to discover after connecting.
    public var discoverServices: [String]
    /// Characteristics to enable notifications on, in order.
    public var subscribeCharacteristics: [String]
    /// Characteristic that receives commands, if any.
    public var commandCharacteristic: String?
    public var commandWriteWithResponse: Bool
    /// Service UUIDs used to filter scans (only UUIDs expected in the primary advertising packet).
    public var scanServiceFilter: [String]
    /// Case-insensitive advertised-name hints used only to label scan results.
    public var nameHints: [String]

    public init(vendorService: String?, discoverServices: [String], subscribeCharacteristics: [String],
                commandCharacteristic: String?, commandWriteWithResponse: Bool, scanServiceFilter: [String], nameHints: [String]) {
        self.vendorService = vendorService.map(UUIDs.normalize)
        self.discoverServices = discoverServices.map(UUIDs.normalize)
        self.subscribeCharacteristics = subscribeCharacteristics.map(UUIDs.normalize)
        self.commandCharacteristic = commandCharacteristic.map(UUIDs.normalize)
        self.commandWriteWithResponse = commandWriteWithResponse
        self.scanServiceFilter = scanServiceFilter.map(UUIDs.normalize)
        self.nameHints = nameHints
    }
}

/// UUID text helpers (uppercase; 16/32-bit SIG UUIDs expanded to 128-bit).
public enum UUIDs {
    public static let sigBaseSuffix = "-0000-1000-8000-00805F9B34FB"

    public static func normalize(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.count == 4, s.allSatisfy(\.isHexDigit) { return "0000" + s + sigBaseSuffix }
        if s.count == 8, s.allSatisfy(\.isHexDigit) { return s + sigBaseSuffix }
        return s
    }

    public static func equal(_ a: String, _ b: String) -> Bool { normalize(a) == normalize(b) }

    // Bluetooth SIG services/characteristics used by Forma.
    public static let heartRateService = normalize("180D")
    public static let heartRateMeasurement = normalize("2A37")
    public static let bodySensorLocation = normalize("2A38")
    public static let batteryService = normalize("180F")
    public static let batteryLevel = normalize("2A19")
    public static let deviceInformationService = normalize("180A")
    public static let manufacturerName = normalize("2A29")
    public static let modelNumber = normalize("2A24")
    public static let firmwareRevision = normalize("2A26")
    public static let hardwareRevision = normalize("2A27")
    public static let softwareRevision = normalize("2A28")
}

// MARK: - Commands (compile-time allowlist)

/// Every command Forma can ever send. Destructive or configuration operations — reset, reboot, erase,
/// firmware/DFU, clock write, haptics/alarms, config or name writes, history trim/delete — are
/// deliberately NOT representable. Each adapter additionally declares which of these it can encode.
public enum AllowedCommand: Hashable, Sendable {
    /// Read-only identification request (e.g. a "hello" that returns device identity).
    case identify
    /// Read battery level.
    case readBattery
    /// Read the band's clock (never set it).
    case readClock
    /// Read the available stored-history range (read-only).
    case readHistoryRange
    /// Start / stop the vendor real-time heart-rate stream (non-destructive state change).
    case setRealtimeHeartRate(enabled: Bool)
    /// Ask the band to transfer stored history.
    case requestHistory
    /// Confirm a history chunk was durably saved. `token` is opaque, taken verbatim from the band's
    /// end-of-chunk marker. Sent only after persistence succeeded.
    case acknowledgeHistory(token: [UInt8])
    /// Abort an in-progress history transfer (no acknowledgement is implied).
    case abortHistory

    public var name: String {
        switch self {
        case .identify: return "identify"
        case .readBattery: return "readBattery"
        case .readClock: return "readClock"
        case .readHistoryRange: return "readHistoryRange"
        case .setRealtimeHeartRate(let on): return on ? "realtimeHROn" : "realtimeHROff"
        case .requestHistory: return "requestHistory"
        case .acknowledgeHistory: return "acknowledgeHistory"
        case .abortHistory: return "abortHistory"
        }
    }
}

public enum CommandEncodingError: Error, Equatable, Sendable {
    /// The adapter does not support (or has not verified) this command.
    case unsupported(String)
    case invalidArgument(String)
}

// MARK: - Capabilities

/// How much Forma knows about a data path for one adapter.
public enum CapabilityStatus: String, Hashable, Sendable, Codable {
    /// Confirmed on the owner's hardware (set at runtime after a passed hardware check).
    case verifiedOnHardware
    /// Documented by public interoperability work with consistent independent evidence; not yet seen on this band.
    case documentedUnverified
    /// A decoded field exists but its meaning is not validated; data is stored as evidence and not used in metrics.
    case candidateUnvalidated
    /// Not available on this family/firmware as far as Forma knows.
    case unsupported
}

public enum Capability: String, Hashable, Sendable, Codable, CaseIterable {
    case standardHeartRate
    case liveHeartRate
    case history
    case historyHeartRate
    case beatIntervals
    case motion
    case battery
    case clockRead
    case skinTemperature
    case spo2
}

/// Whether a decoded field's meaning is validated for the current firmware.
public enum FieldStatus: String, Hashable, Sendable, Codable {
    case validated
    case unvalidated
}

// MARK: - Decoded events

public enum SensorContactState: String, Hashable, Sendable, Codable {
    case notSupported, detected, notDetected
}

/// Summary of raw accelerometer samples contained in one record (device units; scale unverified).
public struct MotionSummary: Hashable, Sendable {
    /// Number of 3-axis accelerometer samples summarized.
    public var sampleCount: Int
    /// Mean vector magnitude in device counts.
    public var meanMagnitude: Double
    /// Mean absolute deviation of the vector magnitude from its median, in device counts. Scale-free
    /// with respect to gravity and orientation; used as the "activity" value of a motion epoch.
    public var activity: Double

    public init(sampleCount: Int, meanMagnitude: Double, activity: Double) {
        self.sampleCount = sampleCount
        self.meanMagnitude = meanMagnitude
        self.activity = activity
    }
}

/// One stored-history record decoded from the band.
public struct HistoryRecord: Hashable, Sendable {
    /// Record kind discriminator (e.g. the "K" byte).
    public var kind: UInt8
    /// Band record counter/page (used with the timestamp for de-duplication and restart detection).
    public var counter: UInt32
    /// Band real-time-clock seconds (Unix epoch per public research; mapped through `ClockMapper`).
    public var deviceSeconds: UInt32
    /// Raw sub-second field (unit unverified; not used for timestamps).
    public var subseconds: UInt16
    public var receivedAt: EpochMillis
    /// Heart-rate candidate decoded from the record, if the kind carries one.
    public var heartRate: Int?
    public var heartRateStatus: FieldStatus
    /// Beat-to-beat intervals in ms — only from fields verified to contain measured intervals.
    public var beatIntervalsMillis: [Double]
    public var motion: MotionSummary?
    public var payloadLength: Int

    public init(kind: UInt8, counter: UInt32, deviceSeconds: UInt32, subseconds: UInt16, receivedAt: EpochMillis,
                heartRate: Int?, heartRateStatus: FieldStatus, beatIntervalsMillis: [Double], motion: MotionSummary?, payloadLength: Int) {
        self.kind = kind
        self.counter = counter
        self.deviceSeconds = deviceSeconds
        self.subseconds = subseconds
        self.receivedAt = receivedAt
        self.heartRate = heartRate
        self.heartRateStatus = heartRateStatus
        self.beatIntervalsMillis = beatIntervalsMillis
        self.motion = motion
        self.payloadLength = payloadLength
    }
}

public struct HistoryMarker: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case start, end, complete }
    public var kind: Kind
    /// For `.end`: the opaque token to echo in the acknowledgement (nil when the marker is too short).
    public var ackToken: [UInt8]?
    public var receivedAt: EpochMillis

    public init(kind: Kind, ackToken: [UInt8]?, receivedAt: EpochMillis) {
        self.kind = kind
        self.ackToken = ackToken
        self.receivedAt = receivedAt
    }
}

public struct CommandResponse: Hashable, Sendable {
    public var command: UInt8
    public var sequence: UInt8
    public var originSequence: UInt8?
    public var resultCode: UInt8?
    public var data: [UInt8]
    public var receivedAt: EpochMillis

    public init(command: UInt8, sequence: UInt8, originSequence: UInt8?, resultCode: UInt8?, data: [UInt8], receivedAt: EpochMillis) {
        self.command = command
        self.sequence = sequence
        self.originSequence = originSequence
        self.resultCode = resultCode
        self.data = data
        self.receivedAt = receivedAt
    }
}

public struct DeviceEventRecord: Hashable, Sendable {
    public var eventID: UInt16
    public var name: String
    public var deviceSeconds: UInt32?
    public var data: [UInt8]
    public var receivedAt: EpochMillis

    public init(eventID: UInt16, name: String, deviceSeconds: UInt32?, data: [UInt8], receivedAt: EpochMillis) {
        self.eventID = eventID
        self.name = name
        self.deviceSeconds = deviceSeconds
        self.data = data
        self.receivedAt = receivedAt
    }
}

/// Everything a decoder can report. Unknown and malformed inputs are reported, never silently dropped.
public enum DecodedEvent: Hashable, Sendable {
    /// Bluetooth SIG Heart Rate Measurement (0x2A37). `bpm` is nil when the device reports no reading.
    case standardHeartRate(bpm: Int?, contact: SensorContactState, rrMillis: [Double], energyKJ: Int?, receivedAt: EpochMillis)
    /// Vendor real-time heart rate.
    case realtimeHeartRate(bpm: Int, deviceSeconds: UInt32?, status: FieldStatus, receivedAt: EpochMillis)
    case historyRecord(HistoryRecord)
    case historyMarker(HistoryMarker)
    case commandResponse(CommandResponse)
    case deviceEvent(DeviceEventRecord)
    case batteryLevel(percent: Int, receivedAt: EpochMillis)
    case clockReading(deviceSeconds: UInt32, receivedAt: EpochMillis)
    case deviceInformation(field: String, value: String)
    /// A valid frame of a packet type the decoder does not interpret.
    case unknownPacket(packetType: UInt8, length: Int, characteristic: String, receivedAt: EpochMillis)
    /// Bytes that failed validation (bad checksum, impossible length, truncated record).
    case malformed(reason: String, byteCount: Int, characteristic: String, receivedAt: EpochMillis)
    /// Bytes skipped while resynchronizing (garbage before a frame, partial frame at disconnect).
    case discarded(byteCount: Int, characteristic: String, receivedAt: EpochMillis)
}

// MARK: - Adapter

/// A stateful decoder for one connection (frame reassembly is per characteristic). Not thread-safe:
/// the sync engine calls it from a single task.
public protocol DeviceDecoder: AnyObject {
    func decode(characteristic: String, bytes: [UInt8], receivedAt: EpochMillis) -> [DecodedEvent]
    /// Drop partial frames (call on disconnect). Returns events describing what was discarded.
    func reset(at time: EpochMillis) -> [DecodedEvent]
}

/// Everything family-specific. Adding a band means adding an adapter; nothing else changes.
public protocol DeviceAdapter: Sendable {
    var adapterID: String { get }
    var parserVersion: String { get }
    var family: DeviceFamily { get }
    var gatt: GATTProfile { get }
    var capabilities: [Capability: CapabilityStatus] { get }
    /// Whether `encode` will produce bytes for this command on this adapter.
    func supports(_ command: AllowedCommand) -> Bool
    /// Encodes an allowed command. Throws `CommandEncodingError.unsupported` for anything not supported.
    func encode(_ command: AllowedCommand, sequence: UInt8) throws -> [UInt8]
    func makeDecoder() -> any DeviceDecoder
}
