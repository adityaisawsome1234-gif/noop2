import Foundation
import Testing
import FormaCore
@testable import FormaProtocol
@testable import FormaSync

/// A scripted WHOOP 5.0 band: on SEND_HISTORICAL_DATA (cmd 22) it streams HistoryStart, K24 records
/// split across small notifications, HistoryEnd with a token, and HistoryComplete.
@Suite struct Whoop5EndToEndTests {
    static let seconds: UInt32 = 1_762_500_000

    static let now: EpochMillis = Int64(seconds) * 1_000 + 86_400_000

    static func framed(_ payload: [UInt8]) -> [UInt8] {
        // swiftlint:disable:next force_try
        try! Whoop5Wire.frame(payload: payload)
    }

    static func record(counter: UInt32, hr: UInt8) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 168)
        p[0] = 47; p[1] = 24
        let s = seconds + counter * 60
        for i in 0..<4 { p[3 + i] = UInt8(counter >> (8 * i) & 0xFF); p[7 + i] = UInt8(s >> (8 * i) & 0xFF) }
        p[17] = hr
        return framed(p)
    }

    static func endMarker() -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 24)
        p[0] = 49; p[2] = 2
        for i in 13..<21 { p[i] = 0xA0 + UInt8(i - 13) }
        return framed(p)
    }

    /// COMMAND_RESPONSE: 36, seq, command, origin seq, result, data.
    static func response(to written: [UInt8], result: UInt8, data: [UInt8] = []) -> LinkEvent {
        .notification(characteristic: Whoop5Adapter.commandFromStrap,
                      bytes: framed([36, 0x40, written[10], written[9], result] + data), receivedAt: now)
    }

    /// A scripted band. Answers hello, clock (band clock = phone clock), range (success with a 25-byte
    /// body), the history request (success, then the chunk in 20-byte notifications) and the ack.
    static func band(log: OrderLog) -> ReplayLink {
        let data = Whoop5Adapter.dataFromStrap
        return ReplayLink(entries: [], services: [Whoop5Adapter.service: [Whoop5Adapter.commandToStrap, data]], responder: { bytes, _ in
            guard bytes.count > 10, bytes[8] == 0x23 else { return [] }
            log.append("write:\(bytes[10])")
            switch bytes[10] {
            case 145: return [response(to: bytes, result: 1)]
            case 11:
                let s = UInt32(now / 1_000)
                return [response(to: bytes, result: 1, data: (0..<4).map { UInt8(s >> (8 * $0) & 0xFF) } + [0, 0, 0, 0])]
            case 34: return [response(to: bytes, result: 1, data: [UInt8](repeating: 0, count: 25))]
            case 23: return [response(to: bytes, result: 1)]
            case 22:
                var stream = framed([49, 0, 1])
                for c in 1...3 { stream += record(counter: UInt32(c), hr: UInt8(55 + c)) }
                stream += endMarker() + framed([49, 0, 3])
                // Deliver in 20-byte notifications to exercise reassembly.
                var events: [LinkEvent] = [response(to: bytes, result: 1)]
                var i = 0
                while i < stream.count {
                    events.append(.notification(characteristic: data, bytes: Array(stream[i..<min(stream.count, i + 20)]), receivedAt: 5_000 + Int64(i)))
                    i += 20
                }
                return events
            default:
                return []
            }
        })
    }

    static func engine(sink: RecordingSink, acknowledge: Bool) -> SyncEngine {
        let device = DeviceRecord(id: "band", family: .whoop5, name: "WHOOP", firstSeen: 0)
        return SyncEngine(adapter: Whoop5Adapter(), sink: sink, device: device, timeSource: ManualTimeSource(now),
                          options: SyncOptions(history: .automatic, acknowledgeHistory: acknowledge, liveHeartRate: false,
                                               liveFlushIntervalMillis: 0, timerIntervalMillis: 0))
    }

    @Test func historyTransferIsPersistedThenAcknowledgedWithToken() async throws {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        let link = Self.band(log: log)
        let run = await runScript(Self.engine(sink: sink, acknowledge: true), link: link)

        // Three records persisted, timestamped by the band clock (not arrival time), marked unvalidated.
        #expect(sink.hr.map(\.bpm) == [56, 57, 58])
        #expect(sink.hr.map(\.timestamp) == (1...3).map { Int64(Self.seconds + UInt32($0) * 60) * 1_000 })
        #expect(sink.hr.allSatisfy { $0.quality.contains(.unvalidatedField) && !$0.quality.contains(.phoneReceiveTime) })

        // Commands: hello (145), clock (11), data range (34), send history (22), then ack (23) after persistence.
        let writes = link.writtenCommands.map { $0.bytes }
        #expect(writes.map { $0[10] } == [145, 11, 34, 22, 23])
        let ack = writes[4]
        #expect(Array(ack[11..<20]) == [0x01] + (0..<8).map { 0xA0 + UInt8($0) })
        let entries = log.all
        let ackIndex = entries.firstIndex(of: "write:23")!
        let ingestIndex = entries.lastIndex(of: "ingest:history")!
        #expect(ingestIndex < ackIndex)
        #expect(sink.currentCursor?.lastCompleteSyncAt != nil)
        #expect(sink.currentCursor?.newestPersistedRecordTime == Int64(Self.seconds + 180) * 1_000)
        #expect(sink.currentCursor?.opaque == Data((0..<8).map { 0xA0 + UInt8($0) }))
        #expect(run.status == .completed)
    }

    @Test func downloadOnlyByDefaultLeavesTheBandsCopy() async throws {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        let link = Self.band(log: log)
        let run = await runScript(Self.engine(sink: sink, acknowledge: false), link: link)
        #expect(sink.hr.count == 3)
        #expect(link.writtenCommands.map { $0.bytes[10] } == [145, 11, 34, 22], "no acknowledgement, no abort")
        #expect(sink.currentCursor?.lastCompleteSyncAt != nil)
        #expect(run.status == .completed)
    }
}
