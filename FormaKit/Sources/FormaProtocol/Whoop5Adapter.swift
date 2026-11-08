import Foundation
import FormaCore

/// Adapter for the WHOOP 5.0 / MG generation, written from publicly documented interoperability facts
/// (see docs/research/SPEC_WHOOP5.md and docs/COMPATIBILITY.md). No third-party code is used.
///
/// Wire format (all integers little-endian):
/// ```
/// frame   = AA 01 LEN(u16) 00 01 HCRC(u16) PAYLOAD PCRC(u32)
/// LEN     = payload length (zero-padded to a multiple of 4 when we build frames) + 4
/// HCRC    = CRC-16/MODBUS over frame[0..<6]
/// PCRC    = CRC-32/ISO-HDLC over the payload
/// payload = type(u8) …   35 command · 36 response · 40/43/47/51/52 data · 48 event · 49 metadata
/// ```
/// Status of every field is tracked: anything not confirmed on the owner's band is decoded as
/// `.unvalidated` and stored as evidence, not used in metrics.
public struct Whoop5Adapter: DeviceAdapter {
    public static let service = "FD4B0001-CCE1-4033-93CE-002D5875F58A"
    public static let commandToStrap = "FD4B0002-CCE1-4033-93CE-002D5875F58A"
    public static let commandFromStrap = "FD4B0003-CCE1-4033-93CE-002D5875F58A"
    public static let eventsFromStrap = "FD4B0004-CCE1-4033-93CE-002D5875F58A"
    public static let dataFromStrap = "FD4B0005-CCE1-4033-93CE-002D5875F58A"
    public static let memfault = "FD4B0007-CCE1-4033-93CE-002D5875F58A"

    /// Command ids (payload byte 2 of a COMMAND packet). Only read-only, stream and history ids appear here.
    public enum CommandID: UInt8, Sendable {
        case abortHistoricalTransmits = 20
        case sendHistoricalData = 22
        case historicalDataResult = 23
        case getDataRange = 34
        case getHello = 145
    }

    public enum PacketType: UInt8, Sendable {
        case command = 35
        case commandResponse = 36
        case realtimeData = 40
        case realtimeRawData = 43
        case historicalData = 47
        case event = 48
        case metadata = 49
        case consoleLogs = 50
        case realtimeIMU = 51
        case historicalIMU = 52
    }

    public let adapterID = "forma.whoop5"
    public let parserVersion = "whoop5-0.1.0"
    public let family = DeviceFamily.whoop5

    public init() {}

    public var gatt: GATTProfile {
        GATTProfile(
            vendorService: Self.service,
            discoverServices: [Self.service, UUIDs.heartRateService, UUIDs.batteryService, UUIDs.deviceInformationService],
            subscribeCharacteristics: [Self.commandFromStrap, Self.eventsFromStrap, Self.dataFromStrap,
                                       UUIDs.heartRateMeasurement, UUIDs.batteryLevel],
            commandCharacteristic: Self.commandToStrap,
            commandWriteWithResponse: true,
            scanServiceFilter: [Self.service],
            nameHints: ["WHOOP"]
        )
    }

    /// What is known per data path. Values reflect public evidence, not the owner's hardware; the app
    /// upgrades entries to `.verifiedOnHardware` only after the matching hardware check passes.
    public var capabilities: [Capability: CapabilityStatus] {
        [
            .standardHeartRate: .documentedUnverified,
            .liveHeartRate: .unsupported,           // vendor real-time toggle payload not documented
            .history: .documentedUnverified,
            .historyHeartRate: .candidateUnvalidated,
            .beatIntervals: .unsupported,           // no validated beat-interval field on this generation
            .motion: .candidateUnvalidated,         // raw accelerometer counts, scale unpublished
            .battery: .documentedUnverified,        // via the standard Battery Service
            .clockRead: .unsupported,               // clock-read response layout not documented
            .skinTemperature: .unsupported,
            .spo2: .unsupported,
        ]
    }

    public func supports(_ command: AllowedCommand) -> Bool {
        switch command {
        case .identify, .readHistoryRange, .requestHistory, .abortHistory: return true
        case .acknowledgeHistory(let token): return token.count == Self.ackTokenLength
        case .readBattery, .readClock, .setRealtimeHeartRate: return false
        }
    }

    /// Length of the opaque token copied from a HistoryEnd marker into the acknowledgement.
    public static let ackTokenLength = 8

