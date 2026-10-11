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
///   the first non-blank line indented less than the item's content.
/// - HTML blocks: `<!--` … `-->`, `<pre>`/`<script>`/`<style>`/`<textarea>`
///   … their closing tag, `<?` … `?>`, `<![CDATA[` … `]]>`; a block-level tag
///   (`<div>`, `<details>`, …) up to the next blank line; and any other tag
///   alone on a line, when it does not continue a paragraph, up to the next
///   blank line. Inside them, nothing is code and nothing is Markdown.
/// - `<details>` opened by HTML blocks: the parser joins everything up to
///   the closing tag into one block, so its depth is tracked too.
struct FenceTracker {
    private(set) var open: (char: UInt8, count: Int, container: Int?)? = nil
    /// The open HTML block: the marker that ends it (nil: the next blank
    /// line), the content column of the list item holding it, and its text.
    private var html: (until: String?, container: Int?, text: String)? = nil
    /// The previous line belongs to a paragraph (a tag line then cannot start an HTML block of kind 7).
    private var inParagraph = false
    /// That paragraph sits in a block quote.
    private var paragraphInQuote = false
    /// Cells of the previous line, when it was paragraph text with a `|` (a table header candidate).
    private var headerCells: Int? = nil
    /// Inside a GFM table: rows are not paragraph text, so other blocks (raw HTML of any kind) may start.
    private var inTable = false
    /// Content column of the list item the current line belongs to, if any.
    private var itemContent: Int? = nil
    /// Depth of the `<details>` the parser is joining top-level blocks into (0: none).
    private(set) var detailsDepth = 0

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

