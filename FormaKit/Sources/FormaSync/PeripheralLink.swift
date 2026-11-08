import Foundation
import FormaCore
import FormaProtocol

/// Events produced by one connection to one peripheral. Implemented by the app's Core Bluetooth link
/// and by `ReplayLink`, so live data and replayed captures travel the same pipeline.
public enum LinkEvent: Sendable, Equatable {
    /// Services/characteristics discovered and notifications enabled. Keys are service UUIDs (uppercase),
    /// values are the characteristic UUIDs (uppercase) that exist under them.
    case ready(services: [String: [String]])
    /// A notification/indication (or read response) from the peripheral.
    case notification(characteristic: String, bytes: [UInt8], receivedAt: EpochMillis)
    /// The link lost `count` notifications before delivering them (for example its buffer overflowed while
    /// the engine was busy). Whatever they carried is gone: the sync engine treats an open history chunk as
    /// damaged and acknowledges nothing more in that transfer. `characteristic` is nil when unknown. Links
    /// that can drop notifications must report it this way, never silently.
    case gap(characteristic: String?, count: Int, at: EpochMillis)
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
    /// Writes an adapter-encoded command to a characteristic. Implementations must deliver writes in
    /// call order. Only `EncodedCommand` is accepted: raw bytes cannot be written through a link.
    func write(_ command: EncodedCommand, characteristic: String, withResponse: Bool) async throws
}
