import Foundation
import FormaCore

/// Sessions (workouts, sleep) with an audit trail of user corrections, and the derived-metric cache.
///
/// Range filters use overlap semantics on the half-open `[start, end)` windows; a zero-length
/// session or window counts as an instant and matches when the query range contains it.
extension FormaStore {
    // MARK: Sessions

    /// Inserts a session and returns its new id (`session.id` is ignored).
    /// - Throws: `StoreError.invalidRecord` for a confidence outside 0...1 or non-finite.
    @discardableResult
    public func insertSession(_ session: Session) throws -> Int64 {
        try RecordValidator.validate(session)
        return try locked { db in
            try Self.insertSessionRow(session, db: db)
        }
    }

    /// Applies an edit to an existing, non-deleted session. For each changed user-facing field
    /// (`kind`, `start`, `end`, `label`, `origin`) one `UserCorrection` row is written in the same
    /// transaction; `updatedAt` becomes "now". Device, detector and confidence are updated without a
    /// correction row (they are not user-editable facts). `createdAt` is never changed and `deleted` is
    /// ignored (use `softDeleteSession`).
    /// - Returns: The union of the old and new ranges: everything derived inside it must be recomputed.
    ///   (Equal to the old range when nothing changed; then nothing is written.)
    /// - Throws: `StoreError.invalidArgument` without an id, `.notFound` for a missing or deleted session.
    @discardableResult
    public func updateSession(_ session: Session) throws -> TimeRange {
        guard let id = session.id else { throw StoreError.invalidArgument("updateSession requires a session id") }
        try RecordValidator.validate(session)
        return try locked { db in
            try db.transaction {
                guard let old = try Self.fetchSession(id: id, db: db) else { throw StoreError.notFound("session \(id)") }
                guard !old.deleted else { throw StoreError.notFound("session \(id) is deleted") }
                var corrections: [(field: String, old: String?, new: String?)] = []
                if old.kind != session.kind {
                    corrections.append((SessionCorrectionField.kind, old.kind.rawValue, session.kind.rawValue))
                }
                if old.range.start != session.range.start {
                    corrections.append((SessionCorrectionField.start, String(old.range.start), String(session.range.start)))
                }
                if old.range.end != session.range.end {
                    corrections.append((SessionCorrectionField.end, String(old.range.end), String(session.range.end)))
                }
                if old.label != session.label {
                    corrections.append((SessionCorrectionField.label, old.label, session.label))
                }
                if old.origin != session.origin {
                    corrections.append((SessionCorrectionField.origin, old.origin.rawValue, session.origin.rawValue))
                }
                let metadataChanged = old.deviceID != session.deviceID || old.detector != session.detector
                    || old.confidence != session.confidence
                guard !corrections.isEmpty || metadataChanged else { return old.range }

                let now = timeSource.now()
                try db.run("""
                    UPDATE session SET kind = ?, start_ms = ?, end_ms = ?, origin = ?, label = ?, device_id = ?,
                                       detector = ?, confidence = ?, updated_at = ?
                    WHERE id = ?
                    """, [session.kind.rawValue, session.range.start, session.range.end, session.origin.rawValue,
                          session.label, session.deviceID, session.detector, session.confidence, now, id])
                for correction in corrections {
                    try db.run(StoreSQL.insertCorrection, [id, correction.field, correction.old, correction.new, now])
                }
                return TimeRange(start: min(old.range.start, session.range.start),
                                 end: max(old.range.end, session.range.end))
            }
        }
    }

    /// Marks a session deleted (the row and its corrections are kept as an audit trail) and writes a
    /// `deleted` correction. Deleting an already deleted session changes nothing.
    /// - Returns: The session's range, for recomputation.
    @discardableResult
    public func softDeleteSession(id: Int64) throws -> TimeRange {
        try locked { db in
            try db.transaction {
                guard let old = try Self.fetchSession(id: id, db: db) else { throw StoreError.notFound("session \(id)") }
                guard !old.deleted else { return old.range }
                let now = timeSource.now()
                try db.run("UPDATE session SET deleted = 1, updated_at = ? WHERE id = ?", [now, id])
                try db.run(StoreSQL.insertCorrection, [id, SessionCorrectionField.deleted, "false", "true", now])
                return old.range
            }
        }
    }

    /// One session by id (including deleted ones).
    public func session(id: Int64) throws -> Session? {
        try locked { db in try Self.fetchSession(id: id, db: db) }
    }

