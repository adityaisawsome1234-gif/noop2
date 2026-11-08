import Foundation
import FormaCore

/// Adapter for the WHOOP 5.0 / MG generation, written from publicly documented interoperability facts
/// (see docs/COMPATIBILITY.md and docs/LICENSE_AUDIT.md). No third-party code is used.
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

    /// Command ids (payload byte 2 of a COMMAND packet). Only read-only, stream and history ids appear
    /// here; nothing that resets, erases, updates firmware, writes the clock or changes persistent
    /// configuration can be expressed.
    public enum CommandID: UInt8, Sendable, CaseIterable {
        /// TOGGLE_REALTIME_HR, data `01` on / `00` off (non-destructive stream toggle).
        case toggleRealtimeHR = 3
        /// GET_CLOCK, no data. Response body: u32 Unix seconds + u32 sub-seconds in 1/32768 s.
        case getClock = 11
        /// ABORT_HISTORICAL_TRANSMITS. Encodable for completeness but NOT supported: the only live
        /// reference client never sends it and its effect on the band's history pointer is unverified.
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

    /// Result byte of a COMMAND_RESPONSE (payload[4]) as used by the public reference client.
    public static let resultSuccess: UInt8 = 1
    public static let resultPending: UInt8 = 2

    public let adapterID = "forma.whoop5"
    public let parserVersion = "whoop5-0.2.0"
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
            .standardHeartRate: .unknown,           // whether 5.0 exposes/enables 180D/2A37 is not established
            .liveHeartRate: .candidateUnvalidated,  // vendor real-time frames: HR byte decoded, meaning unvalidated
            .history: .documentedUnverified,        // download flow from the public reference client
            .historyHeartRate: .candidateUnvalidated,
            .beatIntervals: .unsupported,           // no validated beat-interval field on this generation
            .motion: .candidateUnvalidated,         // raw accelerometer counts, scale and rate unpublished
            .battery: .unknown,                     // standard Battery Service, presence on 5.0 second-hand only
            .clockRead: .documentedUnverified,      // GET_CLOCK layout from the public reference client
            .skinTemperature: .unsupported,
            .spo2: .unsupported,
        ]
    }

    public func supports(_ command: AllowedCommand) -> Bool {
        switch command {
        case .identify, .readClock, .readHistoryRange, .requestHistory, .setRealtimeHeartRate: return true
        case .acknowledgeHistory(let token): return token.count == Self.ackTokenLength
        // Battery comes from the standard Battery Service; abort is never sent (see CommandID).
        case .readBattery, .abortHistory: return false
        }
    }

    /// Length of the opaque token copied from a HistoryEnd marker into the acknowledgement.
    public static let ackTokenLength = 8

    public func encode(_ command: AllowedCommand, sequence: UInt8) throws -> EncodedCommand {
        guard supports(command) else { throw CommandEncodingError.unsupported(command.name) }
        let id: CommandID
        var data: [UInt8] = []
        switch command {
        case .identify:
            id = .getHello
            data = [0x01]
        case .readClock:
            id = .getClock
        case .readHistoryRange:
            id = .getDataRange
        case .requestHistory:
            id = .sendHistoricalData
        case .setRealtimeHeartRate(let on):
            id = .toggleRealtimeHR
            data = [on ? 0x01 : 0x00]
        case .acknowledgeHistory(let token):
            guard token.count == Self.ackTokenLength else { throw CommandEncodingError.invalidArgument("ack token must be \(Self.ackTokenLength) bytes") }
            id = .historicalDataResult
            data = [0x01] + token   // 0x01 = success, followed by the HistoryEnd token
        case .readBattery, .abortHistory:
            throw CommandEncodingError.unsupported(command.name)
        }
        let bytes = try Whoop5Wire.frame(payload: [PacketType.command.rawValue, sequence, id.rawValue] + data)
        return EncodedCommand(command: command, sequence: sequence, bytes: bytes)
    }

    public func makeDecoder() -> any DeviceDecoder { Whoop5Decoder() }

    /// Wraps a bare payload in a WHOOP 5.0 frame so tools and tests can feed payload-only captures
    /// through the normal decoder. The result is plain bytes: it cannot be written to a band, because
    /// links accept only adapter-encoded commands.
    public static func frame(payload: [UInt8]) throws -> [UInt8] { try Whoop5Wire.frame(payload: payload) }

    /// Which allowlisted command a response's command id answers.
    static func answeredCommand(_ id: UInt8) -> AllowedCommand.Kind? {
        switch CommandID(rawValue: id) {
        case .getHello: return .identify
        case .getClock: return .readClock
        case .getDataRange: return .readHistoryRange
        case .sendHistoricalData: return .requestHistory
        case .historicalDataResult: return .acknowledgeHistory
        case .toggleRealtimeHR: return .setRealtimeHeartRate
        case .abortHistoricalTransmits: return .abortHistory
        case .none: return nil
        }
    }

    /// 1 success and 2 pending are agreed by every public source. 0 is contested (the reference client
    /// calls it FAILURE, the reference emulator counts it as success), so it is `.unknown`; Forma only
    /// proceeds on an explicit success. Anything else (3 UNSUPPORTED, …) is a refusal.
    static func status(ofResult result: UInt8) -> CommandStatus {
        switch result {
        case resultSuccess: return .success
        case resultPending: return .pending
        case 0: return .unknown
        default: return .rejected
        }
    }
}

