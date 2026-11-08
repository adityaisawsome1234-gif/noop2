// Adversarial tests for the device-adapter layer (DeviceAdapter.swift, Whoop5Adapter.swift).
//
// Every expectation here is derived from the documented intent (docs/ARCHITECTURE.md, docs/PRD.md, the doc
// comments on the public types, and the public protocol research notes) and from the project invariants:
//   - only commands in the compile-time allowlist are ever encoded; nothing destructive, no clock write;
//   - never fabricate measurements (nil, not 0); unvalidated fields are marked unvalidated;
//   - malformed/unknown input is reported, never silently dropped, and never crashes;
//   - history acknowledgements echo the band's end-of-chunk token verbatim.
// Reference CRCs and the frame builder below are written independently from the documented algorithm
// (CRC-16/MODBUS over header bytes 0..<6, CRC-32/ISO-HDLC over the payload), not copied from the adapter.
//
// History: written by an independent breaker against the first adapter. The failures it exposed (frames
// swallowed after a truncated frame, receive times inherited from discarded bytes, zero-filled accelerometer
// blocks reported as stillness, a trap when framing oversized payloads) were fixed and these tests now pass.
// Contract changes since then are reflected in the expectations: `encode` returns an `EncodedCommand`,
// `frame(payload:)` throws for payloads that cannot be framed, and abort/battery-read are not supported.

import Foundation
import Testing
import FormaCore
@testable import FormaProtocol

// MARK: - Independent reference helpers

fileprivate func advCRC16Modbus(_ bytes: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for b in bytes {
        crc ^= UInt16(b)
        for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xA001 : (crc >> 1) }
    }
    return crc
}

fileprivate func advCRC32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in bytes {
        crc ^= UInt32(b)
        for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : (crc >> 1) }
    }
    return ~crc
}

fileprivate func advLE16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
fileprivate func advLE32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

/// 8-byte WHOOP 5.0 header `AA 01 LEN 00 01 HCRC` for an arbitrary declared length.
fileprivate func advHeader(declared: Int) -> [UInt8] {
    var h: [UInt8] = [0xAA, 0x01] + advLE16(UInt16(declared)) + [0x00, 0x01]
    h += advLE16(advCRC16Modbus(h))
    return h
}

/// Frame built from the documented algorithm. `pad` zero-pads to a multiple of 4 (Forma does; the band may not).
fileprivate func advFrame(_ payload: [UInt8], pad: Bool = true) -> [UInt8] {
    var p = payload
    if pad { while p.count % 4 != 0 { p.append(0) } }
    return advHeader(declared: p.count + 4) + p + advLE32(advCRC32(p))
}

/// Strictly parses exactly one frame; returns the payload (including any padding) or nil.
fileprivate func advParseSingleFrame(_ f: [UInt8]) -> [UInt8]? {
    guard f.count >= 12, f[0] == 0xAA, f[1] == 0x01, f[4] == 0x00, f[5] == 0x01 else { return nil }
    guard UInt16(f[6]) | UInt16(f[7]) << 8 == advCRC16Modbus(Array(f[0..<6])) else { return nil }
    let declared = Int(UInt16(f[2]) | UInt16(f[3]) << 8)
    guard declared >= 4, f.count == 8 + declared else { return nil }
    let payload = Array(f[8..<(f.count - 4)])
    let stored = UInt32(f[f.count - 4]) | UInt32(f[f.count - 3]) << 8 | UInt32(f[f.count - 2]) << 16 | UInt32(f[f.count - 1]) << 24
    guard stored == advCRC32(payload) else { return nil }
    return payload
}

fileprivate func advHex(_ s: String) -> [UInt8] {
    let clean = Array(s.filter(\.isHexDigit))
    return stride(from: 0, to: clean.count, by: 2).map { UInt8(String(clean[$0..<($0 + 2)]), radix: 16)! }
}

fileprivate func advHexString(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

/// Data payload: type, K, status, counter(u32 LE), seconds(u32 LE), subseconds(u16 LE), zero body up to `length`.
fileprivate func advRecord(type: UInt8 = 47, k: UInt8, counter: UInt32, seconds: UInt32, subseconds: UInt16 = 0,
                           length: Int, set: [Int: UInt8] = [:]) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: max(13, length))
    p[0] = type; p[1] = k; p[2] = 0
    for i in 0..<4 {
        p[3 + i] = UInt8((counter >> (8 * UInt32(i))) & 0xFF)
        p[7 + i] = UInt8((seconds >> (8 * UInt32(i))) & 0xFF)
    }
    p[11] = UInt8(subseconds & 0xFF); p[12] = UInt8(subseconds >> 8)
    for (o, v) in set where o < p.count { p[o] = v }
    return p
}

/// K10 record (1920 bytes like the public capture) with accelerometer axes at payload offsets 85/285/485.
fileprivate func advK10(hr: UInt8, x: [Int16], y: [Int16], z: [Int16], length: Int = 1_920) -> [UInt8] {
    var p = advRecord(k: 10, counter: 101, seconds: 1_779_039_600, length: length, set: [17: hr, 18: 100])
    for (base, axis) in [(85, x), (285, y), (485, z)] {
        for (i, v) in axis.enumerated() {
            let u = UInt16(bitPattern: v)
            p[base + 2 * i] = UInt8(u & 0xFF)
            p[base + 2 * i + 1] = UInt8(u >> 8)
        }
    }
    return p
}

/// METADATA payload (type 49) of the given kind; for HistoryEnd the token sits at payload 13..<21.
fileprivate func advMetadata(kind: UInt8, length: Int = 3, token: [UInt8]? = nil) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: max(3, length))
    p[0] = 0x31; p[2] = kind
    if let token { for (i, b) in token.enumerated() where 13 + i < p.count { p[13 + i] = b } }
    return p
}

fileprivate extension Array where Element == DecodedEvent {
    var advRecords: [HistoryRecord] { compactMap { if case .historyRecord(let r) = $0 { return r } else { return nil } } }
    var advMarkers: [HistoryMarker] { compactMap { if case .historyMarker(let m) = $0 { return m } else { return nil } } }
    var advHasMalformed: Bool { contains { if case .malformed = $0 { return true } else { return false } } }
    var advReportedBytes: Int {
        reduce(0) {
            switch $1 {
            case .malformed(_, let n, _, _), .discarded(let n, _, _): return $0 + n
            default: return $0
            }
        }
    }
}

/// Deterministic generator (SplitMix64) so fuzz failures are reproducible.
fileprivate struct AdvRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    mutating func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8(truncatingIfNeeded: next()) } }
}

