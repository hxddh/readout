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
    private(set) var open: (char: Character, count: Int, container: Int?)? = nil
    /// The open HTML block: the marker that ends it (nil: the next blank
    /// line), the content column of the list item holding it, and its text.
    private var html: (until: String?, container: Int?, text: String)? = nil
    /// The previous line belongs to a paragraph (a tag line then cannot start an HTML block of kind 7).
    private var inParagraph = false
    /// That paragraph sits in a block quote.
    private var paragraphInQuote = false
    /// Content column of the list item the current line belongs to, if any.
    private var itemContent: Int? = nil
    /// Depth of the `<details>` the parser is joining top-level blocks into (0: none).
    private(set) var detailsDepth = 0

    /// Inside code or raw HTML, or inside a `<details>` the parser will join.
    var isOpen: Bool { open != nil || html != nil || detailsDepth > 0 }

    private static let marker = try! NSRegularExpression(pattern: #"^( {0,3})([-*+]|\d{1,9}[.)])( {1,4})(?=\S)"#)
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup",
        "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame",
        "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link",
        "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search", "section",
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
        let trimmed = line.drop(while: { $0 == " " })
        let indent = line.count - trimmed.count
        let blank = trimmed.allSatisfy { $0 == " " || $0 == "\t" }

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
                if indent < (f.container ?? 0) + 4, trimmed.first == f.char {
                    let run = trimmed.prefix(while: { $0 == f.char }).count
                    if run >= f.count && trimmed.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) { open = nil }
                }
                inParagraph = false
                return true
            }
        }
        if blank {
            inParagraph = false
            return false
        }
        let s = String(line)
        let ns = s as NSString
        // A paragraph in a container this line still belongs to (cmark-gfm's
        // rule for what may interrupt it).
        let continues = inParagraph && !(itemContent.map { indent < $0 } ?? false) && !paragraphInQuote
        var item = Self.marker.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
        if let m = item, continues {
            // Only a bullet or a list starting at 1 interrupts a paragraph.
            let number = ns.substring(with: m.range(at: 2)).dropLast()
            if !number.isEmpty && number.drop(while: { $0 == "0" }) != "1" { item = nil }
        }
        if let m = item {
            itemContent = m.range.length
        } else if let c = itemContent, indent < c, !inParagraph {
            itemContent = nil
        }
        let base = itemContent ?? 0
        let relative = indent - (indent >= base ? base : 0)
        // A line left of the item's content that is not lazy paragraph text
        // (a fence, HTML, heading, quote or break) ends the list item.
        let outdented = itemContent != nil && indent < base
        if relative < 4, let c = trimmed.first, c == "`" || c == "~" {
            let run = trimmed.prefix(while: { $0 == c }).count
            if run >= 3 && !(c == "`" && trimmed.dropFirst(run).contains("`")) {
                if outdented { itemContent = nil }
                open = (c, run, itemContent != nil ? base : nil)
                inParagraph = false
                return true
            }
        }
        // A kind-7 tag line cannot interrupt such a paragraph.
        if relative < 4, trimmed.hasPrefix("<"), let until = htmlStart(trimmed, continuesParagraph: continues) {
            if outdented { itemContent = nil }
            html = (until, itemContent != nil ? base : nil, s)
            if let until, Self.ends(String(trimmed.lowercased().dropFirst()), until) { endHTML() }
            inParagraph = false
            return true
        }
        let isHeading = relative < 4 && trimmed.hasPrefix("#") && (trimmed.drop(while: { $0 == "#" }).first.map { $0 == " " || $0 == "\t" } ?? true)
        let isBreak = relative < 4 && Self.isBreak(trimmed)
        if outdented && (isHeading || isBreak || trimmed.hasPrefix(">")) { itemContent = nil }
        // Headings, breaks and setext underlines end a paragraph; other text continues or starts one.
        let underline = inParagraph && relative < 4 && trimmed.allSatisfy { $0 == "=" || $0 == " " || $0 == "\t" }
        let wasParagraph = inParagraph
        inParagraph = !isHeading && !isBreak && !underline && !(relative >= 4 && !inParagraph)
        if !inParagraph { paragraphInQuote = false }
        else if relative < 4 && trimmed.hasPrefix(">") { paragraphInQuote = true }
        else if !wasParagraph || item != nil { paragraphInQuote = false }
        return false
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

    private static func isBreak<S: StringProtocol>(_ trimmed: S) -> Bool {
        let chars = trimmed.filter { $0 != " " && $0 != "\t" }
        guard let c = chars.first, c == "-" || c == "*" || c == "_" else { return false }
        return chars.count >= 3 && chars.allSatisfy { $0 == c }
    }
}
