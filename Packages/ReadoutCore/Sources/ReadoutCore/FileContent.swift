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
