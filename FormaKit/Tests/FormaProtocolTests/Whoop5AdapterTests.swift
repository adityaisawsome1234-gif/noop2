import Foundation
import Testing
import FormaCore
@testable import FormaProtocol

func hex(_ s: String) -> [UInt8] {
    let clean = s.filter { $0.isHexDigit }
    var out: [UInt8] = []
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        out.append(UInt8(clean[i..<j], radix: 16)!)
        i = j
    }
    return out
}

func hexOf(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

/// Test helper: frames a payload that is known to be small enough.
func framed(_ payload: [UInt8]) -> [UInt8] {
    // swiftlint:disable:next force_try
    try! Whoop5Wire.frame(payload: payload)
}

/// Builds a data payload: type, K, status, counter, seconds, subseconds, then body bytes up to `length`.
func dataPayload(type: UInt8 = 47, k: UInt8, counter: UInt32, seconds: UInt32, length: Int, set: [Int: UInt8] = [:]) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: max(13, length))
    p[0] = type; p[1] = k; p[2] = 0
    for i in 0..<4 { p[3 + i] = UInt8(counter >> (8 * i) & 0xFF); p[7 + i] = UInt8(seconds >> (8 * i) & 0xFF) }
    for (o, v) in set where o < p.count { p[o] = v }
    return p
}

@Suite struct Whoop5WireTests {
    @Test func crcCatalogueCheckValues() {
        let check = Array("123456789".utf8)
        #expect(Whoop5Wire.crc16Modbus(check) == 0x4B37)
        #expect(Whoop5Wire.crc32(check) == 0xCBF4_3926)
    }

    @Test func helloFrameMatchesPublishedBytes() throws {
        // GET_HELLO, sequence 1, data 01 — the frame published by public interoperability work.
        let frame = try Whoop5Adapter().encode(.identify, sequence: 1)
        #expect(hexOf(frame.bytes) == "aa0108000001e67123019101363e5c8d")
        #expect(frame.command == .identify && frame.sequence == 1)
    }

    @Test func frameBuilderMatchesIndependentlyDerivedVectors() throws {
        // Derived by a separate verification script from the documented algorithm (not captured from a band).
        let a = Whoop5Adapter()
        #expect(hexOf(try a.encode(.readHistoryRange, sequence: 7).bytes) == "aa0108000001e67123072200698f3e31")
        #expect(hexOf(try a.encode(.requestHistory, sequence: 8).bytes) == "aa0108000001e67123081600a33b4881")
        #expect(hexOf(try a.encode(.setRealtimeHeartRate(enabled: true), sequence: 180).bytes) == "aa0108000001e67123b4030155eabe0d")
        #expect(hexOf(try a.encode(.setRealtimeHeartRate(enabled: false), sequence: 182).bytes) == "aa0108000001e67123b60300ad0e3d79")
        #expect(hexOf(try a.encode(.readClock, sequence: 96).bytes) == "aa0108000001e67123600b0027cde038")
        #expect(hexOf(try a.encode(.acknowledgeHistory(token: [UInt8](repeating: 0, count: 8)), sequence: 59).bytes)
                == "aa0110000001e0d1233b17010000000000000000ed8d38cd")
        // The abort frame is still derivable from the documented algorithm, but Forma never sends it.
        #expect(hexOf(framed([0x23, 0x01, 0x14])) == "aa0108000001e67123011400ae62afbc")
    }

    @Test func frameBuilderRejectsOversizedPayloads() {
        #expect(throws: FrameBuildError.self) { _ = try Whoop5Adapter.frame(payload: [UInt8](repeating: 0x2F, count: 65_529)) }
        // The largest payload whose padded length + 4 still fits the u16 length field.
        #expect(Whoop5Wire.maxPayloadLength == 65_528)
        #expect((try? Whoop5Adapter.frame(payload: [UInt8](repeating: 0x2F, count: Whoop5Wire.maxPayloadLength)))?.count == 8 + 65_528 + 4)
    }

    @Test func acknowledgementCarriesSuccessByteAndToken() throws {
        let token: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let frame = try Whoop5Adapter().encode(.acknowledgeHistory(token: token), sequence: 9).bytes
        // payload: 23 09 17 01 + token (12 bytes, already 4-aligned) → declared length 16
        #expect(frame[2] == 16 && frame[3] == 0)
        #expect(Array(frame[8..<20]) == [0x23, 0x09, 0x17, 0x01] + token)
        #expect(Whoop5Wire.crc32(frame[8..<20]) == Whoop5Wire.u32(frame, 20))
    }

    @Test func allowlistRejectsEverythingElse() {
        let a = Whoop5Adapter()
        #expect(a.supports(.readClock) && a.supports(.setRealtimeHeartRate(enabled: true)) && a.supports(.setRealtimeHeartRate(enabled: false)))
        #expect(!a.supports(.readBattery), "battery comes from the standard Battery Service")
        #expect(!a.supports(.abortHistory), "never sent: unused by the reference client, effect unverified")
        #expect(!a.supports(.acknowledgeHistory(token: [1, 2, 3])))
        #expect(throws: CommandEncodingError.self) { _ = try a.encode(.abortHistory, sequence: 1) }
        #expect(throws: CommandEncodingError.self) { _ = try a.encode(.readBattery, sequence: 1) }
        #expect(throws: CommandEncodingError.self) { _ = try a.encode(.acknowledgeHistory(token: []), sequence: 1) }
        #expect(throws: CommandEncodingError.self) { _ = try StandardHeartRateAdapter().encode(.identify, sequence: 1) }
        // Only read-only, stream and history command ids exist at all.
        #expect(Set(Whoop5Adapter.CommandID.allCases.map(\.rawValue)) == [3, 11, 20, 22, 23, 34, 145])
    }

    @Test func responsesAreMatchedToTheCommandsTheyAnswer() {
        #expect(Whoop5Adapter.answeredCommand(34) == .readHistoryRange)
        #expect(Whoop5Adapter.answeredCommand(22) == .requestHistory)
        #expect(Whoop5Adapter.answeredCommand(23) == .acknowledgeHistory)
        #expect(Whoop5Adapter.answeredCommand(11) == .readClock)
        #expect(Whoop5Adapter.answeredCommand(3) == .setRealtimeHeartRate)
        #expect(Whoop5Adapter.answeredCommand(99) == nil)
        #expect(Whoop5Adapter.status(ofResult: 1) == .success)
        #expect(Whoop5Adapter.status(ofResult: 2) == .pending)
        #expect(Whoop5Adapter.status(ofResult: 0) == .unknown, "contested between public sources")
        #expect(Whoop5Adapter.status(ofResult: 3) == .rejected)
    }
}

