import Foundation
import cmark_gfm
import cmark_gfm_extensions
#if canImport(Glibc)
import Glibc
#endif

/// Deep nesting, flattened before swift-markdown parses it: its tree
/// conversion recurses once per level (and Readout's renderer after it), so
/// enough nested `>`, list items, emphasis or links overflow any thread's
/// stack (a crafted 160 KB line, a 16 MB one), at every launch once restored.
///
/// Past `containers` levels of block quotes and list items, a quote's or
/// item's marker is escaped (`\>`, `\-`, `1\.`): the rest is text in the
/// deepest container. Past `inlines` levels of links, images, emphasis and
/// strikethrough, every opener in the paragraph, heading or table holding
/// them is escaped (`\[`, `\*`): it shows as written. Only nesting no real
/// document has changes (markdown-it's CommonMark preset stops at 20 levels).
///
/// The levels are cmark-gfm's own, as swift-markdown will parse the text:
/// its C API builds and walks the tree without recursing. That parse runs
/// only where nesting that deep is possible at all (`mayNest`), which no
/// ordinary document reaches. Decided per node, and a fragment
/// (`IncrementalParser`) holds the same nodes as the whole document: a
/// splice, an incremental and a full parse flatten alike. Runs on the text
/// the Markdown parser gets (math and footnote references already tokens,
/// `MathProtector`).
///
/// So bounded, a parse fits a GCD thread's 512 KB stack, with room to spare
/// (`CoreFixes38Tests.theDeepestDocumentFitsASmallStack`).
enum NestingCap {
    static let containers = 16
    static let inlines = 16

