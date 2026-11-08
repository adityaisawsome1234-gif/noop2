import Foundation
import FormaCore
import FormaProtocol

/// A `PeripheralLink` that plays back a `CaptureFile`. Received entries become notifications in their
/// recorded order; written commands are recorded for assertions.
///
/// Replay is deterministic: entries are emitted as fast as the consumer reads them, carrying their
/// original receive timestamps. An optional `responder` lets tests script band behaviour in response
/// to commands (e.g. emit a history batch when a history request is written).
public final class ReplayLink: PeripheralLink, @unchecked Sendable {
    public typealias Responder = @Sendable (_ written: [UInt8], _ characteristic: String) -> [LinkEvent]

    public let peripheralID: String
    public let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let lock = NSLock()
    private var writes: [(characteristic: String, bytes: [UInt8], withResponse: Bool)] = []
    private var closed = false
    private let responder: Responder?
    private let failWritesAfter: Int?

    /// - Parameters:
    ///   - entries: capture entries; `.rx` become notifications, `.event` entries whose note starts with
    ///     "disconnect" end the stream, `.tx` entries are ignored (they were our own writes).
    ///   - services: what `.ready` reports first.
    ///   - endWithDisconnect: append a disconnect after the last entry (default true).
    ///   - responder: scripted reactions to writes, emitted immediately after each write.
    ///   - failWritesAfter: make every write after this many succeed calls throw (to test failure paths).
    public init(peripheralID: String = "replay", entries: [CaptureEntry], services: [String: [String]],
                endWithDisconnect: Bool = true, responder: Responder? = nil, failWritesAfter: Int? = nil) {
        self.peripheralID = peripheralID
        self.responder = responder
        self.failWritesAfter = failWritesAfter
        var cont: AsyncStream<LinkEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
        continuation.yield(.ready(services: services))
        var lastTime: EpochMillis = 0
        var ended = false
        for e in entries {
            lastTime = e.t
            switch e.dir {
            case .rx:
                guard let bytes = Self.hexBytes(e.d) else { continue }
                continuation.yield(.notification(characteristic: UUIDs.normalize(e.c), bytes: bytes, receivedAt: e.t))
            case .event:
                if (e.note ?? "").lowercased().hasPrefix("disconnect") {
                    continuation.yield(.disconnected(reason: e.note, at: e.t))
                    ended = true
                }
            case .tx:
                continue
            }
            if ended { break }
        }
        if ended {
            continuation.finish()
            closed = true
        } else if endWithDisconnect && responder == nil {
            continuation.yield(.disconnected(reason: "end of capture", at: lastTime))
            continuation.finish()
            closed = true
        }
    }

    public func write(_ bytes: [UInt8], characteristic: String, withResponse: Bool) async throws {
        let reaction: [LinkEvent] = try lock.withLock {
            if closed { throw LinkError.notConnected }
            if let limit = failWritesAfter, writes.count >= limit { throw LinkError.writeFailed("scripted failure") }
            writes.append((UUIDs.normalize(characteristic), bytes, withResponse))
            return responder?(bytes, UUIDs.normalize(characteristic)) ?? []
        }
        for event in reaction {
            continuation.yield(event)
            if case .disconnected = event {
                finish()
                break
            }
        }
    }

    /// Ends the stream (used by scripted tests once the responder has nothing left to say).
    public func finish(reason: String = "replay finished", at time: EpochMillis = 0) {
        let wasClosed = lock.withLock { () -> Bool in
            let was = closed
            closed = true
            return was
        }
        if !wasClosed {
            continuation.yield(.disconnected(reason: reason, at: time))
        }
        continuation.finish()
    }

    /// Everything written so far (characteristic, bytes, with-response flag).
    public var writtenCommands: [(characteristic: String, bytes: [UInt8], withResponse: Bool)] {
        lock.withLock { writes }
    }

    static func hexBytes(_ hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
}
