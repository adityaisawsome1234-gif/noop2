import Foundation

/// Progress marker for a device's stored history. The `opaque` payload is defined by the device
/// adapter (for example the band's own history position that was acknowledged last); Forma never
/// interprets it outside the adapter.
public struct SyncCursor: Hashable, Sendable, Codable {
    public var deviceID: String
    public var adapterID: String
    public var opaque: Data?
    /// Newest device-history record time that has been durably persisted.
    public var newestPersistedRecordTime: EpochMillis?
    /// When a history transfer last ran to completion (band reported "no more data").
    public var lastCompleteSyncAt: EpochMillis?
    public var updatedAt: EpochMillis

    public init(deviceID: String, adapterID: String, opaque: Data?, newestPersistedRecordTime: EpochMillis?,
                lastCompleteSyncAt: EpochMillis?, updatedAt: EpochMillis) {
        self.deviceID = deviceID
        self.adapterID = adapterID
        self.opaque = opaque
        self.newestPersistedRecordTime = newestPersistedRecordTime
        self.lastCompleteSyncAt = lastCompleteSyncAt
        self.updatedAt = updatedAt
    }
}

/// Everything decoded from one unit of transfer (a live chunk or one history batch).
/// A sink must persist all of it in ONE transaction; history acknowledgements are only sent
/// after `IngestSink.ingest` returns successfully.
public struct IngestBatch: Sendable {
    public var provenance: Provenance
    public var heartRates: [HeartRateSample]
    public var beatIntervals: [BeatInterval]
    public var motion: [MotionEpoch]
    public var aux: [AuxMeasurement]
    /// Cursor to store atomically with the records (nil = leave unchanged).
    public var cursor: SyncCursor?

    public init(provenance: Provenance, heartRates: [HeartRateSample] = [], beatIntervals: [BeatInterval] = [],
                motion: [MotionEpoch] = [], aux: [AuxMeasurement] = [], cursor: SyncCursor? = nil) {
        self.provenance = provenance
        self.heartRates = heartRates
        self.beatIntervals = beatIntervals
        self.motion = motion
        self.aux = aux
        self.cursor = cursor
    }

    public var isEmpty: Bool {
        heartRates.isEmpty && beatIntervals.isEmpty && motion.isEmpty && aux.isEmpty && cursor == nil
    }
}

public struct IngestResult: Hashable, Sendable {
    public var batchID: Int64
    public var inserted: Int
    /// Records skipped because an identical record (same dedup key) already existed.
    public var duplicates: Int

    public init(batchID: Int64, inserted: Int, duplicates: Int) {
        self.batchID = batchID
        self.inserted = inserted
        self.duplicates = duplicates
    }
}

/// Raw bytes as received, kept only when diagnostics capture is enabled (bounded retention).
public struct RawFrameRecord: Hashable, Sendable, Codable {
    public var deviceID: String?
    public var receivedAt: EpochMillis
    public var characteristic: String
    public var bytes: Data
    public var parseStatus: String

    public init(deviceID: String?, receivedAt: EpochMillis, characteristic: String, bytes: Data, parseStatus: String) {
        self.deviceID = deviceID
        self.receivedAt = receivedAt
        self.characteristic = characteristic
        self.bytes = bytes
        self.parseStatus = parseStatus
    }
}

/// Lifecycle record for one sync attempt (shown in Sync diagnostics).
public struct SyncRunRecord: Hashable, Sendable, Codable {
    public enum Status: String, Sendable, Codable {
        case running, completed, interrupted, failed
    }

    public var id: Int64?
    public var deviceID: String
    public var startedAt: EpochMillis
    public var endedAt: EpochMillis?
    public var status: Status
    public var batches: Int
    public var recordsInserted: Int
    public var duplicates: Int
    public var malformedFrames: Int
    public var note: String?

    public init(id: Int64? = nil, deviceID: String, startedAt: EpochMillis, endedAt: EpochMillis? = nil,
                status: Status, batches: Int = 0, recordsInserted: Int = 0, duplicates: Int = 0,
                malformedFrames: Int = 0, note: String? = nil) {
        self.id = id
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.batches = batches
        self.recordsInserted = recordsInserted
        self.duplicates = duplicates
        self.malformedFrames = malformedFrames
        self.note = note
    }
}

/// Persistence boundary used by the sync engine. Implemented by `FormaStore`; tests may use the
/// same store in memory. All methods are synchronous and must be safe to call from any thread.
public protocol IngestSink: Sendable {
    /// Persist the batch atomically (records + cursor). Duplicate records are ignored, not errors.
    func ingest(_ batch: IngestBatch) throws -> IngestResult
    func syncCursor(deviceID: String) throws -> SyncCursor?
    func upsertDevice(_ device: DeviceRecord) throws
    func recordConnectionEvent(_ event: ConnectionEvent) throws
    /// Store raw evidence if capture is enabled; the sink enforces retention bounds.
    func recordRawFrame(_ frame: RawFrameRecord) throws
    func beginSyncRun(_ run: SyncRunRecord) throws -> Int64
    func finishSyncRun(_ run: SyncRunRecord) throws
}
