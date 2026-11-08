import Foundation
import CoreBluetooth
import FormaCore
import FormaProtocol
import FormaSync

/// `PeripheralLink` over one connected `CBPeripheral`. Created by `BLECentral` once services are
/// discovered and notifications are enabled; closed on disconnect. One connection can have several links
/// one after the other (a fresh one when the app model stops reading the previous one); they share the
/// connection's `GATTWriteChannel`.
///
/// Everything except `events` and `write` runs on the BLE queue (`BLECentral` calls it there).
final class CoreBluetoothLink: PeripheralLink, @unchecked Sendable {
    /// Events kept for a consumer that is behind. When it falls this far behind, the link ends instead of
    /// dropping events: the sync engine must never read a stream with a hole in it, because it could then
    /// acknowledge band history whose middle was lost.
    static let bufferLimit = 10_000

    let peripheralID: String
    let events: AsyncStream<LinkEvent>

    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let queue: DispatchQueue
    private let characteristics: [String: CBCharacteristic]
    private let writes: GATTWriteChannel
    private let writer: UInt64
    private let onConsumerGone: (CoreBluetoothLink) -> Void
    private let onOverflow: (CoreBluetoothLink) -> Void
    private var closed = false

    /// - Parameters:
    ///   - onConsumerGone: called on `queue` when the consumer stops reading (its task was cancelled).
    ///   - onOverflow: called on `queue` when the link ended because its consumer fell too far behind.
    init(peripheral: CBPeripheral, queue: DispatchQueue, characteristics: [String: CBCharacteristic], writes: GATTWriteChannel,
         onConsumerGone: @escaping (CoreBluetoothLink) -> Void, onOverflow: @escaping (CoreBluetoothLink) -> Void) {
        self.peripheralID = peripheral.identifier.uuidString
        self.queue = queue
        self.characteristics = characteristics
        self.writes = writes
        self.writer = writes.newWriter()
        self.onConsumerGone = onConsumerGone
        self.onOverflow = onOverflow
        var cont: AsyncStream<LinkEvent>.Continuation!
        // `.bufferingOldest`: on overflow the newest event is refused (and the link ends), so what the consumer
        // still reads is a gap-free prefix that starts with `.ready`.
        self.events = AsyncStream(bufferingPolicy: .bufferingOldest(Self.bufferLimit)) { cont = $0 }
        self.continuation = cont
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination, let self else { return }
            self.queue.async { self.consumerCancelled() }
        }
    }

    /// On the BLE queue.
    func emit(_ event: LinkEvent) {
        guard !closed else { return }
        let result = continuation.yield(event)
        if case .dropped = result {
            // End the stream here: the consumer still gets every event before this one, then the end.
            closed = true
            writes.fail(writer: writer)
            continuation.finish()
            onOverflow(self)
        } else if case .terminated = result {
            consumerCancelled()
        }
    }

    /// On the BLE queue: the connection ended, or the central replaced this link.
    func close(reason: String, at time: EpochMillis) {
        guard !closed else { return }
        closed = true
        writes.fail(writer: writer)
        continuation.yield(.disconnected(reason: reason, at: time))
        continuation.finish()
    }

    private func consumerCancelled() {
        guard !closed else { return }
        closed = true
        writes.fail(writer: writer)
        onConsumerGone(self)
    }

    /// Only adapter-encoded commands can be written (`EncodedCommand`); raw bytes cannot reach the band.
    func write(_ command: EncodedCommand, characteristic: String, withResponse: Bool) async throws {
        let bytes = command.bytes
        let key = UUIDs.normalize(characteristic)
        guard characteristics[key] != nil else { throw LinkError.characteristicNotFound(key) }
        let data = Data(bytes)
        let writer = self.writer
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Hand-over and the flow-control check happen on the BLE queue, in call order.
            queue.async {
                guard !self.closed, let c = self.characteristics[key] else {
                    cont.resume(throwing: LinkError.notConnected)
                    return
                }
                self.writes.enqueue(data, to: c, key: key, preferResponse: withResponse, writer: writer, continuation: cont)
            }
        }
    }
}

/// The write path of one connection. Confined to the BLE queue.
///
/// - Writes reach Core Bluetooth in call order: a without-response write that has to wait for
///   `canSendWriteWithoutResponse` holds back the writes behind it, and the check and the send happen in
///   one step on the queue that also receives `peripheralIsReady(toSendWriteWithoutResponse:)`, so the
///   wake-up cannot be missed.
/// - A with-response write completes on `didWriteValueFor`; iOS confirms them in order per characteristic.
///   A write whose caller was already answered (link closed, timed out) keeps its place in that order, so
///   its late confirmation is not taken for the next write's.
/// - Every write completes or fails within `timeoutSeconds`, so a lost confirmation cannot stall the sync
///   engine, which awaits its writes.
final class GATTWriteChannel: @unchecked Sendable {
    static let timeoutSeconds: Double = 30

