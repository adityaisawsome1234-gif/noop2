import Foundation
import Testing
import FormaCore
@testable import FormaStore

@Suite("Raw frames, devices, connection history, sync runs")
struct DiagnosticsTests {
    private func frame(_ receivedAt: EpochMillis, size: Int = 20, fill: UInt8 = 0xAB) -> RawFrameRecord {
        RawFrameRecord(deviceID: deviceA, receivedAt: receivedAt, characteristic: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6",
                       bytes: Data(repeating: fill, count: size), parseStatus: "ok")
    }

    private func frameStats(_ store: FormaStore) throws -> (count: Int, bytes: Int) {
        try store.withConnectionForTesting { db in
            let statement = try db.prepare("SELECT COUNT(*), COALESCE(SUM(length(bytes)), 0) FROM raw_frame")
            try statement.step()
            return (statement.int(0) ?? -1, statement.int(1) ?? -1)
        }
    }

    // MARK: Raw frames

    @Test func rawCaptureIsOffByDefault() throws {
        let store = try makeStore()
        #expect(try store.rawCaptureEnabled() == false)
        try store.recordRawFrame(frame(t0))
        #expect(try store.rawFrames().isEmpty)
    }

    @Test func rawCaptureStoresFramesWhileEnabled() throws {
        let store = try makeStore()
        try store.setRawCaptureEnabled(true)
        #expect(try store.rawCaptureEnabled())
        #expect(try store.setting(forKey: StoreSettingKey.rawCaptureEnabled) == "true")
        let empty = RawFrameRecord(deviceID: nil, receivedAt: t0 + 1, characteristic: "2a37", bytes: Data(),
                                   parseStatus: "malformed: empty")
        try store.recordRawFrame(frame(t0))
        try store.recordRawFrame(empty)
        #expect(try store.rawFrames() == [empty, frame(t0)])
        #expect(try store.rawFrames(limit: 1) == [empty])
        try store.setRawCaptureEnabled(false)
        try store.recordRawFrame(frame(t0 + 2))
        #expect(try store.rawFrames().count == 2)
        #expect(try store.deleteRawFrames() == 2)
        #expect(try store.rawFrames().isEmpty)
    }

    @Test func retentionBoundsTheFrameCount() throws {
        let store = try makeStore(retention: RawFrameRetention(maxAgeMillis: EpochMillis.millisPerDay, maxFrames: 10,
                                                               maxTotalBytes: 1 << 20))
        try store.setRawCaptureEnabled(true)
        for index in 0..<35 {
            try store.recordRawFrame(frame(t0 + Int64(index), fill: UInt8(index)))
            #expect(try frameStats(store).count <= 10)
        }
        let newest = try #require(try store.rawFrames(limit: 1).first)
        #expect(newest.bytes.first == 34)
        let kept = try frameStats(store).count
        #expect(kept >= 9)
        #expect(try store.rawFrames().map(\.receivedAt) == (0..<kept).map { t0 + 34 - Int64($0) })
    }

    @Test func retentionBoundsTheTotalBytes() throws {
        let store = try makeStore(retention: RawFrameRetention(maxAgeMillis: EpochMillis.millisPerDay, maxFrames: 1_000,
                                                               maxTotalBytes: 100))
        try store.setRawCaptureEnabled(true)
        for index in 0..<20 {
            try store.recordRawFrame(frame(t0 + Int64(index), size: 30))
            #expect(try frameStats(store).bytes <= 100)
        }
        #expect(try store.rawFrames(limit: 1).first?.receivedAt == t0 + 19)
        // A frame that alone exceeds the byte bound is not stored (and evicts nothing).
        let before = try frameStats(store)
        try store.recordRawFrame(frame(t0 + 100, size: 101))
        #expect(try frameStats(store) == before)
        // A frame of exactly the bound is kept, alone.
        try store.recordRawFrame(frame(t0 + 101, size: 100))
        #expect(try frameStats(store) == (1, 100))
    }

    @Test func retentionDropsFramesOlderThanTheAgeBound() throws {
        let time = ManualTimeSource(t0)
        let store = try makeStore(time: time, retention: RawFrameRetention(maxAgeMillis: 60_000, maxFrames: 1_000,
                                                                           maxTotalBytes: 1 << 20))
        try store.setRawCaptureEnabled(true)
        try store.recordRawFrame(frame(t0 - 10_000))
        try store.recordRawFrame(frame(t0))
        time.advance(byMillis: 55_000)
        try store.enforceRawFrameRetention()
        #expect(try store.rawFrames().map(\.receivedAt) == [t0])
        time.advance(byMillis: 10_000)
        try store.recordRawFrame(frame(t0 + 65_000))
        #expect(try store.rawFrames().map(\.receivedAt) == [t0 + 65_000])
    }