    public func encode(_ command: AllowedCommand, sequence: UInt8) throws -> [UInt8] {
        guard supports(command) else { throw CommandEncodingError.unsupported(command.name) }
        let id: CommandID
        var data: [UInt8] = []
        switch command {
        case .identify:
            id = .getHello
            data = [0x01]
        case .readHistoryRange:
            id = .getDataRange
        case .requestHistory:
            id = .sendHistoricalData
        case .abortHistory:
            id = .abortHistoricalTransmits
        case .acknowledgeHistory(let token):
            guard token.count == Self.ackTokenLength else { throw CommandEncodingError.invalidArgument("ack token must be \(Self.ackTokenLength) bytes") }
            id = .historicalDataResult
            data = [0x01] + token   // 0x01 = success, followed by the HistoryEnd token
        default:
            throw CommandEncodingError.unsupported(command.name)
        }
        return Whoop5Wire.frame(payload: [PacketType.command.rawValue, sequence, id.rawValue] + data)
    }

    public func makeDecoder() -> any DeviceDecoder { Whoop5Decoder() }

    /// Wraps a bare payload in a WHOOP 5.0 frame. Used by tools and tests to feed payload-only
    /// captures through the normal decoder.
    public static func frame(payload: [UInt8]) -> [UInt8] { Whoop5Wire.frame(payload: payload) }
}

// MARK: - Wire helpers (CRCs, little-endian reads, frame building)

enum Whoop5Wire {
    static let startOfFrame: UInt8 = 0xAA
    static let headerLength = 8
    /// Largest declared length Forma accepts (the largest public record is ~2 KB).
    static let maxDeclaredLength = 16_384

    /// CRC-16/MODBUS: poly 0x8005 reflected (0xA001), init 0xFFFF, no final xor.
    static func crc16Modbus<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    private static let crc32Table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        return c
    }

    /// CRC-32/ISO-HDLC (zlib): reflected 0x04C11DB7, init and xorout 0xFFFFFFFF.
    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = crc32Table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func u16(_ b: [UInt8], _ o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= b.count else { return nil }
        return UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= b.count else { return nil }
        return UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    static func i16(_ b: [UInt8], _ o: Int) -> Int16? {
        u16(b, o).map { Int16(bitPattern: $0) }
    }

    /// Builds a frame: pads the payload with zeros to a multiple of 4, then adds header and CRCs.
    static func frame(payload: [UInt8]) -> [UInt8] {
        var padded = payload
        while padded.count % 4 != 0 { padded.append(0) }
        let declared = UInt16(padded.count + 4)
        var out: [UInt8] = [startOfFrame, 0x01, UInt8(declared & 0xFF), UInt8(declared >> 8), 0x00, 0x01]
        let hcrc = crc16Modbus(out)
        out += [UInt8(hcrc & 0xFF), UInt8(hcrc >> 8)]
        out += padded
        let pcrc = crc32(padded)
        out += [UInt8(pcrc & 0xFF), UInt8(pcrc >> 8 & 0xFF), UInt8(pcrc >> 16 & 0xFF), UInt8(pcrc >> 24 & 0xFF)]
        return out
    }
}

// MARK: - Frame reassembly

/// Reassembles WHOOP 5.0 frames from notification chunks for one characteristic.
/// The header CRC is checked BEFORE the declared length is trusted, so a stray 0xAA inside data cannot
/// desynchronize the stream. The buffer is bounded.
struct Whoop5Deframer {
    enum Output: Equatable {
        case frame(payload: [UInt8], receivedAt: EpochMillis)
        case malformed(reason: String, byteCount: Int)
        case discarded(byteCount: Int)
    }

    private var buffer: [UInt8] = []
    private var firstChunkTime: EpochMillis?
    static let maxBuffer = Whoop5Wire.maxDeclaredLength * 2