    private struct Outgoing {
        let id: UInt64
        let writer: UInt64
        let key: String
        let characteristic: CBCharacteristic
        let data: Data
        let type: CBCharacteristicWriteType
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct Sent {
        let id: UInt64
        let writer: UInt64
        /// nil once the caller was answered without the confirmation.
        var continuation: CheckedContinuation<Void, Error>?
    }

    private let peripheral: CBPeripheral
    private let queue: DispatchQueue
    private var nextID: UInt64 = 0
    private var nextWriter: UInt64 = 0
    /// Not yet handed to Core Bluetooth, in call order.
    private var outbox: [Outgoing] = []
    /// With-response writes handed to Core Bluetooth, oldest first, per characteristic.
    private var awaitingConfirmation: [String: [Sent]] = [:]

    init(peripheral: CBPeripheral, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.queue = queue
    }

    /// Identifies the writes of one link, so they can be failed when that link closes.
    func newWriter() -> UInt64 {
        nextWriter &+= 1
        return nextWriter
    }

    func enqueue(_ data: Data, to c: CBCharacteristic, key: String, preferResponse: Bool, writer: UInt64,
                 continuation: CheckedContinuation<Void, Error>) {
        // The write type the characteristic supports, preferring the requested one. (Diagnostics lists each
        // characteristic's properties, so a command characteristic that takes only without-response writes —
        // and so gets no delivery confirmation — is visible there.)
        let props = c.properties
        let withResponse = preferResponse
            ? (props.contains(.write) || !props.contains(.writeWithoutResponse))
            : (!props.contains(.writeWithoutResponse) && props.contains(.write))
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        let maxLength = peripheral.maximumWriteValueLength(for: type)
        guard data.count <= maxLength else {
            continuation.resume(throwing: LinkError.writeFailed("command of \(data.count) bytes exceeds the link limit of \(maxLength)"))
            return
        }
        nextID &+= 1
        let id = nextID
        outbox.append(Outgoing(id: id, writer: writer, key: key, characteristic: c, data: data, type: type, continuation: continuation))
        pump()
        queue.asyncAfter(deadline: .now() + Self.timeoutSeconds) { [weak self] in self?.timeOut(id) }
    }

    /// Hands over what may go now (also called from `peripheralIsReady(toSendWriteWithoutResponse:)`).
    func pump() {
        while let next = outbox.first {
            if next.type == .withoutResponse, !peripheral.canSendWriteWithoutResponse { return }
            outbox.removeFirst()
            peripheral.writeValue(next.data, for: next.characteristic, type: next.type)
            if next.type == .withResponse {
                awaitingConfirmation[next.key, default: []].append(Sent(id: next.id, writer: next.writer, continuation: next.continuation))
            } else {
                next.continuation.resume()
            }
        }
    }

    /// `didWriteValueFor`.
    func didWrite(key: String, error: Error?) {
        guard var sent = awaitingConfirmation[key], !sent.isEmpty else { return }
        let oldest = sent.removeFirst()
        awaitingConfirmation[key] = sent.isEmpty ? nil : sent
        guard let continuation = oldest.continuation else { return }
        if let error {
            continuation.resume(throwing: BLECentral.isPairingError(error) ? LinkError.pairingRequired : LinkError.writeFailed(error.localizedDescription))
        } else {
            continuation.resume()
        }
    }

    /// The link `writer` closed: its waiting writes fail with `notConnected`.
    func fail(writer: UInt64) {
        fail(where: { $0 == writer })
    }

    /// The connection ended: no confirmation will come for anything.
    func failAll() {
        fail(where: { _ in true })
        awaitingConfirmation.removeAll()
    }

    private func fail(where matches: (UInt64) -> Bool) {
        let dropped = outbox.filter { matches($0.writer) }
        outbox.removeAll { matches($0.writer) }
        for o in dropped { o.continuation.resume(throwing: LinkError.notConnected) }
        for key in Array(awaitingConfirmation.keys) {
            guard var sent = awaitingConfirmation[key] else { continue }
            for i in sent.indices where matches(sent[i].writer) {
                sent[i].continuation?.resume(throwing: LinkError.notConnected)
                sent[i].continuation = nil
            }
            awaitingConfirmation[key] = sent
        }
        pump()
    }

    private func timeOut(_ id: UInt64) {
        if let i = outbox.firstIndex(where: { $0.id == id }) {
            let o = outbox.remove(at: i)
            o.continuation.resume(throwing: LinkError.timedOut)
            pump()
            return
        }
        for key in Array(awaitingConfirmation.keys) {
            guard var sent = awaitingConfirmation[key], let i = sent.firstIndex(where: { $0.id == id }),
                  let continuation = sent[i].continuation else { continue }
            sent[i].continuation = nil
            awaitingConfirmation[key] = sent
            continuation.resume(throwing: LinkError.timedOut)
            return
        }
    }
}
