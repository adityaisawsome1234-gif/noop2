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

    /// One written command as the link saw it.
    public struct Write: Hashable, Sendable {
        public var characteristic: String
        public var command: EncodedCommand
        public var withResponse: Bool
        public var bytes: [UInt8] { command.bytes }
    }

    public let peripheralID: String
    public let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let lock = NSLock()
    private var writes: [Write] = []
    private var closed = false
    private let responder: Responder?
    private let failWritesAfter: Int?
    /// Receive time of the last capture entry (the default time of `finish`).
    private var lastEntryTime: EpochMillis = 0

    /// - Parameters:
    ///   - entries: capture entries of ONE connection; `.rx` become notifications, an `.event` entry whose
    ///     note starts with "disconnect" ends the stream, one whose note starts with "gap" becomes a `.gap`
    ///     (lost notifications recorded by the engine), `.tx` entries are ignored (they were our own
    ///     writes). Split multi-connection captures with `ReplayLink.segments(of:)` first.
    ///   - services: what `.ready` reports first.
    ///   - endWithDisconnect: append a disconnect after the last entry (default true). Ignored when a
    ///     `responder` is given: a scripted band keeps the link open for its reactions until it disconnects
    ///     itself or the test calls `finish(reason:at:)`.
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
                guard let bytes = HexCodec.decode(e.d) else { continue }
                continuation.yield(.notification(characteristic: UUIDs.normalize(e.c), bytes: bytes, receivedAt: e.t))
            case .event:
                let note = (e.note ?? "").lowercased()
                if note.hasPrefix("disconnect") {
                    continuation.yield(.disconnected(reason: e.note, at: e.t))
                    ended = true
                } else if note.hasPrefix("gap") {
                    continuation.yield(.gap(characteristic: e.c.isEmpty ? nil : UUIDs.normalize(e.c), count: Self.gapCount(note), at: e.t))
                }
            case .tx:
                continue
            }
            if ended { break }
        }
        self.lastEntryTime = lastTime
        if ended {
            continuation.finish()
            closed = true
        } else if endWithDisconnect && responder == nil {
            continuation.yield(.disconnected(reason: "end of capture", at: lastTime))
            continuation.finish()
            closed = true
        }
    }

    public func write(_ command: EncodedCommand, characteristic: String, withResponse: Bool) async throws {
        let reaction: [LinkEvent] = try lock.withLock {
            if closed { throw LinkError.notConnected }
            if let limit = failWritesAfter, writes.count >= limit { throw LinkError.writeFailed("scripted failure") }
            writes.append(Write(characteristic: UUIDs.normalize(characteristic), command: command, withResponse: withResponse))
            return responder?(command.bytes, UUIDs.normalize(characteristic)) ?? []
        }
        for event in reaction {
            if case .disconnected = event {
                // The link goes down exactly once: mark it closed before yielding the scripted disconnect.
                let wasClosed = lock.withLock { () -> Bool in
                    let was = closed
                    closed = true
                    return was
                }
                if !wasClosed { continuation.yield(event) }
                continuation.finish()
                break
            }
            continuation.yield(event)
        }
    }

    /// Ends the stream (used by scripted tests once the responder has nothing left to say). The disconnect
    /// is stamped `time`, or the last capture entry's time when nil.
    public func finish(reason: String = "replay finished", at time: EpochMillis? = nil) {
        let (wasClosed, last) = lock.withLock { () -> (Bool, EpochMillis) in
            let was = closed
            closed = true
            return (was, lastEntryTime)
        }
        if !wasClosed {
            continuation.yield(.disconnected(reason: reason, at: time ?? last))
        }
        continuation.finish()
    }

    /// "gap: 3 notification(s) lost" → 3 (1 when no count is recorded).
    static func gapCount(_ note: String) -> Int {
        let digits = note.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits).map { max(1, $0) } ?? 1
    }

    /// Everything written so far, in order.
    public var writtenCommands: [Write] {
        lock.withLock { writes }
    }

    /// Splits a capture into one entry list per connection. Each segment ends with its "disconnect"
    /// event (if any); "ready" events start nothing on their own. Entries after the last disconnect form
    /// a final segment.
    public static func segments(of entries: [CaptureEntry]) -> [[CaptureEntry]] {
        var out: [[CaptureEntry]] = []
        var current: [CaptureEntry] = []
        for e in entries {
            current.append(e)
            if e.dir == .event, (e.note ?? "").lowercased().hasPrefix("disconnect") {
                out.append(current)
                current = []
            }
        }
        if current.contains(where: { $0.dir != .event }) { out.append(current) }
        return out
    }
}