/// A hostile but realistic notification stream: valid frames (padded and unpadded), garbage, stray start
/// bytes, bit-flipped frames, truncated frames and headers with impossible lengths.
fileprivate func advHostileStream(_ rng: inout AdvRNG) -> [UInt8] {
    var s: [UInt8] = []
    for _ in 0..<rng.int(1...8) {
        switch rng.int(0...6) {
        case 0: s += rng.bytes(rng.int(0...40))
        case 1: s += advFrame(rng.bytes(rng.int(0...60)))
        case 2: s += advFrame(rng.bytes(rng.int(1...60)), pad: false)
        case 3:
            var f = advFrame(rng.bytes(rng.int(1...60)))
            f[rng.int(0...(f.count - 1))] ^= UInt8(1 << rng.int(0...7))
            s += f
        case 4:
            let f = advFrame(rng.bytes(rng.int(1...60)))
            s += f.prefix(rng.int(1...(f.count - 1)))
        case 5:
            s += advHeader(declared: rng.int(0...1) == 0 ? rng.int(0...3) : rng.int(16_385...65_535))
        default:
            s += [0xAA] + rng.bytes(rng.int(0...10))
        }
    }
    return s
}

fileprivate func advChunks(_ bytes: [UInt8], _ rng: inout AdvRNG, maxChunk: Int = 30) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var i = 0
    while i < bytes.count {
        let n = rng.int(1...maxChunk)
        out.append(Array(bytes[i..<min(bytes.count, i + n)]))
        i += n
    }
    return out
}

fileprivate struct AdvDeframeTally {
    var frames: [[UInt8]] = []
    var frameTimes: [EpochMillis] = []
    var malformedBytes = 0
    var malformedCount = 0
    var discardedBytes = 0
    var remaining = 0
    /// Bytes consumed by emitted frames: 8-byte header + payload + 4-byte CRC.
    var frameBytes: Int { frames.reduce(0) { $0 + $1.count + 12 } }
}

fileprivate func advDeframe(_ chunks: [[UInt8]], times: [EpochMillis]? = nil) -> AdvDeframeTally {
    var d = Whoop5Deframer()
    var t = AdvDeframeTally()
    for (i, c) in chunks.enumerated() {
        for o in d.append(c, receivedAt: times?[i] ?? EpochMillis(i)) {
            switch o {
            case .frame(let p, let at): t.frames.append(p); t.frameTimes.append(at)
            case .malformed(_, let n): t.malformedBytes += n; t.malformedCount += 1
            case .discarded(let n): t.discardedBytes += n
            }
        }
    }
    t.remaining = d.reset()
    return t
}

// MARK: - Command allowlist

/// The only command id each allowlisted operation may ever map to (public command table). A clock READ may
/// only be GET_CLOCK (11), never SET_CLOCK (10); battery only GET_BATTERY_LEVEL (26).
fileprivate func advExpectedCommandID(_ c: AllowedCommand) -> UInt8 {
    switch c {
    case .identify: return 145            // GET_HELLO (read-only)
    case .readBattery: return 26          // GET_BATTERY_LEVEL (read-only)
    case .readClock: return 11            // GET_CLOCK (read-only)
    case .readHistoryRange: return 34     // GET_DATA_RANGE (read-only)
    case .setRealtimeHeartRate: return 3  // TOGGLE_REALTIME_HR (non-destructive stream toggle)
    case .requestHistory: return 22       // SEND_HISTORICAL_DATA
    case .acknowledgeHistory: return 23   // HISTORICAL_DATA_RESULT
    case .abortHistory: return 20         // ABORT_HISTORICAL_TRANSMITS
    }
}

/// Destructive / configuration command ids from the public command table. None may ever be encoded.
fileprivate let advDestructiveCommandIDs: [UInt8: String] = [
    10: "SET_CLOCK", 16: "TOGGLE_R7_DATA_COLLECTION", 19: "RUN_HAPTIC_PATTERN_MAVERICK", 25: "FORCE_TRIM",
    29: "REBOOT_STRAP", 32: "POWER_CYCLE_STRAP", 33: "SET_READ_POINTER", 36: "START_FIRMWARE_LOAD",
    37: "LOAD_FIRMWARE_DATA", 38: "PROCESS_FIRMWARE_IMAGE", 39: "SET_LED_DRIVE", 41: "SET_TIA_GAIN",
    43: "SET_BIAS_OFFSET", 45: "ENTER_BLE_DFU", 52: "SET_DP_TYPE", 53: "FORCE_DP_TYPE", 66: "SET_ALARM_TIME",
    68: "RUN_ALARM", 69: "DISABLE_ALARM", 77: "SET_ADVERTISING_NAME_HARVARD", 79: "RUN_HAPTICS_PATTERN",
    83: "VERIFY_FIRMWARE_IMAGE", 105: "TOGGLE_IMU_MODE_HISTORICAL", 115: "START_DEVICE_CONFIG_KEY_EXCHANGE",
    116: "SEND_NEXT_DEVICE_CONFIG", 117: "START_FEATURE_FLAG_KEY_EXCHANGE", 118: "SEND_NEXT_FEATURE_FLAG",
    119: "SET_DEVICE_CONFIG_VALUE", 120: "SET_FEATURE_FLAG_VALUE", 123: "SELECT_WRIST", 124: "TOGGLE_LABRADOR_DATA_GENERATION",
    125: "TOGGLE_LABRADOR_RAW_SAVE", 131: "SET_RESEARCH_PACKET", 140: "SET_ADVERTISING_NAME",
    142: "START_FIRMWARE_LOAD_NEW", 143: "LOAD_FIRMWARE_DATA_NEW", 144: "PROCESS_FIRMWARE_IMAGE_NEW",
    153: "TOGGLE_PERSISTENT_R20", 154: "TOGGLE_PERSISTENT_R21",
]

fileprivate let advAllCommands: [AllowedCommand] = {
    var cs: [AllowedCommand] = [.identify, .readBattery, .readClock, .readHistoryRange, .setRealtimeHeartRate(enabled: true),
                                .setRealtimeHeartRate(enabled: false), .requestHistory, .abortHistory]
    for n in 0...24 { cs.append(.acknowledgeHistory(token: (0..<n).map { UInt8(truncatingIfNeeded: 0xA5 &+ $0 &* 37) })) }
    cs.append(.acknowledgeHistory(token: [UInt8](repeating: 0xAA, count: 8)))   // token full of start-of-frame bytes
    cs.append(.acknowledgeHistory(token: [UInt8](repeating: 0x00, count: 8)))
    return cs
}()

fileprivate let advSequences: [UInt8] = [0, 1, 2, 9, 127, 128, 0xAA, 254, 255]

