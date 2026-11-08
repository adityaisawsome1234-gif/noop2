// Regression tests for the second review of the WHOOP 5.0 adapter: linear-time reassembly on hostile input,
// the documented nested-frame limit, field-presence-aware `contentDecoded`, K10 zero vectors, the device-
// information sanitizer and explicitly declared vendor characteristics.

import Foundation
import Testing
import FormaCore
@testable import FormaProtocol

fileprivate func rfHeader(declared: UInt16) -> [UInt8] {
    var h: [UInt8] = [0xAA, 0x01, UInt8(declared & 0xFF), UInt8(declared >> 8), 0x00, 0x01]
    let crc = Whoop5Wire.crc16Modbus(h)
    h += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    return h
}

fileprivate func rfFrame(_ payload: [UInt8]) -> [UInt8] { (try? Whoop5Wire.frame(payload: payload)) ?? [] }

/// A frame without padding (the band does not always pad), so a short payload stays short.
fileprivate func rfUnpaddedFrame(_ payload: [UInt8]) -> [UInt8] {
    let crc = Whoop5Wire.crc32(payload)
    return rfHeader(declared: UInt16(payload.count + 4)) + payload + (0..<4).map { UInt8(truncatingIfNeeded: crc >> (8 * UInt32($0))) }
}

/// Data payload: type, kind, status, counter, seconds, sub-seconds, zero body up to `length`, then `set`.
fileprivate func rfRecord(kind: UInt8, length: Int, set: [Int: UInt8] = [:], type: UInt8 = 47) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: max(13, length))
    p[0] = type
    p[1] = kind
    p[3] = 7
    let seconds: UInt32 = 1_779_000_000
    for i in 0..<4 { p[7 + i] = UInt8(truncatingIfNeeded: seconds >> (8 * UInt32(i))) }
    for (k, v) in set where k < p.count { p[k] = v }
    return p
}

/// K10 with the given accelerometer axes (100 samples each) and sample-count byte.
fileprivate func rfK10(x: [Int16], y: [Int16], z: [Int16], countByte: UInt8 = 100, hr: UInt8 = 70) -> [UInt8] {
    var p = rfRecord(kind: 10, length: 1_920, set: [17: hr, 18: countByte])
    for (axis, base) in [(x, 85), (y, 285), (z, 485)] {
        for (i, v) in axis.enumerated() {
            let u = UInt16(bitPattern: v)
            p[base + 2 * i] = UInt8(u & 0xFF)
            p[base + 2 * i + 1] = UInt8(u >> 8)
        }
    }
    return p
}

fileprivate func rfDecode(_ payload: [UInt8]) -> HistoryRecord? {
    let events = Whoop5Decoder().decode(characteristic: Whoop5Adapter.dataFromStrap, bytes: rfUnpaddedFrame(payload), receivedAt: 1)
    if case .historyRecord(let r)? = events.first { return r }
    return nil
}

/// Feeds `stream` in `size`-byte notifications; returns the outputs and the elapsed time.
fileprivate func rfDeframe(_ stream: [UInt8], size: Int) -> (outputs: [Whoop5Deframer.Output], seconds: Double) {
    var d = Whoop5Deframer()
    var out: [Whoop5Deframer.Output] = []
    let clock = ContinuousClock()
    let start = clock.now
    var i = 0
    while i < stream.count {
        let j = min(stream.count, i + size)
        out += d.append(Array(stream[i..<j]), receivedAt: Int64(i))
        i = j
    }
    let elapsed = clock.now - start
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    return (out, seconds)
}

/// Bytes accounted for by the outputs (frames count their whole frame length).
fileprivate func rfAccounted(_ outputs: [Whoop5Deframer.Output]) -> Int {
    outputs.reduce(0) { sum, o in
        switch o {
        case .frame(let p, _): return sum + Whoop5Wire.headerLength + p.count + 4
        case .malformed(_, let n), .discarded(let n): return sum + n
        }
    }
}

