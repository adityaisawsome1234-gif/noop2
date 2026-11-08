import Foundation
import CoreBluetooth
import FormaCore
import FormaProtocol
import FormaSync

/// `PeripheralLink` over one connected `CBPeripheral`. Created by `BLECentral` once services are
/// discovered and notifications are enabled; closed on disconnect. Writes are serialized: a
/// with-response write completes when iOS reports `didWriteValueFor`; a without-response write waits
/// for `canSendWriteWithoutResponse`.
final class CoreBluetoothLink: PeripheralLink, @unchecked Sendable {
    let peripheralID: String
    let events: AsyncStream<LinkEvent>

    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let peripheral: CBPeripheral
    private let queue: DispatchQueue
    private let characteristics: [String: CBCharacteristic]
    private let lock = NSLock()
    private var closed = false
    // FIFO of continuations waiting for with-response write confirmations (per characteristic).
    private var pendingWrites: [String: [CheckedContinuation<Void, Error>]] = [:]
    private var waitingForWriteWindow: [CheckedContinuation<Void, Never>] = []

    init(peripheral: CBPeripheral, queue: DispatchQueue, characteristics: [String: CBCharacteristic]) {
        self.peripheral = peripheral
        self.peripheralID = peripheral.identifier.uuidString
        self.queue = queue
        self.characteristics = characteristics
        var cont: AsyncStream<LinkEvent>.Continuation!
        // Bounded buffer: if the consumer stalls, the oldest notifications are dropped (and counted as a gap)
        // rather than growing memory without limit.
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(10_000)) { cont = $0 }
        self.continuation = cont
    }

    /// Called on the BLE queue by `BLECentral`.
    func emit(_ event: LinkEvent) {
        let isClosed = lock.withLock { closed }
        guard !isClosed else { return }
        continuation.yield(event)
    }

    func close(reason: String, at time: EpochMillis) {
        let (waiters, windowWaiters): ([CheckedContinuation<Void, Error>], [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard !closed else { return ([], []) }
            closed = true
            let w = pendingWrites.values.flatMap { $0 }
            pendingWrites.removeAll()
            let ww = waitingForWriteWindow
            waitingForWriteWindow.removeAll()
            return (w, ww)
        }
        for w in waiters { w.resume(throwing: LinkError.notConnected) }
        for w in windowWaiters { w.resume() }
        continuation.yield(.disconnected(reason: reason, at: time))
        continuation.finish()
    }

    func write(_ bytes: [UInt8], characteristic: String, withResponse: Bool) async throws {
        let key = UUIDs.normalize(characteristic)
        guard let c = characteristics[key] else { throw LinkError.characteristicNotFound(key) }
        if lock.withLock({ closed }) { throw LinkError.notConnected }
        let maxLength = peripheral.maximumWriteValueLength(for: withResponse ? .withResponse : .withoutResponse)
        guard bytes.count <= maxLength else { throw LinkError.writeFailed("command of \(bytes.count) bytes exceeds the link limit of \(maxLength)") }
        let data = Data(bytes)
        if withResponse {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let accepted = lock.withLock { () -> Bool in
                    if closed { return false }
                    pendingWrites[key, default: []].append(cont)
                    return true
                }
                guard accepted else {
                    cont.resume(throwing: LinkError.notConnected)
                    return
                }
                queue.async { self.peripheral.writeValue(data, for: c, type: .withResponse) }
            }
        } else {
            while !peripheral.canSendWriteWithoutResponse {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let accepted = lock.withLock { () -> Bool in
                        if closed { return false }
                        waitingForWriteWindow.append(cont)
                        return true
                    }
                    if !accepted { cont.resume() }
                }
                if lock.withLock({ closed }) { throw LinkError.notConnected }
            }
            queue.async { self.peripheral.writeValue(data, for: c, type: .withoutResponse) }
        }
    }

    /// Called on the BLE queue from `didWriteValueFor`.
    func completeWrite(characteristic: String, error: Error?) {
        let waiter: CheckedContinuation<Void, Error>? = lock.withLock {
            guard var list = pendingWrites[characteristic], !list.isEmpty else { return nil }
            let first = list.removeFirst()
            pendingWrites[characteristic] = list
            return first
        }
        guard let waiter else { return }
        if let error {
            waiter.resume(throwing: BLECentral.isPairingError(error) ? LinkError.pairingRequired : LinkError.writeFailed(error.localizedDescription))
        } else {
            waiter.resume()
        }
    }

    /// Called on the BLE queue from `peripheralIsReady(toSendWriteWithoutResponse:)`.
    func readyForWriteWithoutResponse() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let w = waitingForWriteWindow
            waitingForWriteWindow.removeAll()
            return w
        }
        for w in waiters { w.resume() }
    }
}
