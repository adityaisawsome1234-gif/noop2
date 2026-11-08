import Foundation
import FormaCore

/// Errors raised by `FormaStore` (SQLite failures surface as `SQLiteError`).
public enum StoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The database was written by a newer Forma build (`user_version` above what this build knows).
    /// It is left untouched: Forma never downgrades a schema.
    case schemaTooNew(found: Int, supported: Int)
    /// The file is an SQLite database that belongs to another application (`PRAGMA application_id`).
    case notAFormaDatabase(applicationID: Int32)
    /// A record failed structural validation. Nothing from the call was written.
    case invalidRecord(String)
    /// A caller-supplied argument is unusable (empty key, missing id, ...).
    case invalidArgument(String)
    /// The referenced row does not exist (or is soft-deleted where that matters).
    case notFound(String)
    /// A stored setting could not be decoded as the requested type.
    case corruptSetting(key: String, detail: String)
    /// The store was closed.
    case closed
    /// The file is not a Forma backup, or its header is unusable.
    case invalidBackup(String)
    /// The backup uses a newer backup format than this build can read.
    case unsupportedBackupVersion(found: Int, supported: Int)
    /// A file could not be created, read, written or deleted.
    case fileError(String)

    public var description: String {
        switch self {
        case .schemaTooNew(let found, let supported):
            return "The database uses schema version \(found), but this build supports up to \(supported). Update Forma."
        case .notAFormaDatabase(let applicationID):
            return "The file is not a Forma database (application id \(applicationID))."
        case .invalidRecord(let detail): return "Invalid record: \(detail)"
        case .invalidArgument(let detail): return "Invalid argument: \(detail)"
        case .notFound(let detail): return "Not found: \(detail)"
        case .corruptSetting(let key, let detail): return "Setting '\(key)' could not be decoded: \(detail)"
        case .closed: return "The store is closed."
        case .invalidBackup(let detail): return "Not a usable Forma backup: \(detail)"
        case .unsupportedBackupVersion(let found, let supported):
            return "The backup uses format version \(found), but this build reads up to \(supported). Update Forma."
        case .fileError(let detail): return "File error: \(detail)"
        }
    }
}

/// Bounds for diagnostics raw-frame capture. All three are always enforced (oldest frames are
/// deleted first), so the `raw_frame` table cannot grow without limit.
public struct RawFrameRetention: Hashable, Sendable {
    /// Frames whose `receivedAt` is older than `now - maxAgeMillis` are deleted (milliseconds).
    public let maxAgeMillis: Int64
    /// Maximum number of stored frames (at least 1).
    public let maxFrames: Int
    /// Maximum summed payload size of stored frames, in bytes (at least 1). A single frame larger
    /// than this is not stored at all.
    public let maxTotalBytes: Int

    public init(maxAgeMillis: Int64, maxFrames: Int, maxTotalBytes: Int) {
        self.maxAgeMillis = max(0, maxAgeMillis)
        self.maxFrames = max(1, maxFrames)
        self.maxTotalBytes = max(1, maxTotalBytes)
    }

    /// 7 days, 100 000 frames, 32 MiB.
    public static let `default` = RawFrameRetention(maxAgeMillis: 7 * EpochMillis.millisPerDay,
                                                    maxFrames: 100_000,
                                                    maxTotalBytes: 32 * 1_024 * 1_024)
}

/// Well-known keys in the `setting` table.
public enum StoreSettingKey {
    /// JSON-encoded `UserProfile`.
    public static let userProfile = "user_profile"
    /// "true"/"false": whether raw BLE frames are captured for diagnostics (default false).
    public static let rawCaptureEnabled = "raw_capture_enabled"

    /// Settings that describe this phone only and are therefore not written to backups.
    public static let deviceLocal: Set<String> = [rawCaptureEnabled]
}

/// `UserCorrection.field` values written by the session editors.
public enum SessionCorrectionField {
    /// `SessionKind` raw value.
    public static let kind = "kind"
    /// Session start, epoch milliseconds as a decimal string.
    public static let start = "start"
    /// Session end, epoch milliseconds as a decimal string.
    public static let end = "end"
    /// Free-text label (nil when absent).
    public static let label = "label"
    /// `SessionOrigin` raw value.
    public static let origin = "origin"
    /// "false" → "true" when a session is soft-deleted.
    public static let deleted = "deleted"
}