@Suite struct ReviewFixDeframerTests {
    @Test func segmentCRCFromPrefixesEqualsTheDirectCRC() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 { state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return state >> 33 }
        let bytes = (0..<4_096).map { _ in UInt8(truncatingIfNeeded: next()) }
        var register: UInt32 = 0xFFFF_FFFF
        var prefix: [UInt32] = [0]
        for b in bytes {
            register = Whoop5Wire.crc32Step(register, b)
            prefix.append(register ^ 0xFFFF_FFFF)
        }
        #expect(prefix.last == Whoop5Wire.crc32(bytes))
        for _ in 0..<500 {
            let a = Int(next() % UInt64(bytes.count))
            let b = a + Int(next() % UInt64(bytes.count - a + 1))
            let combined = Whoop5Wire.crc32OfSegment(prefixCRC: prefix[a], extendedCRC: prefix[b], length: b - a)
            #expect(combined == Whoop5Wire.crc32(bytes[a..<b]), "segment \(a)..<\(b)")
        }
    }

    /// Hostile inputs from the review that took seconds (release build) because every notification rescanned
    /// the pending span, every truncation restarted the look-ahead, and every candidate's CRC was recomputed.
    /// Each must now take a small fraction of that even in a debug build, with every byte accounted for.
    @Test func hostileStreamsAreReassembledInLinearTime() {
        let validTail = rfFrame([0x31, 0x00, 0x03, 0x00])
        let a = rfHeader(declared: 0xFFFF) + rfHeader(declared: 0xFDE8) + [UInt8](repeating: 0xAA, count: 64_000)
        var b = rfHeader(declared: 0xFFFF) + rfHeader(declared: 0xFDE8)
        while b.count < 16_384 { b += rfHeader(declared: 0x07D0) }
        let d = (0..<8_000).flatMap { _ in rfHeader(declared: 0xFFFF) } + validTail
        let genuine = rfFrame(rfRecord(kind: 24, length: 30_000, set: [17: 60]))
        let cases: [(String, [UInt8], Int)] = [("A", a, 20), ("B", b, 20), ("D", d, d.count), ("genuine 30 KB bytewise", genuine, 1)]
        for (name, stream, size) in cases {
            let (outputs, seconds) = rfDeframe(stream, size: size)
            #expect(seconds < 5, "\(name): \(seconds) s")
            let pending = stream.count - rfAccounted(outputs)
            #expect(pending >= 0 && pending <= 65_543, "\(name): accounting")
        }
        // D ends with a complete valid frame: it is recovered and nothing before it is left pending.
        let (dOut, _) = rfDeframe(d, size: d.count)
        #expect(dOut.contains(.frame(payload: [0x31, 0x00, 0x03, 0x00], receivedAt: 0)))
        #expect(rfAccounted(dOut) == d.count)
        // The genuine frame arrives intact even one byte at a time.
        let (gOut, _) = rfDeframe(genuine, size: 1)
        #expect(gOut.count == 1 && rfAccounted(gOut) == genuine.count)
    }

    /// Documented limit (Whoop5Deframer doc, ARCHITECTURE §2): a CRC-valid frame nested inside another CRC-valid
    /// frame makes the outcome depend on the split. Either way nothing is silently lost: the outer frame is
    /// delivered whole, or it is reported as malformed and the inner frame is delivered.
    @Test func nestedValidFramesAreTheDocumentedSplitDependence() {
        let inner = rfFrame([0x31, 0x00, 0x03, 0x00])
        let outerPayload: [UInt8] = [0x2F, 0x10, 0x6A, 0, 0, 1, 2, 3] + inner + [UInt8](repeating: 0x07, count: 39)
        let outer = rfFrame(outerPayload)
        let (whole, _) = rfDeframe(outer, size: outer.count)
        #expect(whole == [.frame(payload: outerPayload + [UInt8](repeating: 0, count: (4 - outerPayload.count % 4) % 4), receivedAt: 0)])
        let cut = 8 + 8 + inner.count + 1
        var dfr = Whoop5Deframer()
        let split = dfr.append(Array(outer.prefix(cut)), receivedAt: 0) + dfr.append(Array(outer.dropFirst(cut)), receivedAt: 1)
        #expect(split.contains(.frame(payload: [0x31, 0x00, 0x03, 0x00], receivedAt: 0)))
        #expect(split.contains { if case .malformed = $0 { return true } else { return false } }, "the lost outer frame is reported")
        #expect(rfAccounted(split) + dfr.pendingByteCount == outer.count, "every byte is accounted for")
    }
}