public enum FrameBuildError: Error, Equatable, Sendable {
    case payloadTooLarge(bytes: Int, maximum: Int)
}

// MARK: - Wire helpers (CRCs, little-endian reads, frame building)

enum Whoop5Wire {
    static let startOfFrame: UInt8 = 0xAA
    static let headerLength = 8
    /// The declared length is a u16; every value from 4 up is structurally possible.
    static let maxDeclaredLength = Int(UInt16.max)
    /// Largest payload the builder accepts (padded payload + 4 must fit the u16 length field).
    static let maxPayloadLength = maxDeclaredLength - 4 - 3

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
    static func frame(payload: [UInt8]) throws -> [UInt8] {
        guard payload.count <= maxPayloadLength else {
            throw FrameBuildError.payloadTooLarge(bytes: payload.count, maximum: maxPayloadLength)
        }
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
///
/// - The header CRC is checked BEFORE the declared length is trusted.
/// - A frame whose payload CRC fails costs only its start byte: scanning resumes at the next byte, so
///   genuine frames inside a bogus or truncated span are recovered (each has its own two CRCs).
/// - While a long frame is still arriving, the bytes after its start are searched for a complete
///   frame that passes both CRCs; finding one proves the pending frame was truncated, and its start byte
///   is dropped. Frames and reported counts are the same however notifications split the stream.
/// - Each frame carries the receive time of the notification that held its first byte.
/// - The buffer holds at most one pending frame (≤ 8 + 65 535 bytes) plus the latest chunk; garbage
///   without a start byte is discarded immediately. Bytes are consumed through a read index (linear time).
struct Whoop5Deframer {
    enum Output: Equatable {
        case frame(payload: [UInt8], receivedAt: EpochMillis)
        case malformed(reason: String, byteCount: Int)
        case discarded(byteCount: Int)
    }

    private var buffer: [UInt8] = []
    private var start = 0
    /// (buffer index of a chunk's first byte, its receive time), ascending.
    private var chunkTimes: [(index: Int, at: EpochMillis)] = []
    /// Where the truncation look-ahead resumes for the current pending frame.
    private var lookaheadFrom: Int?

    var pendingByteCount: Int { buffer.count - start }

    mutating func append(_ chunk: [UInt8], receivedAt: EpochMillis) -> [Output] {
        guard !chunk.isEmpty else { return [] }
        compact()
        chunkTimes.append((buffer.count, receivedAt))
        buffer.append(contentsOf: chunk)
        var out: [Output] = []
        while start < buffer.count {
            // 1. Skip to the next start-of-frame byte.
            guard let sof = buffer[start...].firstIndex(of: Whoop5Wire.startOfFrame) else {
                out.append(.discarded(byteCount: buffer.count - start))
                consume(to: buffer.count)
                break
            }
            if sof > start {
                out.append(.discarded(byteCount: sof - start))
                consume(to: sof)
            }
            // 2. Need a full header.
            guard buffer.count - start >= Whoop5Wire.headerLength else { break }
            guard headerIsValid(at: start) else {
                // Not a real header: drop this 0xAA and resynchronize.
                out.append(.discarded(byteCount: 1))
                consume(to: start + 1)
                continue
            }
            let declared = Int(Whoop5Wire.u16(buffer, start + 2) ?? 0)
            guard declared >= 4 else {
                out.append(.malformed(reason: "declared length \(declared) out of range", byteCount: 1))
                consume(to: start + 1)
                continue
            }
            let total = Whoop5Wire.headerLength + declared
            // 3. Complete frame: check the payload CRC.
            if buffer.count - start >= total {
                lookaheadFrom = nil
                if payloadIsValid(at: start, total: total) {
                    let payload = Array(buffer[(start + Whoop5Wire.headerLength)..<(start + total - 4)])
                    out.append(.frame(payload: payload, receivedAt: time(of: start)))
                    consume(to: start + total)
                } else {
                    out.append(.malformed(reason: "payload CRC mismatch", byteCount: 1))
                    consume(to: start + 1)
                }
                continue
            }
            // 4. Still arriving: a complete valid frame starting inside the pending span means it was truncated.
            //    Like a CRC failure, that costs only the start byte; rescanning then reaches the valid frame
            //    (so the outcome does not depend on how notifications split the stream).
            if completeFrameStart(after: start) != nil {
                out.append(.malformed(reason: "frame truncated (declared \(declared) bytes)", byteCount: 1))
                consume(to: start + 1)
                lookaheadFrom = nil
                continue
            }
            break
        }
        return out
    }

    /// Drops any partial frame (disconnect). Returns the number of bytes discarded.
    mutating func reset() -> Int {
        let n = buffer.count - start
        buffer.removeAll()
        start = 0
        chunkTimes.removeAll()
        lookaheadFrom = nil
        return n
    }

    // MARK: Helpers

    private func headerIsValid(at i: Int) -> Bool {
        guard let stored = Whoop5Wire.u16(buffer, i + 6) else { return false }
        return Whoop5Wire.crc16Modbus(buffer[i..<(i + 6)]) == stored
    }

    private func payloadIsValid(at i: Int, total: Int) -> Bool {
        guard let stored = Whoop5Wire.u32(buffer, i + total - 4) else { return false }
        return Whoop5Wire.crc32(buffer[(i + Whoop5Wire.headerLength)..<(i + total - 4)]) == stored
    }

    /// First index after `pending` where a complete frame passing both CRCs starts, if any. Candidates
    /// that are not complete yet are revisited on the next append (the search resumes at the first one).
    private mutating func completeFrameStart(after pending: Int) -> Int? {
        var j = max(pending + 1, lookaheadFrom ?? 0)
        var firstUndecided: Int?
        while j + Whoop5Wire.headerLength <= buffer.count, let k = buffer[j...].firstIndex(of: Whoop5Wire.startOfFrame) {
            j = k
            guard j + Whoop5Wire.headerLength <= buffer.count else { break }
            if headerIsValid(at: j) {
                let declared = Int(Whoop5Wire.u16(buffer, j + 2) ?? 0)
                let total = Whoop5Wire.headerLength + declared
                if declared >= 4 {
                    if j + total <= buffer.count {
                        if payloadIsValid(at: j, total: total) { return j }
                    } else if firstUndecided == nil {
                        firstUndecided = j
                    }
                }
            }
            j += 1
        }
        lookaheadFrom = firstUndecided ?? max(pending + 1, buffer.count - Whoop5Wire.headerLength + 1)
        return nil
    }

    private func time(of index: Int) -> EpochMillis {
        var at = chunkTimes.first?.at ?? 0
        for entry in chunkTimes {
            if entry.index <= index { at = entry.at } else { break }
        }
        return at
    }

    private mutating func consume(to index: Int) {
        start = min(index, buffer.count)
        // Keep only the chunk entry that covers `start` and later ones.
        while chunkTimes.count > 1, chunkTimes[1].index <= start { chunkTimes.removeFirst() }
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
            chunkTimes.removeAll()
            lookaheadFrom = nil
        }
    }

    private mutating func compact() {
        guard start > 0 else { return }
        buffer.removeFirst(start)
        chunkTimes = chunkTimes.map { (max(0, $0.index - start), $0.at) }
        if let l = lookaheadFrom { lookaheadFrom = max(0, l - start) }
        start = 0
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

    /// Record kinds whose content Forma decodes (heart-rate candidate and/or motion summary).
    static let decodedKinds: Set<UInt8> = [7, 9, 10, 12, 18, 24]

    public init() {}

    public func pendingPartialBytes(excluding characteristic: String) -> Int {
        let excluded = UUIDs.normalize(characteristic)
        return deframers.reduce(0) { $0 + ($1.key == excluded ? 0 : $1.value.pendingByteCount) }
    }

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
        for (c, var d) in deframers.sorted(by: { $0.key < $1.key }) {
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
            let data = Array(p[5...])
            let response = CommandResponse(command: p[2], sequence: p[1], originSequence: p[3], resultCode: p[4], data: data,
                                           receivedAt: receivedAt, answers: Whoop5Adapter.answeredCommand(p[2]),
                                           status: Whoop5Adapter.status(ofResult: p[4]))
            var events: [DecodedEvent] = [.commandResponse(response)]
            if p[2] == Whoop5Adapter.CommandID.getClock.rawValue, p[4] == Whoop5Adapter.resultSuccess,
               let seconds = Whoop5Wire.u32(data, 0), let sub = Whoop5Wire.u32(data, 4) {
                // Sub-seconds are 1/32768 s per the reference client; anything out of range is ignored.
                let subMillis: Int? = sub < 32_768 ? Int(sub) * 1_000 / 32_768 : nil
                events.append(.clockReading(deviceSeconds: seconds, subsecondMillis: subMillis, receivedAt: receivedAt))
            }
            return events
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
            return [decodeHistoryRecord(p, characteristic: characteristic, receivedAt: receivedAt)]
        case .historicalIMU:
            // Part of a history transfer, but Forma does not store raw IMU streams: reported as undecoded
            // history so a chunk containing it is never acknowledged.
            guard p.count >= 13, let counter = Whoop5Wire.u32(p, 3), let seconds = Whoop5Wire.u32(p, 7), let sub = Whoop5Wire.u16(p, 11) else {
                return [.malformed(reason: "history IMU frame shorter than its 13-byte header", byteCount: p.count, characteristic: characteristic, receivedAt: receivedAt)]
            }
            return [.historyRecord(HistoryRecord(kind: p[1], counter: counter, deviceSeconds: seconds, subseconds: sub, receivedAt: receivedAt,
                                                 heartRate: nil, heartRateStatus: .unvalidated, beatIntervalsMillis: [], motion: nil,
                                                 payloadLength: p.count, contentDecoded: false))]
        case .realtimeData, .realtimeRawData, .realtimeIMU:
            if p.count >= 13, let seconds = Whoop5Wire.u32(p, 7), let bpm = Self.heartRateCandidate(p) {
                return [.realtimeHeartRate(bpm: bpm, deviceSeconds: seconds, status: .unvalidated, receivedAt: receivedAt)]
            }
            return [.unknownPacket(packetType: typeByte, length: p.count, characteristic: characteristic, receivedAt: receivedAt)]
        case .command, .consoleLogs, .none:
            return [.unknownPacket(packetType: typeByte, length: p.count, characteristic: characteristic, receivedAt: receivedAt)]
        }
    }

    /// Heart-rate candidate byte by record kind (public research; meaning unvalidated). 0 means "no reading".
    static func heartRateCandidate(_ p: [UInt8]) -> Int? {
        guard p.count >= 2 else { return nil }
        let offset: Int
        switch p[1] {
        case 9, 10, 12, 24: offset = 17
        case 18: offset = 14
        case 7: offset = 27
        default: return nil
        }
        guard offset < p.count, p[offset] != 0 else { return nil }
        return Int(p[offset])
    }

    /// Common 13-byte data header, then per-kind body fields.
    func decodeHistoryRecord(_ p: [UInt8], characteristic: String, receivedAt: EpochMillis) -> DecodedEvent {
        guard p.count >= 13, let counter = Whoop5Wire.u32(p, 3), let seconds = Whoop5Wire.u32(p, 7), let sub = Whoop5Wire.u16(p, 11) else {
            return .malformed(reason: "data record shorter than its 13-byte header", byteCount: p.count, characteristic: characteristic, receivedAt: receivedAt)
        }
        let kind = p[1]
        let decoded = Self.decodedKinds.contains(kind)
        return .historyRecord(HistoryRecord(kind: kind, counter: counter, deviceSeconds: seconds, subseconds: sub, receivedAt: receivedAt,
                                            heartRate: decoded ? Self.heartRateCandidate(p) : nil, heartRateStatus: .unvalidated,
                                            beatIntervalsMillis: [], motion: kind == 10 ? Self.motionSummaryK10(p) : nil,
                                            payloadLength: p.count, contentDecoded: decoded))
    }

    /// Samples per axis in a K10 record (payload byte 18 holds this count in every public capture).
    static let k10SamplesPerAxis = 100
    /// ASSUMPTION (unverified): 50 Hz sampling, so 100 samples span 2 s. No public source states the
    /// rate; it only matters when the user lets unvalidated motion feed sleep candidates.
    static let k10AssumedSpanMillis: Int64 = 2_000

    /// K10: 100 × i16 accelerometer samples per axis at payload offsets 85 (x), 285 (y), 485 (z).
    /// Returns nil (no measurement) when the record is too short, its sample-count byte is not 100,
    /// or the block is zero-filled: a working accelerometer always measures gravity, so zero vectors
    /// are absent samples, not stillness.
    static func motionSummaryK10(_ p: [UInt8]) -> MotionSummary? {
        let count = k10SamplesPerAxis
        let offsets = [85, 285, 485]
        guard p.count > 18, Int(p[18]) == count, offsets.allSatisfy({ $0 + count * 2 <= p.count }) else { return nil }
        var magnitudes: [Double] = []
        magnitudes.reserveCapacity(count)
        var zeroVectors = 0
        for i in 0..<count {
            guard let x = Whoop5Wire.i16(p, offsets[0] + 2 * i), let y = Whoop5Wire.i16(p, offsets[1] + 2 * i),
                  let z = Whoop5Wire.i16(p, offsets[2] + 2 * i) else { return nil }
            if x == 0, y == 0, z == 0 { zeroVectors += 1 }
            let dx = Double(x), dy = Double(y), dz = Double(z)
            magnitudes.append((dx * dx + dy * dy + dz * dz).squareRoot())
        }
        guard zeroVectors <= 2 else { return nil }
        let sorted = magnitudes.sorted()
        let median = (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        let mean = magnitudes.reduce(0, +) / Double(count)
        let activity = magnitudes.reduce(0) { $0 + abs($1 - median) } / Double(count)
        return MotionSummary(sampleCount: count, meanMagnitude: mean, activity: activity, spanMillis: k10AssumedSpanMillis)
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
        guard let text = sanitizedText(b) else { return [] }
        return [.deviceInformation(field: field, value: text)]
    }

    /// Device-information strings become keys and provenance, so they are reduced to printable ASCII:
    /// cut at the first NUL, every other character outside U+0020…U+007E removed (control, format,
    /// bidi and replacement characters included), whitespace trimmed, at most 64 characters.
    static func sanitizedText(_ b: [UInt8]) -> String? {
        let prefix = b.prefix { $0 != 0 }
        let printable = prefix.filter { (0x20...0x7E).contains($0) }
        let text = String(decoding: printable, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(64))
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

    public func encode(_ command: AllowedCommand, sequence: UInt8) throws -> EncodedCommand {
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
