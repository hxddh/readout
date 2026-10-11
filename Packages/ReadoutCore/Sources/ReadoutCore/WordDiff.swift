import Foundation

/// What changed inside a modified block: a word-level comparison of its
/// normalized Markdown source with the text the reader last saw.
///
/// Source, not rendered HTML: a diff of HTML breaks apart on tables, math
/// and code, while the source compares the same way for every kind of block.
/// Tokens are CJK characters one by one, runs of letters and digits, runs of
/// white space, and every other character on its own.
public enum WordDiff {
    public enum Segment: Equatable, Sendable {
        case equal(String)
        case deleted(String)
        case inserted(String)
    }

    /// Above this many tokens on either side, lines are compared instead.
    static let maxTokens = 6000
    /// Unchanged runs longer than this are shortened to their ends.
    static let maxEqual = 160
    static let keepEqual = 60

    public static func segments(old: String, new: String) -> [Segment] {
        if old == new { return old.isEmpty ? [] : [.equal(old)] }
        // An edit is usually local: the shared start and end are cut off on
        // the bytes first (at character and word boundaries), so only the
        // part that differs is tokenized and compared.
        let (prefix, oldMid, newMid, suffix) = trim(old, new)
        var out: [Segment] = []
        func append(_ s: Segment) {
            switch (out.last, s) {
            case let (.equal(x)?, .equal(y)): out[out.count - 1] = .equal(x + y)
            case let (.deleted(x)?, .deleted(y)): out[out.count - 1] = .deleted(x + y)
            case let (.inserted(x)?, .inserted(y)): out[out.count - 1] = .inserted(x + y)
            default: out.append(s)
            }
        }
        if !prefix.isEmpty { append(.equal(prefix)) }
        if oldMid.utf8.count + newMid.utf8.count > lineFirst {
            // A long middle (edits far apart): lines first, then words inside
            // each changed run of lines that is not too long.
            let a = lines(oldMid), b = lines(newMid)
            var del = "", ins = ""
            func flushRun() {
                if del.utf8.count + ins.utf8.count <= lineFirst {
                    for seg in wordSegments(del, ins) { append(seg) }
                } else {
                    if !del.isEmpty { append(.deleted(del)) }
                    if !ins.isEmpty { append(.inserted(ins)) }
                }
                del = ""; ins = ""
            }
            for op in align(a, b) {
                switch op {
                case let .deleted(t): del += t
                case let .inserted(t): ins += t
                case .equal: flushRun(); append(op)
                }
            }
            flushRun()
        } else {
            for seg in wordSegments(oldMid, newMid) { append(seg) }
        }
        if !suffix.isEmpty { append(.equal(suffix)) }
        return cleanup(out)
    }

    /// Middles longer than this (bytes) are compared line by line first.
    static let lineFirst = 4000

    static func wordSegments(_ old: String, _ new: String) -> [Segment] {
        var a = tokens(old), b = tokens(new)
        if a.count > maxTokens || b.count > maxTokens { a = lines(old); b = lines(new) }
        return align(a, b)
    }