@Suite struct ReviewFixRecordDecodingTests {
    /// A record of a decoded kind whose heart-rate field lies beyond its payload is not fully decoded.
    @Test func decodedKindsWithoutTheirHeartRateFieldAreNotContentDecoded() {
        let cases: [(UInt8, Int, Bool)] = [(24, 14, false), (24, 17, false), (24, 18, true), (9, 17, false), (12, 18, true),
                                           (18, 14, false), (18, 15, true), (7, 27, false), (7, 28, true)]
        for (kind, length, expected) in cases {
            guard let r = rfDecode(rfRecord(kind: kind, length: length, set: [14: 61, 17: 61, 27: 61])) else {
                Issue.record("K\(kind) \(length)"); continue
            }
            #expect(r.contentDecoded == expected, "K\(kind) length \(length)")
            if !expected { #expect(r.heartRate == nil, "K\(kind) length \(length): no field, no value") }
        }
    }

    @Test func k10WhoseMotionBlockIsNotUnderstoodKeepsItsHeartRateButIsNotContentDecoded() {
        let z = [Int16](repeating: 1_210, count: 100)
        let zeros = [Int16](repeating: 0, count: 100)
        guard let odd = rfDecode(rfK10(x: zeros, y: zeros, z: z, countByte: 50)) else { Issue.record("decode"); return }
        #expect(odd.heartRate == 70 && odd.motion == nil && !odd.contentDecoded)
        guard let short = rfDecode(rfRecord(kind: 10, length: 600, set: [17: 70, 18: 100])) else { Issue.record("decode"); return }
        #expect(short.heartRate == 70 && short.motion == nil && !short.contentDecoded, "motion block cut off")
        guard let empty = rfDecode(rfK10(x: zeros, y: zeros, z: zeros)) else { Issue.record("decode"); return }
        #expect(empty.motion == nil && empty.contentDecoded, "a zero-filled block measured nothing: decoded, nothing to keep")
    }

    /// "never fabricate": zero vectors are absent samples, never magnitude-0 measurements.
    @Test func k10ZeroVectorsAreLeftOutOfEveryStatistic() {
        var z = [Int16](repeating: 1_210, count: 100)
        z[98] = 0
        z[99] = 0
        let zeros = [Int16](repeating: 0, count: 100)
        guard let r = rfDecode(rfK10(x: zeros, y: zeros, z: z)), let m = r.motion else { Issue.record("expected motion"); return }
        #expect(m.sampleCount == 98)
        #expect(m.activity == 0, "only real samples, all of magnitude 1210")
        #expect(abs(m.meanMagnitude - 1_210) < 1e-9)
        #expect(r.contentDecoded)
        // Fewer real samples than the minimum: not summarized, and the record is not fully decoded.
        var sparse = [Int16](repeating: 0, count: 100)
        for i in 0..<(Whoop5Decoder.k10MinimumRealSamples - 1) { sparse[i] = 1_000 }
        guard let s = rfDecode(rfK10(x: zeros, y: zeros, z: sparse)) else { Issue.record("decode"); return }
        #expect(s.motion == nil && !s.contentDecoded)
    }
}

@Suite struct ReviewFixDeviceInformationTests {
    private func firmware(_ bytes: [UInt8]) -> [DecodedEvent] {
        Whoop5Decoder().decode(characteristic: "2A26", bytes: bytes, receivedAt: 3)
    }