    mutating func append(_ chunk: [UInt8], receivedAt: EpochMillis) -> [Output] {
        if buffer.isEmpty { firstChunkTime = receivedAt }
        buffer.append(contentsOf: chunk)
        var out: [Output] = []
        while true {
            // 1. Skip to the next start-of-frame byte.
            guard let sof = buffer.firstIndex(of: Whoop5Wire.startOfFrame) else {
                if !buffer.isEmpty { out.append(.discarded(byteCount: buffer.count)) }
                buffer.removeAll()
                firstChunkTime = nil
                break
            }
            if sof > 0 {
                out.append(.discarded(byteCount: sof))
                buffer.removeFirst(sof)
            }
            // 2. Need a full header.
            guard buffer.count >= Whoop5Wire.headerLength else { break }
            let storedHeaderCRC = Whoop5Wire.u16(buffer, 6) ?? 0
            let computed = Whoop5Wire.crc16Modbus(buffer[0..<6])
            guard storedHeaderCRC == computed else {
                // Not a real header: drop this 0xAA and resynchronize.
                out.append(.discarded(byteCount: 1))
                buffer.removeFirst()
                continue
            }
            let declared = Int(Whoop5Wire.u16(buffer, 2) ?? 0)
            guard declared >= 4, declared <= Whoop5Wire.maxDeclaredLength else {
                out.append(.malformed(reason: "declared length \(declared) out of range", byteCount: Whoop5Wire.headerLength))
                buffer.removeFirst(Whoop5Wire.headerLength)
                continue
            }
            let total = Whoop5Wire.headerLength + declared
            // 3. Wait for the whole frame.
            guard buffer.count >= total else {
                if buffer.count > Self.maxBuffer {
                    out.append(.discarded(byteCount: buffer.count))
                    buffer.removeAll()
                    firstChunkTime = nil
                }
                break
            }
            let payload = Array(buffer[Whoop5Wire.headerLength..<(total - 4)])
            let storedCRC = Whoop5Wire.u32(buffer, total - 4) ?? 0
            let at = firstChunkTime ?? receivedAt
            if Whoop5Wire.crc32(payload) == storedCRC {
                out.append(.frame(payload: payload, receivedAt: at))
            } else {
                out.append(.malformed(reason: "payload CRC mismatch", byteCount: total))
            }
            buffer.removeFirst(total)
            firstChunkTime = buffer.isEmpty ? nil : receivedAt
        }
        return out
    }

    /// Drops any partial frame (disconnect). Returns the number of bytes discarded.
    mutating func reset() -> Int {
        let n = buffer.count
        buffer.removeAll()
        firstChunkTime = nil
        return n
    }
}

// MARK: - Decoder

public final class Whoop5Decoder: DeviceDecoder {
    private var deframers: [String: Whoop5Deframer] = [:]

    /// Event ids known from public documentation (names only; bodies are not decoded).
    static let eventNames: [UInt16: String] = [
        0: "UNDEFINED", 1: "ERROR", 2: "CONSOLE_OUTPUT", 3: "BATTERY_LEVEL", 4: "SYSTEM_CONTROL", 7: "CHARGING_ON",
        8: "CHARGING_OFF", 9: "WRIST_ON", 10: "WRIST_OFF", 11: "BLE_CONNECTION_UP", 12: "BLE_CONNECTION_DOWN",
        13: "RTC_LOST", 14: "DOUBLE_TAP", 15: "BOOT", 16: "SET_RTC", 17: "TEMPERATURE_LEVEL", 18: "PAIRING_MODE",
        28: "FLASH_INIT_COMPLETE", 29: "STRAP_CONDITION_REPORT", 33: "BLE_REALTIME_HR_ON", 34: "BLE_REALTIME_HR_OFF",
        63: "EXTENDED_BATTERY_INFORMATION", 96: "HIGH_FREQ_SYNC_PROMPT", 97: "HIGH_FREQ_SYNC_ENABLED",
        98: "HIGH_FREQ_SYNC_DISABLED", 109: "BATTERY_PACK_INFO", 123: "GENERIC_FIRMWARE_EVENT",
    ]

    public init() {}

    public func decode(characteristic: String, bytes: [UInt8], receivedAt: EpochMillis) -> [DecodedEvent] {
        let c = UUIDs.normalize(characteristic)
        switch c {
        case UUIDs.heartRateMeasurement:
            return [StandardServiceParsing.heartRate(bytes, characteristic: c, receivedAt: receivedAt)]
        case UUIDs.batteryLevel:
            return StandardServiceParsing.battery(bytes, characteristic: c, receivedAt: receivedAt)
        case UUIDs.firmwareRevision, UUIDs.hardwareRevision, UUIDs.modelNumber, UUIDs.manufacturerName, UUIDs.softwareRevision:
            return StandardServiceParsing.deviceInformation(bytes, characteristic: c)
        case Whoop5Adapter.commandFromStrap, Whoop5Adapter.eventsFromStrap, Whoop5Adapter.dataFromStrap, Whoop5Adapter.memfault:
            var deframer = deframers[c] ?? Whoop5Deframer()
            let outputs = deframer.append(bytes, receivedAt: receivedAt)
            deframers[c] = deframer
            var events: [DecodedEvent] = []
            for o in outputs {
                switch o {
                case .frame(let payload, let at): events.append(contentsOf: decodePayload(payload, characteristic: c, receivedAt: at))
                case .malformed(let reason, let n): events.append(.malformed(reason: reason, byteCount: n, characteristic: c, receivedAt: receivedAt))
                case .discarded(let n): events.append(.discarded(byteCount: n, characteristic: c, receivedAt: receivedAt))
                }
            }
            return events
        default:
            return [.unknownPacket(packetType: 0, length: bytes.count, characteristic: c, receivedAt: receivedAt)]
        }
    }

