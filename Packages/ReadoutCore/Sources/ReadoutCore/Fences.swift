import Foundation

/// Follows a Markdown source line by line and tells which lines are code or
/// raw HTML rather than Markdown, with CommonMark's rules, so every pre-pass
/// (math protection, footnote extraction, incremental fragmenting) agrees
/// with the parser:
///
/// - Fenced code: 3+ backticks or tildes indented less than 4 spaces (a
///   backtick fence's info string may not contain a backtick), closed by a
///   line of the same character, at least as long, with nothing after it.
///   A fence opened inside a list item also ends where the item ends: at
///   the first non-blank line indented less than the item's content (tabs
///   counted to the next multiple of 4 columns). A fence may open right
///   after the list marker (`2. ```bash`) or after block quote markers
///   (`> ```bash`, `> - ```bash`); a quoted fence ends with the quote, at
///   the first line with fewer `>` (fenced code has no lazy lines).
/// - HTML blocks: `<!--` … `-->`, `<pre>`/`<script>`/`<style>`/`<textarea>`
///   … their closing tag, `<?` … `?>`, `<![CDATA[` … `]]>`; a block-level tag
///   (`<div>`, `<details>`, …) up to the next blank line; and any other tag
///   alone on a line, when it does not continue a paragraph, up to the next
///   blank line. Inside them, nothing is code and nothing is Markdown.
/// - `<details>` opened by HTML blocks: the parser joins everything up to
///   the closing tag into one block, so its depth is tracked too.
struct FenceTracker: Equatable {
    /// The open fence: its character and length; the content column of the
    /// list item holding it (from the quote's content inside a quote); the
    /// number of `>` before it (0: not in a quote) and the indentation of
    /// the first `>` when the quote sits in a list item.
    private struct Fence: Equatable { var char: UInt8, count: Int, container: Int?, quote: Int = 0, outer: Int = 0 }
    private var open: Fence? = nil
    /// The open HTML block: the marker that ends it (nil: the next blank
    /// line), the content column of the list item holding it, its text, and
    /// as for a fence the quote it is in (it ends with the quote too).
    private struct HTMLBlock: Equatable { var until: String?, container: Int?, text: String, quote: Int = 0, outer: Int = 0 }
    private var html: HTMLBlock? = nil
    /// The previous line belongs to a paragraph (a tag line then cannot start an HTML block of kind 7).
    private var inParagraph = false
    /// That paragraph sits in a block quote.
    private var paragraphInQuote = false
    /// Cells of the previous line, when it was paragraph text with a `|` (a table header candidate).
    private var headerCells: Int? = nil
    /// Inside a GFM table: rows are not paragraph text, so other blocks (raw HTML of any kind) may start.
    private var inTable = false
    /// Content columns of the open list items, outermost first (nested items
    /// keep their parents: a line left of a nested item's content may still be in the outer one).
    private var items: [Int] = []
    /// Content column of the innermost open list item, if any.
    private var itemContent: Int? { items.last }
    /// Closes the list items whose content starts right of `column`.
    private mutating func closeItems(rightOf column: Int) {
        while let last = items.last, last > column { items.removeLast() }
    }
    /// The list item inside a block quote the current line belongs to: the
    /// quote depth and the item's content column from the quote's content.
    private struct QuoteItem: Equatable { var depth: Int, content: Int }
    private var quoteItem: QuoteItem? = nil
    /// Depth of the `<details>` the parser is joining top-level blocks into (0: none).
    private(set) var detailsDepth = 0
    /// The last Markdown line consumed is indented code: 4+ columns past the
    /// content of the list item it belongs to (or the margin), not continuing a paragraph.
    private(set) var indentedCode = false