    @Test func emptyOrUnprintableValuesAreReportedNotDropped() {
        for bytes: [UInt8] in [[0x00, 0x41], [0xFF, 0xFE], [0x20, 0x20], [], [0x09]] {
            let events = firmware(bytes)
            #expect(events.count == 1, "\(bytes)")
            guard case .malformed(_, let n, _, let at)? = events.first else { Issue.record("\(bytes): \(events)"); continue }
            #expect(n == bytes.count && at == 3)
        }
    }

    @Test func unprintableBytesBecomeVisibleEscapesSoDistinctValuesNeverMerge() {
        #expect(firmware(Array("1.2\u{1B}[31m\u{7F}evil".utf8)) == [.deviceInformation(field: "firmware", value: "1.2\\x1B[31m\\x7Fevil")])
        let beta = firmware(Array("4.1β".utf8))
        #expect(beta == [.deviceInformation(field: "firmware", value: "4.1\\xCE\\xB2")])
        #expect(beta != firmware(Array("4.1".utf8)))
        #expect(firmware(Array("a\\b".utf8)) == [.deviceInformation(field: "firmware", value: "a\\\\b")], "a backslash is escaped too")
        #expect(firmware(Array("  41.17.3 \0junk".utf8)) == [.deviceInformation(field: "firmware", value: "41.17.3")])
    }

    @Test func truncationKeepsEscapesWholeAndTrimsAgain() {
        let cap = StandardServiceParsing.maxDeviceInformationLength
        #expect(firmware(Array(String(repeating: "A", count: 70).utf8)) == [.deviceInformation(field: "firmware", value: String(repeating: "A", count: cap))])
        let escapeAtTheCut = String(repeating: "A", count: cap - 2) + "é"
        #expect(firmware(Array(escapeAtTheCut.utf8)) == [.deviceInformation(field: "firmware", value: String(repeating: "A", count: cap - 2))])
        let spaceAtTheCut = String(repeating: "B", count: cap - 1) + " C"
        #expect(firmware(Array(spaceAtTheCut.utf8)) == [.deviceInformation(field: "firmware", value: String(repeating: "B", count: cap - 1))])
    }
}

@Suite struct ReviewFixGATTTests {
    /// 16-bit vendor UUIDs sit on the SIG base: an adapter declares them instead of relying on inference.
    @Test func vendorCharacteristicsOnTheSIGBaseCanBeDeclared() {
        let inferred = GATTProfile(vendorService: nil, discoverServices: [], subscribeCharacteristics: [], commandCharacteristic: nil,
                                   commandWriteWithResponse: true, scanServiceFilter: [], nameHints: [])
        #expect(!inferred.carriesVendorFrames("FFF1"))
        #expect(inferred.carriesVendorFrames("ADF00005-0000-0000-0000-000000000000"))
        let declared = GATTProfile(vendorService: nil, discoverServices: [], subscribeCharacteristics: ["FFF1"], commandCharacteristic: "FFF2",
                                   commandWriteWithResponse: true, scanServiceFilter: [], nameHints: [], framedCharacteristics: ["fff1"])
        #expect(declared.carriesVendorFrames("FFF1"))
        #expect(!declared.carriesVendorFrames("2A37"))
        let whoop = Whoop5Adapter().gatt
        for c in [Whoop5Adapter.commandFromStrap, Whoop5Adapter.eventsFromStrap, Whoop5Adapter.dataFromStrap, Whoop5Adapter.memfault] {
            #expect(whoop.carriesVendorFrames(c))
        }
        #expect(!whoop.carriesVendorFrames(UUIDs.heartRateMeasurement))
        #expect(!whoop.carriesVendorFrames("2A00"))
    }
}
