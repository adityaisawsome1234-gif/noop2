import Foundation
import Testing
import FormaCore
@testable import FormaStore

/// Fixed reference time for every test: 2026-03-01T00:00:00Z.
let t0: EpochMillis = 1_772_323_200_000
let deviceA = "band-A"
let deviceB = "band-B"

func makeStore(time: ManualTimeSource = ManualTimeSource(t0),
               retention: RawFrameRetention = .default) throws -> FormaStore {
    try FormaStore(path: nil, timeSource: time, rawFrameRetention: retention)
}

func provenance(_ deviceID: String = deviceA, source: MeasurementSource = .deviceHistory,
                createdAt: EpochMillis = t0, note: String? = nil) -> Provenance {
    Provenance(deviceID: deviceID, adapterID: "whoop5", parserVersion: "1.0.0", firmwareVersion: "50.1.2",
               source: source, syncRunID: nil, createdAt: createdAt, note: note)
}

func hr(_ timestamp: EpochMillis, _ bpm: Int, device: String = deviceA, source: MeasurementSource = .deviceHistory,
        quality: QualityFlags = [], deviceTimeRaw: Int64? = nil, clockOffset: Int64? = nil) -> HeartRateSample {
    HeartRateSample(deviceID: device, timestamp: timestamp, bpm: bpm, source: source, deviceTimeRaw: deviceTimeRaw,
                    receivedAt: timestamp + 5_000, clockOffsetMillis: clockOffset, quality: quality)
}

func rr(_ timestamp: EpochMillis, _ interval: Double, recordKey: Int64, index: Int, device: String = deviceA,
        source: MeasurementSource = .deviceHistory, quality: QualityFlags = []) -> BeatInterval {
    BeatInterval(deviceID: device, timestamp: timestamp, intervalMillis: interval, source: source, recordKey: recordKey,
                 indexInRecord: index, receivedAt: timestamp + 5_000, timingBasis: .reconstructedFromRecordTime,
                 quality: quality)
}

func motionEpoch(_ timestamp: EpochMillis, activity: Double, samples: Int = 50, device: String = deviceA,
                 source: MeasurementSource = .deviceHistory) -> MotionEpoch {
    MotionEpoch(deviceID: device, timestamp: timestamp, epochMillis: 1_000, activity: activity, sampleCount: samples,
                source: source)
}

func auxMeasurement(_ timestamp: EpochMillis, _ kind: AuxKind, _ value: Double, device: String = deviceA,
                    validated: Bool = false) -> AuxMeasurement {
    AuxMeasurement(deviceID: device, timestamp: timestamp, kind: kind, value: value, source: .deviceHistory,
                   validated: validated, quality: validated ? [] : [.unvalidatedField])
}

func cursor(_ deviceID: String = deviceA, newest: EpochMillis?, opaque: [UInt8] = [1, 2, 3],
            updatedAt: EpochMillis = t0) -> SyncCursor {
    SyncCursor(deviceID: deviceID, adapterID: "whoop5", opaque: Data(opaque), newestPersistedRecordTime: newest,
               lastCompleteSyncAt: nil, updatedAt: updatedAt)
}

/// Records with batch IDs cleared, for comparing stored data with what was ingested.
func withoutBatch(_ samples: [HeartRateSample]) -> [HeartRateSample] {
    samples.map { var copy = $0; copy.batchID = nil; return copy }
}

func withoutBatch(_ intervals: [BeatInterval]) -> [BeatInterval] {
    intervals.map { var copy = $0; copy.batchID = nil; return copy }
}

func withoutBatch(_ epochs: [MotionEpoch]) -> [MotionEpoch] {
    epochs.map { var copy = $0; copy.batchID = nil; return copy }
}

func withoutBatch(_ measurements: [AuxMeasurement]) -> [AuxMeasurement] {
    measurements.map { var copy = $0; copy.batchID = nil; return copy }
}

/// Everything time-based in the store.
let everything = TimeRange(start: Int64.min, end: Int64.max)

/// Deterministic PRNG (SplitMix64) so shuffles are reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A fresh directory under the system temporary directory, removed on deinit.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("forma-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> String {
        url.appendingPathComponent(name).path(percentEncoded: false)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Thread-safe error collection for multi-threaded tests.
final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [any Error] = []

    func record(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        collected.append(error)
    }

    var errors: [any Error] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

/// Strict RFC 4180 parser for checking exported files: CRLF record separators, quoted fields with
/// doubled quotes; returns nil for anything malformed.
func parseCSV(_ text: String) -> [[String]]? {
    var records: [[String]] = []
    var record: [String] = []
    var field = ""
    var scalars = Array(text.unicodeScalars)[...]
    var inQuotes = false
    var fieldWasQuoted = false
    while let scalar = scalars.popFirst() {
        if inQuotes {
            if scalar == "\"" {
                if scalars.first == "\"" {
                    scalars.removeFirst()
                    field.unicodeScalars.append("\"")
                } else {
                    inQuotes = false
                }
            } else {
                field.unicodeScalars.append(scalar)
            }
            continue
        }
        switch scalar {
        case "\"":
            guard field.isEmpty, !fieldWasQuoted else { return nil }
            inQuotes = true
            fieldWasQuoted = true
        case ",":
            record.append(field)
            field = ""
            fieldWasQuoted = false
        case "\r":
            guard scalars.popFirst() == "\n" else { return nil }
            record.append(field)
            records.append(record)
            record = []
            field = ""
            fieldWasQuoted = false
        case "\n":
            return nil
        default:
            guard !fieldWasQuoted else { return nil }
            field.unicodeScalars.append(scalar)
        }
    }
    guard !inQuotes, field.isEmpty, record.isEmpty else { return nil }
    return records
}

func readCSV(_ url: URL) throws -> [[String]] {
    let text = try String(contentsOf: url, encoding: .utf8)
    return try #require(parseCSV(text), "not RFC 4180: \(url.lastPathComponent)")
}

/// Column lookup for parsed CSV rows.
struct CSVTable {
    let header: [String]
    let rows: [[String]]

    init(_ records: [[String]]) throws {
        header = try #require(records.first)
        rows = Array(records.dropFirst())
    }

    func value(_ row: Int, _ column: String) throws -> String {
        let index = try #require(header.firstIndex(of: column), "no column \(column)")
        return rows[row][index]
    }
}