    /// Inside code or raw HTML, or inside a `<details>` the parser will join.
    var isOpen: Bool { open != nil || html != nil || detailsDepth > 0 }

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup",
        "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame",
        "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link",
        "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "section", "source",
        "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul",
    ]
    /// Kind 1: ends at a line with any of their end tags.
    private static let rawTags: Set<String> = ["pre", "script", "style", "textarea"]
    private static let rawEnd = "</raw>"
    private static let completeTag = try! NSRegularExpression(
        pattern: #"^(?:<[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:[^\s"'=<>`]+|'[^']*'|"[^"]*"))?)*\s*/?>|</[A-Za-z][A-Za-z0-9-]*\s*>)\s*$"#)

    /// Feeds one line; returns true when the line is code or raw HTML
    /// (fence lines included), false when it is Markdown.
    mutating func consume<S: StringProtocol>(_ line: S) -> Bool {
        if let r = line.utf8.withContiguousStorageIfAvailable({ consume(bytes: $0, line) }) { return r }
        return Array(line.utf8).withUnsafeBufferPointer { consume(bytes: $0, line) }
    }

    private static let space: UInt8 = 0x20, tab: UInt8 = 0x09

    private mutating func consume<S: StringProtocol>(bytes u: UnsafeBufferPointer<UInt8>, _ line: S) -> Bool {
        indentedCode = false
        let n = u.count
        var indent = 0
        while indent < n && u[indent] == Self.space { indent += 1 }
        var blank = true
        for k in indent..<n where u[k] != Self.space && u[k] != Self.tab { blank = false; break }
        /// Bytes from `from` on are all spaces or tabs.
        func restBlank(_ from: Int) -> Bool {
            var k = from
            while k < n { if u[k] != Self.space && u[k] != Self.tab { return false }; k += 1 }
            return true
        }
        let first: UInt8 = indent < n ? u[indent] : 0
        /// Columns of leading white space (tabs to the next multiple of 4) and where it ends.
        /// `column`: the column of `start` (tabs stop at multiples of 4 from the line's start).
        func lead(from start: Int, column: Int = 0) -> (columns: Int, end: Int) {
            var c = column, k = start
            while k < n, u[k] == Self.space || u[k] == Self.tab { c = u[k] == Self.tab ? (c / 4 + 1) * 4 : c + 1; k += 1 }
            return (c - column, k)
        }
        /// White space after quote markers, without the column of a tab right after the last `>` that stands for its space.
        func lead(after q: (at: Int, column: Int, tabSpace: Bool)) -> (columns: Int, end: Int) {
            let l = lead(from: q.at, column: q.column)
            return (q.tabSpace ? l.columns - 1 : l.columns, l.end)
        }
        /// A closing fence for `f` at `p`: the fence character, at least as many, nothing after.
        func closes(_ f: Fence, at p: Int) -> Bool {
            guard p < n, u[p] == f.char else { return false }
            var run = 0
            while p + run < n && u[p + run] == f.char { run += 1 }
            return run >= f.count && restBlank(p + run)
        }
        let cols = lead(from: 0)

        if let h = html, h.quote > 0 {
            if let q = Self.afterQuotes(u, depth: h.quote, outer: h.outer) {
                let l = lead(after: q)
                if let c = h.container, l.end < n, l.columns < c {
                    endHTML()   // the quoted list item ended, and the block with it
                    quoteItem = nil
                } else if let until = h.until {
                    html!.text += "\n" + line
                    if Self.ends(line.lowercased(), until) { endHTML() }
                    inParagraph = false
                    return true
                } else if l.end == n {
                    // `>` alone: a blank line in the quote ends the block.
                    endHTML()
                    inParagraph = false
                    paragraphInQuote = false
                    inTable = false
                    headerCells = nil
                    return false
                } else {
                    html!.text += "\n" + line
                    return true
                }
            } else {
                endHTML()       // the quote ended (an HTML block has no lazy lines)
                quoteItem = nil
            }
        } else if let h = html {
            if let c = h.container, !blank, cols.columns < c {
                // The list item ended (an HTML block has no lazy lines), and the block with it.
                endHTML()
                closeItems(rightOf: cols.columns)
            } else if let until = h.until {
                html!.text += "\n" + line
                if Self.ends(line.lowercased(), until) { endHTML() }
                inParagraph = false
                return true
            } else if blank {
                endHTML()
                inParagraph = false
                return false
            } else {
                html!.text += "\n" + line
                return true
            }
        }
        if let f = open, f.quote > 0 {
            // A line without the quote's markers ends the quote, and the fence in it.
            if let q = Self.afterQuotes(u, depth: f.quote, outer: f.outer) {
                let l = lead(after: q)
                if let c = f.container, l.end < n, l.columns < c {
                    open = nil      // the quoted list item ended, and the fence with it
                    quoteItem = nil
                } else {
                    if l.columns < (f.container ?? 0) + 4, closes(f, at: l.end) { open = nil }
                    inParagraph = false
                    return true
                }
            } else {
                open = nil
                quoteItem = nil
            }
        } else if let f = open {
            let l = cols
            if let c = f.container, !blank, l.columns < c {
                open = nil      // the list item ended, and the fence with it
                closeItems(rightOf: cols.columns)
            } else {
                if l.columns < (f.container ?? 0) + 4, closes(f, at: l.end) { open = nil }
                inParagraph = false
                return true
            }
        }
        if blank {
            inParagraph = false
            inTable = false
            headerCells = nil
            quoteItem = nil
            return false
        }
        // A paragraph in a container this line still belongs to (cmark-gfm's
        // rule for what may interrupt it).
        let continues = inParagraph && !(itemContent.map { cols.columns < $0 } ?? false) && !paragraphInQuote
        let itemStarted: Bool
        var emptyItem = false, itemCode = false, itemBlock = false
        /// A block quote right after the marker (`1. > text`): where it starts, and its column.
        var quoteFrom: (at: Int, column: Int)? = nil
        // The innermost item this line is far enough right to be in (lazy paragraph text aside).
        let lineBase = items.last(where: { $0 <= cols.columns }) ?? 0
        // A nested item may sit up to 3 columns right of the item's content (`1. a` / `    - b`).
        if let item = Self.listItem(u, indent: indent, interrupting: continues, maxIndent: lineBase + 3) {
            closeItems(rightOf: indent)
            items.append(item.column)
            itemStarted = true
            emptyItem = item.at == n
            itemCode = item.code
            // A fence right after the marker (`2. ```bash`, `- - ```text`) opens in the item.
            var content = item.column, at = item.at
            while !itemCode, at < n, let inner = Self.listItem(UnsafeBufferPointer(rebasing: u[at...]), indent: 0, interrupting: false, column: content) {
                if inner.code { at = n; break }
                if inner.at == n - at { emptyItem = true }   // `- 1.`: an empty item in the item
                content += inner.column
                at += inner.at
                items.append(content)
            }
            // A break or heading as the item's content (`1. ---`) is no paragraph for lazy lines.
            if !itemCode, at < n { itemBlock = Self.isBreak(u, from: at) || Self.isATXHeading(u, at: at) }
            if !itemCode, at < n, u[at] == 0x3E { quoteFrom = (at, content) }
            if !itemCode, let fence = Self.fenceRun(u, at: at) {
                open = Fence(char: fence.char, count: fence.count, container: content)
                inParagraph = false
                paragraphInQuote = false
                inTable = false
                headerCells = nil
                return true
            }
            // Raw HTML right after the marker (`1. <div>`) starts an HTML block in the item.
            if !itemCode, at < n, u[at] == 0x3C {
                let rest = String(decoding: UnsafeBufferPointer(rebasing: u[at...]), as: UTF8.self)
                if let until = Self.htmlStart(rest, continuesParagraph: false) {
                    html = HTMLBlock(until: until, container: content, text: String(line))
                    if let until, Self.ends(String(rest.lowercased().dropFirst()), until) { endHTML() }
                    inParagraph = false
                    paragraphInQuote = false
                    inTable = false
                    headerCells = nil
                    return true
                }
            }
        } else {
            itemStarted = false
            if !inParagraph { closeItems(rightOf: cols.columns) }
        }
        let base = itemStarted ? (itemContent ?? 0) : lineBase
        let relative = indent - (indent >= base ? base : 0)
        // A line left of the item's content that is not lazy paragraph text
        // (a fence, HTML, heading, quote or break) ends the list item.
        let outdented = itemContent.map { cols.columns < $0 } ?? false
        // Block quote markers: what follows them is indented from the quote's
        // content column, not from the start of the line.
        var quoteCode: Bool? = nil
        if (relative < 4 && first == 0x3E) || quoteFrom != nil {   // >
            // A quote left of the item's content ends it (no lazy line).
            if outdented && quoteFrom == nil { closeItems(rightOf: cols.columns) }
            var k = quoteFrom?.at ?? indent, col = quoteFrom?.column ?? indent, depth = 0, contentCol = col
            while k < n {
                var s = 0
                while s < 4, k + s < n, u[k + s] == Self.space { s += 1 }
                guard s <= 3, k + s < n, u[k + s] == 0x3E else { break }
                k += s + 1; col += s + 1; depth += 1; contentCol = col
                if k < n, u[k] == Self.space { k += 1; col += 1; contentCol = col }
                else if k < n, u[k] == Self.tab { contentCol = col + 1; break }   // one column of the tab follows the marker
            }
            var c = col, e = k
            while e < n, u[e] == Self.space || u[e] == Self.tab { c = u[e] == Self.tab ? (c / 4 + 1) * 4 : c + 1; e += 1 }
            if e == n {
                // `>` alone: a blank line inside the quote ends its paragraph.
                inParagraph = false
                paragraphInQuote = false
                inTable = false
                headerCells = nil
                return false
            }
            // List items inside the quote (spaces only after the markers).
            var quoteItemStarted = false, quoteItemAt = 0, quoteItemCode = false
            if contentCol == col {
                let sub = UnsafeBufferPointer(rebasing: u[k...])
                let subIndent = e - k
                if c - col == subIndent, let item = Self.listItem(sub, indent: subIndent, interrupting: inParagraph && paragraphInQuote, column: col) {
                    quoteItem = QuoteItem(depth: depth, content: item.column)
                    quoteItemStarted = true
                    quoteItemAt = item.at
                    quoteItemCode = item.code
                    emptyItem = item.at == sub.count   // `>-`
                } else if let q = quoteItem, q.depth != depth || (c - contentCol < q.content && !inParagraph) {
                    quoteItem = nil
                }
            } else {
                quoteItem = nil
            }
            let columns = c - contentCol, qBase = quoteItem?.content ?? 0
            let qRelative = columns - (columns >= qBase ? qBase : 0)
            if quoteItemStarted {
                quoteCode = quoteItemCode   // `> 1.     code`
            } else if !inParagraph || !paragraphInQuote {
                quoteCode = qRelative >= 4   // a new quote after a paragraph outside it starts afresh
            } else {
                quoteCode = false
            }
            // A fence in the quote (`> ```bash`), or right after a list marker in it (`> - ```bash`).
            var fenceAt: Int? = nil, container: Int? = nil
            if quoteItemStarted, let q = quoteItem {
                fenceAt = quoteItemCode ? nil : k + quoteItemAt
                container = q.content
            } else if qRelative < 4 {
                fenceAt = e
                container = quoteItem != nil && columns >= qBase ? qBase : nil
            }
            // A break, heading or setext underline in the quote (`>#`, `>-` under its text) is no paragraph for lazy lines.
            if let at = fenceAt, at < n {
                itemBlock = Self.isBreak(u, from: at) || Self.isATXHeading(u, at: at)
                    || (inParagraph && paragraphInQuote && !quoteItemStarted && Self.isUnderline(u, at: at))
            }
            if let at = fenceAt, let fence = Self.fenceRun(u, at: at) {
                open = Fence(char: fence.char, count: fence.count, container: container, quote: depth, outer: base)
                inParagraph = false
                paragraphInQuote = false
                inTable = false
                headerCells = nil
                return true
            }
            // Raw HTML in the quote (`> <details>`); a tag line cannot interrupt the quote's paragraph.
            if let at = fenceAt, at < n, u[at] == 0x3C {
                let rest = String(decoding: UnsafeBufferPointer(rebasing: u[at...]), as: UTF8.self)
                if let until = Self.htmlStart(rest, continuesParagraph: inParagraph && paragraphInQuote && !quoteItemStarted) {
                    html = HTMLBlock(until: until, container: container, text: String(line), quote: depth, outer: base)
                    if let until, Self.ends(String(rest.lowercased().dropFirst()), until) { endHTML() }
                    inParagraph = false
                    paragraphInQuote = false
                    inTable = false
                    headerCells = nil
                    return true
                }
            }
        } else if !inParagraph {
            quoteItem = nil
        }
        // Columns from the item's content (a tab-indented line may be in the item).
        let leadRelative = cols.columns - (cols.columns >= base ? base : 0)
        if leadRelative < 4, let fence = Self.fenceRun(u, at: cols.end) {
            closeItems(rightOf: cols.columns)
            open = Fence(char: fence.char, count: fence.count, container: itemContent)
            inParagraph = false
            inTable = false
            headerCells = nil
            return true
        }
        // A kind-7 tag line cannot interrupt such a paragraph.
        if leadRelative < 4, cols.end < n, u[cols.end] == 0x3C {   // <
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if let until = Self.htmlStart(trimmed, continuesParagraph: continues) {
                closeItems(rightOf: cols.columns)
                html = HTMLBlock(until: until, container: itemContent, text: String(line))
                if let until, Self.ends(String(trimmed.lowercased().dropFirst()), until) { endHTML() }
                inParagraph = false
                inTable = false
                headerCells = nil
                return true
            }
        }
        var isHeading = false
        if relative < 4 && first == 0x23 {   // #
            var k = indent
            while k < n && u[k] == 0x23 { k += 1 }
            // 1 to 6 # and then a space, a tab or the end of the line.
            isHeading = k - indent <= 6 && (k == n || u[k] == Self.space || u[k] == Self.tab)
        }
        let isBreak = relative < 4 && Self.isBreak(u, from: indent)
        if outdented && (isHeading || isBreak || first == 0x3E) { closeItems(rightOf: cols.columns) }
        // Headings, breaks and setext underlines end a paragraph; other text continues or starts one.
        var underline = false
        if continues && relative < 4 && first == 0x3D {   // = (a lazy line is no underline)
            var k = indent
            while k < n && u[k] == 0x3D { k += 1 }
            underline = restBlank(k)
        } else if continues && !itemStarted && relative < 4 && first == 0x2D {   // - (`-`, `--`: `---` is a break too)
            var k = indent
            while k < n && u[k] == 0x2D { k += 1 }
            underline = restBlank(k)
        }
        if inTable {
            if isHeading || isBreak || first == 0x3E || itemStarted || leadRelative >= 4 {
                inTable = false     // another block starts: the table ends
            } else {
                return false        // a row
            }
        } else if inParagraph, relative < 4, let header = headerCells, Self.delimiterCells(u, from: indent) == header {
            // A delimiter row under a header line: the paragraph's last line becomes a table.
            inTable = true
            inParagraph = false
            paragraphInQuote = false
            headerCells = nil
            return false
        }
        if let quoteCode {
            indentedCode = quoteCode
        } else if itemStarted {
            indentedCode = itemCode   // `1.     code`
        } else if !inParagraph && !itemStarted {
            // Columns, with tabs to the next multiple of 4, as CommonMark counts them.
            var columns = 0, k = 0
            while k < n, u[k] == Self.space || u[k] == Self.tab { columns = u[k] == Self.tab ? (columns / 4 + 1) * 4 : columns + 1; k += 1 }
            indentedCode = columns - (columns >= base ? base : 0) >= 4
        }
        let wasParagraph = inParagraph
        // Indented code (also tab-indented, or in a quote) is no paragraph for the next line to continue.
        inParagraph = !isHeading && !isBreak && !underline && !(relative >= 4 && !inParagraph) && !indentedCode
            && !emptyItem && !itemBlock   // an empty item, or one holding a break or heading, holds no paragraph
        if !inParagraph { paragraphInQuote = false }
        else if (relative < 4 && first == 0x3E) || quoteFrom != nil { paragraphInQuote = true }
        else if !wasParagraph || itemStarted { paragraphInQuote = false }
        headerCells = inParagraph && u.contains(0x7C) ? Self.cells(u, from: indent) : nil
        return false
    }

    /// Takes a line the Markdown parser reads as paragraph text whatever it
    /// holds: a line inside multi-line display math (`MathProtector` puts a
    /// filler there), so `- 2x` in it opens no list item.
    mutating func continueParagraph() {
        indentedCode = false
        inParagraph = true
        headerCells = nil
    }

    /// A fence opening at `p`: 3+ backticks (none in the info string) or tildes.
    private static func fenceRun(_ u: UnsafeBufferPointer<UInt8>, at p: Int) -> (char: UInt8, count: Int)? {
        guard p < u.count, u[p] == 0x60 || u[p] == 0x7E else { return nil }   // ` or ~
        let c = u[p]
        var run = 0
        while p + run < u.count && u[p + run] == c { run += 1 }
        guard run >= 3 else { return nil }
        if c == 0x60 { for k in (p + run)..<u.count where u[k] == 0x60 { return nil } }
        return (c, run)
    }

    /// Where the content starts after `depth` block quote markers (each up to
    /// 3 spaces, `>` and one optional space), past `outer` columns of list
    /// item indentation (tabs to the next multiple of 4; what a tab gives past
    /// them counts as spaces before the first `>`); nil when the line has
    /// fewer markers (or is blank). Also its column, and whether a tab right
    /// after the last `>` gives its first column as the marker's space.
    private static func afterQuotes(_ u: UnsafeBufferPointer<UInt8>, depth: Int, outer: Int) -> (at: Int, column: Int, tabSpace: Bool)? {
        let n = u.count
        var k = 0, column = 0
        while column < outer, k < n, u[k] == space || u[k] == tab {
            column = u[k] == tab ? (column / 4 + 1) * 4 : column + 1
            k += 1
        }
        if column < outer { return nil }
        var extra = column - outer   // columns of a tab past the item's indentation
        var tabSpace = false
        for _ in 0..<depth {
            var s = 0
            while s < 4, k + s < n, u[k + s] == space { s += 1 }
            guard s + extra <= 3, k + s < n, u[k + s] == 0x3E else { return nil }
            extra = 0
            k += s + 1
            column += s + 1
            tabSpace = false
            if k < n, u[k] == space { k += 1; column += 1 } else if k < n, u[k] == tab { tabSpace = true }
        }
        return (k, column, tabSpace)
    }

    /// Cells in a table row: `|`-separated (a `\|` does not separate), outer pipes optional.
    private static func cells(_ u: UnsafeBufferPointer<UInt8>, from: Int) -> Int {
        var lo = from, hi = u.count
        while hi > lo && (u[hi - 1] == space || u[hi - 1] == tab) { hi -= 1 }
        if lo < hi && u[lo] == 0x7C { lo += 1 }
        if hi > lo && u[hi - 1] == 0x7C && (hi - 2 < lo || u[hi - 2] != 0x5C) { hi -= 1 }
        var count = 1
        var k = lo
        while k < hi {
            if u[k] == 0x5C { k += 2; continue }
            if u[k] == 0x7C { count += 1 }
            k += 1
        }
        return count
    }

    /// The cell count of a delimiter row (`| --- | :-: |`), nil if it is not one.
    private static func delimiterCells(_ u: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard u.contains(0x7C) else { return nil }
        var lo = from, hi = u.count
        while hi > lo && (u[hi - 1] == space || u[hi - 1] == tab) { hi -= 1 }
        if lo < hi && u[lo] == 0x7C { lo += 1 }
        if hi > lo && u[hi - 1] == 0x7C { hi -= 1 }
        var count = 0
        var cell = UnsafeBufferPointer(rebasing: u[lo..<hi])[...]
        while true {
            let end = cell.firstIndex(of: 0x7C) ?? cell.endIndex
            var part = cell[cell.startIndex..<end]
            while let f = part.first, f == space || f == tab { part = part.dropFirst() }
            while let l = part.last, l == space || l == tab { part = part.dropLast() }
            if part.first == 0x3A { part = part.dropFirst() }
            if part.last == 0x3A { part = part.dropLast() }
            guard !part.isEmpty, part.allSatisfy({ $0 == 0x2D }) else { return nil }
            count += 1
            if end == cell.endIndex { break }
            cell = cell[cell.index(after: end)...]
        }
        return count
    }

    /// The parser joins top-level blocks after an HTML block that opens a
    /// `<details>` until the depth returns to zero (`MarkdownParser.parseFragment`).
    private mutating func endHTML() {
        guard let h = html else { return }
        html = nil
        guard h.container == nil, h.quote == 0, FastBytes.contains(h.text, 0x3C) else { return }
        let d = MarkdownParser.detailsDepth(h.text + "\n")   // the parser's raw HTML ends with the line break
        if detailsDepth == 0 {
            if d > 0 { detailsDepth = d }
        } else {
            detailsDepth = max(0, detailsDepth + d)
        }
    }

    /// If `trimmed` starts an HTML block, the marker that ends it
    /// (`.some(nil)`: the next blank line); nil when it starts none.
    static func htmlStart<S: StringProtocol>(_ trimmed: S, continuesParagraph: Bool) -> String?? {
        // By byte, as cmark-gfm: `>` followed by a variation selector or a
        // combining mark is one Character, and would not compare as `>`.
        let raw = Array(trimmed.utf8)
        let b = raw.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }   // ASCII lowercased
        func starts(_ p: String, _ a: [UInt8]) -> Bool { a.starts(with: p.utf8) }
        if starts("<!--", b) { return .some("-->") }
        if starts("<?", b) { return .some("?>") }
        if starts("<![CDATA[", raw) { return .some("]]>") }   // case-sensitive in CommonMark
        // Kind 4 (declarations): <! and an uppercase ASCII letter, as in the bundled cmark-gfm.
        if starts("<!", b), raw.count > 2, raw[2] >= 0x41 && raw[2] <= 0x5A { return .some(">") }
        guard b.first == 0x3C else { return nil }
        let closing = b.count > 1 && b[1] == 0x2F
        let tag = b.dropFirst(closing ? 2 : 1)   // at most one slash: <//div> is text
        func isLetter(_ c: UInt8) -> Bool { c >= 0x61 && c <= 0x7A }
        guard let first = tag.first, isLetter(first) else { return nil }
        let nameBytes = tag.prefix(while: { isLetter($0) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D })
        let name = String(decoding: nameBytes, as: UTF8.self)
        let rest = tag.dropFirst(nameBytes.count)
        let next = rest.first
        let ends = next == nil || next == 0x20 || next == 0x09 || next == 0x3E || (next == 0x2F && rest.dropFirst().first == 0x3E)
        if !closing, ends, next != 0x2F, Self.rawTags.contains(name) { return .some(Self.rawEnd) }
        if ends && Self.blockTags.contains(name) { return .some(nil) }
        let s = String(trimmed)
        if !continuesParagraph, Self.completeTag.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil {
            return .some(nil)
        }
        return nil
    }

    /// By byte, as `htmlStart`.
    private static func ends(_ lower: String, _ until: String) -> Bool {
        guard until == rawEnd else { return FastBytes.contains(lower, bytes: until) }
        return ["</pre>", "</script>", "</style>", "</textarea>"].contains { FastBytes.contains(lower, bytes: $0) }
    }

    /// A setext heading underline at `p`: a run of `=` or of `-`, then only white space.
    private static func isUnderline(_ u: UnsafeBufferPointer<UInt8>, at p: Int) -> Bool {
        guard p < u.count, u[p] == 0x3D || u[p] == 0x2D else { return false }
        var k = p
        while k < u.count && u[k] == u[p] { k += 1 }
        while k < u.count && (u[k] == space || u[k] == tab) { k += 1 }
        return k == u.count
    }

    /// An ATX heading at `p`: 1 to 6 `#`, then a space, a tab or the end of the line.
    private static func isATXHeading(_ u: UnsafeBufferPointer<UInt8>, at p: Int) -> Bool {
        var h = p
        while h < u.count && u[h] == 0x23 { h += 1 }
        return h > p && h - p <= 6 && (h == u.count || u[h] == space || u[h] == tab)
    }

    /// A thematic break: 3+ of the same `-`, `*` or `_`, spaces and tabs between.
    private static func isBreak(_ u: UnsafeBufferPointer<UInt8>, from: Int) -> Bool {
        guard from < u.count else { return false }
        let c = u[from]
        guard c == 0x2D || c == 0x2A || c == 0x5F else { return false }
        var count = 0
        for k in from..<u.count {
            if u[k] == c { count += 1 } else if u[k] != space && u[k] != tab { return false }
        }
        return count >= 3
    }

    /// A list item starting this line: up to 3 spaces, a bullet or 1-9
    /// digits and `.` or `)`, then white space (tabs to the next multiple of
    /// 4 columns, from `column`, the column of the buffer's start). Returns
    /// the content column (from the buffer's start) and where the content
    /// starts. 1-4 columns of white space before it; with 5 or more the
    /// content is indented code (`code`), one column past the marker; with
    /// nothing after the marker the item is empty (`at` is the end).
    /// When the line would interrupt a paragraph, only a bullet or a list
    /// starting at 1 counts, and not an empty item.
    private static func listItem(_ u: UnsafeBufferPointer<UInt8>, indent: Int, interrupting: Bool,
                                 column start: Int = 0, maxIndent: Int = 3) -> (column: Int, at: Int, code: Bool)? {
        let n = u.count
        guard indent <= maxIndent, indent < n else { return nil }
        var k = indent
        var number: Int? = nil
        let c = u[k]
        if c == 0x2D || c == 0x2A || c == 0x2B {
            k += 1
        } else if c >= 0x30 && c <= 0x39 {
            var v = 0
            while k < n, u[k] >= 0x30, u[k] <= 0x39, k - indent < 9 { v = v * 10 + Int(u[k] - 0x30); k += 1 }
            guard k < n, u[k] == 0x2E || u[k] == 0x29 else { return nil }
            number = v
            k += 1
        } else {
            return nil
        }
        var col = start + k, p = k
        while p < n, u[p] == space || u[p] == tab { col = u[p] == tab ? (col / 4 + 1) * 4 : col + 1; p += 1 }
        if p == n { return interrupting ? nil : (k + 1, n, false) }
        let width = col - (start + k)
        guard width >= 1 else { return nil }
        let next = u[p]
        if next == 0x0A || next == 0x0B || next == 0x0C || next == 0x0D { return nil }
        if interrupting, let number, number != 1 { return nil }
        if width >= 5 { return (k + 1, k, true) }
        return (col - start, p, false)
    }
}