        if let h = html {
            if let c = h.container, !blank, indent < c {
                // The list item ended (an HTML block has no lazy lines), and the block with it.
                endHTML()
                itemContent = nil
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
        if let f = open {
            if let c = f.container, !blank, indent < c {
                open = nil      // the list item ended, and the fence with it
                itemContent = nil
            } else {
                if indent < (f.container ?? 0) + 4, first == f.char {
                    var run = 0
                    while indent + run < n && u[indent + run] == f.char { run += 1 }
                    if run >= f.count && restBlank(indent + run) { open = nil }
                }
                inParagraph = false
                return true
            }
        }
        if blank {
            inParagraph = false
            inTable = false
            headerCells = nil
            return false
        }
        // A paragraph in a container this line still belongs to (cmark-gfm's
        // rule for what may interrupt it).
        let continues = inParagraph && !(itemContent.map { indent < $0 } ?? false) && !paragraphInQuote
        let itemStarted: Bool
        if let content = Self.listItem(u, indent: indent, interrupting: continues) {
            itemContent = content
            itemStarted = true
        } else {
            itemStarted = false
            if let c = itemContent, indent < c, !inParagraph { itemContent = nil }
        }
        let base = itemContent ?? 0
        let relative = indent - (indent >= base ? base : 0)
        // A line left of the item's content that is not lazy paragraph text
        // (a fence, HTML, heading, quote or break) ends the list item.
        let outdented = itemContent != nil && indent < base
        if relative < 4, first == 0x60 || first == 0x7E {   // ` or ~
            var run = 0
            while indent + run < n && u[indent + run] == first { run += 1 }
            var backtickInInfo = false
            if first == 0x60 { for k in (indent + run)..<n where u[k] == 0x60 { backtickInInfo = true; break } }
            if run >= 3 && !backtickInInfo {
                if outdented { itemContent = nil }
                open = (first, run, itemContent != nil ? base : nil)
                inParagraph = false
                inTable = false
                headerCells = nil
                return true
            }
        }
        // A kind-7 tag line cannot interrupt such a paragraph.
        if relative < 4, first == 0x3C {   // <
            let trimmed = line.drop(while: { $0 == " " })
            if let until = htmlStart(trimmed, continuesParagraph: continues) {
                if outdented { itemContent = nil }
                html = (until, itemContent != nil ? base : nil, String(line))
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
            isHeading = k == n || u[k] == Self.space || u[k] == Self.tab
        }
        let isBreak = relative < 4 && Self.isBreak(u, from: indent)
        if outdented && (isHeading || isBreak || first == 0x3E) { itemContent = nil }
        // Headings, breaks and setext underlines end a paragraph; other text continues or starts one.
        var underline = false
        if inParagraph && relative < 4 && first == 0x3D {   // =
            var k = indent
            while k < n && u[k] == 0x3D { k += 1 }
            underline = restBlank(k)
        }
        if inTable {
            if isHeading || isBreak || first == 0x3E || itemStarted || relative >= 4 {
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
        let wasParagraph = inParagraph
        inParagraph = !isHeading && !isBreak && !underline && !(relative >= 4 && !inParagraph)
        if !inParagraph { paragraphInQuote = false }
        else if relative < 4 && first == 0x3E { paragraphInQuote = true }
        else if !wasParagraph || itemStarted { paragraphInQuote = false }
        headerCells = inParagraph && u.contains(0x7C) ? Self.cells(u, from: indent) : nil
        return false
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
        guard h.container == nil, h.text.contains("<") else { return }
        let d = MarkdownParser.detailsDepth(h.text)
        if detailsDepth == 0 {
            if d > 0 { detailsDepth = d }
        } else {
            detailsDepth = max(0, detailsDepth + d)
        }
    }

    /// If `trimmed` starts an HTML block, the marker that ends it
    /// (`.some(nil)`: the next blank line); nil when it starts none.
    private func htmlStart<S: StringProtocol>(_ trimmed: S, continuesParagraph: Bool) -> String?? {
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<!--") { return .some("-->") }
        if lower.hasPrefix("<?") { return .some("?>") }
        if lower.hasPrefix("<![cdata[") { return .some("]]>") }
        if lower.hasPrefix("<!"), lower.dropFirst(2).first?.isLetter == true { return .some(">") }
        let afterBracket = lower.dropFirst()
        let closing = afterBracket.hasPrefix("/")
        let name = String(afterBracket.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" }))
        guard !name.isEmpty else { return nil }
        let next = afterBracket.drop(while: { $0 == "/" }).dropFirst(name.count).first
        let ends = next == nil || next == " " || next == "\t" || next == ">" || (next == "/" && afterBracket.drop(while: { $0 == "/" }).dropFirst(name.count + 1).first == ">")
        if !closing, ends, next != "/", Self.rawTags.contains(name) { return .some(Self.rawEnd) }
        if ends && Self.blockTags.contains(name) { return .some(nil) }
        let s = String(trimmed)
        if !continuesParagraph, Self.completeTag.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil {
            return .some(nil)
        }
        return nil
    }

    private static func ends(_ lower: String, _ until: String) -> Bool {
        guard until == rawEnd else { return lower.contains(until) }
        return lower.contains("</pre>") || lower.contains("</script>") || lower.contains("</style>") || lower.contains("</textarea>")
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

    /// The content column of a list item starting this line: up to 3 spaces,
    /// a bullet or 1-9 digits and `.` or `)`, then 1-4 spaces before text.
    /// When the line would interrupt a paragraph, only a bullet or a list
    /// starting at 1 counts.
    private static func listItem(_ u: UnsafeBufferPointer<UInt8>, indent: Int, interrupting: Bool) -> Int? {
        let n = u.count
        guard indent <= 3, indent < n else { return nil }
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
        var spaces = 0
        while k + spaces < n && u[k + spaces] == space { spaces += 1 }
        guard spaces >= 1 && spaces <= 4, k + spaces < n else { return nil }
        let next = u[k + spaces]
        if next == tab || next == 0x0A || next == 0x0B || next == 0x0C || next == 0x0D { return nil }
        if next >= 0x80 {
            // Unicode white space (no-break space, ideographic space) is not text.
            var it = String(decoding: UnsafeBufferPointer(rebasing: u[(k + spaces)...]), as: UTF8.self).unicodeScalars.makeIterator()
            if let scalar = it.next(), scalar.properties.isWhitespace { return nil }
        }
        if interrupting, let number, number != 1 { return nil }
        return k + spaces
    }
}
