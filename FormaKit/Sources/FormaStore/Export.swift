import Foundation
import FormaCore

/// CSV export of the user's data for use in other tools.
///
/// Format: RFC 4180 (comma separated, CRLF line endings, fields containing a comma, double quote,
/// CR or LF are quoted with inner quotes doubled), UTF-8, one header row whose column names carry
/// their units (`ts_epoch_ms`, `interval_ms`, ...; motion `activity` is in source-specific units, see
/// `MotionEpoch.activity`). A missing value is an empty cell, never 0: that includes `activity` of a motion epoch with `sample_count` 0, which by definition
/// has no motion data (the backup keeps the stored value). Timestamps appear twice: epoch
/// milliseconds and ISO 8601 UTC. Codes (`source`, `quality_flags`, `timing_basis`) are accompanied
/// by readable names.
///
/// Text cells (labels, device names, detector and metric text) are written exactly as stored. A
/// spreadsheet may evaluate a cell that begins with `=`, `+`, `-` or `@` as a formula when the file
/// is opened; Forma does not rewrite such text (that would change the data), so open exports from
/// devices or labels you do not trust with formula evaluation disabled.
extension FormaStore {
    /// Files written by `exportCSV`, in the order they are returned.
    public enum CSVFile: String, CaseIterable, Sendable {
        case heartRates = "hr_samples.csv"
        case beatIntervals = "beat_intervals.csv"
        case motion = "motion_epochs.csv"
        case aux = "aux_measurements.csv"
        case sessions = "sessions.csv"
        case derivedMetrics = "derived_metrics.csv"
        case devices = "devices.csv"

        /// Header row of the file.
        public var columns: [String] {
            switch self {
            case .heartRates:
                return ["ts_epoch_ms", "ts_utc_iso8601", "device_id", "bpm", "source", "source_name", "device_time_raw",
                        "received_at_epoch_ms", "clock_offset_ms", "quality_flags", "quality_flag_names", "batch_id"]
            case .beatIntervals:
                return ["ts_epoch_ms", "ts_utc_iso8601", "device_id", "interval_ms", "source", "source_name",
                        "record_key", "index_in_record", "received_at_epoch_ms", "timing_basis", "timing_basis_name",
                        "quality_flags", "quality_flag_names", "batch_id"]
            case .motion:
                return ["ts_epoch_ms", "ts_utc_iso8601", "device_id", "epoch_length_ms", "activity", "sample_count",
                        "source", "source_name", "device_time_raw", "quality_flags", "quality_flag_names", "batch_id"]
            case .aux:
                return ["ts_epoch_ms", "ts_utc_iso8601", "device_id", "kind", "value", "unit", "validated", "source",
                        "source_name", "quality_flags", "quality_flag_names", "batch_id"]
            case .sessions:
                return ["id", "kind", "start_ts_epoch_ms", "start_ts_utc_iso8601", "end_ts_epoch_ms", "end_ts_utc_iso8601",
                        "duration_s", "origin", "label", "device_id", "detector", "detector_confidence_0_1",
                        "created_at_epoch_ms", "updated_at_epoch_ms", "deleted"]
            case .derivedMetrics:
                return ["metric_id", "spec_version", "window_start_epoch_ms", "window_start_utc_iso8601",
                        "window_end_epoch_ms", "window_end_utc_iso8601", "value", "unit", "availability",
                        "coverage_0_1", "confidence", "inputs_json", "computed_at_epoch_ms"]
            case .devices:
                return ["id", "family", "name", "firmware", "hardware", "first_seen_epoch_ms", "first_seen_utc_iso8601",
                        "last_connected_epoch_ms", "last_connected_utc_iso8601"]
            }
        }
    }

