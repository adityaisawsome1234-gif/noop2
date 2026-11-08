import Foundation
import FormaCore

/// Events produced by one connection to one peripheral. Implemented by the app's Core Bluetooth link
/// and by `ReplayLink`, so live data and replayed captures travel the same pipeline.
public enum LinkEvent: Sendable, Equatable {
    /// Services/characteristics discovered and notifications enabled. Keys are service UUIDs (uppercase),
    /// values are the characteristic UUIDs (uppercase) that exist under them.
    case ready(services: [String: [String]])
    /// A notification/indication (or read response) from the peripheral.
    case notification(characteristic: String, bytes: [UInt8], receivedAt: EpochMillis)
    /// The link went down. `reason` is a human-readable description when known.
    case disconnected(reason: String?, at: EpochMillis)
}

public enum LinkError: Error, Equatable, Sendable {
    case notConnected
    case characteristicNotFound(String)
    case writeFailed(String)
    case timedOut
    /// The peripheral rejected the request because the link is not encrypted/bonded (ATT 0x05/0x0F).
    case pairingRequired
}

/// One connection to one peripheral.
public protocol PeripheralLink: AnyObject, Sendable {
    /// Stable local identifier of the peripheral (on iOS: the CBPeripheral identifier).
    var peripheralID: String { get }
    /// Single-consumer stream of link events for the lifetime of this connection.
    var events: AsyncStream<LinkEvent> { get }
    /// Writes bytes to a characteristic. Implementations must deliver writes in call order.
    func write(_ bytes: [UInt8], characteristic: String, withResponse: Bool) async throws
}

/// Normalizes UUID strings for comparison: trims, uppercases, expands 16-bit SIG UUIDs to 128-bit.
public enum UUIDText {
    public static let sigBaseSuffix = "-0000-1000-8000-00805F9B34FB"

    public static func normalize(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.count == 4, s.allSatisfy(\.isHexDigit) { return "0000" + s + sigBaseSuffix }
        if s.count == 8, s.allSatisfy(\.isHexDigit) { return s + sigBaseSuffix }
        return s
    }

    public static func equal(_ a: String, _ b: String) -> Bool { normalize(a) == normalize(b) }
}
