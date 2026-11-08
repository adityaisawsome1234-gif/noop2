import Foundation
import FormaCore
import FormaProtocol
import FormaSync

/// Events from the platform Bluetooth layer to the app model. Delivered on any thread; the model hops
/// to the main actor.
public enum CentralEvent: Sendable {
    case stateChanged(LinkState)
    case bluetoothProblem(String?)
    case discovered(DiscoveredDevice, advertisement: [String: String])
    case scanStopped
    case linkReady(any PeripheralLink, services: [GATTServiceSummary])
    case connectionEvent(ConnectionEvent)
    case pairingProblem(String)
}

/// The Bluetooth central as seen by the app model (Core Bluetooth on iOS; a fake in tests).
public protocol BandCentral: AnyObject, Sendable {
    /// Keep the selected band connected (pending connect; reconnect on drop).
    func connectSelected(profile: GATTProfile)
    /// Stop collection (cancel this app's connection).
    func disconnect()
    func select(peripheralID: String, profile: GATTProfile)
    func forgetSelected()
    func startScan(includeUnfiltered: Bool)
    func stopScan()
    /// Identifier of the band selected earlier (persisted by the platform layer).
    var savedPeripheralID: String? { get }
    /// Install the event handler (called once by the app model).
    func setEventHandler(_ handler: @escaping @Sendable (CentralEvent) -> Void)
}

/// Platform services the app model needs (file locations, protection, backups, archive creation).
public protocol PlatformServices: Sendable {
    /// Path of the live or demo database. `nil` means in-memory (tests).
    func databasePath(demo: Bool) throws -> String?
    /// Apply file protection to the database and its side files.
    func protectDatabase(at path: String)
    func setIncludedInBackups(_ included: Bool) throws
    func isIncludedInBackups() -> Bool
    /// An empty directory for staging exports.
    func makeStagingDirectory() throws -> URL
    /// Archive a directory into a single file's bytes (zip on iOS).
    func archiveDirectory(_ url: URL) throws -> Data
    /// Run short work that must finish even if the app is suspended mid-way (background task on iOS).
    func runProtected<T: Sendable>(_ name: String, _ body: () throws -> T) rethrows -> T
    var appVersion: String { get }
    var osVersion: String { get }
    /// Persisted lightweight preferences (UserDefaults on iOS).
    func preference(_ key: String) -> String?
    func setPreference(_ value: String?, forKey key: String)
}

/// App-wide appearance preference (Settings → Appearance).
public enum AppearancePreference: String, Hashable, Sendable, CaseIterable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "Match system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
