#if DEBUG
import SwiftUI
import FormaCore
import FormaProtocol
import FormaFeatures

/// No-op central for previews.
final class PreviewCentral: BandCentral, @unchecked Sendable {
    func connectSelected(profile: GATTProfile) {}
    func disconnect() {}
    func select(peripheralID: String, profile: GATTProfile) {}
    func forgetSelected() {}
    func startScan(includeUnfiltered: Bool) {}
    func stopScan() {}
    var savedPeripheralID: String? { nil }
    func setEventHandler(_ handler: @escaping @Sendable (CentralEvent) -> Void) {}
}

/// In-memory platform for previews (no files, no backups).
final class PreviewPlatform: PlatformServices, @unchecked Sendable {
    private var prefs: [String: String] = ["onboardingComplete": "1"]
    func databasePath(demo: Bool) throws -> String? { nil }
    func protectDatabase(at path: String) {}
    func setIncludedInBackups(_ included: Bool) throws {}
    func isIncludedInBackups() -> Bool { false }
    func makeStagingDirectory() throws -> URL { FileManager.default.temporaryDirectory }
    func archiveDirectory(_ url: URL) throws -> Data { Data() }
    func runProtected<T: Sendable>(_ name: String, _ body: () throws -> T) rethrows -> T { try body() }
    var appVersion: String { "preview" }
    var osVersion: String { "preview" }
    func preference(_ key: String) -> String? { prefs[key] }
    func setPreference(_ value: String?, forKey key: String) { prefs[key] = value }
}

@MainActor
enum PreviewModels {
    static func empty() -> AppModel {
        AppModel(central: PreviewCentral(), platform: PreviewPlatform())
    }

    static func demo() -> AppModel {
        let model = empty()
        Task { await model.enterDemo() }
        return model
    }
}












#endif