/// The languages a document's code fences name: each fence info string's
/// first word, lowercased, in order of first use, each once. The page
/// starts loading their grammars while the document parses. Deliberately
/// over-inclusive, not CommonMark: on every line any run of spaces, tabs and
/// container markers (`>`, `-`, `+`, `*`, `1.`, `1)`) is skipped before a
/// fence of 3+ backticks or tildes. A line that only looks like a fence
/// costs one grammar loaded early; a fence missed, a plain first paint.
public enum FenceLanguages {
    /// Only the first `maxBytes` are looked at (a huge file's later fences load when shown).
    public static func scan(_ text: String, limit: Int = 16, maxBytes: Int = 4 << 20) -> [String] {
        if let r = text.utf8.withContiguousStorageIfAvailable({ scan($0, limit: limit, maxBytes: maxBytes) }) { return r }
        return Array(text.utf8.prefix(maxBytes)).withUnsafeBufferPointer { scan($0, limit: limit, maxBytes: maxBytes) }
    }

    private static func scan(_ b: UnsafeBufferPointer<UInt8>, limit: Int, maxBytes: Int) -> [String] {
        var out: [String] = []
        let n = min(b.count, maxBytes)
        var i = 0
        while i < n, out.count < limit {
            // Spaces, tabs, > - + * and digits followed by . or ): skipped.
            while i < n {
                let c = b[i]
                if c == 0x20 || c == 0x09 || c == 0x3E || c == 0x2D || c == 0x2B || c == 0x2A { i += 1; continue }
                if c >= 0x30, c <= 0x39 {
                    var k = i
                    while k < n, b[k] >= 0x30, b[k] <= 0x39 { k += 1 }
                    if k < n, b[k] == 0x2E || b[k] == 0x29 { i = k + 1; continue }
                }
                break
            }
            // A fence: 3+ backticks or tildes, then the info string's first word.
            if i < n, b[i] == 0x60 || b[i] == 0x7E {
                let fence = b[i], open = i
                while i < n, b[i] == fence { i += 1 }
                if i - open >= 3 {
                    while i < n, b[i] == 0x20 || b[i] == 0x09 { i += 1 }
                    let start = i
                    while i < n, i - start < 32, ![0x20, 0x09, 0x0A, 0x0D, 0x60, 0x7B].contains(b[i]) { i += 1 }   // space tab EOL ` {
                    if i > start, let word = String(bytes: UnsafeBufferPointer(rebasing: b[start..<i]), encoding: .utf8)?.lowercased(),
                       !out.contains(word) {
                        out.append(word)
                    }
                }
            }
            while i < n, b[i] != 0x0A { i += 1 }
            i += 1
        }
        return out
    }
}
