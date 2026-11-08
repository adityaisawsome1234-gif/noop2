import Foundation

/// One forward-only schema step. It runs in its own transaction together with the
/// `PRAGMA user_version` bump, so a failing step leaves the database at the previous version.
struct Migration: Sendable {
    /// Schema version after this step (`PRAGMA user_version`). Versions are 1, 2, 3, … with no gaps.
    let version: Int
    let name: String
    let sql: String
}

/// Ordered schema migrations keyed by `PRAGMA user_version`.
///
/// Rules: never edit a shipped migration, only append; a database whose version is newer than
/// the newest known migration is refused (`StoreError.schemaTooNew`) and never downgraded.
enum Migrations {
    /// Marks Forma databases in the SQLite header (`PRAGMA application_id`): ASCII "FORM".
    static let applicationID: Int32 = 0x464F_524D

    static let all: [Migration] = [
        Migration(version: 1, name: "initial schema", sql: schemaV1),
        Migration(version: 2, name: "band records keyed by their own clock", sql: schemaV2),
    ]

    /// v2: a band record keeps ONE identity — (device, source, raw device time) — whatever clock offset was
    /// applied to its timestamp on each download, so a record the band re-sends (history is not acknowledged
    /// by default) can never be stored twice. Rows already duplicated under that identity keep the first copy.
    static let schemaV2 = """
        DELETE FROM hr_sample
        WHERE device_time_raw IS NOT NULL
          AND rowid NOT IN (SELECT MIN(rowid) FROM hr_sample WHERE device_time_raw IS NOT NULL
                            GROUP BY device_id, source, device_time_raw);
        CREATE UNIQUE INDEX uq_hr_sample_device_time_raw ON hr_sample(device_id, source, device_time_raw)
            WHERE device_time_raw IS NOT NULL;

        ALTER TABLE motion_epoch ADD COLUMN device_time_raw INTEGER;
        CREATE UNIQUE INDEX uq_motion_epoch_device_time_raw ON motion_epoch(device_id, source, device_time_raw)
            WHERE device_time_raw IS NOT NULL;
        """

    /// Newest schema version this build knows.
    static var latestVersion: Int { all.map(\.version).max() ?? 0 }

    /// Read-only header check: refuses another application's file and a schema newer than
    /// `supported`. Reads `application_id` and `user_version` only, so a refused file is left
    /// byte-for-byte unchanged (run it before anything that rewrites the header, such as enabling WAL).
    /// - Returns: The file's current schema version.
    @discardableResult
    static func checkCompatibility(_ db: SQLiteConnection, supported: Int = latestVersion) throws -> Int {
        let owner = try db.applicationID()
        guard owner == 0 || owner == applicationID else {
            throw StoreError.notAFormaDatabase(applicationID: owner)
        }
        let found = try db.userVersion()
        guard found <= supported else {
            throw StoreError.schemaTooNew(found: found, supported: supported)
        }
        return found
    }

    /// Brings `db` up to the newest version in `migrations`, one transaction per step.
    /// - Throws: `StoreError.notAFormaDatabase` for another application's file,
    ///   `StoreError.schemaTooNew` for a database written by a newer build, or the SQLite error of
    ///   a failing step (which is rolled back).
    static func migrate(_ db: SQLiteConnection, migrations: [Migration] = all) throws {
        let ordered = migrations.sorted { $0.version < $1.version }
        let supported = ordered.last?.version ?? 0
        let found = try checkCompatibility(db, supported: supported)
        for migration in ordered where migration.version > found {
            try db.transaction {
                // Re-read under the write lock: another connection may have migrated meanwhile.
                let current = try db.userVersion()
                guard current <= supported else {
                    throw StoreError.schemaTooNew(found: current, supported: supported)
                }
                guard current < migration.version else { return }
                try db.execute(migration.sql)
                try db.setUserVersion(migration.version)
            }
        }
    }