    public func reset(at time: EpochMillis) -> [DecodedEvent] {
        var events: [DecodedEvent] = []
        for (c, var d) in deframers {
            let n = d.reset()
            if n > 0 { events.append(.discarded(byteCount: n, characteristic: c, receivedAt: time)) }
        }
        deframers.removeAll()
        return events
    }

    func decodePayload(_ p: [UInt8], characteristic: String, receivedAt: EpochMillis) -> [DecodedEvent] {
        guard let typeByte = p.first else {
            return [.malformed(reason: "empty payload", byteCount: 0, characteristic: characteristic, receivedAt: receivedAt)]
        }
        switch Whoop5Adapter.PacketType(rawValue: typeByte) {
        case .commandResponse:
            guard p.count >= 5 else { return [.malformed(reason: "response shorter than 5 bytes", byteCount: p.count, characteristic: characteristic, receivedAt: receivedAt)] }
            return [.commandResponse(CommandResponse(command: p[2], sequence: p[1], originSequence: p[3], resultCode: p[4],
                                                     data: Array(p[5...]), receivedAt: receivedAt))]
        case .event:
            guard let id = Whoop5Wire.u16(p, 2) else { return [.malformed(reason: "event shorter than 4 bytes", byteCount: p.count, characteristic: characteristic, receivedAt: receivedAt)] }
            // The event timestamp layout is not confirmed by real captures, so it is not used.
            return [.deviceEvent(DeviceEventRecord(eventID: id, name: Self.eventNames[id] ?? "EVENT_\(id)", deviceSeconds: nil,
                                                   data: Array(p.dropFirst(4)), receivedAt: receivedAt))]
        case .metadata:
            guard p.count >= 3 else { return [.malformed(reason: "metadata shorter than 3 bytes", byteCount: p.count, characteristic: characteristic, receivedAt: receivedAt)] }
            switch p[2] {
            case 1: return [.historyMarker(HistoryMarker(kind: .start, ackToken: nil, receivedAt: receivedAt))]
            case 2:
                // The acknowledgement echoes 8 bytes of the end marker (payload 13..<21); shorter markers carry no token.
                let token: [UInt8]? = p.count > 21 ? Array(p[13..<21]) : nil
                return [.historyMarker(HistoryMarker(kind: .end, ackToken: token, receivedAt: receivedAt))]
            case 3: return [.historyMarker(HistoryMarker(kind: .complete, ackToken: nil, receivedAt: receivedAt))]
            default: return [.unknownPacket(packetType: typeByte, length: p.count, characteristic: characteristic, receivedAt: receivedAt)]
            }
        case .historicalData:
            return [decodeDataRecord(p, characteristic: characteristic, receivedAt: receivedAt)].compactMap { $0 }
        case .realtimeData, .realtimeRawData, .realtimeIMU, .historicalIMU, .command, .consoleLogs, .none:
            return [.unknownPacket(packetType: typeByte, length: p.count, characteristic: characteristic, receivedAt: receivedAt)]
        }
    }