    @Test func retentionIsAppliedWhenOpening() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path("frames.sqlite")
        do {
            let store = try FormaStore(path: path, timeSource: ManualTimeSource(t0))
            try store.setRawCaptureEnabled(true)
            for index in 0..<50 { try store.recordRawFrame(frame(t0 + Int64(index))) }
            #expect(try frameStats(store).count == 50)
        }
        let reopened = try FormaStore(path: path, timeSource: ManualTimeSource(t0),
                                      rawFrameRetention: RawFrameRetention(maxAgeMillis: 1_000_000, maxFrames: 20,
                                                                           maxTotalBytes: 1 << 20))
        #expect(try frameStats(reopened).count <= 20)
        #expect(try reopened.rawFrames(limit: 1).first?.receivedAt == t0 + 49)
    }

    @Test func retentionPolicyClampsNonsenseBounds() {
        let policy = RawFrameRetention(maxAgeMillis: -5, maxFrames: 0, maxTotalBytes: -1)
        #expect(policy == RawFrameRetention(maxAgeMillis: 0, maxFrames: 1, maxTotalBytes: 1))
    }

    // MARK: Devices

    @Test func upsertDeviceKeepsKnownValues() throws {
        let store = try makeStore()
        try store.upsertDevice(DeviceRecord(id: deviceA, family: .whoop5, name: "WHOOP 4C1", firmwareVersion: "50.1",
                                            hardwareRevision: "MG", firstSeen: t0, lastConnected: t0 + 10))
        try store.upsertDevice(DeviceRecord(id: deviceA, family: .unknown, name: "WHOOP renamed", firmwareVersion: nil,
                                            hardwareRevision: nil, firstSeen: t0 + 500, lastConnected: nil))
        #expect(try store.device(id: deviceA) == DeviceRecord(id: deviceA, family: .whoop5, name: "WHOOP renamed",
                                                              firmwareVersion: "50.1", hardwareRevision: "MG",
                                                              firstSeen: t0, lastConnected: t0 + 10))
        try store.upsertDevice(DeviceRecord(id: deviceA, family: .whoop5, name: "WHOOP renamed", firmwareVersion: "51.0",
                                            firstSeen: t0 - 100, lastConnected: t0 + 20))
        let updated = try #require(try store.device(id: deviceA))
        #expect(updated.firmwareVersion == "51.0")
        #expect(updated.firstSeen == t0 - 100)
        #expect(updated.lastConnected == t0 + 20)
        try store.upsertDevice(DeviceRecord(id: deviceB, family: .standardHeartRate, name: "Strap", firstSeen: t0 + 1))
        #expect(try store.devices().map(\.id) == [deviceA, deviceB])
        #expect(try store.device(id: "missing") == nil)
        #expect(throws: StoreError.self) {
            try store.upsertDevice(DeviceRecord(id: "", family: .whoop5, name: "x", firstSeen: t0))
        }
    }

    @Test func unknownStoredFamilyReadsAsUnknown() throws {
        let store = try makeStore()
        try store.withConnectionForTesting { db in
            try db.run("INSERT INTO device (id, family, name, first_seen) VALUES ('d', 'whoop9', 'Future', 1)")
        }
        #expect(try store.device(id: "d")?.family == .unknown)
    }

    // MARK: Connection history

    @Test func connectionEventsAreReturnedNewestFirst() throws {
        let store = try makeStore()
        let events = [
            ConnectionEvent(deviceID: nil, timestamp: t0, kind: .scanStarted),
            ConnectionEvent(deviceID: deviceA, timestamp: t0 + 1_000, kind: .connected, detail: "rssi -61"),
            ConnectionEvent(deviceID: deviceA, timestamp: t0 + 9_000, kind: .disconnected, detail: "timeout"),
        ]
        for event in events { try store.recordConnectionEvent(event) }
        #expect(try store.connectionEvents() == events.reversed())
        #expect(try store.connectionEvents(limit: 1) == [events[2]])
        #expect(try store.connectionEvents(deviceID: deviceA).count == 2)
        #expect(try store.connectionEvents(limit: -3).isEmpty)
    }

    @Test func connectionHistoryIsBounded() throws {
        let store = try makeStore()
        store.connectionEventLimit = 50
        for index in 0..<200 {
            try store.recordConnectionEvent(ConnectionEvent(deviceID: deviceA, timestamp: t0 + Int64(index), kind: .connecting))
            #expect(try store.tableCounts()["connection_event"] ?? 0 <= 50)
        }
        #expect(try store.connectionEvents(limit: 1).first?.timestamp == t0 + 199)
    }

    // MARK: Sync runs

    @Test func syncRunLifecycle() throws {
        let store = try makeStore()
        let id = try store.beginSyncRun(SyncRunRecord(deviceID: deviceA, startedAt: t0, status: .running))
        #expect(try store.syncRun(id: id) == SyncRunRecord(id: id, deviceID: deviceA, startedAt: t0, status: .running))
        let finished = SyncRunRecord(id: id, deviceID: deviceA, startedAt: t0, endedAt: t0 + 30_000, status: .completed,
                                     batches: 4, recordsInserted: 1_200, duplicates: 30, malformedFrames: 2,
                                     note: "band reported no more data")
        try store.finishSyncRun(finished)
        #expect(try store.syncRun(id: id) == finished)
        let second = try store.beginSyncRun(SyncRunRecord(deviceID: deviceB, startedAt: t0 + 60_000, status: .running))
        #expect(try store.syncRuns().map(\.id) == [second, id])
        #expect(try store.syncRuns(limit: 1).map(\.id) == [second])
        #expect(try store.syncRuns(deviceID: deviceA).map(\.id) == [id])
        #expect(throws: StoreError.invalidArgument("finishSyncRun requires the id returned by beginSyncRun")) {
            try store.finishSyncRun(SyncRunRecord(deviceID: deviceA, startedAt: t0, status: .failed))
        }
        #expect(throws: StoreError.notFound("sync run 999")) {
            try store.finishSyncRun(SyncRunRecord(id: 999, deviceID: deviceA, startedAt: t0, status: .failed))
        }
    }
}