    /// Schema v1. All timestamps are INTEGER epoch milliseconds (UTC). Measurement rows are
    /// deduplicated by their natural keys (which include `source`, so live and band-history copies
    /// of the same moment are both kept). `batch_id` links every measurement to the ingest batch
    /// that carries its provenance.
    static let schemaV1 = """
        PRAGMA application_id = \(applicationID);

        CREATE TABLE device (
            id             TEXT PRIMARY KEY NOT NULL,
            family         TEXT NOT NULL,
            name           TEXT NOT NULL,
            firmware       TEXT,
            hardware       TEXT,
            first_seen     INTEGER NOT NULL,
            last_connected INTEGER
        );

        CREATE TABLE ingest_batch (
            id             INTEGER PRIMARY KEY,
            device_id      TEXT NOT NULL,
            adapter_id     TEXT NOT NULL,
            parser_version TEXT NOT NULL,
            firmware       TEXT,
            source         INTEGER NOT NULL,
            sync_run_id    INTEGER,
            created_at     INTEGER NOT NULL,
            note           TEXT
        );

        CREATE TABLE hr_sample (
            device_id       TEXT NOT NULL,
            ts_ms           INTEGER NOT NULL,
            bpm             INTEGER NOT NULL,
            source          INTEGER NOT NULL,
            device_time_raw INTEGER,
            received_at     INTEGER NOT NULL,
            clock_offset_ms INTEGER,
            quality         INTEGER NOT NULL DEFAULT 0,
            batch_id        INTEGER REFERENCES ingest_batch(id),
            UNIQUE (device_id, source, ts_ms)
        );
        CREATE INDEX idx_hr_sample_ts ON hr_sample(ts_ms);
        CREATE INDEX idx_hr_sample_device_ts ON hr_sample(device_id, ts_ms);

        CREATE TABLE beat_interval (
            device_id    TEXT NOT NULL,
            ts_ms        INTEGER NOT NULL,
            interval_ms  REAL NOT NULL,
            source       INTEGER NOT NULL,
            record_key   INTEGER NOT NULL,
            idx          INTEGER NOT NULL,
            received_at  INTEGER NOT NULL,
            timing_basis INTEGER NOT NULL,
            quality      INTEGER NOT NULL DEFAULT 0,
            batch_id     INTEGER REFERENCES ingest_batch(id),
            UNIQUE (device_id, source, record_key, idx)
        );
        CREATE INDEX idx_beat_interval_ts ON beat_interval(ts_ms);
        CREATE INDEX idx_beat_interval_device_ts ON beat_interval(device_id, ts_ms);

        CREATE TABLE motion_epoch (
            device_id    TEXT NOT NULL,
            ts_ms        INTEGER NOT NULL,
            epoch_ms     INTEGER NOT NULL,
            activity     REAL NOT NULL,
            sample_count INTEGER NOT NULL,
            source       INTEGER NOT NULL,
            quality      INTEGER NOT NULL DEFAULT 0,
            batch_id     INTEGER REFERENCES ingest_batch(id),
            UNIQUE (device_id, source, ts_ms, epoch_ms)
        );
        CREATE INDEX idx_motion_epoch_ts ON motion_epoch(ts_ms);
        CREATE INDEX idx_motion_epoch_device_ts ON motion_epoch(device_id, ts_ms);

        CREATE TABLE aux_measurement (
            device_id TEXT NOT NULL,
            ts_ms     INTEGER NOT NULL,
            kind      TEXT NOT NULL,
            value     REAL NOT NULL,
            source    INTEGER NOT NULL,
            validated INTEGER NOT NULL DEFAULT 0,
            quality   INTEGER NOT NULL DEFAULT 0,
            batch_id  INTEGER REFERENCES ingest_batch(id),
            UNIQUE (device_id, source, kind, ts_ms)
        );
        CREATE INDEX idx_aux_measurement_ts ON aux_measurement(ts_ms);
        CREATE INDEX idx_aux_measurement_device_ts ON aux_measurement(device_id, ts_ms);

        CREATE TABLE raw_frame (
            id             INTEGER PRIMARY KEY,
            device_id      TEXT,
            received_at    INTEGER NOT NULL,
            characteristic TEXT NOT NULL,
            bytes          BLOB NOT NULL,
            parse_status   TEXT NOT NULL
        );
        CREATE INDEX idx_raw_frame_received_at ON raw_frame(received_at);

        CREATE TABLE connection_event (
            id        INTEGER PRIMARY KEY,
            device_id TEXT,
            ts_ms     INTEGER NOT NULL,
            kind      TEXT NOT NULL,
            detail    TEXT
        );
        CREATE INDEX idx_connection_event_ts ON connection_event(ts_ms);

        CREATE TABLE sync_cursor (
            device_id        TEXT PRIMARY KEY NOT NULL,
            adapter_id       TEXT NOT NULL,
            opaque           BLOB,
            newest_record_ms INTEGER,
            last_complete_ms INTEGER,
            updated_at       INTEGER NOT NULL
        );

        CREATE TABLE sync_run (
            id               INTEGER PRIMARY KEY,
            device_id        TEXT NOT NULL,
            started_at       INTEGER NOT NULL,
            ended_at         INTEGER,
            status           TEXT NOT NULL,
            batches          INTEGER NOT NULL DEFAULT 0,
            records_inserted INTEGER NOT NULL DEFAULT 0,
            duplicates       INTEGER NOT NULL DEFAULT 0,
            malformed_frames INTEGER NOT NULL DEFAULT 0,
            note             TEXT
        );
        CREATE INDEX idx_sync_run_started ON sync_run(started_at);

        CREATE TABLE session (
            id         INTEGER PRIMARY KEY,
            kind       TEXT NOT NULL,
            start_ms   INTEGER NOT NULL,
            end_ms     INTEGER NOT NULL,
            origin     TEXT NOT NULL,
            label      TEXT,
            device_id  TEXT,
            detector   TEXT,
            confidence REAL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted    INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_session_kind_start ON session(kind, start_ms);

        CREATE TABLE user_correction (
            id         INTEGER PRIMARY KEY,
            session_id INTEGER REFERENCES session(id),
            field      TEXT NOT NULL,
            old_value  TEXT,
            new_value  TEXT,
            created_at INTEGER NOT NULL
        );
        CREATE INDEX idx_user_correction_session ON user_correction(session_id);

        CREATE TABLE derived_metric (
            metric_id    TEXT NOT NULL,
            spec_version INTEGER NOT NULL,
            start_ms     INTEGER NOT NULL,
            end_ms       INTEGER NOT NULL,
            value        REAL,
            unit         TEXT NOT NULL,
            availability TEXT NOT NULL,
            coverage     REAL,
            confidence   TEXT NOT NULL,
            inputs_json  TEXT NOT NULL,
            computed_at  INTEGER NOT NULL,
            PRIMARY KEY (metric_id, spec_version, start_ms, end_ms)
        );
        CREATE INDEX idx_derived_metric_start ON derived_metric(start_ms);

        CREATE TABLE setting (
            key   TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """
}

/// Table names, shared by diagnostics, deletion and export.
enum Schema {
    static let measurementTables = ["hr_sample", "beat_interval", "motion_epoch", "aux_measurement"]

    static let allTables = [
        "device", "ingest_batch", "hr_sample", "beat_interval", "motion_epoch", "aux_measurement", "raw_frame",
        "connection_event", "sync_cursor", "sync_run", "session", "user_correction", "derived_metric", "setting",
    ]

    /// Children before parents, so foreign keys are never violated mid-transaction.
    static let deletionOrder = [
        "user_correction", "hr_sample", "beat_interval", "motion_epoch", "aux_measurement", "ingest_batch", "session",
        "raw_frame", "connection_event", "sync_cursor", "sync_run", "derived_metric", "device", "setting",
    ]
}