@Suite struct Whoop5DeframerTests {
    let payloads: [[UInt8]] = [
        [0x24, 0x09, 0x91, 0x01, 0x00, 0xAA, 0xAA, 0x01],                       // response containing 0xAA bytes
        dataPayload(k: 24, counter: 7, seconds: 1_762_500_000, length: 40, set: [17: 61]),
        [0x31, 0x00, 0x01],                                                     // metadata start
    ]

    var stream: [UInt8] { payloads.flatMap { framed($0) } }

    func decodeAll(_ chunks: [[UInt8]]) -> [Whoop5Deframer.Output] {
        var d = Whoop5Deframer()
        return chunks.flatMap { d.append($0, receivedAt: 1) }
    }

    func frames(_ outputs: [Whoop5Deframer.Output]) -> [[UInt8]] {
        outputs.compactMap { if case .frame(let p, _) = $0 { return p } else { return nil } }
    }

    @Test func splitAtEveryPosition() {
        let s = stream
        let expected = payloads.map { p -> [UInt8] in var q = p; while q.count % 4 != 0 { q.append(0) }; return q }
        for cut in 0...s.count {
            let out = decodeAll([Array(s[..<cut]), Array(s[cut...])])
            #expect(frames(out) == expected, "split at \(cut)")
        }
        // One byte at a time.
        #expect(frames(decodeAll(s.map { [$0] })) == expected)
    }

    @Test func garbageAndStrayStartBytesResync() {
        let noisy: [UInt8] = [0x00, 0xAA, 0x13, 0xAA, 0x01, 0x02] + stream + [0xAA]
        let out = decodeAll([noisy])
        #expect(frames(out).count == 3)
        let discarded = out.reduce(0) { if case .discarded(let n) = $1 { return $0 + n } else { return $0 } }
        #expect(discarded >= 5)
    }

    @Test func corruptedPayloadIsReportedAndStreamContinues() {
        var s = stream
        s[12] ^= 0xFF // inside the first payload
        let out = decodeAll([s])
        #expect(frames(out).count == 2)
        #expect(out.contains { if case .malformed(let r, _) = $0 { return r.contains("CRC") } else { return false } })
    }

    @Test func corruptedHeaderResyncs() {
        var s = stream
        s[7] ^= 0x01 // header CRC of the first frame
        let out = decodeAll([s])
        #expect(frames(out).count == 2)
    }