@Suite struct AdversarialCommandAllowlistTests {
    @Test func everyEncodableCommandIsAWellFormedNonDestructiveFrame() {
        let adapters: [any DeviceAdapter] = AdapterRegistry.all + [Whoop5Adapter(), StandardHeartRateAdapter()]
        for adapter in adapters {
            for command in advAllCommands {
                for seq in advSequences {
                    let bytes: [UInt8]
                    do {
                        bytes = try adapter.encode(command, sequence: seq).bytes
                    } catch {
                        #expect(error is CommandEncodingError, "\(adapter.adapterID) threw a non-CommandEncodingError for \(command.name)")
                        #expect(!adapter.supports(command), "\(adapter.adapterID).supports(\(command.name)) is true but encode threw \(error)")
                        continue
                    }
                    #expect(adapter.supports(command), "\(adapter.adapterID) encoded \(command.name) although supports() is false")
                    guard let p = advParseSingleFrame(bytes) else {
                        Issue.record("\(adapter.adapterID) \(command.name) seq \(seq): not one well-formed frame: \(advHexString(bytes))")
                        continue
                    }
                    #expect(p.count % 4 == 0, "Forma pads its own frames to a multiple of 4")
                    #expect(p.count >= 3 && p[0] == 0x23, "must be a COMMAND (35) packet, never PUFFIN_COMMAND or anything else")
                    guard p.count >= 3 else { continue }
                    #expect(p[1] == seq, "sequence byte")
                    #expect(advDestructiveCommandIDs[p[2]] == nil,
                            "\(command.name) encoded destructive command \(p[2]) \(advDestructiveCommandIDs[p[2]] ?? "")")
                    #expect(p[2] == advExpectedCommandID(command), "\(command.name) encoded command id \(p[2])")
                }
            }
        }
    }

    @Test func commandIDTableHoldsNoDestructiveID() {
        let ids = (0...255).compactMap { Whoop5Adapter.CommandID(rawValue: UInt8($0))?.rawValue }
        #expect(!ids.isEmpty)
        let readStreamOrHistory: Set<UInt8> = [3, 11, 20, 22, 23, 26, 34, 145]
        for id in ids {
            #expect(readStreamOrHistory.contains(id), "CommandID \(id) is not a read, stream or history command")
            #expect(advDestructiveCommandIDs[id] == nil, "CommandID table contains destructive id \(id)")
        }
    }

    @Test func independentlyDerivedHistoryCommandVectors() throws {
        // Derived from the documented frame algorithm by a separate script (research notes), not captured.
        let a = Whoop5Adapter()
        #expect(advHexString(try a.encode(.readHistoryRange, sequence: 57).bytes) == "aa0108000001e67123392200f347cb1f")
        #expect(advHexString(try a.encode(.requestHistory, sequence: 58).bytes) == "aa0108000001e671233a16005d0aa7a6")
        #expect(advHexString(try a.encode(.acknowledgeHistory(token: [0, 0, 0, 0, 0, 0, 0, 0]), sequence: 59).bytes)
                == "aa0110000001e0d1233b17010000000000000000ed8d38cd")
        #expect(advHexString(try a.encode(.identify, sequence: 1).bytes) == "aa0108000001e67123019101363e5c8d")
    }

    @Test func acknowledgementEchoesTheEndMarkerTokenVerbatim() throws {
        // Token bytes chosen to trip naive handling: start-of-frame byte, zero, 0xFF, command-looking bytes.
        let token: [UInt8] = [0xAA, 0x01, 0x00, 0xFF, 0x23, 0x17, 0x80, 0x7F]
        let events = Whoop5Decoder().decode(characteristic: Whoop5Adapter.dataFromStrap,
                                            bytes: advFrame(advMetadata(kind: 2, length: 28, token: token)), receivedAt: 1)
        guard let marker = events.advMarkers.first, marker.kind == .end, let echoed = marker.ackToken else {
            Issue.record("expected an end marker with a token: \(events)"); return
        }
        #expect(echoed == token)
        let frame = try Whoop5Adapter().encode(.acknowledgeHistory(token: echoed), sequence: 200).bytes
        #expect(advParseSingleFrame(frame) == [0x23, 200, 0x17, 0x01] + token, "01 (success) followed by the token, unchanged")
    }

    @Test func acknowledgementWithAnyOtherTokenLengthIsNeverEncodable() {
        let a = Whoop5Adapter()
        for n in 0...40 where n != Whoop5Adapter.ackTokenLength {
            let c = AllowedCommand.acknowledgeHistory(token: [UInt8](repeating: 0x5A, count: n))
            #expect(!a.supports(c), "token length \(n)")
            #expect(throws: CommandEncodingError.self, "token length \(n)") { _ = try a.encode(c, sequence: 3) }
        }
    }

    @Test func standardHeartRateAdapterCanNeverWrite() {
        let a = StandardHeartRateAdapter()
        #expect(a.gatt.commandCharacteristic == nil)
        for c in advAllCommands {
            #expect(!a.supports(c), "\(c.name)")
            #expect(throws: CommandEncodingError.unsupported(c.name)) { _ = try a.encode(c, sequence: 1) }
        }
    }
}

// MARK: - GATT profile, capabilities, registry

fileprivate func advIsCanonicalUUID(_ s: String) -> Bool {
    let chars = Array(s)
    guard chars.count == 36 else { return false }
    for (i, c) in chars.enumerated() {
        if [8, 13, 18, 23].contains(i) {
            if c != "-" { return false }
        } else if !(c.isHexDigit && (c.isNumber || c.isUppercase)) {
            return false
        }
    }
    return true
}

@Suite struct AdversarialAdapterProfileTests {
    @Test func gattUUIDsAreCanonicalUppercase128Bit() {
        for a in AdapterRegistry.all {
            let g = a.gatt
            let all = [g.vendorService, g.commandCharacteristic].compactMap { $0 } + g.discoverServices + g.subscribeCharacteristics + g.scanServiceFilter
            for u in all {
                #expect(advIsCanonicalUUID(u), "\(a.adapterID): \(u) is not canonical 128-bit uppercase")
                #expect(UUIDs.normalize(u) == u, "\(a.adapterID): \(u) is not normalized")
            }
        }
    }

