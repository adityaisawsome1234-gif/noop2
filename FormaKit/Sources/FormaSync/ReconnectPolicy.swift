import Foundation

/// Decides when to retry a connection. On iOS a pending `connect()` never times out, so after a normal
/// disconnect Forma re-issues the connect immediately and lets iOS wait for the band. Backoff applies only
/// when connection attempts themselves fail (errors), to avoid hammering a band that rejects the link.
public struct ReconnectPolicy: Sendable {
    public var initialDelaySeconds: Double
    public var maxDelaySeconds: Double
    public var multiplier: Double
    /// Fractional jitter (0.2 = ±20%) applied by `delay(afterFailures:jitterUnit:)`.
    public var jitter: Double

    public init(initialDelaySeconds: Double = 2, maxDelaySeconds: Double = 300, multiplier: Double = 2, jitter: Double = 0.2) {
        self.initialDelaySeconds = max(0, initialDelaySeconds)
        self.maxDelaySeconds = max(self.initialDelaySeconds, maxDelaySeconds)
        self.multiplier = max(1, multiplier)
        self.jitter = min(max(0, jitter), 0.9)
    }

    /// Delay before retrying after `consecutiveFailures` failed attempts (0 = retry immediately).
    /// `jitterUnit` in [0, 1) selects the jitter deterministically (tests pass fixed values).
    public func delay(afterFailures consecutiveFailures: Int, jitterUnit: Double) -> Double {
        guard consecutiveFailures > 0 else { return 0 }
        let exponent = Double(min(consecutiveFailures - 1, 30))
        let base = min(maxDelaySeconds, initialDelaySeconds * pow(multiplier, exponent))
        let unit = min(max(jitterUnit, 0), 0.999_999)
        let factor = 1 + jitter * (2 * unit - 1)
        return min(maxDelaySeconds, max(0, base * factor))
    }
}

/// 8-bit command sequence numbers with wraparound (0…255, then 0 again).
public struct SequenceCounter: Sendable {
    public private(set) var value: UInt8

    public init(start: UInt8 = 0) { value = start }

    /// Returns the next sequence number, wrapping from 255 to 0.
    public mutating func next() -> UInt8 {
        value = value &+ 1
        return value
    }
}