    /// Common 13-byte data header, then per-kind body fields.
    func decodeDataRecord(_ p: [UInt8], characteristic: String, receivedAt: EpochMillis) -> DecodedEvent? {
        guard p.count >= 13, let counter = Whoop5Wire.u32(p, 3), let seconds = Whoop5Wire.u32(p, 7), let sub = Whoop5Wire.u16(p, 11) else {
            return .malformed(reason: "data record shorter than its 13-byte header", byteCount: p.count, characteristic: characteristic, receivedAt: receivedAt)
        }
        let kind = p[1]
        var heartRate: Int?
        var motion: MotionSummary?
        let hrOffset: Int?
        switch kind {
        case 9, 12, 24: hrOffset = 17
        case 18: hrOffset = 14
        case 7: hrOffset = 27
        case 10: hrOffset = 17
        default: hrOffset = nil
        }
        if let o = hrOffset, o < p.count, p[o] != 0 { heartRate = Int(p[o]) }
        if kind == 10 { motion = Self.motionSummaryK10(p) }
        return .historyRecord(HistoryRecord(kind: kind, counter: counter, deviceSeconds: seconds, subseconds: sub, receivedAt: receivedAt,
                                            heartRate: heartRate, heartRateStatus: .unvalidated, beatIntervalsMillis: [],
                                            motion: motion, payloadLength: p.count))
    }

    /// K10: 100 × i16 accelerometer samples per axis at payload offsets 85 (x), 285 (y), 485 (z).
    /// Returns nil when the record is too short to contain all three axes.
    static func motionSummaryK10(_ p: [UInt8]) -> MotionSummary? {
        let count = 100
        let offsets = [85, 285, 485]
        guard offsets.allSatisfy({ $0 + count * 2 <= p.count }) else { return nil }
        var magnitudes: [Double] = []
        magnitudes.reserveCapacity(count)
        for i in 0..<count {
            guard let x = Whoop5Wire.i16(p, offsets[0] + 2 * i), let y = Whoop5Wire.i16(p, offsets[1] + 2 * i),
                  let z = Whoop5Wire.i16(p, offsets[2] + 2 * i) else { return nil }
            let dx = Double(x), dy = Double(y), dz = Double(z)
            magnitudes.append((dx * dx + dy * dy + dz * dz).squareRoot())
        }
        let sorted = magnitudes.sorted()
        let median = (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        let mean = magnitudes.reduce(0, +) / Double(count)
        let activity = magnitudes.reduce(0) { $0 + abs($1 - median) } / Double(count)
        return MotionSummary(sampleCount: count, meanMagnitude: mean, activity: activity)
    }
}

// MARK: - Bluetooth SIG standard services

/// Minimal parsers for SIG characteristics, shared by adapters. (Heart Rate Measurement per the
/// Heart Rate Service specification: flags; UINT8/UINT16 HR; optional energy; RR in 1/1024 s.)
enum StandardServiceParsing {
    static func heartRate(_ b: [UInt8], characteristic: String, receivedAt: EpochMillis) -> DecodedEvent {
        guard let flags = b.first else {
            return .malformed(reason: "empty heart rate measurement", byteCount: 0, characteristic: characteristic, receivedAt: receivedAt)
        }
        var o = 1
        let bpmRaw: Int
        if flags & 0x01 == 0 {
            guard b.count >= 2 else { return .malformed(reason: "heart rate measurement too short", byteCount: b.count, characteristic: characteristic, receivedAt: receivedAt) }
            bpmRaw = Int(b[1]); o = 2
        } else {
            guard let v = Whoop5Wire.u16(b, 1) else { return .malformed(reason: "heart rate measurement too short", byteCount: b.count, characteristic: characteristic, receivedAt: receivedAt) }
            bpmRaw = Int(v); o = 3
        }
        let contact: SensorContactState = flags & 0x04 == 0 ? .notSupported : (flags & 0x02 != 0 ? .detected : .notDetected)
        var energy: Int?
        if flags & 0x08 != 0 {
            guard let e = Whoop5Wire.u16(b, o) else { return .malformed(reason: "energy field truncated", byteCount: b.count, characteristic: characteristic, receivedAt: receivedAt) }
            energy = Int(e); o += 2
        }
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            guard (b.count - o) % 2 == 0 else { return .malformed(reason: "odd number of RR bytes", byteCount: b.count, characteristic: characteristic, receivedAt: receivedAt) }
            while o + 2 <= b.count {
                rr.append(Double(Whoop5Wire.u16(b, o) ?? 0) * 1_000 / 1_024)
                o += 2
            }
        }
        return .standardHeartRate(bpm: bpmRaw == 0 ? nil : bpmRaw, contact: contact, rrMillis: rr, energyKJ: energy, receivedAt: receivedAt)
    }

