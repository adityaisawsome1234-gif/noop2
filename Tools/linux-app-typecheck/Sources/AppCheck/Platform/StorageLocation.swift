import Foundation

/// Where Forma keeps its databases and how they are protected.
///
/// - Data protection: `completeUntilFirstUserAuthentication`. Background Bluetooth events can wake
///   Forma while the phone is locked and it must be able to write the database then. With this class
///   the files are encrypted and unreadable after a reboot until the user unlocks the phone once.
///   (`complete` would make every locked-phone background write fail.)
/// - Backups: by default the directory is excluded from iCloud Backup and computer backups, so health
///   data stays on this phone. The user can opt in from Settings. Excluding from backup also means
///   deleting the app (or losing the phone) loses unexported history; the UI says so.
/// - Live and demo data use different files and are never mixed.
enum StorageLocation {
    enum Kind: String {
        case live = "forma"
        case demo = "forma-demo"
    }

    /// `Application Support/Forma/` — created with the protection class applied to the directory so
    /// SQLite's `-wal` and `-shm` side files inherit it.
    static func directory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Forma", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        } else {
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
        }
        return dir
    }

    static func databaseURL(_ kind: Kind) throws -> URL {
        try directory().appendingPathComponent("\(kind.rawValue).sqlite", isDirectory: false)
    }

    /// Applies the protection class to the database and its side files (call after opening).
    static func applyProtection(toDatabaseAt url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if fm.fileExists(atPath: path) {
                try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
            }
        }
    }

    /// Include or exclude the whole Forma directory from iCloud Backup / computer backups.
    static func setIncludedInBackups(_ included: Bool) throws {
        var dir = try directory()
        var values = URLResourceValues()
        values.isExcludedFromBackup = !included
        try dir.setResourceValues(values)
    }

    static func isIncludedInBackups() -> Bool {
        guard let dir = try? directory(),
              let values = try? dir.resourceValues(forKeys: [.isExcludedFromBackupKey]) else { return false }
        return !(values.isExcludedFromBackup ?? false)
    }

    /// A fresh, empty temporary directory for exports before the user picks a destination.
    static func makeExportStagingDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forma-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        return dir
    }
}
