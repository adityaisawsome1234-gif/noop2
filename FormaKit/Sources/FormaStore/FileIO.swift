import Foundation
import FormaCore

// MARK: - Buffered writing

/// Appends UTF-8 text to a new file in large chunks (streaming: memory stays bounded by the buffer).
final class BufferedFileWriter {
    let url: URL
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private let flushThreshold: Int
    private var isClosed = false
    /// Bytes handed to the file so far (excluding what is still buffered).
    private(set) var bytesFlushed: Int64 = 0

    /// Creates the file at `url`, replacing an existing regular file (never a directory).
    init(url: URL, flushThreshold: Int = 256 * 1_024) throws {
        self.url = url
        self.flushThreshold = max(1, flushThreshold)
        let path = url.path(percentEncoded: false)
        try FileOps.removeRegularFile(atPath: path)
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw StoreError.fileError("cannot create \(path)")
        }
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(self.flushThreshold)
    }

    deinit { abandon() }

    func write(_ text: String) throws {
        buffer.append(contentsOf: text.utf8)
        if buffer.count >= flushThreshold { try flush() }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        bytesFlushed += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
    }

    /// Flushes, forces the bytes to stable storage and closes the file.
    func finish() throws {
        try flush()
        try handle.synchronize()
        try handle.close()
        isClosed = true
    }

    /// Closes without guaranteeing anything about the content (error paths).
    func abandon() {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }
}

/// Writes a file through a temporary `<name>.partial` sibling that replaces the destination only
/// after everything was written and synced, so a failed export never leaves a truncated file under
/// the final name. Missing parent directories are created; an existing directory at the destination
/// is refused, never removed.
enum AtomicFile {
    static func write(to url: URL, _ body: (BufferedFileWriter) throws -> Void) throws -> Int64 {
        let destination = url.path(percentEncoded: false)
        if FileOps.isDirectory(atPath: destination) {
            throw StoreError.fileError("\(destination) is a directory")
        }
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw StoreError.fileError("cannot create \(parent.path(percentEncoded: false)): \(error.localizedDescription)")
        }
        let temporary = url.appendingPathExtension("partial")
        let writer = try BufferedFileWriter(url: temporary)
        do {
            try body(writer)
            try writer.finish()
            try FileOps.removeRegularFile(atPath: destination)
            try FileManager.default.moveItem(at: temporary, to: url)
            return writer.bytesFlushed
        } catch {
            writer.abandon()
            try? FileOps.removeRegularFile(atPath: temporary.path(percentEncoded: false))
            throw error
        }
    }
}

enum FileOps {
    static func isDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Deletes `path` if it is a file; does nothing if it does not exist; refuses directories.
    static func removeRegularFile(atPath path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue { throw StoreError.fileError("\(path) is a directory") }
        try FileManager.default.removeItem(atPath: path)
    }
}

// MARK: - Bounded line reading

/// Reads a file line by line (LF-terminated, a CR before the LF is dropped) without ever holding
/// more than `maxLineBytes` plus one read chunk in memory. Over-long lines are skipped while being
/// read and reported as `.tooLong`, never loaded.
final class BoundedLineReader {
    enum Line {
        case text([UInt8])
        case tooLong(byteCount: Int)
    }

    private let handle: FileHandle
    private let maxLineBytes: Int
    private let chunkSize: Int
    private var buffer: [UInt8] = []
    private var start = 0          // first unconsumed byte in `buffer`
    private var scanFrom = 0       // bytes before this index (from `start`) contain no LF
    private var reachedEOF = false
    private var discarding = false // inside an over-long line
    private var discardedBytes = 0

    init(url: URL, maxLineBytes: Int, chunkSize: Int = 64 * 1_024) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.maxLineBytes = max(1, maxLineBytes)
        self.chunkSize = max(1, chunkSize)
    }

    deinit { try? handle.close() }

    func next() throws -> Line? {
        while true {
            if let newline = buffer[scanFrom...].firstIndex(of: 0x0A) {
                let lineEnd = newline
                defer {
                    start = newline + 1
                    scanFrom = start
                }
                if discarding {
                    let total = discardedBytes + (lineEnd - start)
                    discarding = false
                    discardedBytes = 0
                    return .tooLong(byteCount: total)
                }
                var end = lineEnd
                if end > start, buffer[end - 1] == 0x0D { end -= 1 }
                if end - start > maxLineBytes { return .tooLong(byteCount: end - start) }
                return .text(Array(buffer[start..<end]))
            }
            // No LF in the unconsumed bytes.
            let pending = buffer.count - start
            if discarding {
                discardedBytes += pending
                dropAll()
            } else if pending > maxLineBytes + 1 {
                // +1 tolerates the CR of a CRLF ending on a line of exactly maxLineBytes.
                discarding = true
                discardedBytes = pending
                dropAll()
            } else {
                scanFrom = buffer.count
            }
            if reachedEOF {
                if discarding {
                    let total = discardedBytes
                    discarding = false
                    discardedBytes = 0
                    return .tooLong(byteCount: total)
                }
                guard buffer.count > start else { return nil }
                var end = buffer.count
                if buffer[end - 1] == 0x0D { end -= 1 }
                let line = Array(buffer[start..<end])
                dropAll()
                return line.count > maxLineBytes ? .tooLong(byteCount: line.count) : .text(line)
            }
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                reachedEOF = true
                continue
            }
            if start > 0 {
                buffer.removeFirst(start)
                scanFrom -= start
                start = 0
            }
            buffer.append(contentsOf: chunk)
        }
    }

    private func dropAll() {
        buffer.removeAll(keepingCapacity: true)
        start = 0
        scanFrom = 0
    }
}

// MARK: - Text formatting

/// Locale-independent formatting used by CSV and backup output.
enum TextFormat {
    /// `YYYY-MM-DDTHH:MM:SS.mmmZ` (UTC, proleptic Gregorian) for any epoch-millisecond value. Years
    /// outside 0...9999 are written with a sign and at least six digits, as ECMAScript does.
    static func iso8601UTC(_ millis: EpochMillis) -> String {
        let millisPerDay: Int64 = 86_400_000
        var days = millis / millisPerDay
        var millisOfDay = millis % millisPerDay
        if millisOfDay < 0 {
            millisOfDay += millisPerDay
            days -= 1
        }
        // civil_from_days (H. Hinnant); no intermediate value can overflow for any Int64 input.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)

        let yearText: String
        if (0...9_999).contains(year) {
            yearText = pad(year, 4)
        } else {
            yearText = (year < 0 ? "-" : "+") + pad(year.magnitude, 6)
        }
        return yearText + "-" + pad(month, 2) + "-" + pad(day, 2)
            + "T" + pad(millisOfDay / 3_600_000, 2) + ":" + pad(millisOfDay / 60_000 % 60, 2)
            + ":" + pad(millisOfDay / 1_000 % 60, 2) + "." + pad(millisOfDay % 1_000, 3) + "Z"
    }

    private static func pad<T: BinaryInteger>(_ value: T, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    /// Shortest round-trip decimal form (`812.5`, `1e-05`); nil for NaN/±∞, which have no number syntax.
    static func number(_ value: Double) -> String? {
        value.isFinite ? String(describing: value) : nil
    }

    /// A JSON string literal (quotes included) for `text`.
    static func jsonString(_ text: String) -> String {
        var out = "\""
        out.reserveCapacity(text.utf8.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
