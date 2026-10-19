import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Deep nesting, flattened before swift-markdown parses it: its tree
/// conversion recurses once per level, and a document parses on threads
/// with small stacks (a GCD worker's is 512 KB), so a few hundred nested
/// `>` or emphasis runs crashed Readout, at every launch once restored.
///
/// Past `containers` levels of block quotes and list items, the next
/// marker on a line is escaped (`\>`, `\-`, `1\.`): the rest of the line is
/// text in the deepest container. A list item's level comes from the items
/// above it (any indentation width, over blank lines), in its block quote
/// (indented after the `>`) or outside one; where nothing above tells, a
/// level per four columns. Past `inlines` levels of links and emphasis in
/// a run of lines, the opener is escaped (`\[`, `\*\*`): it shows as
/// written. Only nesting no real document has changes (markdown-it's
/// CommonMark preset stops at 20 levels).
///
/// Decided per run of non-blank lines, and the list items open where it
/// starts, which are none at any line a fragment (`IncrementalParser`) may
/// start at: a fragment holds whole runs, so a splice, an incremental and
/// a full parse flatten alike. Lines of fenced code opened
/// in the run are left alone. Runs on the text the Markdown parser gets
/// (math and footnote references already tokens, `MathProtector`).
enum NestingCap {
    static let containers = 16
    static let inlines = 16

    /// `text` flattened, and the 0-based lines changed; nil when nothing is.
    static func apply(_ text: String) -> (text: String, lines: Set<Int>)? {
        var text = text
        text.makeContiguousUTF8()
        return text.utf8.withContiguousStorageIfAvailable { u -> (text: String, lines: Set<Int>)? in
            var inserts: [(at: Int, line: Int)] = []
            // The run of non-blank lines so far: its lines, its first line's
            // number, and whether it may nest too deep (an upper bound: a
            // level takes a `[` or two of `*`, `_`, `~`).
            var lines: [(start: Int, end: Int)] = []
            var runLine = 0, openers = 0, delimiters = 0, deep = false
            // Open list items carry over blank lines (a loose list), and end
            // where a fragment may start (`IncrementalParser.startsFresh`: a
            // line after a blank one, at column 0, no container marker), so
            // every parse has them alike.
            var lists: Lists = [], runLists: Lists = []
            var afterBlank = true
            let n = u.count
            guard let base = u.baseAddress else { return nil }
            var s = 0, line = 0
            while s <= n {
                let e = s < n ? memchr(base + s, 0x0A, n - s).map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? n : n
                if afterBlank, s < e, !isSpace(u[s]), !startsMarker(u, s, e) { lists.removeAll(keepingCapacity: true) }
                let before = lists
                let prefix = containerPrefix(u, s, e, lists: &lists)
                afterBlank = prefix.blank
                if prefix.blank {
                    if !lines.isEmpty {
                        if deep || openers + delimiters / 2 > inlines { flatten(u, lines: lines, first: runLine, lists: runLists, into: &inserts) }
                        lines.removeAll(keepingCapacity: true)
                        openers = 0; delimiters = 0; deep = false
                    }
                } else {
                    if lines.isEmpty { runLine = line; runLists = before }
                    lines.append((s, e))
                    if prefix.escape != nil { deep = true }
                    var o = 0, d = 0
                    var k = s
                    while k < e {
                        let c = base[k]
                        if c == 0x5B { o += 1 } else if c == 0x2A || c == 0x5F || c == 0x7E { d += 1 }
                        k += 1
                    }
                    openers += o; delimiters += d
                }
                s = e + 1
                line += 1
            }
            if !lines.isEmpty, deep || openers + delimiters / 2 > inlines { flatten(u, lines: lines, first: runLine, lists: runLists, into: &inserts) }
            guard !inserts.isEmpty else { return nil }
            inserts.sort { $0.at < $1.at }
            var out: [UInt8] = []
            out.reserveCapacity(n + inserts.count)
            var from = 0
            for x in inserts {
                out.append(contentsOf: UnsafeBufferPointer(rebasing: u[from..<x.at]))
                out.append(0x5C)   // backslash
                from = x.at
            }
            out.append(contentsOf: UnsafeBufferPointer(rebasing: u[from..<n]))
            return (String(decoding: out, as: UTF8.self), Set(inserts.map(\.line)))
        } ?? nil
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }

    /// The line starts with a block quote or list marker.
    private static func startsMarker(_ u: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int) -> Bool {
        let c = u[s]
        if c == 0x3E { return true }
        if c == 0x2D || c == 0x2A || c == 0x2B { return s + 1 == e || isSpace(u[s + 1]) }
        var k = s
        while k < e, k - s < 9, u[k] >= 0x30, u[k] <= 0x39 { k += 1 }
        return k > s && k < e && (u[k] == 0x2E || u[k] == 0x29) && (k + 1 == e || isSpace(u[k + 1]))
    }

    /// The list items open in a run of lines, from the lines before: their
    /// content column, how deep each is, and the block quote it is in
    /// (`containerPrefix`).
    typealias Lists = [(content: Int, depth: Int, quote: Int)]

