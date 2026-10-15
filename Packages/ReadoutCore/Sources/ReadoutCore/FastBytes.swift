import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Byte searches over a string's UTF-8 with `memchr` (native strings are
/// contiguous UTF-8). The update path scans every line of a document several
/// times; a byte loop through `String.UTF8View` costs several times more.
enum FastBytes {
    /// The string contains `byte`.
    @inline(__always)
    static func contains(_ s: String, _ byte: UInt8) -> Bool {
        if let r = s.utf8.withContiguousStorageIfAvailable({ buf -> Bool in
            guard let base = buf.baseAddress, buf.count > 0 else { return false }
            return memchr(base, Int32(byte), buf.count) != nil
        }) { return r }
        return s.utf8.contains(byte)
    }

    /// The string contains the two bytes `a`, `b` in a row.
    @inline(__always)
    static func contains(_ s: String, _ a: UInt8, _ b: UInt8) -> Bool {
        if let r = s.utf8.withContiguousStorageIfAvailable({ buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            let n = buf.count
            var i = 0
            while i < n - 1 {
                guard let p = memchr(base + i, Int32(a), n - 1 - i) else { return false }
                let k = base.distance(to: p.assumingMemoryBound(to: UInt8.self))
                if buf[k + 1] == b { return true }
                i = k + 1
            }
            return false
        }) { return r }
        var previous: UInt8 = 0
        for x in s.utf8 { if x == b && previous == a { return true }; previous = x }
        return false
    }

    /// The lines of `s` as substrings of it, split at LF (a trailing LF gives
    /// a last empty line). The same as splitting on the Character "\n" for
    /// text with LF line endings (what the parser works on: a CR LF pair is
    /// one Character, so it would not split there), without running grapheme
    /// breaking over every line.
    static func lineSlices(_ s: String) -> [Substring] {
        var s = s
        s.makeContiguousUTF8()
        let offsets = s.utf8.withContiguousStorageIfAvailable { buf -> [Int] in
            guard let base = buf.baseAddress else { return [] }
            var out: [Int] = []
            let n = buf.count
            var start = 0
            while start < n, let p = memchr(base + start, 0x0A, n - start) {
                let k = base.distance(to: p.assumingMemoryBound(to: UInt8.self))
                out.append(k)
                start = k + 1
            }
            return out
        } ?? s.utf8.indices.filter { s.utf8[$0] == 0x0A }.map { s.utf8.distance(from: s.utf8.startIndex, to: $0) }
        var out: [Substring] = []
        out.reserveCapacity(offsets.count + 1)
        let u = s.utf8
        var start = u.startIndex
        for k in offsets {
            let end = u.index(u.startIndex, offsetBy: k)
            out.append(Substring(u[start..<end]))
            start = u.index(after: end)
        }
        out.append(Substring(u[start...]))
        return out
    }

    /// The text may hold a task checkbox: `[`, a space, `x` or `X`, then `]`
    /// (what cmark-gfm's tasklist extension accepts). False means it holds none.
    static func mayHaveCheckbox(_ s: String) -> Bool {
        guard contains(s, 0x5B) else { return false }   // [
        var p2: UInt8 = 0, p1: UInt8 = 0   // the two bytes before c
        for c in s.utf8 {
            if c == 0x5D && p2 == 0x5B && (p1 == 0x20 || p1 == 0x78 || p1 == 0x58) { return true }
            p2 = p1; p1 = c
        }
        return false
    }

    /// The lines of `s`, split at LF (a trailing LF gives a last empty line).
    static func lines(_ s: String) -> [String] {
        var s = s
        s.makeContiguousUTF8()
        return s.utf8.withContiguousStorageIfAvailable { buf -> [String] in
            guard let base = buf.baseAddress else { return [""] }
            var out: [String] = []
            let n = buf.count
            var start = 0
            while true {
                if let p = memchr(base + start, 0x0A, n - start) {
                    let k = base.distance(to: p.assumingMemoryBound(to: UInt8.self))
                    out.append(String(decoding: UnsafeBufferPointer(start: base + start, count: k - start), as: UTF8.self))
                    start = k + 1
                } else {
                    out.append(String(decoding: UnsafeBufferPointer(start: base + start, count: n - start), as: UTF8.self))
                    return out
                }
            }
        } ?? s.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { String(Substring($0)) }
    }
}