    @Test func profileRolesAreConsistent() {
        for a in AdapterRegistry.all {
            let g = a.gatt
            if let cmd = g.commandCharacteristic {
                #expect(!g.subscribeCharacteristics.contains(cmd), "\(a.adapterID) subscribes to its own write characteristic")
            }
            if let v = g.vendorService { #expect(g.discoverServices.contains(v), "\(a.adapterID) never discovers its vendor service") }
            #expect(Set(g.scanServiceFilter).isSubset(of: Set(g.discoverServices)), "\(a.adapterID) scans for a service it never discovers")
            #expect(Set(g.subscribeCharacteristics).count == g.subscribeCharacteristics.count, "\(a.adapterID) duplicate subscriptions")
            let writes = advAllCommands.contains { a.supports($0) }
            #expect(writes == (g.commandCharacteristic != nil), "\(a.adapterID): commands supported but nowhere to write them (or vice versa)")
        }
    }

    @Test func everySubscribedCharacteristicReachesARealParser() {
        for a in AdapterRegistry.all {
            for c in a.gatt.subscribeCharacteristics {
                for spelling in [c, c.lowercased(), " \(c)\n"] {
                    let events = a.makeDecoder().decode(characteristic: spelling, bytes: [], receivedAt: 1)
                    let fellThrough = events.contains { if case .unknownPacket(0, _, _, _) = $0 { return true } else { return false } }
                    #expect(!fellThrough, "\(a.adapterID): notifications on \(spelling) are not routed to any parser")
                }
            }
        }
    }

    @Test func staticCapabilitiesAreCompleteAndNeverClaimHardwareVerification() {
        for a in AdapterRegistry.all {
            for cap in Capability.allCases {
                #expect(a.capabilities[cap] != nil, "\(a.adapterID) has no status for \(cap)")
                // `.verifiedOnHardware` is set only at runtime after a passed hardware check.
                #expect(a.capabilities[cap] != .verifiedOnHardware, "\(a.adapterID) statically claims \(cap) verified on hardware")
            }
        }
    }

    @Test func capabilitiesAgreeWithCommandSupport() {
        let token = [UInt8](repeating: 1, count: Whoop5Adapter.ackTokenLength)
        for a in AdapterRegistry.all {
            let caps = a.capabilities
            if caps[.clockRead] == .unsupported { #expect(!a.supports(.readClock), "\(a.adapterID)") }
            if caps[.liveHeartRate] == .unsupported {
                #expect(!a.supports(.setRealtimeHeartRate(enabled: true)), "\(a.adapterID)")
                #expect(!a.supports(.setRealtimeHeartRate(enabled: false)), "\(a.adapterID)")
            }
            if caps[.history] == .unsupported {
                #expect(!a.supports(.requestHistory), "\(a.adapterID)")
                #expect(!a.supports(.acknowledgeHistory(token: token)), "\(a.adapterID)")
            }
            if a.supports(.requestHistory) || a.supports(.acknowledgeHistory(token: token)) {
                #expect(caps[.history] != .unsupported, "\(a.adapterID) transfers history while declaring it unsupported")
            }
        }
    }

    @Test func registryRoundTripsEveryAdapter() {
        let ids = AdapterRegistry.all.map { $0.adapterID }
        #expect(Set(ids).count == ids.count)
        #expect(Set(AdapterRegistry.all.map { $0.family }).count == ids.count)
        for a in AdapterRegistry.all {
            #expect(!a.parserVersion.isEmpty)
            #expect(AdapterRegistry.adapter(for: a.family)?.adapterID == a.adapterID)
            #expect(AdapterRegistry.adapter(forDiscoveredServices: a.gatt.discoverServices)?.adapterID == a.adapterID)
        }
    }

    @Test func registryAcceptsCoreBluetoothSpellingsAndRejectsUnusableServiceSets() {
        #expect(AdapterRegistry.adapter(forDiscoveredServices: [" FD4B0001-CCE1-4033-93CE-002D5875F58A\n"])?.adapterID == "forma.whoop5")
        #expect(AdapterRegistry.adapter(forDiscoveredServices: ["0000180d"])?.adapterID == "forma.standard-hr")
        #expect(AdapterRegistry.adapter(forDiscoveredServices: ["0000180D-0000-1000-8000-00805f9b34fb"])?.adapterID == "forma.standard-hr")
        #expect(AdapterRegistry.adapter(forDiscoveredServices: ["180F", "180A"]) == nil, "battery + device information alone carry no heart rate")
        #expect(AdapterRegistry.adapter(forDiscoveredServices: []) == nil)
        // WHOOP 4.0's vendor service is a different family; Forma has no adapter for it.
        let gen4 = "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
        #expect(AdapterRegistry.adapter(forDiscoveredServices: [gen4]) == nil)
        #expect(AdapterRegistry.adapter(forDiscoveredServices: [gen4, "180D"])?.adapterID == "forma.standard-hr")
        #expect(AdapterRegistry.adapter(for: .whoop4) == nil)
        #expect(AdapterRegistry.adapter(for: .unknown) == nil)
    }

    @Test func uuidNormalizationExpandsSIGShortFormsAndIsIdempotent() {
        #expect(UUIDs.normalize("2a37") == "00002A37-0000-1000-8000-00805F9B34FB")
        #expect(UUIDs.normalize("00002a37") == "00002A37-0000-1000-8000-00805F9B34FB")
        #expect(UUIDs.normalize("\t2A37 ") == UUIDs.heartRateMeasurement)
        for s in ["180D", "2a19", "fd4b0005-cce1-4033-93ce-002d5875f58a", "0000180f", ""] {
            #expect(UUIDs.normalize(UUIDs.normalize(s)) == UUIDs.normalize(s), "\(s)")
        }
        #expect(UUIDs.equal("fd4b0002-cce1-4033-93ce-002d5875f58a", Whoop5Adapter.commandToStrap))
        #expect(!UUIDs.equal("180D", "180F"))
        #expect(!UUIDs.equal("0001", Whoop5Adapter.service))
    }
}

// MARK: - Frame reassembly

@Suite struct AdversarialDeframerTests {
    /// "reports malformed or discarded bytes instead of throwing them away silently": every byte fed in is a
    /// frame byte, a reported malformed/discarded byte, or still buffered (reported by reset).
    @Test func everyByteIsAccountedForUnderSeededFuzz() {
        var rng = AdvRNG(state: 0x5EED_0001)
        for round in 0..<500 {
            let stream = advHostileStream(&rng)
            let t = advDeframe(advChunks(stream, &rng))
            #expect(t.frameBytes + t.malformedBytes + t.discardedBytes + t.remaining == stream.count,
                    "round \(round): \(t.frameBytes)+\(t.malformedBytes)+\(t.discardedBytes)+\(t.remaining) != \(stream.count)")
        }
    }

    @Test func framesDoNotDependOnNotificationBoundaries() {
        var rng = AdvRNG(state: 0x5EED_0002)
        for round in 0..<300 {
            let stream = advHostileStream(&rng)
            let whole = advDeframe([stream])
            let pieces = advDeframe(advChunks(stream, &rng))
            let bytewise = advDeframe(stream.map { [$0] })
            #expect(pieces.frames == whole.frames, "round \(round)")
            #expect(bytewise.frames == whole.frames, "round \(round)")
            #expect(pieces.malformedCount == whole.malformedCount && bytewise.malformedCount == whole.malformedCount, "round \(round)")
        }
    }

    /// IMPLEMENTATION BUG: after a frame whose header is valid but whose body never fully arrives, the
    /// deframer trusts the declared length, and on the payload-CRC mismatch throws away the WHOLE declared
    /// span, including complete, valid frames that arrived inside it. The documented intent is that the
    /// assembler "resyncs after garbage" and that a bad frame cannot desynchronize the stream.
    @Test func framesFollowingATruncatedFrameAreNotSwallowed() {
        let full = advFrame(advRecord(k: 24, counter: 1, seconds: 1_779_000_000, length: 40))   // 52-byte frame
        let truncated = Array(full.prefix(20))                                                     // header valid, body cut short
        let b: [UInt8] = [0x24, 0x0B, 0x91, 0x01, 0x00, 0xB1, 0xB2, 0xB3]
        let c: [UInt8] = [0x24, 0x0C, 0x22, 0x02, 0x00, 0xC1, 0xC2, 0xC3]
        let d: [UInt8] = [0x24, 0x0D, 0x16, 0x03, 0x00, 0xD1, 0xD2, 0xD3]
        let t = advDeframe([truncated, advFrame(b), advFrame(c), advFrame(d)])
        #expect(t.frames == [b, c, d], "valid frames lost behind a truncated frame; got \(t.frames.map(advHexString))")
        #expect(t.malformedBytes + t.discardedBytes + t.remaining >= truncated.count, "the truncated frame must be reported")
    }

    /// IMPLEMENTATION BUG (same root cause, history impact): one truncated history record makes the decoder
    /// silently lose the following complete record(s) while the HistoryEnd marker still arrives intact, so the
    /// sync engine (which acks on HistoryEnd) would acknowledge a chunk missing records it never persisted.
    @Test func historyRecordsAfterATruncatedRecordAreDecodedBeforeTheEndMarker() {
        let decoder = Whoop5Decoder()
        let base: UInt32 = 1_779_000_000
        var events: [DecodedEvent] = []
        var now: EpochMillis = 1_000
        func feed(_ bytes: [UInt8]) {
            events += decoder.decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: bytes, receivedAt: now)
            now += 50
        }
        feed(advFrame(advMetadata(kind: 1)))
        let r1 = advFrame(advRecord(k: 24, counter: 1, seconds: base, length: 168, set: [17: 60]))
        feed(Array(r1.prefix(60)))                      // the rest of record 1 never arrives
        for n in 2...6 {
            feed(advFrame(advRecord(k: 24, counter: UInt32(n), seconds: base + UInt32(60 * n), length: 168, set: [17: UInt8(60 + n)])))
        }
        feed(advFrame(advMetadata(kind: 2, length: 28, token: [1, 2, 3, 4, 5, 6, 7, 8])))
        feed(advFrame(advMetadata(kind: 3)))
        let endIndex = events.firstIndex { if case .historyMarker(let m) = $0 { return m.kind == .end } else { return false } }
        let beforeEnd = endIndex.map { Array(events[..<$0]) } ?? events
        #expect(beforeEnd.advRecords.map(\.counter) == [2, 3, 4, 5, 6],
                "complete records lost before HistoryEnd (end marker decoded: \(endIndex != nil))")
    }

    /// IMPLEMENTATION BUG: a frame's phone receive time must be the time its first byte arrived. A stray
    /// start byte left over from an earlier notification (e.g. the tail of a frame whose start was missed)
    /// makes the next frame inherit that earlier chunk's time, even though the stray byte is discarded. The
    /// sync engine uses a record/marker's receivedAt as "last history activity" and compares it against the
    /// current notification time, so a stale time causes a false idle-timeout abort of the history transfer.
    @Test func frameReceiveTimeIsNotInheritedFromDiscardedBytes() {
        let decoder = Whoop5Decoder()
        let c = Whoop5Adapter.eventsFromStrap
        let first = decoder.decode(characteristic: c, bytes: [0x13, 0x37, 0x5A, 0xAA], receivedAt: 1_000)
        #expect(first.allSatisfy { if case .discarded = $0 { return true } else { return false } })
        let events = decoder.decode(characteristic: c, bytes: advFrame(advMetadata(kind: 1)), receivedAt: 100_000)
        #expect(events.advMarkers.count == 1)
        #expect(events.advMarkers.first?.receivedAt == 100_000,
                "frame stamped with the time of an earlier, discarded byte: \(events.advMarkers.first?.receivedAt ?? -1)")
    }

    @Test func frameReceiveTimeIsTheArrivalOfItsFirstChunk() {
        let a = advFrame(advRecord(k: 24, counter: 1, seconds: 1_779_000_000, length: 40, set: [17: 50]))
        let b = advFrame(advRecord(k: 24, counter: 2, seconds: 1_779_000_060, length: 40, set: [17: 51]))
        // chunk 1: first half of A; chunk 2: rest of A + first half of B; chunk 3: rest of B.
        let t = advDeframe([Array(a.prefix(20)), Array(a.dropFirst(20)) + Array(b.prefix(10)), Array(b.dropFirst(10))],
                           times: [10, 20, 30])
        #expect(t.frames.count == 2)
        #expect(t.frameTimes == [10, 20])
    }

    @Test func unpaddedFramesFromTheBandAreAccepted() {
        // Whether the band pads payloads is open (the public 162-byte "live identity" K24 payload is most likely a
        // truncated extraction); either way an unpadded frame must decode, since the declared length decides.
        let p = advRecord(k: 24, counter: 3_871, seconds: 1_779_773_861, length: 162, set: [17: 151])
        let frame = advFrame(p, pad: false)
        #expect(frame.count == 8 + 162 + 4)
        let events = Whoop5Decoder().decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: frame, receivedAt: 7)
        guard events.count == 1, let r = events.advRecords.first else { Issue.record("\(events)"); return }
        #expect(r.counter == 3_871 && r.deviceSeconds == 1_779_773_861 && r.heartRate == 151 && r.payloadLength == 162)
    }

    @Test func declaredLengthBoundaries() {
        let limit = Whoop5Wire.maxDeclaredLength
        // The largest public record (K10, 1_920-byte payload) must fit under Forma's bound.
        #expect(limit >= 1_920 + 4)
        let big = advRecord(k: 24, counter: 9, seconds: 1_779_000_000, length: limit - 4, set: [17: 55])   // declared == limit
        let accepted = Whoop5Decoder().decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: advFrame(big, pad: false), receivedAt: 1)
        #expect(accepted.advRecords.first?.payloadLength == limit - 4)
        // The bound is the u16 field itself: no larger length can even be expressed in a header.
        #expect(limit == Int(UInt16.max))
        for declared in 0...3 {
            let out = Whoop5Decoder().decode(characteristic: Whoop5Adapter.dataFromStrap,
                                             bytes: advHeader(declared: declared) + [UInt8](repeating: 0, count: 8), receivedAt: 1)
            #expect(out.advHasMalformed, "declared length \(declared) cannot even hold the payload CRC")
        }
    }

    @Test func frameWithEmptyPayloadIsReportedNotDropped() {
        let frame = advHeader(declared: 4) + advLE32(advCRC32([]))
        let events = Whoop5Decoder().decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: frame, receivedAt: 1)
        #expect(events.count == 1)
        #expect(events.advHasMalformed)
    }

    @Test func longRunOfStartBytesIsHandledInBoundedTime() {
        let chunk = [UInt8](repeating: 0xAA, count: 244)
        var d = Whoop5Deframer()
        var accounted = 0
        var frames = 0
        let elapsed = ContinuousClock().measure {
            for i in 0..<1_000 {
                for o in d.append(chunk, receivedAt: EpochMillis(i)) {
                    switch o {
                    case .frame: frames += 1
                    case .malformed(_, let n), .discarded(let n): accounted += n
                    }
                }
            }
        }
        accounted += d.reset()
        #expect(frames == 0)
        #expect(accounted == 244_000)
        #expect(elapsed < .seconds(10))
    }

    @Test func resetReportsPartialFramesPerCharacteristicAndNeverStitchesAcrossConnections() {
        let decoder = Whoop5Decoder()
        let frame = advFrame(advRecord(k: 24, counter: 5, seconds: 1_779_000_000, length: 40, set: [17: 61]))
        #expect(decoder.decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: Array(frame.prefix(30)), receivedAt: 10).isEmpty)
        #expect(decoder.decode(characteristic: "fd4b0004-cce1-4033-93ce-002d5875f58a", bytes: [0xAA, 0x01], receivedAt: 11).isEmpty)
        var discarded: [String: Int] = [:]
        for e in decoder.reset(at: 99) {
            guard case .discarded(let n, let c, let at) = e else { Issue.record("unexpected reset event \(e)"); continue }
            discarded[c, default: 0] += n
            #expect(at == 99)
        }
        #expect(discarded == [Whoop5Adapter.dataFromStrap: 30, Whoop5Adapter.eventsFromStrap: 2])
        // After reconnecting, the old frame's tail must not be stitched onto its pre-disconnect head.
        let tail = decoder.decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: Array(frame.dropFirst(30)), receivedAt: 200)
        #expect(tail.advRecords.isEmpty)
        let fresh = decoder.decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: frame, receivedAt: 300)
        #expect(fresh.advRecords.map(\.counter) == [5])
    }

    @Test func zeroLengthNotificationsAreHarmless() {
        let decoder = Whoop5Decoder()
        let frame = advFrame(advMetadata(kind: 3))
        var events: [DecodedEvent] = []
        events += decoder.decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: [], receivedAt: 1)
        events += decoder.decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: Array(frame.prefix(5)), receivedAt: 2)
        events += decoder.decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: [], receivedAt: 3)
        events += decoder.decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: Array(frame.dropFirst(5)), receivedAt: 4)
        #expect(events.count == 1)
        #expect(events.advMarkers.map(\.kind) == [.complete])
        #expect(events.advMarkers.first?.receivedAt == 2)
    }
}

