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
        var budget = maxWork
        return segments(old: old, new: new, budget: &budget)
    }

    /// `budget` is shared by every comparison drawing on it (one update's
    /// edited blocks); once it is spent, changed runs are shown replaced whole.
    public static func segments(old: String, new: String, budget: inout Int) -> [Segment] {
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
        if budget <= 0 {
            // The budget is spent: the changed middle is shown replaced whole.
            if !oldMid.isEmpty { append(.deleted(oldMid)) }
            if !newMid.isEmpty { append(.inserted(newMid)) }
        } else if oldMid.utf8.count + newMid.utf8.count > lineFirst {
            // A long middle (edits far apart): lines first, then words inside
            // each changed run of lines that is not too long.
            let a = lines(oldMid), b = lines(newMid)
            var del = "", ins = ""
            func flushRun() {
                if del.utf8.count + ins.utf8.count <= lineFirst {
                    for seg in wordSegments(del, ins, budget: &budget) { append(seg) }
                } else {
                    if !del.isEmpty { append(.deleted(del)) }
                    if !ins.isEmpty { append(.inserted(ins)) }
                }
                del = ""; ins = ""
            }
            for op in align(a, b, budget: &budget) {
                switch op {
                case let .deleted(t): del += t
                case let .inserted(t): ins += t
                case .equal: flushRun(); append(op)
                }
            }
            flushRun()
        } else {
            for seg in wordSegments(oldMid, newMid, budget: &budget) { append(seg) }
        }
        if !suffix.isEmpty { append(.equal(suffix)) }
        return cleanup(out)
    }

    /// Middles longer than this (bytes) are compared line by line first.
    static let lineFirst = 4000

    static func wordSegments(_ old: String, _ new: String, budget: inout Int) -> [Segment] {
        var a = tokens(old), b = tokens(new)
        if a.count > maxTokens || b.count > maxTokens { a = lines(old); b = lines(new) }
        return align(a, b, budget: &budget)
    }

    /// Myers (the standard library's CollectionDifference) over token ids:
    /// comparing integers, not strings.
    /// Myers takes time in proportion to (old + new) × differences. Above
    /// this, a run is shown as replaced whole: a block rewritten throughout
    /// reads no better compared token by token, and the window must not stall.
    static let maxWork = 8_000_000

    /// `budget` is what is left of the block's work allowance; each comparison
    /// spends what it used (differences × length), or its whole allowance when it gives up.
    static func align(_ a: [Substring], _ b: [Substring], budget: inout Int) -> [Segment] {
        var ids: [Substring: Int] = [:]
        let ia = a.map { t in ids[t] ?? { ids[t] = ids.count; return ids.count - 1 }() }
        let ib = b.map { t in ids[t] ?? { ids[t] = ids.count; return ids.count - 1 }() }
        let size = max(1, ia.count + ib.count)
        let maxD = min(1000, max(0, budget) / size)
        let script = ia.isEmpty || ib.isEmpty ? nil : myers(ia, ib, maxD: maxD)
        if let (removed, added) = script {
            budget -= (removed.lazy.filter { $0 }.count + added.lazy.filter { $0 }.count + 1) * size
        } else if !ia.isEmpty && !ib.isEmpty {
            budget -= (maxD + 1) * size
        }
        guard let script else {
            var out: [Segment] = []
            if !a.isEmpty { out.append(.deleted(a.joined())) }
            if !b.isEmpty { out.append(.inserted(b.joined())) }
            return out
        }
        let (removed, added) = script
        var out: [Segment] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count && removed[i] { out.append(.deleted(String(a[i]))); i += 1; continue }
            if j < b.count && added[j] { out.append(.inserted(String(b[j]))); j += 1; continue }
            out.append(.equal(String(a[i]))); i += 1; j += 1
        }
        return out
    }

    /// Myers' O((N+M)·D) difference, giving up (nil) beyond `maxD` edits.
    /// Returns which tokens of `a` are removed and which of `b` are added.
    static func myers(_ a: [Int], _ b: [Int], maxD: Int) -> (removed: [Bool], added: [Bool])? {
        let n = a.count, m = b.count
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        var found = false
        search: for d in 0...maxD {
            var row = [Int](repeating: 0, count: 2 * d + 1)
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n && y < m && a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                row[k + d] = x
                if x >= n && y >= m { trace.append(row); found = true; break search }
            }
            trace.append(row)
        }
        guard found else { return nil }
        var removed = [Bool](repeating: false, count: n), added = [Bool](repeating: false, count: m)
        var x = n, y = m
        for d in stride(from: trace.count - 1, to: 0, by: -1) {
            let prev = trace[d - 1]
            func at(_ k: Int) -> Int { let i = k + (d - 1); return i >= 0 && i < prev.count ? prev[i] : -1 }
            let k = x - y
            let down = k == -d || (k != d && at(k - 1) < at(k + 1))
            let prevK = down ? k + 1 : k - 1
            let prevX = at(prevK), prevY = prevX - prevK
            while x > (down ? prevX : prevX + 1) && y > (down ? prevY + 1 : prevY) { x -= 1; y -= 1 }
            if down { added[prevY] = true } else { removed[prevX] = true }
            x = prevX; y = prevY
        }
        return (removed, added)
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
        // Never inside a character: an emoji with its modifier, a letter with its accent.
        func boundary(_ text: String, _ offset: Int) -> Bool {
            String.Index(text.utf8.index(text.utf8.startIndex, offsetBy: offset), within: text) != nil
        }
        while p > 0 && !(boundary(old, p) && boundary(new, p)) { p -= 1 }
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
        while s > 0 && !(boundary(old, a.count - s) && boundary(new, b.count - s)) { s -= 1 }
        func str(_ x: ArraySlice<UInt8>) -> String { String(decoding: x, as: UTF8.self) }
        return (str(a[0..<p]), str(a[p..<(a.count - s)]), str(b[p..<(b.count - s)]), str(a[(a.count - s)...]))
    }

    /// Readable grouping: a short unchanged run between two changes (a shared
    /// space or character) is folded into them, so a rewritten phrase reads
    /// as one deletion and one insertion; deletions come before insertions.
    static func cleanup(_ segments: [Segment]) -> [Segment] {
        var segs = regroup(segments)
        var changed = true
        while changed {
            changed = false
            segs = regroup(slide(segs))
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
            segs = regroup(segs)
        }
        return segs
    }

    /// Within each run of changes, one deletion and then one insertion.
    static func regroup(_ segs: [Segment]) -> [Segment] {
        var out: [Segment] = []
        var del = "", ins = ""
        func flush() {
            if !del.isEmpty { out.append(.deleted(del)) }
            if !ins.isEmpty { out.append(.inserted(ins)) }
            del = ""; ins = ""
        }
        for s in segs {
            switch s {
            case let .deleted(t): del += t
            case let .inserted(t): ins += t
            case let .equal(t):
                flush()
                if t.isEmpty { continue }
                if case let .equal(prev)? = out.last { out[out.count - 1] = .equal(prev + t) } else { out.append(s) }
            }
        }
        flush()
        return out
    }

    /// A lone insertion or deletion between two equal runs can often sit in
    /// several places ("33| |\n|…| 27|" vs "33 |\n|… 27 |"). Put it where it
    /// reads best: starting a line, else at a word boundary.
    static let slideLimit = 4000

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
            // A large change reads the same wherever it sits; moving it costs time in proportion to its size.
            if text.utf8.count > slideLimit { k += 1; continue }
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
        var budget = maxWork
        return html(old: old, new: new, budget: &budget)
    }

    public static func html(old: String, new: String, budget: inout Int) -> String {
        let segs = segments(old: old, new: new, budget: &budget)
        var out = ""
        for (n, s) in segs.enumerated() {
            switch s {
            case let .deleted(t): out += "<del>\(HTML.escape(shortenChange(t)))</del>"
            case let .inserted(t): out += "<ins>\(HTML.escape(shortenChange(t)))</ins>"
            case let .equal(t):
                out += HTML.escape(shorten(t, first: n == 0, last: n == segs.count - 1))
            }
        }
        return out
    }

    /// Changes longer than this show their two ends.
    static let maxChange = 2000

    static func shortenChange(_ t: String) -> String {
        guard t.utf8.count > maxChange, t.count > maxChange else { return t }
        return String(t.prefix(maxChange / 2 - 50)) + " … " + String(t.suffix(maxChange / 2 - 50))
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
            if v >= 0x80 && i > scalars.startIndex && String.Index(i, within: text) == nil {
                // Inside a character (a vowel sign after a space, conjoining jamo):
                // it stays with the token it continues.
            } else if word {
                if kind != 1 { flush(i); kind = 1 }
            } else if v == 0x20 || v == 0x09 {
                if kind != 2 { flush(i); kind = 2 }
            } else if v >= 0x80 && (s.properties.isGraphemeExtend || s.properties.generalCategory == .spacingMark
                                    || v == 0x200D || s.properties.isEmojiModifier) {
                // Combining marks (every kind), variation selectors, joiners and
                // skin-tone modifiers stay with what they follow.
            } else {
                flush(i); kind = 0
                // A CJK character, or any other character, is a token of its own.
                // The whole character: emoji sequences, keycaps, accents.
                var end = text.index(after: i)
                if end <= i { end = next }
                out.append(text[i..<end]); start = end
                i = end
                continue
            }
            i = next
        }
        flush(scalars.endIndex)
        return out
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