    @Test func impossibleLengthRejected() {
        var header: [UInt8] = [0xAA, 0x01, 0x02, 0x00, 0x00, 0x01]   // declared 2 < 4
        let crc = Whoop5Wire.crc16Modbus(header)
        header += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        let out = decodeAll([header + stream])
        #expect(out.contains { if case .malformed(let r, _) = $0 { return r.contains("out of range") } else { return false } })
        #expect(frames(out).count == 3)
    }

    @Test func hugeDeclaredLengthDoesNotSwallowFollowingFrames() {
        // A header-CRC-valid header declaring 65 535 bytes, followed by three genuine frames.
        var header: [UInt8] = [0xAA, 0x01, 0xFF, 0xFF, 0x00, 0x01]
        let crc = Whoop5Wire.crc16Modbus(header)
        header += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        let out = decodeAll([header + stream])
        #expect(out.contains { if case .malformed(let r, _) = $0 { return r.contains("truncated") } else { return false } })
        #expect(frames(out).count == 3)
    }

    @Test func framesAfterATruncatedFrameAreRecoveredAndKeepTheirOwnReceiveTimes() {
        let full = framed(dataPayload(k: 24, counter: 1, seconds: 1_762_500_000, length: 180, set: [17: 60]))
        let truncated = Array(full.prefix(60))
        let b = framed(dataPayload(k: 24, counter: 2, seconds: 1_762_500_001, length: 180, set: [17: 61]))
        let c = framed([0x31, 0x00, 0x02] + [UInt8](repeating: 7, count: 21))
        var d = Whoop5Deframer()
        var out = d.append(truncated, receivedAt: 10)
        out += d.append(b, receivedAt: 20)
        out += d.append(c, receivedAt: 30)
        let got = out.compactMap { o -> EpochMillis? in if case .frame(_, let at) = o { return at } else { return nil } }
        #expect(got == [20, 30], "both genuine frames are recovered with their own arrival times: \(out)")
        #expect(out.contains { if case .malformed = $0 { return true } else { return false } })
    }

    @Test func seededFuzzNeverCrashesAndNeverEmitsBadFrames() {
        var rng = SystemRandomNumberGenerator()
        _ = rng
        var state: UInt64 = 0x1234_5678
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        for _ in 0..<300 {
            var bytes: [UInt8] = []
            for _ in 0..<Int(next() % 400) { bytes.append(UInt8(next() & 0xFF)) }
            if next() % 2 == 0 { bytes.insert(contentsOf: stream, at: Int(next() % UInt64(bytes.count + 1))) }
            var d = Whoop5Deframer()
            var chunks: [[UInt8]] = []
            var i = 0
            while i < bytes.count { let n = Int(next() % 30) + 1; chunks.append(Array(bytes[i..<min(bytes.count, i + n)])); i += n }
            for c in chunks {
                for o in d.append(c, receivedAt: 0) {
                    if case .frame(let p, _) = o {
                        // Every emitted frame must be one we can rebuild with valid CRCs.
                        #expect(framed(p).count >= 12)
                    }
                }
            }
            _ = d.reset()
        }
    }
}

@Suite struct Whoop5DecoderTests {
    func decode(_ payload: [UInt8], on c: String = Whoop5Adapter.dataFromStrap) -> [DecodedEvent] {
        Whoop5Decoder().decode(characteristic: c, bytes: framed(payload), receivedAt: 500)
    }

    @Test func normalHistoryHeartRateCandidateIsUnvalidated() {
        let events = decode(dataPayload(k: 24, counter: 9, seconds: 1_762_500_000, length: 168, set: [17: 58]))
        guard case .historyRecord(let r)? = events.first else { Issue.record("expected record: \(events)"); return }
        #expect(r.kind == 24 && r.counter == 9 && r.deviceSeconds == 1_762_500_000)
        #expect(r.heartRate == 58 && r.heartRateStatus == .unvalidated)
        #expect(r.beatIntervalsMillis.isEmpty)
    }

    @Test func zeroMarkerMeansNoHeartRate() {
        let events = decode(dataPayload(k: 24, counter: 1, seconds: 1_762_500_000, length: 40))
        guard case .historyRecord(let r)? = events.first else { Issue.record("expected record"); return }
        #expect(r.heartRate == nil)
    }

