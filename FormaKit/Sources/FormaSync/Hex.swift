import Foundation

/// Hex text ⇄ bytes, shared by capture files, replay and the CLI so they accept exactly the same input.
public enum HexCodec {
    private static let digits: [UInt8] = Array("0123456789abcdef".utf8)

    /// Lowercase hex, no separators.
    public static func encode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Strict: an even number of ASCII hex digits (either case) and nothing else. Nil otherwise.
    public static func decode(_ hex: String) -> [UInt8]? {
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

    /// For hand-written input: hex digits separated by any of whitespace, commas, colons or dashes, each
    /// group optionally prefixed with `0x`/`0X`. A group must have an even number of digits. Any other
    /// character makes the whole input invalid (nil) — nothing is silently dropped.
    public static func decodeLoose(_ text: String) -> [UInt8]? {
        var out: [UInt8] = []
        let separators: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x3A, 0x2D]
        let utf8 = Array(text.utf8)
        var i = 0
        while i < utf8.count {
            if separators.contains(utf8[i]) { i += 1; continue }
            var j = i
            if j + 1 < utf8.count, utf8[j] == 0x30, utf8[j + 1] == 0x78 || utf8[j + 1] == 0x58 { j += 2 }
            let groupStart = j
            while j < utf8.count, !separators.contains(utf8[j]) { j += 1 }
            let group = utf8[groupStart..<j]
            guard !group.isEmpty, group.count % 2 == 0 else { return nil }
            var k = group.startIndex
            while k < group.endIndex {
                guard let hi = nibble(group[k]), let lo = nibble(group[k + 1]) else { return nil }
                out.append(hi << 4 | lo)
                k += 2
            }
            i = j
        }
        return out
    }

    static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
}