// MARK: - Decoding

@Suite struct AdversarialDecoderTests {
    func decodeData(_ payload: [UInt8], pad: Bool = true, at: EpochMillis = 123) -> [DecodedEvent] {
        Whoop5Decoder().decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: advFrame(payload, pad: pad), receivedAt: at)
    }

    func motion(x: [Int16], y: [Int16], z: [Int16]) -> MotionSummary? {
        decodeData(advK10(hr: 70, x: x, y: y, z: z)).advRecords.first?.motion
    }

    @Test func publishedSyntheticK18RecordVector() {
        // Public synthetic K18 HISTORICAL_DATA payload: counter 0x01020304, seconds 0x11223344, subseconds 0x5566, marker 77 @14.
        let events = decodeData(advHex("2f120104030201443322116655aa4dbbccddeeff"), at: 42)
        guard events.count == 1, let r = events.advRecords.first else { Issue.record("\(events)"); return }
        #expect(r.kind == 18)
        #expect(r.counter == 16_909_060)
        #expect(r.deviceSeconds == 287_454_020)
        #expect(r.subseconds == 21_862)
        #expect(r.heartRate == 77)
        #expect(r.heartRateStatus == .unvalidated)
        #expect(r.beatIntervalsMillis.isEmpty && r.motion == nil)
        #expect(r.receivedAt == 42)
    }

    @Test func publishedResponseFrameVector() {
        // Public synthetic COMMAND_RESPONSE to GET_HELLO: seq 9, answers 145, origin seq 1, result 0, data 000000.
        let frame = advHex("aa010c000001e741" + "2409910100000000" + "401adc66")
        let events = Whoop5Decoder().decode(characteristic: Whoop5Adapter.commandFromStrap, bytes: frame, receivedAt: 5)
        #expect(events == [.commandResponse(CommandResponse(command: 145, sequence: 9, originSequence: 1, resultCode: 0,
                                                            data: [0, 0, 0], receivedAt: 5, answers: .identify, status: .unknown))])
    }

    @Test func eventHeaderTimestampIsNeverTrusted() {
        // Synthetic event 17 (goose's assumed timestamp at 4..9) and the prefix of the owned capture, where
        // the same bytes are an i16 waveform (an implausible "timestamp" in 2105).
        for payload in [advHex("300211000403020106050000deadbeef"), advHex("30001100d1ffb3ff5eff49ff")] {
            let events = Whoop5Decoder().decode(characteristic: Whoop5Adapter.eventsFromStrap, bytes: advFrame(payload), receivedAt: 9)
            guard events.count == 1, case .deviceEvent(let e)? = events.first else { Issue.record("\(events)"); continue }
            #expect(e.eventID == 17 && e.name == "TEMPERATURE_LEVEL")
            #expect(e.deviceSeconds == nil)
            #expect(Array(e.data.prefix(payload.count - 4)) == Array(payload.dropFirst(4)), "event body kept verbatim as evidence")
        }
    }

    @Test func eventIDIsSixteenBitsSoClockDiscontinuityNamesCannotAlias() {
        // The sync engine treats RTC_LOST / BOOT / SET_RTC (by name) as clock discontinuities.
        func name(_ id: UInt16) -> String? {
            let e = Whoop5Decoder().decode(characteristic: Whoop5Adapter.eventsFromStrap,
                                           bytes: advFrame([0x30, 0x00, UInt8(id & 0xFF), UInt8(id >> 8)]), receivedAt: 1)
            if case .deviceEvent(let r)? = e.first { return r.name } else { return nil }
        }
        #expect(name(13) == "RTC_LOST")
        #expect(name(15) == "BOOT")
        #expect(name(16) == "SET_RTC")
        #expect(name(0x010D) != "RTC_LOST")
        #expect(name(0x0F0F) != "BOOT")
        #expect(name(0xFF10) != "SET_RTC")
    }

    @Test func historyHeartRateCandidatesAreNeverZeroAndAlwaysUnvalidated() {
        for k in 0...255 {
            for length in [13, 15, 18, 28, 40, 168] {
                for v: UInt8 in [0, 1, 51, 151, 255] {
                    let p = advRecord(k: UInt8(k), counter: 1, seconds: 1_779_000_000, length: length, set: [14: v, 17: v, 27: v])
                    let events = decodeData(p)
                    guard events.count == 1, let r = events.advRecords.first else {
                        Issue.record("K\(k) length \(length): \(events)"); continue
                    }
                    if let hr = r.heartRate {
                        #expect(hr > 0, "K\(k): zero must mean 'no heart rate', never 0 bpm")
                        #expect(hr == Int(v), "K\(k): heart-rate candidate must be the byte the band sent")
                    }
                    if v == 0 { #expect(r.heartRate == nil, "K\(k) length \(length)") }
                    #expect(r.heartRateStatus == .unvalidated, "K\(k): not validated on the owner's band")
                    #expect(r.beatIntervalsMillis.isEmpty, "K\(k): beat intervals are unsupported on this generation")
                    if k != 10 { #expect(r.motion == nil, "K\(k): motion only comes from K10 accelerometer axes") }
                }
            }
        }
    }

    @Test func k10ActivityIsMeanAbsoluteDeviationOfMagnitudeFromMedian() {
        let zeros = [Int16](repeating: 0, count: 100)
        let ramp = (1...100).map { Int16($0) }   // no (0, 0, 0) sample anywhere
        // Hand-computed: magnitudes 1…100 → median 50.5, mean 50.5, mean |m − 50.5| = 25.
        for (x, y, z) in [(zeros, zeros, ramp), (ramp.map { -$0 }, zeros, zeros), (zeros, ramp, zeros)] {
            guard let m = motion(x: x, y: y, z: z) else { Issue.record("expected motion"); continue }
            #expect(m.sampleCount == 100)
            #expect(abs(m.meanMagnitude - 50.5) < 1e-9)
            #expect(abs(m.activity - 25.0) < 1e-9)
        }
        // Orientation-free: constant |a| = 5 split as (3, 4, 0) is perfectly still with magnitude 5.
        guard let still = motion(x: [Int16](repeating: 3, count: 100), y: [Int16](repeating: -4, count: 100), z: zeros) else {
            Issue.record("expected motion"); return
        }
        #expect(still.activity == 0 && abs(still.meanMagnitude - 5) < 1e-9)
    }

    @Test func extremeAxisCountsDoNotOverflow() {
        let minimum = [Int16](repeating: .min, count: 100)
        guard let m = motion(x: minimum, y: minimum, z: minimum) else { Issue.record("expected motion"); return }
        #expect(abs(m.meanMagnitude - 32_768 * Double(3).squareRoot()) < 1e-6)
        #expect(m.activity == 0)
    }

    /// IMPLEMENTATION BUG: "never fabricate measurements (nil, not 0)". A 3-axis accelerometer always measures
    /// gravity (the public capture's |a| is ~1,000–1,600 counts); 100 samples of exactly (0, 0, 0) are an
    /// absent/zero-filled block (the protocol zero-fills unused regions), not a reading. The decoder reports
    /// it as MotionSummary(meanMagnitude: 0, activity: 0), i.e. measured perfect stillness, which the sync
    /// engine stores as a motion epoch with activity 0 that sleep detection would read as "asleep".
    @Test func allZeroAccelerometerBlockIsNotReportedAsMeasuredStillness() {
        let zeros = [Int16](repeating: 0, count: 100)
        let events = decodeData(advK10(hr: 70, x: zeros, y: zeros, z: zeros))
        guard let r = events.advRecords.first else { Issue.record("\(events)"); return }
        #expect(r.heartRate == 70)
        #expect(r.motion == nil, "zero-filled accelerometer block reported as measured stillness: \(String(describing: r.motion))")
    }

    @Test func rawClockFieldsAreReportedVerbatimNeverSubstituted() {
        let cases: [(UInt32, UInt32, UInt16)] = [(.max, .max, .max), (0, 0, 0), (1, 946_684_799, 1_000)]
        for (counter, seconds, sub) in cases {
            let events = decodeData(advRecord(k: 24, counter: counter, seconds: seconds, subseconds: sub, length: 40, set: [17: 60]), at: 777)
            guard let r = events.advRecords.first else { Issue.record("\(events)"); continue }
            #expect(r.counter == counter)
            #expect(r.deviceSeconds == seconds, "device time must never be replaced (e.g. by receive time)")
            #expect(r.subseconds == sub)
            #expect(r.receivedAt == 777)
        }
    }

    @Test func standardHeartRateFlagsFollowTheSIGSpecification() {
        let d = Whoop5Decoder()
        func hr(_ b: [UInt8]) -> DecodedEvent? { d.decode(characteristic: "2A37", bytes: b, receivedAt: 1).first }
        #expect(hr([0x00, 60]) == .standardHeartRate(bpm: 60, contact: .notSupported, rrMillis: [], energyKJ: nil, receivedAt: 1))
        // Bit 1 (contact detected) is meaningless while bit 2 (contact supported) is clear.
        #expect(hr([0x02, 60]) == .standardHeartRate(bpm: 60, contact: .notSupported, rrMillis: [], energyKJ: nil, receivedAt: 1))
        #expect(hr([0x04, 60]) == .standardHeartRate(bpm: 60, contact: .notDetected, rrMillis: [], energyKJ: nil, receivedAt: 1))
        #expect(hr([0x06, 60]) == .standardHeartRate(bpm: 60, contact: .detected, rrMillis: [], energyKJ: nil, receivedAt: 1))
        // Reserved bits 5–7 are ignored.
        #expect(hr([0xE0, 60]) == .standardHeartRate(bpm: 60, contact: .notSupported, rrMillis: [], energyKJ: nil, receivedAt: 1))
        // UINT16 HR 300, energy 0x1234 kJ, RR 0x0400 (1000 ms) and 0xFFFF.
        #expect(hr([0x19, 0x2C, 0x01, 0x34, 0x12, 0x00, 0x04, 0xFF, 0xFF])
                == .standardHeartRate(bpm: 300, contact: .notSupported, rrMillis: [1_000, 65_535.0 * 1_000 / 1_024], energyKJ: 4_660, receivedAt: 1))
        // UINT16 zero → no reading (nil, never 0).
        #expect(hr([0x01, 0x00, 0x00]) == .standardHeartRate(bpm: nil, contact: .notSupported, rrMillis: [], energyKJ: nil, receivedAt: 1))
        for bad: [UInt8] in [[], [0x00], [0x01, 60], [0x08, 60, 0x05], [0x18, 60, 0x05, 0x00, 0x01]] {
            guard case .malformed? = hr(bad) else { Issue.record("expected malformed for \(bad)"); continue }
        }
    }

    @Test func batteryLevelIsNeverClampedOrGuessed() {
        let d = Whoop5Decoder()
        #expect(d.decode(characteristic: "2a19", bytes: [0], receivedAt: 1) == [.batteryLevel(percent: 0, receivedAt: 1)])
        #expect(d.decode(characteristic: "2A19", bytes: [100], receivedAt: 1) == [.batteryLevel(percent: 100, receivedAt: 1)])
        for bad: [UInt8] in [[101], [255], [], [50, 0]] {
            let e = d.decode(characteristic: "2A19", bytes: bad, receivedAt: 1)
            #expect(e.count == 1 && e.advHasMalformed, "battery bytes \(bad) must be reported, not clamped")
        }
    }

    @Test func everyCompleteFrameYieldsAtLeastOneEvent() {
        var rng = AdvRNG(state: 0x5EED_0003)
        for type in 0...255 {
            for length in [1, 2, 3, 4, 5, 12, 13, 21, 22, 40] {
                var p = rng.bytes(length)
                p[0] = UInt8(type)
                for c in [Whoop5Adapter.commandFromStrap, Whoop5Adapter.eventsFromStrap, Whoop5Adapter.dataFromStrap] {
                    let events = Whoop5Decoder().decode(characteristic: c, bytes: advFrame(p), receivedAt: 1)
                    #expect(!events.isEmpty, "type \(type) length \(length) on \(c) silently dropped")
                    #expect(events.allSatisfy { if case .discarded = $0 { return false } else { return true } },
                            "a valid frame must not be reported as discarded bytes")
                }
            }
        }
    }

    @Test func realtimeAndIMUCarriersAreNotMislabelledAsHistory() {
        for type: UInt8 in [40, 43, 51] {
            let events = decodeData(advRecord(type: type, k: 24, counter: 3, seconds: 1_779_000_000, length: 40, set: [17: 70]))
            #expect(events.advRecords.isEmpty, "packet type \(type) is not HISTORICAL_DATA (47)")
            #expect(!events.isEmpty, "packet type \(type) must be reported, not dropped")
            #expect(events.advReportedBytes == 0, "a valid frame is not malformed or discarded bytes")
        }
        // HISTORICAL_IMU_DATA_STREAM (52) belongs to a history transfer but Forma does not store it: it is
        // reported as history whose content was not decoded, so its chunk is never acknowledged.
        let imu = decodeData(advRecord(type: 52, k: 24, counter: 3, seconds: 1_779_000_000, length: 40, set: [17: 70]))
        #expect(imu.advRecords.count == 1 && imu.advRecords.allSatisfy { !$0.contentDecoded && $0.heartRate == nil })
        #expect(imu.advReportedBytes == 0)
    }

    @Test func unknownMetadataKindsAreReportedNotTurnedIntoMarkers() {
        for kind in [0, 4, 5, 0x81, 0xFF] {
            let events = decodeData(advMetadata(kind: UInt8(kind), length: 24, token: [9, 9, 9, 9, 9, 9, 9, 9]))
            #expect(events.advMarkers.isEmpty, "metadata kind \(kind)")
            #expect(events.count == 1)
        }
    }

    @Test func endMarkerTokenNeedsMoreThan21PayloadBytes() {
        let token: [UInt8] = [8, 7, 6, 5, 4, 3, 2, 1]
        func endToken(length: Int, pad: Bool) -> [UInt8]?? {
            decodeData(advMetadata(kind: 2, length: length, token: token), pad: pad).advMarkers.first.map(\.ackToken)
        }
        #expect(endToken(length: 21, pad: false) == .some(nil), "21-byte end marker carries no token")
        #expect(endToken(length: 22, pad: false) == .some(token))
        #expect(endToken(length: 24, pad: true) == .some(token))
        #expect(endToken(length: 3, pad: true) == .some(nil))
    }

    @Test func interleavedCharacteristicsWithMixedUUIDSpellingsReassembleIndependently() {
        let decoder = Whoop5Decoder()
        let dataFrames = (1...3).map { advFrame(advRecord(k: 24, counter: UInt32($0), seconds: 1_779_000_000 + UInt32($0), length: 40, set: [17: 70])) }
        let eventFrames = [13, 15, 29].map { advFrame([0x30, 0x00, UInt8($0), 0x00, 0xAA, 0xAA]) }
        let dataSpellings = [Whoop5Adapter.dataFromStrap, Whoop5Adapter.dataFromStrap.lowercased(), " " + Whoop5Adapter.dataFromStrap.lowercased()]
        let eventSpellings = [Whoop5Adapter.eventsFromStrap.lowercased(), Whoop5Adapter.eventsFromStrap]
        var events: [DecodedEvent] = []
        for i in 0..<3 {
            // Three contiguous pieces of each frame, data and event pieces alternating on the two characteristics.
            let dataCuts = [0, 7, 23, dataFrames[i].count]
            let eventCuts = [0, 5, 12, eventFrames[i].count]
            for j in 0..<3 {
                events += decoder.decode(characteristic: dataSpellings[(3 * i + j) % dataSpellings.count],
                                         bytes: Array(dataFrames[i][dataCuts[j]..<dataCuts[j + 1]]), receivedAt: 1)
                events += decoder.decode(characteristic: eventSpellings[(3 * i + j) % eventSpellings.count],
                                         bytes: Array(eventFrames[i][eventCuts[j]..<eventCuts[j + 1]]), receivedAt: 1)
            }
        }
        #expect(events.advRecords.map(\.counter) == [1, 2, 3])
        let ids = events.compactMap { e -> UInt16? in if case .deviceEvent(let r) = e { return r.eventID } else { return nil } }
        #expect(ids == [13, 15, 29])
        #expect(!events.advHasMalformed)
        #expect(events.advReportedBytes == 0)
    }
}