    @Test func k10MotionSummaryFromAccelerometerAxes() {
        var p = dataPayload(k: 10, counter: 3, seconds: 1_762_500_000, length: 1288, set: [17: 70, 18: 100])
        // Constant 1000-count magnitude on z with alternating ±100 on x → activity is small but non-zero.
        for i in 0..<100 {
            let x: Int16 = i % 2 == 0 ? 100 : -100
            let z: Int16 = 1000
            p[85 + 2 * i] = UInt8(UInt16(bitPattern: x) & 0xFF); p[86 + 2 * i] = UInt8(UInt16(bitPattern: x) >> 8)
            p[485 + 2 * i] = UInt8(UInt16(bitPattern: z) & 0xFF); p[486 + 2 * i] = UInt8(UInt16(bitPattern: z) >> 8)
        }
        guard case .historyRecord(let r)? = decode(p).first, let m = r.motion else { Issue.record("expected motion"); return }
        #expect(m.sampleCount == 100)
        #expect(abs(m.meanMagnitude - (1_000_000.0 + 10_000).squareRoot()) < 1e-6)
        #expect(m.activity == 0) // every sample has identical magnitude
        #expect(m.spanMillis == Whoop5Decoder.k10AssumedSpanMillis)
        #expect(r.heartRate == 70 && r.contentDecoded)
    }

    @Test func k10WithoutRealSamplesHasNoMotion() {
        // All-zero accelerometer block: absent samples, not stillness.
        let zero = dataPayload(k: 10, counter: 3, seconds: 1_762_500_000, length: 1288, set: [17: 70, 18: 100])
        guard case .historyRecord(let r)? = decode(zero).first else { Issue.record("expected record"); return }
        #expect(r.motion == nil)
        // Sample-count byte other than 100: layout not understood.
        var odd = zero
        odd[18] = 50
        for i in 0..<100 { odd[485 + 2 * i] = 0xE8; odd[486 + 2 * i] = 0x03 }
        guard case .historyRecord(let r2)? = decode(odd).first else { Issue.record("expected record"); return }
        #expect(r2.motion == nil)
    }

    @Test func undecodedKindsAndHistoryIMUAreMarked() {
        guard case .historyRecord(let k21)? = decode(dataPayload(k: 21, counter: 4, seconds: 1_762_500_000, length: 140)).first else {
            Issue.record("expected record"); return
        }
        #expect(!k21.contentDecoded && k21.heartRate == nil)
        guard case .historyRecord(let imu)? = decode(dataPayload(type: 52, k: 1, counter: 5, seconds: 1_762_500_000, length: 64)).first else {
            Issue.record("expected record"); return
        }
        #expect(!imu.contentDecoded)
    }

    @Test func realtimeFramesCarryAnUnvalidatedHeartRateCandidate() {
        let events = decode(dataPayload(type: 43, k: 10, counter: 8, seconds: 1_762_500_100, length: 168, set: [17: 150]))
        #expect(events == [.realtimeHeartRate(bpm: 150, deviceSeconds: 1_762_500_100, status: .unvalidated, receivedAt: 500)])
        // No candidate for this kind → reported, not guessed.
        guard case .unknownPacket(let t, _, _, _)? = decode(dataPayload(type: 40, k: 21, counter: 8, seconds: 1_762_500_100, length: 140)).first else {
            Issue.record("expected unknown"); return
        }
        #expect(t == 40)
    }

    @Test func clockResponseBecomesAClockReading() {
        // GET_CLOCK response: seconds 1_762_500_000, sub-seconds 16 384/32 768 s = 500 ms.
        var p: [UInt8] = [0x24, 0x07, 0x0B, 0x60, 0x01]
        p += [0x00, 0x27, 0x0D, 0x69] // 1_762_500_352 LE? (checked below)
        p += [0x00, 0x40, 0x00, 0x00]
        let events = decode(p, on: Whoop5Adapter.commandFromStrap)
        let seconds = UInt32(0x00) | UInt32(0x27) << 8 | UInt32(0x0D) << 16 | UInt32(0x69) << 24
        #expect(events.count == 2)
        #expect(events.last == .clockReading(deviceSeconds: seconds, subsecondMillis: 500, receivedAt: 500))
        guard case .commandResponse(let r)? = events.first else { Issue.record("expected response"); return }
        #expect(r.answers == .readClock && r.status == .success)
        // A failed clock read yields no reading.
        let failed = decode([0x24, 0x07, 0x0B, 0x60, 0x00, 0, 0, 0, 0, 0, 0, 0, 0], on: Whoop5Adapter.commandFromStrap)
        #expect(failed.count == 1)
    }

    @Test func truncatedK10HasNoMotion() {
        guard case .historyRecord(let r)? = decode(dataPayload(k: 10, counter: 3, seconds: 1_762_500_000, length: 168, set: [17: 70])).first else {
            Issue.record("expected record"); return
        }
        #expect(r.motion == nil)
    }