    /// Sessions sorted by start time.
    /// - Parameters:
    ///   - kind: Only this kind (nil = all).
    ///   - range: Only sessions overlapping this range (nil = all).
    ///   - includeCandidates: Include detector proposals the user has not confirmed. Pass false for
    ///     confirmed totals.
    ///   - includeDeleted: Include soft-deleted sessions.
    public func sessions(kind: SessionKind? = nil, in range: TimeRange? = nil, includeCandidates: Bool = true,
                         includeDeleted: Bool = false) throws -> [Session] {
        var conditions: [String] = []
        var values: [any SQLiteValueConvertible] = []
        if let kind {
            conditions.append("kind = ?")
            values.append(kind.rawValue)
        }
        if let range {
            conditions.append(StoreSQL.overlap)
            values += StoreSQL.overlapArguments(range)
        }
        if !includeCandidates {
            conditions.append("origin <> ?")
            values.append(SessionOrigin.detectedCandidate.rawValue)
        }
        if !includeDeleted {
            conditions.append("deleted = 0")
        }
        var sql = "SELECT \(RowDecoder.sessionColumns) FROM session"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY start_ms, id"
        return try locked { db in try db.query(sql, values) { RowDecoder.session($0) } }
    }

    /// Correction history, oldest first; for one session or (nil) for all.
    public func corrections(sessionID: Int64? = nil) throws -> [UserCorrection] {
        var sql = "SELECT \(RowDecoder.correctionColumns) FROM user_correction"
        var values: [any SQLiteValueConvertible] = []
        if let sessionID {
            sql += " WHERE session_id = ?"
            values.append(sessionID)
        }
        sql += " ORDER BY created_at, id"
        return try locked { db in try db.query(sql, values) { RowDecoder.correction($0) } }
    }

    static func fetchSession(id: Int64, db: SQLiteConnection) throws -> Session? {
        try db.query("SELECT \(RowDecoder.sessionColumns) FROM session WHERE id = ?", [id]) { RowDecoder.session($0) }.first
    }

    static func insertSessionRow(_ session: Session, db: SQLiteConnection) throws -> Int64 {
        try db.run(StoreSQL.insertSession,
                   [session.kind.rawValue, session.range.start, session.range.end, session.origin.rawValue,
                    session.label, session.deviceID, session.detector, session.confidence, session.createdAt,
                    session.updatedAt, session.deleted])
        return db.lastInsertRowID
    }

    // MARK: Derived metrics

    /// Inserts or replaces cached derived values, keyed by (metric, spec version, window), in one
    /// transaction. A nil `value` is stored as NULL and read back as nil, never as 0.
    /// - Throws: `StoreError.invalidRecord` (nothing written) for an empty metric ID, a non-finite
    ///   value, or a coverage outside 0...1.
    public func putDerived(_ records: [DerivedMetricRecord]) throws {
        for (index, record) in records.enumerated() {
            try RecordValidator.validate(record, at: "derived[\(index)]")
        }
        guard !records.isEmpty else { return }
        try locked { db in
            try db.transaction {
                let statement = try db.prepare("""
                    INSERT INTO derived_metric (\(RowDecoder.derivedColumns))
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (metric_id, spec_version, start_ms, end_ms) DO UPDATE SET
                        value = excluded.value, unit = excluded.unit, availability = excluded.availability,
                        coverage = excluded.coverage, confidence = excluded.confidence,
                        inputs_json = excluded.inputs_json, computed_at = excluded.computed_at
                    """)
                for record in records {
                    statement.reset()
                    try statement.bind(values: [record.metricID, record.specVersion, record.window.start,
                                                record.window.end, record.value, record.unit, record.availability,
                                                record.coverage, record.confidence.rawValue, record.inputsJSON,
                                                record.computedAt])
                    try statement.step()
                }
            }
        }
    }

    /// Cached values of one metric whose windows overlap `range`, sorted by window then spec version.
    /// Pass `specVersion` to ignore values computed by other versions of the metric's spec.
    public func derived(metricID: String, in range: TimeRange, specVersion: Int? = nil) throws -> [DerivedMetricRecord] {
        var sql = "SELECT \(RowDecoder.derivedColumns) FROM derived_metric WHERE metric_id = ? AND \(StoreSQL.overlap)"
        var values: [any SQLiteValueConvertible] = [metricID]
        values += StoreSQL.overlapArguments(range)
        if let specVersion {
            sql += " AND spec_version = ?"
            values.append(specVersion)
        }
        sql += " ORDER BY start_ms, end_ms, spec_version"
        return try locked { db in try db.query(sql, values) { RowDecoder.derived($0) } }
    }

    /// Deletes cached values whose windows overlap `range` (optionally of one metric only), so they
    /// are recomputed. Returns the number of deleted rows.
    @discardableResult
    public func invalidateDerived(overlapping range: TimeRange, metricID: String? = nil) throws -> Int {
        var sql = "DELETE FROM derived_metric WHERE \(StoreSQL.overlap)"
        var values = StoreSQL.overlapArguments(range)
        if let metricID {
            sql += " AND metric_id = ?"
            values.append(metricID)
        }
        return try locked { db in try db.run(sql, values) }
    }
}