// MARK: - Robustness (crash-freedom) on untrusted input

/// Body of the exit test below: frame an oversized payload-only capture and decode it.
/// Runs in a child process so a trap cannot take down the test runner.
fileprivate func advFrameOversizedPayloadOnlyCapture() {
    // Refusing to frame it (a thrown error) is fine; trapping is not.
    guard let frame = try? Whoop5Adapter.frame(payload: [UInt8](repeating: 0x2F, count: 65_532)) else { exit(0) }
    let events = Whoop5Decoder().decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: frame, receivedAt: 0)
    if events.contains(where: { if case .historyRecord = $0 { return true } else { return false } }) { exit(3) }
}

@Suite struct AdversarialRobustnessTests {
    /// IMPLEMENTATION BUG: `Whoop5Adapter.frame(payload:)` is public and documented as the way tools wrap
    /// payload-only captures (forma-replay decodes user-supplied hex files with it). A payload of 65_529+
    /// bytes overflows the u16 declared length (`UInt16(padded.count + 4)`) and traps, crashing the tool on
    /// malformed input instead of reporting it ("malformed frames are rejected without crashing").
    @Test func payloadOnlyCaptureFramingDoesNotTrapOnOversizedPayload() async {
        await #expect(processExitsWith: .success) {
            advFrameOversizedPayloadOnlyCapture()
        }
    }

    @Test func decoderNeverCrashesOnArbitraryCharacteristicsAndBytes() {
        var rng = AdvRNG(state: 0x5EED_0004)
        let characteristics = [Whoop5Adapter.commandFromStrap, Whoop5Adapter.eventsFromStrap, Whoop5Adapter.dataFromStrap,
                               Whoop5Adapter.memfault, Whoop5Adapter.commandToStrap, "2A37", "2a19", "2A26", "2A24", "2A29",
                               "2A27", "2A28", "2A38", "FFFF", "", "not-a-uuid"]
        for adapter in AdapterRegistry.all {
            let decoder = adapter.makeDecoder()
            for _ in 0..<3_000 {
                let c = characteristics[rng.int(0...(characteristics.count - 1))]
                var bytes = rng.bytes(rng.int(0...80))
                if rng.int(0...3) == 0 { bytes = advFrame(bytes) }
                _ = decoder.decode(characteristic: c, bytes: bytes, receivedAt: EpochMillis(rng.int(0...1_000_000)))
                if rng.int(0...200) == 0 { _ = decoder.reset(at: 0) }
            }
            _ = decoder.reset(at: 1)
        }
    }
}