    /// Writes one CSV file per table into `directory` (created if needed; existing files with the
    /// same names are atomically replaced once their new content is complete). Files are streamed
    /// page by page, so memory use stays bounded.
    /// - Parameter range: Limit measurements to timestamps in the range and sessions/derived values to
    ///   windows overlapping it; nil exports everything. Devices are always exported in full.
    /// - Returns: The written files, in `CSVFile.allCases` order.
    /// - Throws: `StoreError.fileError` (also when a file would replace this store's own database),
    ///   `SQLiteError`, or `CancellationError` when the calling task is cancelled.
    @discardableResult
    public func exportCSV(to directory: URL, range: TimeRange? = nil) throws -> [URL] {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.fileError("cannot create \(directory.path(percentEncoded: false)): \(error.localizedDescription)")
        }
        let urls = CSVFile.allCases.map { directory.appendingPathComponent($0.rawValue) }
        for url in urls { try refuseDatabaseFileAsDestination(url) }
        var written: [URL] = []
        for (file, url) in zip(CSVFile.allCases, urls) {
            try Task.checkCancellation()
            _ = try AtomicFile.write(to: url) { output in
                let csv = CSVWriter(output: output)
                try csv.writeRow(file.columns)
                try writeCSVRows(file, range: range, to: csv)
            }
            written.append(url)
        }
        return written
    }

    private func writeCSVRows(_ file: CSVFile, range: TimeRange?, to csv: CSVWriter) throws {
        typealias F = CSVField
        switch file {
        case .heartRates:
            try forEachPage(.heartRate, range: range, decode: RowDecoder.heartRate) { page in
                for s in page {
                    try csv.writeRow([F.int(s.timestamp), F.iso(s.timestamp), s.deviceID, F.int(s.bpm),
                                      F.int(s.source.rawValue), s.source.description, F.int(s.deviceTimeRaw),
                                      F.int(s.receivedAt), F.int(s.clockOffsetMillis), F.int(s.quality.rawValue),
                                      F.flagNames(s.quality), F.int(s.batchID)])
                }
            }
        case .beatIntervals:
            try forEachPage(.beatInterval, range: range, decode: RowDecoder.beatInterval) { page in
                for b in page {
                    try csv.writeRow([F.int(b.timestamp), F.iso(b.timestamp), b.deviceID, F.number(b.intervalMillis),
                                      F.int(b.source.rawValue), b.source.description, F.int(b.recordKey),
                                      F.int(b.indexInRecord), F.int(b.receivedAt), F.int(b.timingBasis.rawValue),
                                      F.timingBasisName(b.timingBasis), F.int(b.quality.rawValue),
                                      F.flagNames(b.quality), F.int(b.batchID)])
                }
            }
        case .motion:
            try forEachPage(.motion, range: range, decode: RowDecoder.motion) { page in
                for m in page {
                    // sampleCount 0 means "no motion data for the epoch": its activity is not a measured 0.
                    try csv.writeRow([F.int(m.timestamp), F.iso(m.timestamp), m.deviceID, F.int(m.epochMillis),
                                      m.sampleCount == 0 ? nil : F.number(m.activity), F.int(m.sampleCount),
                                      F.int(m.source.rawValue), m.source.description, F.int(m.deviceTimeRaw),
                                      F.int(m.quality.rawValue), F.flagNames(m.quality), F.int(m.batchID)])
                }
            }
        case .aux:
            try forEachPage(.aux, range: range, decode: RowDecoder.aux) { page in
                for a in page {
                    try csv.writeRow([F.int(a.timestamp), F.iso(a.timestamp), a.deviceID, a.kind.rawValue,
                                      F.number(a.value), F.unit(of: a.kind), a.validated ? "1" : "0",
                                      F.int(a.source.rawValue), a.source.description, F.int(a.quality.rawValue),
                                      F.flagNames(a.quality), F.int(a.batchID)])
                }
            }
        case .sessions:
            for s in try sessions(in: range, includeCandidates: true, includeDeleted: true) {
                try csv.writeRow([F.int(s.id), s.kind.rawValue, F.int(s.range.start), F.iso(s.range.start),
                                  F.int(s.range.end), F.iso(s.range.end), F.durationSeconds(s.range),
                                  s.origin.rawValue, s.label, s.deviceID, s.detector, F.number(s.confidence),
                                  F.int(s.createdAt), F.int(s.updatedAt), s.deleted ? "1" : "0"])
            }
        case .derivedMetrics:
            for r in try allDerived(overlapping: range) {
                try csv.writeRow([r.metricID, F.int(r.specVersion), F.int(r.window.start), F.iso(r.window.start),
                                  F.int(r.window.end), F.iso(r.window.end), F.number(r.value), r.unit, r.availability,
                                  F.number(r.coverage), r.confidence.rawValue, r.inputsJSON, F.int(r.computedAt)])
            }
        case .devices:
            for d in try devices() {
                try csv.writeRow([d.id, d.family.rawValue, d.name, d.firmwareVersion, d.hardwareRevision,
                                  F.int(d.firstSeen), F.iso(d.firstSeen), F.int(d.lastConnected), F.iso(d.lastConnected)])
            }
        }
    }

    /// Every cached derived value (all metrics), optionally only windows overlapping `range`.
    func allDerived(overlapping range: TimeRange?) throws -> [DerivedMetricRecord] {
        var sql = "SELECT \(RowDecoder.derivedColumns) FROM derived_metric"
        var values: [any SQLiteValueConvertible] = []
        if let range {
            sql += " WHERE \(StoreSQL.overlap)"
            values = StoreSQL.overlapArguments(range)
        }
        sql += " ORDER BY metric_id, start_ms, end_ms, spec_version"
        return try locked { db in try db.query(sql, values) { RowDecoder.derived($0) } }
    }
}

