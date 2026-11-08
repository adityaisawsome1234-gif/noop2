import Foundation
import FormaCore

/// A diagnostic capture: every BLE notification received (and every command written) during a
/// session, with timestamps. The app exports these from the Diagnostics screen; `forma-replay` and the
/// test suite feed them through the exact same decode → normalize → ingest pipeline as live data.
///
/// Format: JSON Lines (UTF-8). Line 1 is a `CaptureHeader`; every following line is a `CaptureEntry`.
/// Bytes are lowercase hex. The format is versioned; readers reject newer major versions.
public struct CaptureHeader: Codable, Hashable, Sendable {
    public static let formatName = "forma-capture"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var createdAt: EpochMillis
    public var deviceFamily: DeviceFamily
    public var deviceName: String?
    public var firmwareVersion: String?
    public var adapterID: String?
    public var parserVersion: String?
    public var appVersion: String?
    public var phoneOS: String?
    public var note: String?

    public init(createdAt: EpochMillis, deviceFamily: DeviceFamily, deviceName: String? = nil,
                firmwareVersion: String? = nil, adapterID: String? = nil, parserVersion: String? = nil,
                appVersion: String? = nil, phoneOS: String? = nil, note: String? = nil) {
        self.format = Self.formatName
        self.version = Self.currentVersion
        self.createdAt = createdAt
        self.deviceFamily = deviceFamily
        self.deviceName = deviceName
        self.firmwareVersion = firmwareVersion
        self.adapterID = adapterID
        self.parserVersion = parserVersion
        self.appVersion = appVersion
        self.phoneOS = phoneOS
        self.note = note
    }
}

public struct CaptureEntry: Codable, Hashable, Sendable {
    public enum Direction: String, Codable, Sendable {
        /// Notification/indication or read value received from the band.
        case rx
        /// Command bytes written to the band.
        case tx
        /// Link event (connect/disconnect) with no bytes; `note` describes it.
        case event
    }

    /// Phone time when the bytes were received/sent.
    public var t: EpochMillis
    public var dir: Direction
    /// Characteristic UUID string (uppercase canonical form), or empty for events.
    public var c: String
    /// Lowercase hex payload.
    public var d: String
    public var note: String?

    public init(t: EpochMillis, dir: Direction, c: String, d: String, note: String? = nil) {
        self.t = t
        self.dir = dir
        self.c = c
        self.d = d
        self.note = note
    }
}

public enum CaptureFileError: Error, Equatable, Sendable {
    case emptyFile
    case notACapture
    case unsupportedVersion(Int)
    case invalidEntry(line: Int, reason: String)
    case lineTooLong(line: Int)
}

public struct CaptureFile: Sendable {
    public var header: CaptureHeader
    public var entries: [CaptureEntry]

    public init(header: CaptureHeader, entries: [CaptureEntry]) {
        self.header = header
        self.entries = entries
    }

    /// Maximum accepted line length (bytes) — bounds memory when reading untrusted files.
    public static let maxLineBytes = 256 * 1024
    /// Entry times outside this range (ms since 1970 up to 2100-01-01) are rejected as malformed.
    public static let plausibleTimes: ClosedRange<EpochMillis> = 0...4_102_444_800_000

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var out = Data()
        out.append(try encoder.encode(header))
        out.append(0x0A)
        for e in entries {
            out.append(try encoder.encode(e))
            out.append(0x0A)
        }
        return out
    }

    /// Parses a capture. Malformed entry lines are reported as errors in `strict` mode and skipped
    /// (with their line numbers returned) otherwise.
    public static func decode(_ data: Data, strict: Bool = false) throws -> (file: CaptureFile, skippedLines: [Int]) {
        let decoder = JSONDecoder()
        var lines: [Data] = []
        var start = data.startIndex
        var lineNumber = 0
        for i in data.indices where data[i] == 0x0A {
            lineNumber += 1
            if i - start > maxLineBytes { throw CaptureFileError.lineTooLong(line: lineNumber) }
            lines.append(data[start..<i])
            start = data.index(after: i)
        }
        if start < data.endIndex {
            lineNumber += 1
            if data.endIndex - start > maxLineBytes { throw CaptureFileError.lineTooLong(line: lineNumber) }
            lines.append(data[start..<data.endIndex])
        }
        let nonEmpty = lines.enumerated().filter { !$0.element.allSatisfy { $0 == 0x20 || $0 == 0x0D || $0 == 0x09 } }
        guard let first = nonEmpty.first else { throw CaptureFileError.emptyFile }
        guard let header = try? decoder.decode(CaptureHeader.self, from: first.element),
              header.format == CaptureHeader.formatName else {
            throw CaptureFileError.notACapture
        }
        guard header.version <= CaptureHeader.currentVersion else {
            throw CaptureFileError.unsupportedVersion(header.version)
        }
        var entries: [CaptureEntry] = []
        var skipped: [Int] = []
        for (index, line) in nonEmpty.dropFirst() {
            do {
                let entry = try decoder.decode(CaptureEntry.self, from: line)
                guard HexCodec.decode(entry.d) != nil else {
                    throw CaptureFileError.invalidEntry(line: index + 1, reason: "payload is not ASCII hex")
                }
                guard Self.plausibleTimes.contains(entry.t) else {
                    throw CaptureFileError.invalidEntry(line: index + 1, reason: "time \(entry.t) outside 1970–2100")
                }
                entries.append(entry)
            } catch {
                if strict {
                    if let e = error as? CaptureFileError { throw e }
                    throw CaptureFileError.invalidEntry(line: index + 1, reason: "invalid JSON entry")
                }
                skipped.append(index + 1)
            }
        }
        return (CaptureFile(header: header, entries: entries), skipped)
    }
}

/// Collects a bounded capture in memory during a diagnostics session. Recording is O(1): a ring
/// buffer keeps the newest `maxEntries` entries.
public final class CaptureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [CaptureEntry] = []
    private var head = 0          // index of the oldest entry once the ring is full
    private var droppedCount = 0
    public let maxEntries: Int

    public init(maxEntries: Int = 50_000) {
        self.maxEntries = max(1, maxEntries)
    }

    public func record(_ entry: CaptureEntry) {
        lock.lock(); defer { lock.unlock() }
        if ring.count < maxEntries {
            ring.append(entry)
        } else {
            ring[head] = entry
            head = (head + 1) % maxEntries
            droppedCount += 1
        }
    }

    /// Entries currently held (cheap; for UI counters).
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return ring.count
    }

    public var dropped: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedCount
    }

    public func snapshot(header: CaptureHeader) -> CaptureFile {
        lock.lock(); defer { lock.unlock() }
        let ordered = head == 0 ? ring : Array(ring[head...] + ring[..<head])
        return CaptureFile(header: header, entries: ordered)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        ring.removeAll()
        head = 0
        droppedCount = 0
    }
}