    static func battery(_ b: [UInt8], characteristic: String, receivedAt: EpochMillis) -> [DecodedEvent] {
        guard b.count == 1, b[0] <= 100 else {
            return [.malformed(reason: "battery level must be one byte 0–100", byteCount: b.count, characteristic: characteristic, receivedAt: receivedAt)]
        }
        return [.batteryLevel(percent: Int(b[0]), receivedAt: receivedAt)]
    }

    static func deviceInformation(_ b: [UInt8], characteristic: String) -> [DecodedEvent] {
        let field: String
        switch characteristic {
        case UUIDs.firmwareRevision: field = "firmware"
        case UUIDs.hardwareRevision: field = "hardware"
        case UUIDs.modelNumber: field = "model"
        case UUIDs.manufacturerName: field = "manufacturer"
        default: field = "software"
        }
        let text = String(decoding: b.prefix(64), as: UTF8.self).trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        guard !text.isEmpty else { return [] }
        return [.deviceInformation(field: field, value: text)]
    }
}

// MARK: - Generic standard heart-rate sensor

/// Adapter for any band that exposes only the Bluetooth SIG Heart Rate Service (also used as the
/// fallback when a WHOOP band broadcasts standard heart rate but its vendor path is unavailable).
public struct StandardHeartRateAdapter: DeviceAdapter {
    public let adapterID = "forma.standard-hr"
    public let parserVersion = "standard-hr-1.0.0"
    public let family = DeviceFamily.standardHeartRate

    public init() {}

    public var gatt: GATTProfile {
        GATTProfile(vendorService: nil,
                    discoverServices: [UUIDs.heartRateService, UUIDs.batteryService, UUIDs.deviceInformationService],
                    subscribeCharacteristics: [UUIDs.heartRateMeasurement, UUIDs.batteryLevel],
                    commandCharacteristic: nil, commandWriteWithResponse: true,
                    scanServiceFilter: [UUIDs.heartRateService], nameHints: [])
    }

    public var capabilities: [Capability: CapabilityStatus] {
        [.standardHeartRate: .documentedUnverified, .liveHeartRate: .documentedUnverified, .history: .unsupported,
         .historyHeartRate: .unsupported, .beatIntervals: .documentedUnverified, .motion: .unsupported,
         .battery: .documentedUnverified, .clockRead: .unsupported, .skinTemperature: .unsupported, .spo2: .unsupported]
    }

    public func supports(_ command: AllowedCommand) -> Bool { false }

    public func encode(_ command: AllowedCommand, sequence: UInt8) throws -> [UInt8] {
        throw CommandEncodingError.unsupported(command.name)
    }

    public func makeDecoder() -> any DeviceDecoder { StandardHeartRateDecoder() }
}

public final class StandardHeartRateDecoder: DeviceDecoder {
    public init() {}

    public func decode(characteristic: String, bytes: [UInt8], receivedAt: EpochMillis) -> [DecodedEvent] {
        let c = UUIDs.normalize(characteristic)
        switch c {
        case UUIDs.heartRateMeasurement: return [StandardServiceParsing.heartRate(bytes, characteristic: c, receivedAt: receivedAt)]
        case UUIDs.batteryLevel: return StandardServiceParsing.battery(bytes, characteristic: c, receivedAt: receivedAt)
        case UUIDs.firmwareRevision, UUIDs.hardwareRevision, UUIDs.modelNumber, UUIDs.manufacturerName, UUIDs.softwareRevision:
            return StandardServiceParsing.deviceInformation(bytes, characteristic: c)
        default: return [.unknownPacket(packetType: 0, length: bytes.count, characteristic: c, receivedAt: receivedAt)]
        }
    }

    public func reset(at time: EpochMillis) -> [DecodedEvent] { [] }
}

/// Picks an adapter from the services actually discovered on a connected peripheral.
public enum AdapterRegistry {
    public static let all: [any DeviceAdapter] = [Whoop5Adapter(), StandardHeartRateAdapter()]

    public static func adapter(forDiscoveredServices services: [String]) -> (any DeviceAdapter)? {
        let normalized = Set(services.map(UUIDs.normalize))
        if normalized.contains(Whoop5Adapter.service) { return Whoop5Adapter() }
        if normalized.contains(UUIDs.heartRateService) { return StandardHeartRateAdapter() }
        return nil
    }

    public static func adapter(for family: DeviceFamily) -> (any DeviceAdapter)? {
        switch family {
        case .whoop5: return Whoop5Adapter()
        case .standardHeartRate: return StandardHeartRateAdapter()
        case .whoop4, .unknown: return nil
        }
    }
}