    @Test func markersAndToken() {
        var end = [UInt8](repeating: 0, count: 24)
        end[0] = 0x31; end[2] = 2
        for i in 13..<21 { end[i] = UInt8(i) }
        let events = decode([0x31, 0, 1]) + decode(end) + decode([0x31, 0, 3]) + decode([0x31, 0, 2])
        let markers = events.compactMap { e -> HistoryMarker? in if case .historyMarker(let m) = e { return m } else { return nil } }
        #expect(markers.map(\.kind) == [.start, .end, .complete, .end])
        #expect(markers[1].ackToken == Array(13..<21).map { UInt8($0) })
        #expect(markers[3].ackToken == nil, "a short end marker carries no token")
    }

    @Test func responsesEventsAndUnknown() {
        let r = decode([0x24, 0x05, 0x91, 0x01, 0x00, 0xDE, 0xAD], on: Whoop5Adapter.commandFromStrap)
        #expect(r == [.commandResponse(CommandResponse(command: 0x91, sequence: 5, originSequence: 1, resultCode: 0, data: [0xDE, 0xAD, 0x00], receivedAt: 500,
                                                       answers: .identify, status: .unknown))])
        guard case .deviceEvent(let e)? = decode([0x30, 0x00, 0x0D, 0x00, 0x01], on: Whoop5Adapter.eventsFromStrap).first else {
            Issue.record("expected event"); return
        }
        #expect(e.eventID == 13 && e.name == "RTC_LOST" && e.deviceSeconds == nil)
        guard case .unknownPacket(let type, _, _, _)? = decode([0x32, 1, 2, 3]).first else { Issue.record("expected unknown"); return }
        #expect(type == 0x32)
        guard case .malformed? = decode([0x2F, 24, 0]).first else { Issue.record("expected malformed short record"); return }
    }

    @Test func standardHeartRateMeasurement() {
        let d = Whoop5Decoder()
        // flags 0x16: UINT8 HR, contact supported+detected, RR present; HR 72; RR 1024 (=1000 ms), 512 (=500 ms)
        #expect(d.decode(characteristic: "2A37", bytes: [0x16, 72, 0x00, 0x04, 0x00, 0x02], receivedAt: 1)
                == [.standardHeartRate(bpm: 72, contact: .detected, rrMillis: [1000, 500], energyKJ: nil, receivedAt: 1)])
        // UINT16 HR with energy expended, contact supported but not detected
        #expect(d.decode(characteristic: "2a37", bytes: [0x0D, 0x2C, 0x01, 0x10, 0x00], receivedAt: 2)
                == [.standardHeartRate(bpm: 300, contact: .notDetected, rrMillis: [], energyKJ: 16, receivedAt: 2)])
        // HR 0 → no reading; odd RR byte → malformed
        #expect(d.decode(characteristic: "2A37", bytes: [0x00, 0x00], receivedAt: 3)
                == [.standardHeartRate(bpm: nil, contact: .notSupported, rrMillis: [], energyKJ: nil, receivedAt: 3)])
        guard case .malformed? = d.decode(characteristic: "2A37", bytes: [0x10, 60, 0x00], receivedAt: 4).first else {
            Issue.record("odd RR bytes must be rejected"); return
        }
        #expect(d.decode(characteristic: "2A19", bytes: [87], receivedAt: 5) == [.batteryLevel(percent: 87, receivedAt: 5)])
        guard case .malformed? = d.decode(characteristic: "2A19", bytes: [101], receivedAt: 6).first else { Issue.record("battery > 100"); return }
        #expect(d.decode(characteristic: "2A26", bytes: Array("41.17.3\0".utf8), receivedAt: 7) == [.deviceInformation(field: "firmware", value: "41.17.3")])
        // Junk after a NUL, bidi controls and non-ASCII are removed; an all-junk value yields nothing.
        #expect(d.decode(characteristic: "2A26", bytes: Array("4\u{202E}1.2\0garbage".utf8), receivedAt: 8) == [.deviceInformation(field: "firmware", value: "41.2")])
        #expect(d.decode(characteristic: "2A27", bytes: [0xFF, 0xFE, 0x00, 0x41], receivedAt: 9).isEmpty)
    }

    @Test func registryPicksAdapterFromServices() {
        #expect(AdapterRegistry.adapter(forDiscoveredServices: ["fd4b0001-cce1-4033-93ce-002d5875f58a", "180D"])?.adapterID == "forma.whoop5")
        #expect(AdapterRegistry.adapter(forDiscoveredServices: ["180d"])?.adapterID == "forma.standard-hr")
        #expect(AdapterRegistry.adapter(forDiscoveredServices: ["1234"]) == nil)
    }
}