    /// Myers (the standard library's CollectionDifference) over token ids:
    /// comparing integers, not strings.
    static func align(_ a: [Substring], _ b: [Substring]) -> [Segment] {
        var ids: [Substring: Int] = [:]
        let ia = a.map { t in ids[t] ?? { ids[t] = ids.count; return ids.count - 1 }() }
        let ib = b.map { t in ids[t] ?? { ids[t] = ids.count; return ids.count - 1 }() }
        var removed = [Bool](repeating: !ib.isEmpty ? false : true, count: a.count)
        var added = [Bool](repeating: !ia.isEmpty ? false : true, count: b.count)
        if !ia.isEmpty && !ib.isEmpty {
            for change in ib.difference(from: ia) {
                switch change {
                case let .remove(offset, _, _): removed[offset] = true
                case let .insert(offset, _, _): added[offset] = true
                }
            }
        }
        var out: [Segment] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count && removed[i] { out.append(.deleted(String(a[i]))); i += 1; continue }
            if j < b.count && added[j] { out.append(.inserted(String(b[j]))); j += 1; continue }
            out.append(.equal(String(a[i]))); i += 1; j += 1
        }
        return out
    }

    /// The longest shared start and end of two texts, cut where a token can
    /// begin (never inside a character or a word), and the middles.
    static func trim(_ old: String, _ new: String) -> (String, String, String, String) {
        let a = Array(old.utf8), b = Array(new.utf8)
        let limit = min(a.count, b.count)
        func cont(_ x: UInt8) -> Bool { x & 0xC0 == 0x80 }
        /// The character starting at byte `i`, and its length.
        func scalar(_ u: [UInt8], _ i: Int) -> (Unicode.Scalar, Int)? {
            guard i < u.count else { return nil }
            var end = i + 1
            while end < u.count && cont(u[end]) { end += 1 }
            guard let sc = String(decoding: u[i..<end], as: UTF8.self).unicodeScalars.first else { return nil }
            return (sc, end - i)
        }
        /// The start of the character that ends just before byte `i`.
        func start(before i: Int, in u: [UInt8]) -> Int {
            var j = i - 1
            while j > 0 && cont(u[j]) { j -= 1 }
            return j
        }
        func wordish(_ x: (Unicode.Scalar, Int)?) -> Bool {
            guard let (sc, _) = x else { return false }
            let v = sc.value
            if v < 0x80 { return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x5F }
            return !CJK.isCJK(sc) && (sc.properties.isAlphabetic || sc.properties.numericType != nil)
        }
        var p = 0
        while p < limit && a[p] == b[p] { p += 1 }
        while p > 0 && p < a.count && cont(a[p]) { p -= 1 }
        while p > 0 && p < b.count && cont(b[p]) { p -= 1 }
        while p > 0 {
            let prev = start(before: p, in: a)
            guard wordish(scalar(a, prev)), wordish(scalar(a, p)) || wordish(scalar(b, p)) else { break }
            p = prev
        }
        var s = 0
        while s < limit - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        while s > 0 && cont(a[a.count - s]) { s -= 1 }
        while s > 0 {
            let first = scalar(a, a.count - s)
            let beforeA = a.count - s > p ? scalar(a, start(before: a.count - s, in: a)) : nil
            let beforeB = b.count - s > p ? scalar(b, start(before: b.count - s, in: b)) : nil
            guard wordish(first), wordish(beforeA) || wordish(beforeB), let (_, len) = first else { break }
            s -= len
        }
        func str(_ x: ArraySlice<UInt8>) -> String { String(decoding: x, as: UTF8.self) }
        return (str(a[0..<p]), str(a[p..<(a.count - s)]), str(b[p..<(b.count - s)]), str(a[(a.count - s)...]))
    }

    /// Readable grouping: a short unchanged run between two changes (a shared
    /// space or character) is folded into them, so a rewritten phrase reads
    /// as one deletion and one insertion; deletions come before insertions.
    static func cleanup(_ segments: [Segment]) -> [Segment] {
        var segs = segments
        var changed = true
        while changed {
            changed = false
            // Regroup: within each run of changes, all deletions first.
            var regrouped: [Segment] = []
            var del = "", ins = ""
            func flush() {
                if !del.isEmpty { regrouped.append(.deleted(del)) }
                if !ins.isEmpty { regrouped.append(.inserted(ins)) }
                del = ""; ins = ""
            }
            for s in segs {
                switch s {
                case let .deleted(t): del += t
                case let .inserted(t): ins += t
                case .equal: flush(); regrouped.append(s)
                }
            }
            flush()
            segs = slide(regrouped)
            // Fold an equality no longer than the changes on both sides of it.
            var k = 1
            while k + 1 < segs.count {
                guard case let .equal(e) = segs[k] else { k += 1; continue }
                let before = changeLength(segs, around: k, step: -1)
                let after = changeLength(segs, around: k, step: 1)
                if before > 0 && after > 0 && e.utf8.count <= 32 && e.count <= min(before, after) && e.count <= 8 {
                    segs[k] = .deleted(e)
                    segs.insert(.inserted(e), at: k + 1)
                    changed = true
                    k += 2
                } else {
                    k += 1
                }
            }
        }
        return segs
    }

    /// A lone insertion or deletion between two equal runs can often sit in
    /// several places ("33| |\n|…| 27|" vs "33 |\n|… 27 |"). Put it where it
    /// reads best: starting a line, else at a word boundary.
    static func slide(_ segs: [Segment]) -> [Segment] {
        var segs = segs
        var k = 1
        while k + 1 < segs.count {
            guard case let .equal(before) = segs[k - 1], case let .equal(after) = segs[k + 1] else { k += 1; continue }
            let isDel: Bool
            let text: String
            switch segs[k] {
            case let .deleted(t): isDel = true; text = t
            case let .inserted(t): isDel = false; text = t
            case .equal: k += 1; continue
            }
            // Only the neighbourhood can matter; long runs keep their far ends as they are.
            let cut1 = before.index(before.endIndex, offsetBy: -200, limitedBy: before.startIndex) ?? before.startIndex
            let cut2 = after.index(after.startIndex, offsetBy: 200, limitedBy: after.endIndex) ?? after.endIndex
            let head = String(before[..<cut1]), tail = String(after[cut2...])
            var e1 = Array(before[cut1...]), x = Array(text), e2 = Array(after[..<cut2])
            // All the way left, then try every position to the right.
            while let l = e1.last, l == x.last { e1.removeLast(); x.insert(x.removeLast(), at: 0); e2.insert(l, at: 0) }
            func score(_ e1: [Character], _ x: [Character]) -> Int {
                if e1.isEmpty || e1.last == "\n" || x.first == "\n" { return 3 }
                if e1.last == " " || x.first == " " { return 1 }
                return 0
            }
            var best = (score(e1, x), e1, x, e2)
            while let f = e2.first, f == x.first {
                e2.removeFirst(); e1.append(f); x.append(x.removeFirst())
                let sc = score(e1, x)
                if sc > best.0 { best = (sc, e1, x, e2) }
            }
            segs[k - 1] = .equal(head + String(best.1))
            segs[k] = isDel ? .deleted(String(best.2)) : .inserted(String(best.2))
            segs[k + 1] = .equal(String(best.3) + tail)
            k += 1
        }
        return segs.filter { if case let .equal(t) = $0 { !t.isEmpty } else { true } }
    }

    private static func changeLength(_ segs: [Segment], around k: Int, step: Int) -> Int {
        var n = 0, i = k + step
        while i >= 0 && i < segs.count {
            switch segs[i] {
            case let .deleted(t), let .inserted(t): n = max(n, t.utf8.count > 64 ? 64 : t.count)
            case .equal: return n
            }
            i += step
        }
        return n
    }

    /// The comparison as HTML: `<del>` and `<ins>` around changes, text
    /// escaped, long unchanged runs shortened with an ellipsis.
    public static func html(old: String, new: String) -> String {
        let segs = segments(old: old, new: new)
        var out = ""
        for (n, s) in segs.enumerated() {
            switch s {
            case let .deleted(t): out += "<del>\(HTML.escape(t))</del>"
            case let .inserted(t): out += "<ins>\(HTML.escape(t))</ins>"
            case let .equal(t):
                out += HTML.escape(shorten(t, first: n == 0, last: n == segs.count - 1))
            }
        }
        return out
    }

    static func shorten(_ t: String, first: Bool, last: Bool) -> String {
        guard t.count > maxEqual else { return t }
        if first && last { return t }
        if first { return "… " + String(t.suffix(keepEqual)) }
        if last { return String(t.prefix(keepEqual)) + " …" }
        return String(t.prefix(keepEqual)) + " … " + String(t.suffix(keepEqual))
    }

    // MARK: Tokens

    static func tokens(_ text: String) -> [Substring] {
        var out: [Substring] = []
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var kind = 0   // 0 none, 1 word, 2 space
        var i = scalars.startIndex
        func flush(_ end: String.Index) { if start < end { out.append(text[start..<end]) }; start = end }
        while i < scalars.endIndex {
            let s = scalars[i]
            let next = scalars.index(after: i)
            let v = s.value
            let word = (v >= 0x61 && v <= 0x7A) || (v >= 0x41 && v <= 0x5A) || (v >= 0x30 && v <= 0x39) || v == 0x5F
                || (v >= 0x80 && !CJK.isCJK(s) && (s.properties.isAlphabetic || s.properties.numericType != nil))
            if word {
                if kind != 1 { flush(i); kind = 1 }
            } else if v == 0x20 || v == 0x09 {
                if kind != 2 { flush(i); kind = 2 }
            } else if v >= 0x0300 && v <= 0x036F || (v >= 0xFE00 && v <= 0xFE0F) || v == 0x200D {
                // Combining marks and joiners stay with what they follow.
            } else {
                flush(i); kind = 0
                // A CJK character, or any other character, is a token of its own.
                var end = next
                while end < scalars.endIndex, isExtender(scalars[end]) { end = scalars.index(after: end) }
                out.append(text[i..<end]); start = end
                i = end
                continue
            }
            i = next
        }
        flush(scalars.endIndex)
        return out
    }

    private static func isExtender(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (v >= 0x0300 && v <= 0x036F) || (v >= 0xFE00 && v <= 0xFE0F) || v == 0x200D || (v >= 0x1F3FB && v <= 0x1F3FF)
    }

    static func lines(_ text: String) -> [Substring] {
        var out: [Substring] = []
        let u = text.utf8
        var start = u.startIndex
        var i = u.startIndex
        while i < u.endIndex {
            let next = u.index(after: i)
            if u[i] == 0x0A { out.append(text[start..<next]); start = next }
            i = next
        }
        if start < u.endIndex { out.append(text[start...]) }
        return out
    }
}
