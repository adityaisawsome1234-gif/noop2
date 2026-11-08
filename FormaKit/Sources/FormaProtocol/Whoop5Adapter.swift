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
            nameHints: ["WHOOP"],
            framedCharacteristics: [Self.commandFromStrap, Self.eventsFromStrap, Self.dataFromStrap, Self.memfault]
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

    /// One byte of the CRC-32 register (before the final xor).
    @inline(__always)
    static func crc32Step(_ register: UInt32, _ byte: UInt8) -> UInt32 {
        crc32Table[Int((register ^ UInt32(byte)) & 0xFF)] ^ (register >> 8)
    }

    // CRC-32 of a segment from two prefix CRCs (the standard "CRC combine" identity, derived from the
    // polynomial arithmetic, not from any particular implementation):
    //   crc(A‖B) = (x^(8·|B|) · crc(A) mod P) ⊕ crc(B)   ⇒   crc(B) = crc(A‖B) ⊕ (x^(8·|B|) · crc(A) mod P)
    // Polynomials use the reflected bit order of the table above (bit 31 is x^0).

    /// a(x)·b(x) mod P(x). `a` must be non-zero (every power of x is).
    static func multiplyModP(_ a: UInt32, _ b: UInt32) -> UInt32 {
        var m: UInt32 = 1 << 31
        var product: UInt32 = 0
        var b = b
        while true {
            if a & m != 0 {
                product ^= b
                if a & (m &- 1) == 0 { break }
            }
            m >>= 1
            b = b & 1 != 0 ? (b >> 1) ^ 0xEDB8_8320 : b >> 1
        }
        return product
    }

    /// x^(2^k) mod P for k = 0…31.
    private static let powersOfX: [UInt32] = {
        var table: [UInt32] = []
        var p: UInt32 = 1 << 30   // x^1
        for _ in 0..<32 {
            table.append(p)
            p = multiplyModP(p, p)
        }
        return table
    }()

    /// x^(8·byteCount) mod P.
    static func shiftOperator(byteCount: Int) -> UInt32 {
        var p: UInt32 = 1 << 31   // x^0
        var n = UInt64(max(0, byteCount))
        var k = 3                 // 8 = 2^3
        while n != 0 {
            if n & 1 != 0 { p = multiplyModP(powersOfX[k & 31], p) }
            n >>= 1
            k += 1
        }
        return p
    }

    /// CRC-32 of the bytes between two prefixes, given the standard CRC-32 of each prefix (taken from the
    /// same origin) and the segment length. O(log length) instead of O(length).
    static func crc32OfSegment(prefixCRC: UInt32, extendedCRC: UInt32, length: Int) -> UInt32 {
        extendedCRC ^ multiplyModP(shiftOperator(byteCount: length), prefixCRC)
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
///   is dropped. Frames and reported counts are the same however notifications split the stream, with
///   one documented exception: when a frame that passes both CRCs contains another complete frame that
///   also passes both CRCs, a split that delivers the inner frame before the outer one completes makes the
///   outer frame look truncated. It is then reported as malformed (never silently dropped) and the inner
///   frame is delivered. Waiting for every pending span to complete would remove that exception but
///   would delay recovery after every genuinely truncated frame by up to 64 KB.
/// - Each frame carries the receive time of the notification that held its first byte.
/// - The buffer holds at most one pending frame (≤ 8 + 65 535 bytes) plus the latest chunk (and a
///   consumed prefix of at most the same size before it is compacted); garbage without a start byte is
///   discarded immediately.
/// - Work is linear in the bytes received, whatever the notification sizes: every byte position is
///   examined once by the look-ahead, payload CRCs come from running prefix CRCs (O(log n) per
///   candidate, so nested or overlapping candidate frames cost no rescans), each candidate frame is
///   checked once when its span completes, receive times are found by binary search, and the consumed
///   prefix is dropped only when it is at least half the buffer.
struct Whoop5Deframer {
    enum Output: Equatable {
        case frame(payload: [UInt8], receivedAt: EpochMillis)
        case malformed(reason: String, byteCount: Int)
        case discarded(byteCount: Int)
    }

    private var buffer: [UInt8] = []
    /// `crcRegister[i]` is the CRC-32 register after `buffer[0..<i]` (before the final xor). Any common
    /// origin works for segment CRCs, so compaction just drops the same prefix.
    private var crcRegister: [UInt32] = [0xFFFF_FFFF]
    private var start = 0
    /// (buffer index of a chunk's first byte, its receive time), ascending. Entries before `chunkHead`
    /// describe consumed bytes and are dropped on compaction.
    private var chunkTimes: [(index: Int, at: EpochMillis)] = []
    private var chunkHead = 0

    // Truncation look-ahead (indices into `buffer`). Valid for any pending frame starting before them.
    /// Next index not yet examined as a possible frame start.
    private var scanFrom = 0
    /// Candidates with a valid header whose span is not complete yet, as a min-heap on the span end.
    private var undecided = SpanHeap()
    /// Start of a complete frame that passes both CRCs, found by the look-ahead.
    private var knownComplete: Int?

    var pendingByteCount: Int { buffer.count - start }

    mutating func append(_ chunk: [UInt8], receivedAt: EpochMillis) -> [Output] {
        guard !chunk.isEmpty else { return [] }
        compactIfWorthwhile()
        chunkTimes.append((buffer.count, receivedAt))
        buffer.reserveCapacity(buffer.count + chunk.count)
        crcRegister.reserveCapacity(crcRegister.count + chunk.count)
        var register = crcRegister[crcRegister.count - 1]
        for b in chunk {
            register = Whoop5Wire.crc32Step(register, b)
            crcRegister.append(register)
        }
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
            //    Like a CRC failure, that costs only the start byte; rescanning then reaches the valid frame.
            if completeFrameExists(after: start) {
                out.append(.malformed(reason: "frame truncated (declared \(declared) bytes)", byteCount: 1))
                consume(to: start + 1)
                continue
            }
            break
        }
        return out
    }

    /// Drops any partial frame (disconnect). Returns the number of bytes discarded.
    mutating func reset() -> Int {
        let n = buffer.count - start
        clear()
        return n
    }

    // MARK: Helpers

    private mutating func clear() {
        buffer.removeAll(keepingCapacity: true)
        crcRegister.removeAll(keepingCapacity: true)
        crcRegister.append(0xFFFF_FFFF)
        start = 0
        chunkTimes.removeAll(keepingCapacity: true)
        chunkHead = 0
        scanFrom = 0
        undecided.removeAll()
        knownComplete = nil
    }

    private func headerIsValid(at i: Int) -> Bool {
        guard let stored = Whoop5Wire.u16(buffer, i + 6) else { return false }
        return Whoop5Wire.crc16Modbus(buffer[i..<(i + 6)]) == stored
    }

    /// Payload CRC of the frame at `i` (complete in the buffer), from the prefix CRCs.
    private func payloadIsValid(at i: Int, total: Int) -> Bool {
        guard let stored = Whoop5Wire.u32(buffer, i + total - 4) else { return false }
        let from = i + Whoop5Wire.headerLength, to = i + total - 4
        let crc = Whoop5Wire.crc32OfSegment(prefixCRC: crcRegister[from] ^ 0xFFFF_FFFF, extendedCRC: crcRegister[to] ^ 0xFFFF_FFFF,
                                            length: to - from)
        return crc == stored
    }

    /// Whether a complete frame passing both CRCs starts after `pending`. Each byte position is examined
    /// once; a candidate whose span is still incomplete is checked once, when its span completes.
    private mutating func completeFrameExists(after pending: Int) -> Bool {
        if let k = knownComplete {
            if k > pending { return true }
            knownComplete = nil
        }
        var j = max(scanFrom, pending + 1)
        let lastStart = buffer.count - Whoop5Wire.headerLength   // last index with a full header
        while j <= lastStart {
            guard let k = buffer[j...lastStart].firstIndex(of: Whoop5Wire.startOfFrame) else {
                j = lastStart + 1
                break
            }
            j = k + 1
            guard headerIsValid(at: k) else { continue }
            let declared = Int(Whoop5Wire.u16(buffer, k + 2) ?? 0)
            guard declared >= 4 else { continue }
            let total = Whoop5Wire.headerLength + declared
            if k + total <= buffer.count {
                if payloadIsValid(at: k, total: total) {
                    scanFrom = j
                    knownComplete = k
                    return true
                }
            } else {
                undecided.push(start: k, end: k + total)
            }
        }
        scanFrom = j
        while let top = undecided.min, top.end <= buffer.count {
            undecided.popMin()
            guard top.start > pending else { continue }
            if payloadIsValid(at: top.start, total: top.end - top.start) {
                knownComplete = top.start
                return true
            }
        }
        return false
    }

    /// Receive time of the chunk that held `index` (binary search over the chunk starts).
    private func time(of index: Int) -> EpochMillis {
        var lo = chunkHead, hi = chunkTimes.count - 1
        guard lo <= hi else { return 0 }
        var best = chunkTimes[lo].at
        while lo <= hi {
            let mid = (lo + hi) / 2
            if chunkTimes[mid].index <= index {
                best = chunkTimes[mid].at
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    private mutating func consume(to index: Int) {
        start = min(index, buffer.count)
        if start == buffer.count {
            clear()
            return
        }
        // Advance the chunk head to the entry that covers `start`.
        while chunkHead + 1 < chunkTimes.count, chunkTimes[chunkHead + 1].index <= start { chunkHead += 1 }
    }

    /// Drops the consumed prefix once it is at least half the buffer (amortized O(1) per byte).
    private mutating func compactIfWorthwhile() {
        guard start > 0, start * 2 >= buffer.count else { return }
        let shift = start
        buffer.removeFirst(shift)
        crcRegister.removeFirst(shift)
        chunkTimes = chunkTimes[chunkHead...].map { (max(0, $0.index - shift), $0.at) }
        chunkHead = 0
        scanFrom = max(0, scanFrom - shift)
        if let k = knownComplete { knownComplete = k >= shift ? k - shift : nil }
        undecided.shift(by: shift)
        start = 0
    }
}

/// Min-heap of candidate frame spans keyed by their end index.
struct SpanHeap {
    private var items: [(start: Int, end: Int)] = []

    var min: (start: Int, end: Int)? { items.first }

    mutating func removeAll() { items.removeAll(keepingCapacity: true) }

    mutating func push(start: Int, end: Int) {
        items.append((start, end))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard items[i].end < items[parent].end else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func popMin() {
        guard !items.isEmpty else { return }
        items.swapAt(0, items.count - 1)
        items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var smallest = i
            if l < items.count, items[l].end < items[smallest].end { smallest = l }
            if r < items.count, items[r].end < items[smallest].end { smallest = r }
            guard smallest != i else { break }
            items.swapAt(i, smallest)
            i = smallest
        }
    }

    /// Re-bases indices after the buffer dropped `shift` bytes; candidates that started in them are gone.
    mutating func shift(by shift: Int) {
        // Subtracting the same amount keeps the heap order; removing entries requires a rebuild.
        let kept = items.filter { $0.start >= shift }.map { (start: $0.start - shift, end: $0.end - shift) }
        items.removeAll(keepingCapacity: true)
        for e in kept { push(start: e.start, end: e.end) }
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
            return StandardServiceParsing.deviceInformation(bytes, characteristic: c, receivedAt: receivedAt)
        case Whoop5Adapter.commandFromStrap, Whoop5Adapter.eventsFromStrap, Whoop5Adapter.dataFromStrap, Whoop5Adapter.memfault:
            // Mutated in place: copying the deframer out of the dictionary would copy its whole buffer
            // (copy-on-write) on every notification.
            let outputs = deframers[c, default: Whoop5Deframer()].append(bytes, receivedAt: receivedAt)
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

    /// Offset of the heart-rate candidate byte by record kind (public research; meaning unvalidated).
    static func heartRateOffset(kind: UInt8) -> Int? {
        switch kind {
        case 9, 10, 12, 24: return 17
        case 18: return 14
        case 7: return 27
        default: return nil
        }
    }

    /// Heart-rate candidate byte by record kind (public research; meaning unvalidated). 0 means "no reading".
    static func heartRateCandidate(_ p: [UInt8]) -> Int? {
        guard p.count >= 2, let offset = heartRateOffset(kind: p[1]) else { return nil }
        guard offset < p.count, p[offset] != 0 else { return nil }
        return Int(p[offset])
    }

    /// Common 13-byte data header, then per-kind body fields. A record of a decoded kind counts as decoded
    /// only when every field Forma reads from it is present and understood; otherwise whatever was decoded
    /// is still reported, but `contentDecoded` is false so its chunk is never acknowledged.
    func decodeHistoryRecord(_ p: [UInt8], characteristic: String, receivedAt: EpochMillis) -> DecodedEvent {
        guard p.count >= 13, let counter = Whoop5Wire.u32(p, 3), let seconds = Whoop5Wire.u32(p, 7), let sub = Whoop5Wire.u16(p, 11) else {
            return .malformed(reason: "data record shorter than its 13-byte header", byteCount: p.count, characteristic: characteristic, receivedAt: receivedAt)
        }
        let kind = p[1]
        var decoded = Self.decodedKinds.contains(kind)
        var heartRate: Int?
        if decoded {
            if let offset = Self.heartRateOffset(kind: kind), offset >= p.count {
                decoded = false   // the heart-rate field is missing: the record is shorter than its kind's layout
            } else {
                heartRate = Self.heartRateCandidate(p)
            }
        }
        var motion: MotionSummary?
        if kind == 10 {
            switch Self.k10Motion(p) {
            case .summary(let m): motion = m
            case .noSamples: break                // zero-filled block: nothing was measured, nothing to keep
            case .notUnderstood: decoded = false  // layout not understood: the band keeps the record
            }
        }
        return .historyRecord(HistoryRecord(kind: kind, counter: counter, deviceSeconds: seconds, subseconds: sub, receivedAt: receivedAt,
                                            heartRate: heartRate, heartRateStatus: .unvalidated, beatIntervalsMillis: [], motion: motion,
                                            payloadLength: p.count, contentDecoded: decoded))
    }

    /// Samples per axis in a K10 record (payload byte 18 held this count in both public captures; inferred).
    static let k10SamplesPerAxis = 100
    /// Fewer real (non-zero) samples than this and the block is not summarized: the record stays undecoded.
    static let k10MinimumRealSamples = 50
    /// ASSUMPTION (unverified): 50 Hz sampling, so 100 samples span 2 s. No public source states the
    /// rate; it only matters when the user lets unvalidated motion feed sleep candidates.
    static let k10AssumedSpanMillis: Int64 = 2_000

    enum K10Motion: Equatable {
        /// Summary of the real samples.
        case summary(MotionSummary)
        /// Every sample is a zero vector: nothing was measured.
        case noSamples
        /// Too short, a sample-count byte other than 100, or too few real samples to summarize.
        case notUnderstood
    }

    /// K10: 100 × i16 accelerometer samples per axis at payload offsets 85 (x), 285 (y), 485 (z).
    /// A working accelerometer always measures gravity, so a (0, 0, 0) vector is an absent sample, never
    /// stillness: such samples are left out of every statistic (and of `sampleCount`).
    static func k10Motion(_ p: [UInt8]) -> K10Motion {
        let count = k10SamplesPerAxis
        let offsets = [85, 285, 485]
        guard p.count > 18, Int(p[18]) == count, offsets.allSatisfy({ $0 + count * 2 <= p.count }) else { return .notUnderstood }
        var magnitudes: [Double] = []
        magnitudes.reserveCapacity(count)
        for i in 0..<count {
            guard let x = Whoop5Wire.i16(p, offsets[0] + 2 * i), let y = Whoop5Wire.i16(p, offsets[1] + 2 * i),
                  let z = Whoop5Wire.i16(p, offsets[2] + 2 * i) else { return .notUnderstood }
            if x == 0, y == 0, z == 0 { continue }
            let dx = Double(x), dy = Double(y), dz = Double(z)
            magnitudes.append((dx * dx + dy * dy + dz * dz).squareRoot())
        }
        if magnitudes.isEmpty { return .noSamples }
        guard magnitudes.count >= k10MinimumRealSamples else { return .notUnderstood }
        let n = magnitudes.count
        let sorted = magnitudes.sorted()
        let median = n % 2 == 0 ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2 : sorted[n / 2]
        let mean = magnitudes.reduce(0, +) / Double(n)
        let activity = magnitudes.reduce(0) { $0 + abs($1 - median) } / Double(n)
        return .summary(MotionSummary(sampleCount: n, meanMagnitude: mean, activity: activity, spanMillis: k10AssumedSpanMillis))
    }

    /// The K10 motion summary, or nil when there is none (see `k10Motion`).
    static func motionSummaryK10(_ p: [UInt8]) -> MotionSummary? {
        if case .summary(let m) = k10Motion(p) { return m }
        return nil
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

    static func deviceInformation(_ b: [UInt8], characteristic: String, receivedAt: EpochMillis = 0) -> [DecodedEvent] {
        let field: String
        switch characteristic {
        case UUIDs.firmwareRevision: field = "firmware"
        case UUIDs.hardwareRevision: field = "hardware"
        case UUIDs.modelNumber: field = "model"
        case UUIDs.manufacturerName: field = "manufacturer"
        default: field = "software"
        }
        guard let text = sanitizedText(b) else {
            // Reported, never silently dropped: an empty or entirely unprintable value is not information.
            return [.malformed(reason: "device information (\(field)) empty or not printable", byteCount: b.count,
                               characteristic: characteristic, receivedAt: receivedAt)]
        }
        return [.deviceInformation(field: field, value: text)]
    }

    /// Longest sanitized device-information value.
    static let maxDeviceInformationLength = 64

    /// Device-information strings become keys and provenance, so they are reduced to printable ASCII
    /// without merging distinct values: cut at the first NUL; every byte outside U+0021…U+007E other than
    /// a plain space (control, format, bidi, non-ASCII) becomes a visible `\xNN` escape and a backslash
    /// becomes `\\`; surrounding spaces are trimmed; at most 64 characters (never cutting an escape),
    /// trimmed again. Nil when nothing printable is left.
    static func sanitizedText(_ b: [UInt8]) -> String? {
        let value = b.prefix { $0 != 0 }
        guard value.contains(where: { (0x21...0x7E).contains($0) }) else { return nil }
        let hex: [Character] = Array("0123456789ABCDEF")
        var tokens: [String] = value.map { byte in
            switch byte {
            case 0x5C: return "\\\\"
            case 0x20...0x7E: return String(UnicodeScalar(byte))
            default: return "\\x" + String(hex[Int(byte >> 4)]) + String(hex[Int(byte & 0x0F)])
            }
        }
        func trimSpaces() {
            while tokens.first == " " { tokens.removeFirst() }
            while tokens.last == " " { tokens.removeLast() }
        }
        trimSpaces()
        var length = 0
        var kept = 0
        for t in tokens {
            guard length + t.count <= maxDeviceInformationLength else { break }
            length += t.count
            kept += 1
        }
        tokens.removeLast(tokens.count - kept)
        trimSpaces()
        let text = tokens.joined()
        return text.isEmpty ? nil : text
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
            return StandardServiceParsing.deviceInformation(bytes, characteristic: c, receivedAt: receivedAt)
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
