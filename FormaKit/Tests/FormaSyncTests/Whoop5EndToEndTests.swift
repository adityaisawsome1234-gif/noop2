import Foundation
import Testing
import FormaCore
@testable import FormaProtocol
@testable import FormaSync

/// A scripted WHOOP 5.0 band: on SEND_HISTORICAL_DATA (cmd 22) it streams HistoryStart, K24 records
/// split across small notifications, HistoryEnd with a token, and HistoryComplete.
@Suite struct Whoop5EndToEndTests {
    static let seconds: UInt32 = 1_762_500_000

    static func record(counter: UInt32, hr: UInt8) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 168)
        p[0] = 47; p[1] = 24
        let s = seconds + counter * 60
        for i in 0..<4 { p[3 + i] = UInt8(counter >> (8 * i) & 0xFF); p[7 + i] = UInt8(s >> (8 * i) & 0xFF) }
        p[17] = hr
        return Whoop5Wire.frame(payload: p)
    }

    static func endMarker() -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 24)
        p[0] = 49; p[2] = 2
        for i in 13..<21 { p[i] = 0xA0 + UInt8(i - 13) }
        return Whoop5Wire.frame(payload: p)
    }

    @Test func historyTransferIsPersistedThenAcknowledgedWithToken() async throws {
        let log = OrderLog()
        let sink = RecordingSink(log: log)
        let data = Whoop5Adapter.dataFromStrap
        let link = ReplayLink(entries: [], services: [Whoop5Adapter.service: [Whoop5Adapter.commandToStrap, data]], responder: { bytes, _ in
            log.append("write:\(bytes.count > 10 ? String(bytes[10]) : "?")")
            guard bytes.count > 10, bytes[8] == 0x23, bytes[10] == 22 else { return [] }
            var stream = Whoop5Wire.frame(payload: [49, 0, 1])
            for c in 1...3 { stream += Self.record(counter: UInt32(c), hr: UInt8(55 + c)) }
            stream += Self.endMarker() + Whoop5Wire.frame(payload: [49, 0, 3])
            // Deliver in 20-byte notifications to exercise reassembly.
            var events: [LinkEvent] = []
            var i = 0
            while i < stream.count {
                events.append(.notification(characteristic: data, bytes: Array(stream[i..<min(stream.count, i + 20)]), receivedAt: 5_000 + Int64(i)))
                i += 20
            }
            return events
        })
        let device = DeviceRecord(id: "band", family: .whoop5, name: "WHOOP", firstSeen: 0)
        let engine = SyncEngine(adapter: Whoop5Adapter(), sink: sink, device: device,
                                timeSource: ManualTimeSource(Int64(Self.seconds) * 1_000 + 86_400_000),
                                options: SyncOptions(history: .automatic, liveHeartRate: false, liveFlushIntervalMillis: 0))
        _ = await runScript(engine, link: link)

        // Three records persisted, timestamped by the band clock (not arrival time), marked unvalidated.
        #expect(sink.hr.map(\.bpm) == [56, 57, 58])
        #expect(sink.hr.map(\.timestamp) == (1...3).map { Int64(Self.seconds + UInt32($0) * 60) * 1_000 })
        #expect(sink.hr.allSatisfy { $0.quality.contains(.unvalidatedField) && !$0.quality.contains(.phoneReceiveTime) })

        // Commands written: hello (145), data range (34), send history (22), then ack (23) after persistence.
        let writes = link.writtenCommands.map { $0.bytes }
        #expect(writes.map { $0[10] } == [145, 34, 22, 23])
        let ack = writes[3]
        #expect(Array(ack[11..<20]) == [0x01] + (0..<8).map { 0xA0 + UInt8($0) })
        let entries = log.all
        let ackIndex = entries.firstIndex(of: "write:23")!
        let ingestIndex = entries.lastIndex(of: "ingest:history")!
        #expect(ingestIndex < ackIndex)
        #expect(sink.currentCursor?.lastCompleteSyncAt != nil)
        #expect(sink.currentCursor?.newestPersistedRecordTime == Int64(Self.seconds + 180) * 1_000)
    }
}