/// RFC 4180 row writer on top of a streaming file writer.
final class CSVWriter {
    private let output: BufferedFileWriter

    init(output: BufferedFileWriter) {
        self.output = output
    }

    /// Writes one record; nil fields become empty cells.
    func writeRow(_ fields: [String?]) throws {
        var line = ""
        for (index, field) in fields.enumerated() {
            if index > 0 { line += "," }
            if let field { line += Self.escape(field) }
        }
        line += "\r\n"
        try output.write(line)
    }

    /// Quotes a field when it contains a comma, double quote, CR or LF, doubling inner quotes.
    /// (Checked on UTF-8 bytes: a CRLF pair is a single `Character` in Swift.)
    static func escape(_ field: String) -> String {
        let needsQuotes = field.utf8.contains { $0 == 0x2C || $0 == 0x22 || $0 == 0x0A || $0 == 0x0D }
        guard needsQuotes else { return field }
        var quoted = "\""
        for scalar in field.unicodeScalars {
            if scalar == "\"" { quoted += "\"\"" } else { quoted.unicodeScalars.append(scalar) }
        }
        quoted += "\""
        return quoted
    }
}

/// Field formatting for CSV cells. Every function maps a missing value to nil (an empty cell).
enum CSVField {
    static func int<T: BinaryInteger>(_ value: T?) -> String? { value.map { String($0) } }
    static func number(_ value: Double?) -> String? { value.flatMap(TextFormat.number) }
    static func iso(_ millis: EpochMillis?) -> String? { millis.map(TextFormat.iso8601UTC) }

    /// Range length in seconds; nil (empty cell) if `end - start` does not fit in Int64, which only a
    /// corrupt or hostile record can produce (`TimeRange.durationSeconds` would trap on it).
    static func durationSeconds(_ range: TimeRange) -> String? {
        let (millis, overflow) = range.end.subtractingReportingOverflow(range.start)
        return overflow ? nil : number(Double(millis) / 1_000)
    }

    /// Names of the set quality flags joined with "|" (unknown bits as `bit<n>`); empty when none.
    static func flagNames(_ flags: QualityFlags) -> String {
        let known: [(QualityFlags, String)] = [
            (.phoneReceiveTime, "phoneReceiveTime"), (.clockOffsetApplied, "clockOffsetApplied"),
            (.nearClockDiscontinuity, "nearClockDiscontinuity"), (.outOfRange, "outOfRange"),
            (.noSensorContact, "noSensorContact"), (.deviceMarkedInvalid, "deviceMarkedInvalid"),
            (.unvalidatedField, "unvalidatedField"), (.clockUnmapped, "clockUnmapped"),
        ]
        var names = known.filter { flags.contains($0.0) }.map(\.1)
        let knownBits = known.reduce(Int64(0)) { $0 | $1.0.rawValue }
        let unknownBits = UInt64(bitPattern: flags.rawValue & ~knownBits)
        for bit in 0..<64 where unknownBits & (1 << UInt64(bit)) != 0 {
            names.append("bit\(bit)")
        }
        return names.joined(separator: "|")
    }

    static func timingBasisName(_ basis: BeatTimingBasis) -> String {
        switch basis {
        case .reconstructedFromReceiveTime: return "reconstructedFromReceiveTime"
        case .reconstructedFromRecordTime: return "reconstructedFromRecordTime"
        }
    }

    /// Unit of an auxiliary measurement's `value` column.
    static func unit(of kind: AuxKind) -> String {
        switch kind {
        case .batteryPercent: return "percent"
        case .skinTemperatureCelsius: return "degC"
        case .spo2Percent: return "percent"
        case .respiratoryRateBrpm: return "breaths_per_min"
        case .skinContact: return "boolean_1_0"
        }
    }
}
