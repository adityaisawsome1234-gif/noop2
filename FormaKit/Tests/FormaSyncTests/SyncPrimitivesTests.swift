import Foundation
import Testing
import FormaCore
@testable import FormaProtocol
@testable import FormaSync

/// Test helper: an encoded command with arbitrary bytes (only tests can build one).
func testCommand(_ bytes: [UInt8]) -> EncodedCommand {
    EncodedCommand(command: .identify, sequence: 0, bytes: bytes)
}

@Suite struct ClockMapperTests {
    let now: EpochMillis = 1_762_560_000_000

    @Test func trustsDeviceClockWithoutReadingOrWithinTolerance() {
        var m = ClockMapper()
        let t = UInt32(now / 1_000) - 60
        #expect(m.map(deviceSeconds: t, now: now) == .init(timestamp: Int64(t) * 1_000, flags: [], appliedOffsetMillis: nil))
        m.add(DeviceClockReading(deviceSeconds: UInt32(now / 1_000), phoneTime: now + 1_500))
        #expect(m.map(deviceSeconds: t, now: now).flags == [])
    }

    @Test func appliesLargeOffsetWithFlag() {
        var m = ClockMapper()
        m.add(DeviceClockReading(deviceSeconds: UInt32(now / 1_000) - 300, subsecondMillis: 0, phoneTime: now)) // band 5 min slow
        let mapped = m.map(deviceSeconds: UInt32(now / 1_000) - 360, now: now)
        #expect(mapped.timestamp == now - 60_000)
        #expect(mapped.flags.contains(.clockOffsetApplied))
        #expect(mapped.appliedOffsetMillis == 300_000)
    }

    @Test func implausibleDeviceTimeIsUnmappedNotArrivalTime() {
        let m = ClockMapper()
        let mapped = m.map(deviceSeconds: 42, now: now)
        #expect(mapped.timestamp == nil)
        #expect(mapped.flags.contains(.clockUnmapped))
        let future = m.map(deviceSeconds: UInt32(now / 1_000) + 3 * 86_400, now: now)
        #expect(future.timestamp == nil)
    }

    @Test func disagreeingReadingsMarkUnstable() {
        var m = ClockMapper()
        m.add(DeviceClockReading(deviceSeconds: 1_700_000_000, phoneTime: 1_700_000_000_000))
        m.add(DeviceClockReading(deviceSeconds: 1_700_000_100, phoneTime: 1_700_000_160_000)) // drifted 60 s
        #expect(m.unstable)
        #expect(m.map(deviceSeconds: 1_700_000_100, now: now).flags.contains(.nearClockDiscontinuity))
        m.add(DeviceClockReading(deviceSeconds: 1_700_000_200, phoneTime: 1_700_000_260_000)) // consistent again
        #expect(!m.unstable)
    }
}

@Suite struct DiscontinuityDetectorTests {
    @Test func detectsRestartAndBackwardClock() {
        var d = DiscontinuityDetector()
        #expect(d.observe(counter: 10, deviceSeconds: 1_000) == .continuous)
        #expect(d.observe(counter: 11, deviceSeconds: 1_001) == .continuous)
        #expect(d.observe(counter: 12, deviceSeconds: 900) == .clockWentBackwards(seconds: 101))
        #expect(d.observe(counter: 3, deviceSeconds: 950) == .counterRestart)
        #expect(d.observe(counter: 4, deviceSeconds: 949) == .continuous) // within tolerance
    }
}

@Suite struct ReconnectPolicyTests {
    @Test func backoffGrowsAndCaps() {
        let p = ReconnectPolicy(initialDelaySeconds: 2, maxDelaySeconds: 60, multiplier: 2, jitter: 0)
        #expect(p.delay(afterFailures: 0, jitterUnit: 0.5) == 0)
        #expect(p.delay(afterFailures: 1, jitterUnit: 0.5) == 2)
        #expect(p.delay(afterFailures: 3, jitterUnit: 0.5) == 8)
        #expect(p.delay(afterFailures: 50, jitterUnit: 0.5) == 60)
        let j = ReconnectPolicy(initialDelaySeconds: 10, maxDelaySeconds: 100, multiplier: 2, jitter: 0.2)
        #expect(abs(j.delay(afterFailures: 1, jitterUnit: 0) - 8) < 1e-9)
        #expect(abs(j.delay(afterFailures: 1, jitterUnit: 0.999999) - 12) < 1e-3)
    }

    @Test func sequenceWrapsAround() {
        var s = SequenceCounter(start: 254)
        #expect(s.next() == 255)
        #expect(s.next() == 0)
        #expect(s.next() == 1)
    }
}

@Suite struct ReplayLinkTests {
    @Test func replaysEntriesThenDisconnects() async throws {
        let link = ReplayLink(entries: [
            CaptureEntry(t: 1, dir: .rx, c: "2a37", d: "0048"),
            CaptureEntry(t: 2, dir: .tx, c: "x", d: "00"),
            CaptureEntry(t: 3, dir: .rx, c: "2A37", d: "zz"), // invalid hex skipped
            CaptureEntry(t: 4, dir: .rx, c: "2A37", d: "0049"),
        ], services: ["180D": ["2A37"]])
        var events: [LinkEvent] = []
        for await e in link.events { events.append(e) }
        #expect(events.count == 4)
        #expect(events[1] == .notification(characteristic: UUIDs.normalize("2A37"), bytes: [0x00, 0x48], receivedAt: 1))
        if case .disconnected = events.last {} else { Issue.record("expected disconnect at end") }
        await #expect(throws: LinkError.notConnected) { try await link.write(testCommand([1]), characteristic: "x", withResponse: true) }
    }

    @Test func responderScriptsReactions() async throws {
        let link = ReplayLink(entries: [], services: [:], responder: { bytes, _ in
            bytes == [0x01] ? [.notification(characteristic: "AA", bytes: [0x02], receivedAt: 5)] : []
        })
        try await link.write(testCommand([0x01]), characteristic: "bb", withResponse: true)
        link.finish()
        var events: [LinkEvent] = []
        for await e in link.events { events.append(e) }
        #expect(events.contains(.notification(characteristic: "AA", bytes: [0x02], receivedAt: 5)))
        #expect(link.writtenCommands.count == 1)
    }

    @Test func uuidNormalization() {
        #expect(UUIDs.normalize(" 2a37 ") == "00002A37-0000-1000-8000-00805F9B34FB")
        #expect(UUIDs.equal("fd4b0001-cce1-4033-93ce-002d5875f58a", "FD4B0001-CCE1-4033-93CE-002D5875F58A"))
    }
}
