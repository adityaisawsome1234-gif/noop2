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
    ///
    /// When iOS refuses the assertion (no background time left) the body runs at once, unprotected, instead
    /// of first waiting for a grant that will not come. When the assertion ends while the body is still
    /// running, the expiry waits briefly so a short transaction can commit before Forma is suspended.
    func runProtected<T: Sendable>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let activity = ExpiringActivity()
        ProcessInfo.processInfo.performExpiringActivity(withReason: name) { expired in
            activity.systemCalled(expired: expired)
        }
        activity.waitForDecision()
        defer { activity.bodyFinished() }
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

/// One `performExpiringActivity` around a short piece of work.
///
/// iOS calls the activity's block once, asynchronously: with `expired == false` when it granted the
/// assertion (the block then holds it until the work has finished), or with `expired == true` when it
/// refused it (the work runs unprotected, without waiting). If the assertion ends while the work is still
/// running, iOS calls the block a second time with `expired == true`; that call waits a moment for the work
/// (a short SQLite transaction) to commit, because Forma may be suspended as soon as it returns.
private final class ExpiringActivity: @unchecked Sendable {
    /// Longest the caller waits for iOS to grant or refuse the assertion before running unprotected.
    private static let decisionTimeout: DispatchTimeInterval = .milliseconds(500)
    /// Longest an expiring assertion is held back for work still running.
    private static let expiryGrace: DispatchTimeInterval = .seconds(1)

    private let decided = DispatchGroup()
    private let finished = DispatchGroup()
    private let lock = NSLock()
    private var calls = 0

    init() {
        decided.enter()
        finished.enter()
    }

    /// The `performExpiringActivity` block.
    func systemCalled(expired: Bool) {
        let isFirst: Bool = lock.withLock {
            calls += 1
            return calls == 1
        }
        if isFirst { decided.leave() }
        if !expired {
            finished.wait() // hold the assertion until the work is done
        } else if !isFirst {
            _ = finished.wait(timeout: .now() + Self.expiryGrace)
        }
    }

    func waitForDecision() {
        _ = decided.wait(timeout: .now() + Self.decisionTimeout)
    }

    func bodyFinished() {
        finished.leave()
    }
}