    /// `text` flattened, and the 0-based lines changed; nil when nothing is.
    static func apply(_ text: String) -> (text: String, lines: Set<Int>)? {
        var text = text
        text.makeContiguousUTF8()
        guard text.utf8.withContiguousStorageIfAvailable(mayNest) == true else { return nil }
        var bytes = Array(text.utf8)
        var lines = Set<Int>()
        // What the escapes leave is parsed again, until nothing nests too
        // deep (each round escapes new characters: it ends). An item's
        // escape can bring up a quote it held: two rounds, rarely three.
        while case let escapes = bytes.withUnsafeBufferPointer(tooDeep), !escapes.isEmpty {
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count + escapes.count)
            var from = 0
            for x in escapes where x.at >= from {
                out += bytes[from..<x.at]
                out.append(0x5C)   // backslash
                from = x.at + 1
                out.append(bytes[x.at])
                lines.insert(x.line)
            }
            out += bytes[from...]
            bytes = out
        }
        return lines.isEmpty ? nil : (String(decoding: bytes, as: UTF8.self), lines)
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }

    /// The end of the line starting at `s` (its LF, or the end of the text).
    private static func lineEnd(_ u: UnsafeBufferPointer<UInt8>, _ s: Int) -> Int {
        guard let base = u.baseAddress, s < u.count else { return u.count }
        return memchr(base + s, 0x0A, u.count - s).map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? u.count
    }

    /// Whether `u` may nest past the limits (an upper bound). A line holds
    /// no more containers than its `>` and half its other leading columns
    /// (an item's content is at least two columns past the item's marker;
    /// one when the marker ends the line); a paragraph no more inline
    /// levels than its `[` and half its `*`, `_` and `~`. A paragraph ends at a
    /// blank line (in a quote too) and where an item with text starts (a
    /// bullet always does; `2.` may be the paragraph's text).
    static func mayNest(_ u: UnsafeBufferPointer<UInt8>) -> Bool {
        let n = u.count
        var s = 0, openers = 0, delimiters = 0
        while s < n {
            let e = lineEnd(u, s)
            var i = s, columns = 0, quotes = 0, marker = false, bullet = false
            while i < e {
                let c = u[i]
                if c == 0x20 { columns += 1; i += 1; continue }
                if c == 0x09 { columns = (columns / 4 + 1) * 4; i += 1; continue }
                if c == 0x3E { quotes += 1; columns += 1; i += 1; continue }
                var k = i + 1
                if c != 0x2D && c != 0x2A && c != 0x2B {   // - * +, or 1. 1)
                    k = i
                    while k < e, k - i < 9, u[k] >= 0x30, u[k] <= 0x39 { k += 1 }
                    guard k > i, k < e, u[k] == 0x2E || u[k] == 0x29 else { break }
                    k += 1
                }
                guard k == e || isSpace(u[k]) else { break }
                bullet = k == i + 1
                columns += k - i
                i = k
                marker = true
            }
            if quotes + (columns - quotes + 1) / 2 > containers { return true }
            if i == e ? !marker : bullet { openers = 0; delimiters = 0 }
            while i < e {
                let c = u[i]
                if c == 0x5B { openers += 1 } else if c == 0x2A || c == 0x5F || c == 0x7E { delimiters += 1 }
                i += 1
            }
            if openers + delimiters / 2 > inlines { return true }
            s = e + 1
        }
        return false
    }

    /// The escapes taking apart what nests past the limits in `u` as
    /// cmark-gfm parses it (swift-markdown's options and extensions), in order.
    static func tooDeep(_ u: UnsafeBufferPointer<UInt8>) -> [(at: Int, line: Int)] {
        // Where each 0-based line starts, and the end of the text.
        var starts = [0]
        while let last = starts.last, last < u.count { starts.append(lineEnd(u, last) + 1) }
        func offset(_ node: UnsafeMutablePointer<cmark_node>) -> Int? {
            let l = Int(cmark_node_get_start_line(node)) - 1, c = Int(cmark_node_get_start_column(node)) - 1
            guard l >= 0, l < starts.count, c >= 0, starts[l] + c < u.count else { return nil }
            return starts[l] + c
        }
        /// The 0-based lines a node is on, but its first.
        func rest(_ node: UnsafeMutablePointer<cmark_node>) -> Range<Int> {
            let first = Int(cmark_node_get_start_line(node)), last = Int(cmark_node_get_end_line(node))
            return first..<max(first, min(last, starts.count - 1))
        }

        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_TABLE_SPANS) else { return [] }
        defer { cmark_parser_free(parser) }
        cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension("table"))
        cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension("strikethrough"))
        u.withMemoryRebound(to: CChar.self) { cmark_parser_feed(parser, $0.baseAddress, $0.count) }
        guard let root = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(root) }
        guard let iter = cmark_iter_new(root) else { return [] }
        defer { cmark_iter_free(iter) }

        var escapes: [(at: Int, line: Int)] = []
        func escape(_ at: Int) {
            switch u[at] {
            case 0x3E, 0x2D, 0x2A, 0x2B, 0x2E, 0x29, 0x5B, 0x5F, 0x7E:   // > - * + . ) [ _ ~
                escapes.append((at, IncrementalParser.lastIndex(starts, atMost: at)))
            default: break
            }
        }
        // The blocks whose openers all go (a paragraph, a heading, a table).
        var blocks: [UnsafeMutablePointer<cmark_node>] = []
        var levels = 0, quotes = 0, inline = 0
        // The block last entered: the one holding the inlines that follow.
        var leaf: UnsafeMutablePointer<cmark_node>? = nil
        while case let event = cmark_iter_next(iter), event != CMARK_EVENT_DONE {
            guard let node = cmark_iter_get_node(iter) else { continue }
            let type = cmark_node_get_type(node), enter = event == CMARK_EVENT_ENTER
            if enter && type.rawValue & 0xC000 != 0xC000 { leaf = node }
            if type == CMARK_NODE_BLOCK_QUOTE || type == CMARK_NODE_ITEM {
                let quote = type == CMARK_NODE_BLOCK_QUOTE
                guard enter else { levels -= 1; if quote { quotes -= 1 }; continue }
                levels += 1
                if quote { quotes += 1 }
                guard levels > containers, var at = offset(node) else { continue }
                if !quote {
                    // A list number keeps its digits: `1\.`.
                    while at < u.count, u[at] >= 0x30, u[at] <= 0x39 { at += 1 }
                    escape(at)
                } else if levels == containers + 1 {
                    // On the lines it goes on to as well (what it holds goes
                    // with it): there, its `>` is the line's `quotes`th.
                    escape(at)
                    for line in rest(node) {
                        var i = starts[line], seen = 0
                        while i < u.count, isSpace(u[i]) || u[i] == 0x3E {
                            if u[i] == 0x3E { seen += 1; if seen == quotes { escape(i); break } }
                            i += 1
                        }
                    }
                }
            } else if type == CMARK_NODE_EMPH || type == CMARK_NODE_STRONG || type == CMARK_NODE_LINK || type == CMARK_NODE_IMAGE
                        || (type.rawValue & 0xC000 == 0xC000 && type.rawValue > CMARK_NODE_ATTRIBUTE.rawValue) {   // ~~ (an extension's)
                guard enter else { inline -= 1; continue }
                inline += 1
                guard inline > inlines else { continue }
                // The block holding it: a paragraph or heading, or a table cell's table.
                guard var block = leaf, blocks.last != block else { continue }
                if String(cString: cmark_node_get_type_string(block)) == "table_cell",
                   let table = cmark_node_parent(block).flatMap(cmark_node_parent) { block = table }
                blocks.append(block)
            }
        }
        // Every `[`, `*`, `_` and `~` of the block, outside code spans: from
        // where it starts on its first line, after the line's quotes and
        // indentation on the others.
        for b in Set(blocks) {
            guard let from = offset(b) else { continue }
            var lines = [from]
            for line in rest(b) {
                var i = starts[line]
                while i < u.count, isSpace(u[i]) || u[i] == 0x3E { i += 1 }
                lines.append(i)
            }
            for start in lines {
                var i = start
                let e = lineEnd(u, i)
                while i < e {
                    switch u[i] {
                    case 0x5C:   // \ escapes the next character
                        i += 2
                    case 0x60:   // a code span, to the next run of as many backticks
                        var r = i
                        while r < e && u[r] == 0x60 { r += 1 }
                        var j = r, closed = false
                        while j < e {
                            guard u[j] == 0x60 else { j += 1; continue }
                            var q = j
                            while q < e && u[q] == 0x60 { q += 1 }
                            if q - j == r - i { closed = true; j = q; break }
                            j = q
                        }
                        i = closed ? j : r
                    case 0x5B, 0x2A, 0x5F, 0x7E:   // [ * _ ~
                        escape(i)
                        i += 1
                    default:
                        i += 1
                    }
                }
            }
        }
        escapes.sort { $0.at < $1.at }
        return escapes
    }
}