    /// Where a line's block quote and list markers end, and the marker that
    /// goes past `containers` levels (nil: none). The first list marker
    /// after the line's last `>` (or its first marker, with none) is as deep
    /// as the item above it in the run, in the same block quote, that it is
    /// indented under (`lists`, which the line updates), its columns counted
    /// from that `>`; a line the run tells nothing about (its first, or the
    /// first indented one) is a level per four columns in. Every other marker
    /// on the line is one more than the one before it.
    static func containerPrefix(_ u: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int, lists: inout Lists) -> (content: Int, escape: Int?, blank: Bool) {
        var i = s, columns = 0, markers = 0, depth = 0
        // The block quote the markers that follow are in: the depth of the
        // last `>` (0: none) and the column after it.
        var quote = 0, quoteColumn = 0
        // A list marker since the last `>`.
        var listInQuote = false
        var item: (content: Int, depth: Int, quote: Int)? = nil
        while i < e {
            let c = u[i]
            if c == 0x20 { columns += 1; i += 1; continue }
            if c == 0x09 { columns = (columns / 4 + 1) * 4; i += 1; continue }
            var end = i + 1   // past the marker
            let list: Bool
            if c == 0x3E {                                   // >
                list = false
            } else if c == 0x2D || c == 0x2A || c == 0x2B {  // - * +
                guard end == e || isSpace(u[end]) else { break }
                list = true
            } else if c >= 0x30 && c <= 0x39 {
                var k = i
                while k < e, k - i < 9, u[k] >= 0x30, u[k] <= 0x39 { k += 1 }
                guard k < e, u[k] == 0x2E || u[k] == 0x29, k + 1 == e || isSpace(u[k + 1]) else { break }
                end = k + 1
                list = true
            } else {
                break
            }
            markers += 1
            if list && !listInQuote {
                // Columns from the quote's `>`, as the items above it in the quote count theirs.
                let at = columns - quoteColumn
                while let last = lists.last, last.quote > quote || (last.quote == quote && last.content > at) { lists.removeLast() }
                depth = (lists.last.flatMap { $0.quote == quote ? $0.depth : nil } ?? quote + at / 4) + 1
                listInQuote = true
            } else if markers == 1 {
                depth = columns / 4 + 1
            } else {
                depth += 1
            }
            if depth > containers {
                // `- - - -`, `* * * *` from here: a thematic break, not nesting.
                if c == 0x2D || c == 0x2A, (i..<e).allSatisfy({ u[$0] == c || isSpace(u[$0]) }) { break }
                // The items before it on the line stay open for the lines
                // below (`- > x` under `- > x`: deeper each line).
                if let item { lists.append(item) }
                // The marker's own character (a list number keeps its digits).
                return (end, end - 1, false)
            }
            columns += end - i
            i = end
            if list {
                // Its content: at least one column past the marker (more is safe: deeper).
                item = (columns + 1 - quoteColumn, depth, quote)
            } else {
                quote = depth
                quoteColumn = columns
                listInQuote = false
            }
        }
        if let item { lists.append(item) }
        return (i, nil, i == e && markers == 0)
    }

