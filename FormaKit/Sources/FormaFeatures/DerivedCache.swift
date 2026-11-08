import Foundation
import FormaCore
import FormaStore

/// Orders writes of cached daily values against invalidations of that cache.
///
/// A screen computation reads measurements and sessions, computes a past day's value and caches it.
/// If new records for that day arrive, or a sleep window is corrected, while the computation runs, its
/// result is already stale: writing it afterwards would keep the stale value forever. Every
/// invalidation therefore goes through `invalidate(_:_:)`, and a computation writes through
/// `write(window:computedAt:_:)` only when nothing overlapping its window was invalidated after the
/// epoch it started at (`currentEpoch`, read before it read any data). Both run under one lock, so an
/// invalidation either happens after the write (and deletes it) or blocks it.
public final class DerivedCacheGate: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var log: [(epoch: UInt64, range: TimeRange)] = []
    /// Invalidations up to this epoch are no longer in `log` (it is bounded).
    private var forgottenThrough: UInt64 = 0
    static let logLimit = 512

    public init() {}

    /// The epoch to pass to `write(window:computedAt:_:)` for a computation starting now.
    public var currentEpoch: UInt64 { lock.withLock { epoch } }

    /// Records an invalidation of cached values overlapping `range` and runs `body` (which deletes them).
    @discardableResult
    public func invalidate<T>(_ range: TimeRange, _ body: () throws -> T) rethrows -> T {
        try lock.withLock {
            epoch &+= 1
            log.append((epoch, range))
            if log.count > Self.logLimit {
                let drop = log.count - Self.logLimit
                forgottenThrough = log[drop - 1].epoch
                log.removeFirst(drop)
            }
            return try body()
        }
    }

    /// Runs `body` (a cache write for `window`) only when no invalidation overlapping `window` happened
    /// after `since`. Returns whether it ran.
    @discardableResult
    public func write(window: TimeRange, computedAt since: UInt64, _ body: () throws -> Void) rethrows -> Bool {
        try lock.withLock {
            if since < forgottenThrough { return false }
            if log.contains(where: { $0.epoch > since && $0.range.overlaps(window) }) { return false }
            try body()
            return true
        }
    }
}

/// Field-validation key (adapter and firmware, see `FieldValidator.historyHeartRateKey`) of each ingest
/// batch, read from the batch's provenance. Provenance never changes once written, so entries stay valid
/// for the lifetime of one store; use a new cache for a new store.
public final class BatchValidationKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [Int64: String] = [:]

    public init() {}

    /// The key of the batch that stored a record, or nil when the batch is unknown.
    public func key(for batchID: Int64?, in store: FormaStore) -> String? {
        guard let batchID else { return nil }
        if let known = lock.withLock({ keys[batchID] }) { return known }
        guard let provenance = (try? store.provenance(batchID: batchID)) ?? nil else { return nil }
        let key = FieldValidator.historyHeartRateKey(adapterID: provenance.adapterID, firmware: provenance.firmwareVersion)
        lock.withLock { keys[batchID] = key }
        return key
    }
}

/// Which band-history heart rate may enter metrics. History heart rate is decoded from a field whose
/// meaning must be validated per adapter and firmware (`FieldValidator`) before Forma uses it.
public enum HistoryHeartRatePolicy: Sendable {
    /// None of it.
    case none
    /// All of it: the caller established that it is valid (tests, replay tools).
    case all
    /// Only records from ingest batches whose adapter-and-firmware key passed validation. Used only
    /// while the band's current firmware has passed too: a firmware update requires validating again.
    case validatedBatches(passedKeys: Set<String>, cache: BatchValidationKeyCache)

    /// Stable description for cache fingerprints.
    var fingerprint: String {
        switch self {
        case .none: return "none"
        case .all: return "all"
        case .validatedBatches(let keys, _): return "batches[" + keys.sorted().joined(separator: ",") + "]"
        }
    }
}

/// A flag a running computation polls to stop early once its result is no longer wanted.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}
