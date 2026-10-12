import Foundation

/// Decodes file bytes and decides whether a freshly observed write looks complete.
public enum FileContent {
    public struct Decoded: Sendable, Equatable {
        public let text: String
        /// Name of a non-UTF-8 encoding that was used, if any.
        public let fallbackEncoding: String?
        /// The file ended in the middle of a UTF-8 sequence (likely still being written).
        public let truncatedTail: Bool
    }

    public static func decode(_ data: Data) -> Decoded {
        if let utf16 = decodeUTF16(data) { return utf16 }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let s = String(data: bytes, encoding: .utf8) {
            return Decoded(text: s, fallbackEncoding: nil, truncatedTail: false)
        }
        // Incomplete multi-byte sequence at the end: decode the valid prefix.
        for cut in 1...3 where bytes.count > cut {
            if let s = String(data: bytes.dropLast(cut), encoding: .utf8) {
                return Decoded(text: s, fallbackEncoding: nil, truncatedTail: true)
            }
        }
        #if canImport(Darwin)
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: bytes, encoding: gb) {
            return Decoded(text: s, fallbackEncoding: "GB18030", truncatedTail: false)
        }
        #endif
        let s = String(decoding: bytes, as: UTF8.self)
        return Decoded(text: s, fallbackEncoding: "UTF-8 (with replacement characters)", truncatedTail: false)
    }

    /// UTF-16 text (what Windows tools and PowerShell redirection write): with
    /// a byte order mark, or without one when the high bytes of mostly-ASCII
    /// text are zero (UTF-8 text never holds NUL bytes like that).
    static func decodeUTF16(_ data: Data) -> Decoded? {
        let b = [UInt8](data.prefix(4096))
        let bigEndian: Bool
        var body = data
        if b.count >= 2 && b[0] == 0xFF && b[1] == 0xFE {
            bigEndian = false; body = data.dropFirst(2)
        } else if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF {
            bigEndian = true; body = data.dropFirst(2)
        } else {
            guard b.count >= 4 else { return nil }
            var zeroEven = 0, zeroOdd = 0
            for (i, v) in b.enumerated() where v == 0 { if i % 2 == 0 { zeroEven += 1 } else { zeroOdd += 1 } }
            let pairs = b.count / 2
            if zeroOdd * 10 >= pairs * 3 && zeroEven * 10 <= zeroOdd { bigEndian = false }
            else if zeroEven * 10 >= pairs * 3 && zeroOdd * 10 <= zeroEven { bigEndian = true }
            else { return nil }
        }
        // An odd byte at the end: still being written.
        let truncated = body.count % 2 == 1
        if truncated { body = body.dropLast() }
        var units: [UInt16] = []
        units.reserveCapacity(body.count / 2)
        var it = body.makeIterator()
        while let x = it.next(), let y = it.next() {
            units.append(bigEndian ? UInt16(x) << 8 | UInt16(y) : UInt16(y) << 8 | UInt16(x))
        }
        // A high surrogate at the end waits for its pair: also still being written.
        var cut = truncated
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast(); cut = true }
        let text = String(decoding: units, as: UTF16.self)
        return Decoded(text: text, fallbackEncoding: bigEndian ? "UTF-16BE" : "UTF-16LE", truncatedTail: cut)
    }

    public enum WriteVerdict: Equatable, Sendable { case accept, waitForMore }

    /// Heuristic for half-written files: an empty or sharply shrunken file shortly after a previous write,
    /// or a truncated UTF-8 tail, is probably mid-write. Callers retry a bounded number of times.
    public static func verdict(newSize: Int, previousSize: Int?, secondsSincePreviousWrite: Double?,
                               truncatedTail: Bool, retriesSoFar: Int, maxRetries: Int = 2) -> WriteVerdict {
        if retriesSoFar >= maxRetries { return .accept }
        if truncatedTail { return .waitForMore }
        guard let prev = previousSize, prev > 0 else { return .accept }
        let recent = (secondsSincePreviousWrite ?? .infinity) < 1.0
        if newSize == 0 { return .waitForMore }
        if recent && Double(newSize) < Double(prev) * 0.5 { return .waitForMore }
        return .accept
    }
}