    /// The escapes flattening one run of non-blank lines.
    private static func flatten(_ u: UnsafeBufferPointer<UInt8>, lines: [(start: Int, end: Int)], first: Int, lists start: Lists,
                                into inserts: inout [(at: Int, line: Int)]) {
        struct Token { var kind: UInt8; var at: Int; var count: Int; var line: Int; var canOpen = true; var canClose = false }
        var tokens: [Token] = []
        var fence: (char: UInt8, count: Int)? = nil
        var lists = start
        for (k, l) in lines.enumerated() {
            let line = first + k
            // Every line, code too, as `apply` read them: the same levels.
            let prefix = containerPrefix(u, l.start, l.end, lists: &lists)
            var i = prefix.content
            // A fence (``` or ~~~) and the code it holds: left as it is.
            var f = i
            if i < l.end && (u[i] == 0x60 || u[i] == 0x7E) { while f < l.end && u[f] == u[i] { f += 1 } }
            let fenceRun = f - i
            if let open = fence {
                if fenceRun >= open.count && u[i] == open.char && (f..<l.end).allSatisfy({ isSpace(u[$0]) }) { fence = nil }
                continue
            }
            if let at = prefix.escape {
                inserts.append((at, line))
                i = at + 1
            } else if fenceRun >= 3 {
                fence = (u[i], fenceRun)
                continue
            }
            // Openers and closers of links and emphasis.
            let lineStart = i
            while i < l.end {
                let c = u[i]
                switch c {
                case 0x5C:   // \ escapes the next character
                    i += 2
                case 0x60:   // a code span, to the next run of as many backticks
                    var r = i
                    while r < l.end && u[r] == 0x60 { r += 1 }
                    let width = r - i
                    var j = r, closed = false
                    while j < l.end {
                        if u[j] == 0x60 {
                            var q = j
                            while q < l.end && u[q] == 0x60 { q += 1 }
                            if q - j == width { closed = true; j = q; break }
                            j = q
                        } else { j += 1 }
                    }
                    i = closed ? j : r
                case 0x5B, 0x5D:   // [ ]
                    tokens.append(Token(kind: c, at: i, count: 1, line: line))
                    i += 1
                case 0x2A, 0x5F, 0x7E:   // * _ ~
                    var r = i
                    while r < l.end && u[r] == c { r += 1 }
                    let before: UInt8? = i > lineStart ? u[i - 1] : nil
                    let after: UInt8? = r < l.end ? u[r] : nil
                    let left = Self.flanks(after, before), right = Self.flanks(before, after)
                    var t = Token(kind: c, at: i, count: r - i, line: line)
                    if c == 0x5F {
                        t.canOpen = left && (!right || isPunctuation(before))
                        t.canClose = right && (!left || isPunctuation(after))
                    } else {
                        t.canOpen = left
                        t.canClose = right
                    }
                    if t.canOpen || t.canClose { tokens.append(t) }
                    i = r
                default:
                    i += 1
                }
            }
        }
        guard !tokens.isEmpty else { return }

        // Which openers a closer takes, as cmark-gfm does (nearest first).
        struct Open { var token: Int; var kind: UInt8; var remaining: Int }
        struct Pair { var open: Int; var close: Int; var levels: Int }
        var stack: [Open] = []
        var pairs: [Pair] = []
        var levels = 0
        // Openers of each kind on the stack: [ * _ ~
        var open = (0, 0, 0, 0)
        func count(_ kind: UInt8, _ d: Int) {
            switch kind {
            case 0x5B: open.0 += d
            case 0x2A: open.1 += d
            case 0x5F: open.2 += d
            default: open.3 += d
            }
        }
        func any(_ kind: UInt8) -> Bool {
            switch kind {
            case 0x5B: return open.0 > 0
            case 0x2A: return open.1 > 0
            case 0x5F: return open.2 > 0
            default: return open.3 > 0
            }
        }
        func popAbove(_ j: Int) {
            while stack.count > j + 1 { count(stack.removeLast().kind, -1) }
        }
        for (ti, t) in tokens.enumerated() {
            switch t.kind {
            case 0x5B:
                stack.append(Open(token: ti, kind: 0x5B, remaining: 1)); count(0x5B, 1)
            case 0x5D:
                guard any(0x5B), let j = stack.lastIndex(where: { $0.kind == 0x5B }) else { break }
                pairs.append(Pair(open: stack[j].token, close: ti, levels: 1))
                levels += 1
                popAbove(j - 1)
            default:
                var n = t.count
                if t.canClose {
                    while n > 0, any(t.kind), let j = stack.lastIndex(where: { $0.kind == t.kind }) {
                        let m = min(n, stack[j].remaining)
                        pairs.append(Pair(open: stack[j].token, close: ti, levels: m / 2 + m % 2))
                        levels += m / 2 + m % 2
                        popAbove(j)
                        stack[j].remaining -= m
                        if stack[j].remaining == 0 { stack.removeLast(); count(t.kind, -1) }
                        n -= m
                    }
                }
                if n > 0 && t.canOpen { stack.append(Open(token: ti, kind: t.kind, remaining: n)); count(t.kind, 1) }
            }
        }
        // All of them nested would still be few enough (nearly every run).
        guard levels > inlines else { return }

        // The levels open at each point; an opener past `inlines` is escaped.
        // At one token, closing comes before opening, and an outer pair opens first.
        var events: [(token: Int, close: Bool, pair: Int)] = []
        events.reserveCapacity(pairs.count * 2)
        for (pi, p) in pairs.enumerated() { events.append((p.open, false, pi)); events.append((p.close, true, pi)) }
        events.sort { a, b in
            if a.token != b.token { return a.token < b.token }
            if a.close != b.close { return a.close }
            return pairs[a.pair].close > pairs[b.pair].close
        }
        var escaped = [Bool](repeating: false, count: pairs.count)
        var escapedTokens = Set<Int>()
        var depth = 0
        for ev in events {
            let p = pairs[ev.pair]
            if ev.close {
                if !escaped[ev.pair] { depth -= p.levels }
            } else if escapedTokens.contains(p.open) || depth + p.levels > inlines {
                escaped[ev.pair] = true
                escapedTokens.insert(p.open)
            } else {
                depth += p.levels
            }
        }
        for ti in escapedTokens {
            let t = tokens[ti]
            for k in 0..<t.count { inserts.append((t.at + k, t.line)) }
        }
    }

    /// CommonMark's flanking: the run's `next` side is not white space, and
    /// is not punctuation unless `previous` is white space or punctuation.
    /// The ends of a line count as white space; any non-ASCII byte as a letter.
    private static func flanks(_ next: UInt8?, _ previous: UInt8?) -> Bool {
        guard let next, !isSpace(next) else { return false }
        return !isPunctuation(next) || previous.map { isSpace($0) || isPunctuation($0) } ?? true
    }

    private static func isPunctuation(_ c: UInt8?) -> Bool {
        guard let c else { return false }
        return (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
    }
}
