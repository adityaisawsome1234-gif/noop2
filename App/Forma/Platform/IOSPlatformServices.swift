import Foundation
import UIKit
import FormaFeatures

/// iOS implementation of the platform services the app model uses.
final class IOSPlatformServices: PlatformServices, @unchecked Sendable {
    func databasePath(demo: Bool) throws -> String? {
        try StorageLocation.databaseURL(demo ? .demo : .live).path
    }

    func protectDatabase(at path: String) {
        StorageLocation.applyProtection(toDatabaseAt: URL(fileURLWithPath: path))
    }

    func setIncludedInBackups(_ included: Bool) throws {
        try StorageLocation.setIncludedInBackups(included)
    }

    func isIncludedInBackups() -> Bool {
        StorageLocation.isIncludedInBackups()
    }

    func makeStagingDirectory() throws -> URL {
        try StorageLocation.makeExportStagingDirectory()
    }

    /// Zips a directory using the system's file coordinator (no third-party code).
    func archiveDirectory(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.forUploading], error: &coordinationError) { zipURL in
            result = Result { try Data(contentsOf: zipURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Holds a process assertion while `body` runs, so a database write started during a background
    /// Bluetooth wake can finish before iOS suspends the app (avoids 0xdead10cc terminations).
    func runProtected<T: Sendable>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        ProcessInfo.processInfo.performExpiringActivity(withReason: name) { expired in
            guard !expired else { return }
            started.signal()
            finished.wait()
        }
        _ = started.wait(timeout: .now() + 0.5)
        defer { finished.signal() }
        return try body()
    }

    var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    func preference(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: "forma.pref." + key)
    }

    func setPreference(_ value: String?, forKey key: String) {
        if let value { UserDefaults.standard.set(value, forKey: "forma.pref." + key) }
        else { UserDefaults.standard.removeObject(forKey: "forma.pref." + key) }
    }
}
