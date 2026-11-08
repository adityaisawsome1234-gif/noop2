import Foundation
import FormaCore

/// Decides whether a decoded-but-unvalidated field may be used in metrics, using independent evidence
/// recorded at the same time. A field is never "validated" merely because it decodes.
public struct FieldValidationResult: Hashable, Sendable, Codable {
    public var status: CheckStatus
    public var overlappingMinutes: Int
    public var medianAbsoluteDifference: Double?
    public var detail: String

    public init(status: CheckStatus, overlappingMinutes: Int, medianAbsoluteDifference: Double?, detail: String) {
        self.status = status
        self.overlappingMinutes = overlappingMinutes
        self.medianAbsoluteDifference = medianAbsoluteDifference
        self.detail = detail
    }
}

public enum FieldValidator {
    /// Settings key under which a passed validation is recorded, per adapter and firmware: a firmware
    /// change requires validating again.
    public static func historyHeartRateKey(adapterID: String, firmware: String?) -> String {
        "fieldValidation.historyHR.\(adapterID).\(firmware ?? "unknown-firmware")"
    }

    /// Compares band-history heart rate (unvalidated) with live heart rate from an independent, documented
    /// source (Bluetooth SIG Heart Rate Service) for the same minutes.
    /// - Passes when ≥ `minimumMinutes` minutes overlap and the median absolute difference of per-minute
    ///   means is ≤ `maxMedianAbsoluteDifference` bpm.
    /// - Fails when enough minutes overlap but values disagree (the field is probably not heart rate).
    /// - Otherwise the result is unverified (not enough overlap yet).
    public static func historyHeartRateAgreement(history: [HeartRateSample], live: [HeartRateSample],
                                                 minimumMinutes: Int = 10, maxMedianAbsoluteDifference: Double = 3) -> FieldValidationResult {
        func perMinute(_ samples: [HeartRateSample]) -> [Int64: Double] {
            var sums: [Int64: (Double, Int)] = [:]
            for s in samples where HeartRateSample.plausibleRange.contains(s.bpm)
                && !s.quality.contains(.clockUnmapped) && !s.quality.contains(.noSensorContact) {
                let minute = s.timestamp / 60_000
                let current = sums[minute] ?? (0, 0)
                sums[minute] = (current.0 + Double(s.bpm), current.1 + 1)
            }
            return sums.mapValues { $0.0 / Double($0.1) }
        }
        let h = perMinute(history.filter { $0.source == .deviceHistory })
        let l = perMinute(live.filter { $0.source == .standardHeartRateService })
        let shared = Set(h.keys).intersection(l.keys)
        guard shared.count >= minimumMinutes else {
            return FieldValidationResult(status: .unverified, overlappingMinutes: shared.count, medianAbsoluteDifference: nil,
                                         detail: "Needs at least \(minimumMinutes) minutes where band history and live standard heart rate overlap (have \(shared.count)).")
        }
        let diffs = shared.compactMap { m -> Double? in
            guard let a = h[m], let b = l[m] else { return nil }
            return abs(a - b)
        }.sorted()
        let median = diffs.count % 2 == 1 ? diffs[diffs.count / 2] : (diffs[diffs.count / 2 - 1] + diffs[diffs.count / 2]) / 2
        if median <= maxMedianAbsoluteDifference {
            return FieldValidationResult(status: .passed, overlappingMinutes: shared.count, medianAbsoluteDifference: median,
                                         detail: "Band history heart rate agrees with live heart rate (median difference \(DisplayFormat.number(median, digits: 1)) bpm over \(shared.count) minutes).")
        }
        return FieldValidationResult(status: .failed, overlappingMinutes: shared.count, medianAbsoluteDifference: median,
                                     detail: "Band history values do not match live heart rate (median difference \(DisplayFormat.number(median, digits: 1)) bpm over \(shared.count) minutes). Forma keeps them as unvalidated evidence and does not use them.")
    }
}
