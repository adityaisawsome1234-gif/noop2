import Foundation
import FormaCore

/// Checks a backup file before it is imported into the user's own (live) data.
///
/// Demo data is synthetic and must never be mixed with live records (PRD §7). A backup exported while
/// Demo mode was active by an earlier build contains the demo database, so a file with any demo record
/// — the `.demo` source, the demo band, or the demo band's sessions — is refused as a whole.
enum BackupInspector {
    static let chunkSize = 1 << 20
    /// The importer skips longer lines without reading them; so does this scan.
    static let maxLineBytes = 1 << 20

    private static let demoDeviceToken = Array("\"\(DemoDataGenerator.deviceID)\"".utf8)
    private static let sourceKeyToken = Array("\"source\"".utf8)

    /// True when the file contains a demo record. Streams the file; memory use is bounded.
    static func containsDemoData(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var line: [UInt8] = []
        var skippingLongLine = false
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            for byte in chunk {
                if byte == 0x0A {
                    if !skippingLongLine, isDemoRecord(line) { return true }
                    line.removeAll(keepingCapacity: true)
                    skippingLongLine = false
                } else if !skippingLongLine {
                    if line.count >= maxLineBytes {
                        skippingLongLine = true
                        line.removeAll(keepingCapacity: true)
                    } else {
                        line.append(byte)
                    }
                }
            }
        }
        return !skippingLongLine && isDemoRecord(line)
    }

    /// One NDJSON record line: `{"type":…,"data":{…}}`.
    static func isDemoRecord(_ line: [UInt8]) -> Bool {
        if hasDemoSource(line) { return true }
        guard index(of: demoDeviceToken, in: line, from: 0) != nil,
              let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let data = object["data"] as? [String: Any] else { return false }
        if data["device_id"] as? String == DemoDataGenerator.deviceID { return true }
        return object["type"] as? String == "device" && data["id"] as? String == DemoDataGenerator.deviceID
    }

    /// A `"source"` key whose value is the demo source code (whitespace tolerated).
    static func hasDemoSource(_ line: [UInt8]) -> Bool {
        var from = 0
        while let start = index(of: sourceKeyToken, in: line, from: from) {
            from = start + 1
            var i = start + sourceKeyToken.count
            while i < line.count, isWhitespace(line[i]) { i += 1 }
            guard i < line.count, line[i] == UInt8(ascii: ":") else { continue }
            i += 1
            while i < line.count, isWhitespace(line[i]) { i += 1 }
            var value = 0
            var digits = 0
            while i < line.count, digits < 6, line[i] >= UInt8(ascii: "0"), line[i] <= UInt8(ascii: "9") {
                value = value * 10 + Int(line[i] - UInt8(ascii: "0"))
                i += 1
                digits += 1
            }
            let continues = i < line.count && (line[i] >= UInt8(ascii: "0") && line[i] <= UInt8(ascii: "9")
                || line[i] == UInt8(ascii: ".") || line[i] == UInt8(ascii: "e") || line[i] == UInt8(ascii: "E"))
            if digits > 0, !continues, value == MeasurementSource.demo.rawValue { return true }
        }
        return false
    }

    private static func isWhitespace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0D }

    private static func index(of token: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard !token.isEmpty, bytes.count >= token.count, from <= bytes.count - token.count else { return nil }
        var i = from
        let last = bytes.count - token.count
        while i <= last {
            if bytes[i] == token[0] {
                var j = 1
                while j < token.count, bytes[i + j] == token[j] { j += 1 }
                if j == token.count { return i }
            }
            i += 1
        }
        return nil
    }
}
