import Foundation
import Markdown

/// Renders swift-markdown nodes to HTML fragments.
struct HTMLRenderer {
    let math: MathProtector
    let resolver: ResourceResolver?
    /// Source lines (1-based access via `isBlank`), used to infer list tightness.
    var sourceLines: [Substring] = []
    /// Bare URLs become links, except inside a link (GFM never nests them).
    var autolinks = true
    /// What a soft line break renders as: a line break in the HTML source
    /// (a space on the page), or `<br>` in a paragraph of `Key: value` lines.
    var softBreak = "\n"

    func isBlank(_ line: Int) -> Bool {
        guard line >= 1, line <= sourceLines.count else { return false }
        return sourceLines[line - 1].allSatisfy { $0 == " " || $0 == "\t" }
    }

    // MARK: Inline

    func inline(_ node: Markup) -> String {
        var out = ""
        // A line break between two wide CJK characters is no space (CSS Text's
        // segment break rule, which WebKit does not apply): decided once the
        // child after it is known.
        var previous: Markup? = nil
        var pendingBreak = false
        for child in node.children {
            if child is SoftBreak, softBreak == "\n" {
                if pendingBreak { out += softBreak }
                pendingBreak = true
                continue
            }
            if pendingBreak {
                pendingBreak = false
                let joined = previous.flatMap { Self.edge($0, last: true) }.map(CJKText.isWideNonHangul) == true
                    && Self.edge(child, last: false).map(CJKText.isWideNonHangul) == true
                if !joined { out += softBreak }
            }
            out += inlineNode(child)
            previous = child
        }
        if pendingBreak { out += softBreak }
        // Lines taken into multi-line display math leave a filler (MathProtector.protect).
        if out.utf8.contains(0xEE), out.contains(MathProtector.filler) {
            out = out.replacingOccurrences(of: "\n" + String(MathProtector.filler), with: "")
                .replacingOccurrences(of: String(MathProtector.filler), with: "")
        }
        return out
    }

    /// The last (or first) code point of an inline's text, through emphasis
    /// and links; nil for code, images, HTML and breaks. Emphasis markers
    /// (`CJKEmphasis`) are skipped; a math or footnote token counts as itself.
    static func edge(_ node: Markup, last: Bool) -> UInt32? {
        switch node {
        case let t as Text:
            let scalars = t.string.unicodeScalars
            let found = last ? scalars.last { $0 != CJKEmphasis.neutral && $0 != CJKEmphasis.punctuation }
                : scalars.first { $0 != CJKEmphasis.neutral && $0 != CJKEmphasis.punctuation }
            return found?.value
        case is Emphasis, is Strong, is Strikethrough, is Link:
            let kids = Array(node.children)
            guard let k = last ? kids.last : kids.first else { return nil }
            return edge(k, last: last)
        default:
            return nil
        }
    }

    func inlineNode(_ node: Markup) -> String {
        switch node {
        case let t as Text:
            return math.restore(inHTML: autolinks ? autolink(t.string) : HTML.escape(t.string))
        case let e as Emphasis:
            return "<em>\(inline(e))</em>"
        case let s as Strong:
            return "<strong>\(inline(s))</strong>"
        case let s as Strikethrough:
            return "<del>\(inline(s))</del>"
        case let c as InlineCode:
            let code = math.restore(plain: c.code)
            if let ref = resolver?.pathReference(code) {
                var attrs = "data-path=\"\(HTML.escape(ref.path))\""
                if let l = ref.line { attrs += " data-line=\"\(l)\"" }
                if let col = ref.column { attrs += " data-col=\"\(col)\"" }
                return "<code class=\"path-link\" \(attrs)>\(HTML.escape(code))</code>"
            }
            return "<code>\(HTML.escape(code))</code>"
        case let l as Link:
            let dest = math.restore(plain: l.destination ?? "")
            var title = ""
            if let t = l.title, !t.isEmpty { title = " title=\"\(HTML.escape(t))\"" }
            var inner = self
            inner.autolinks = false
            return "<a href=\"\(HTML.escape(HTML.safeLink(dest)))\"\(title)>\(inner.inline(l))</a>"
        case let img as Image:
            return image(img)
        case is SoftBreak:
            return softBreak
        case is LineBreak:
            return "<br>"
        case let h as InlineHTML:
            return HTML.sanitize(h.rawHTML, resolver: resolver)
        case let s as SymbolLink:
            return "<code>\(HTML.escape(s.destination ?? ""))</code>"
        default:
            return inline(node)
        }
    }

    private func image(_ img: Image) -> String {
        let src = math.restore(plain: img.source ?? "")
        let alt = HTML.escape(math.restore(plain: img.plainText))
        var title = ""
        if let t = img.title, !t.isEmpty { title = " title=\"\(HTML.escape(math.restore(plain: t)))\"" }
        guard let resolver else {
            return "<img src=\"\(HTML.escape(src))\" alt=\"\(alt)\"\(title) loading=\"lazy\">"
        }
        let r = resolver.image(src)
        var dims = ""
        if let w = r.width, let h = r.height, w > 0, h > 0 {
            dims = " width=\"\(w)\" height=\"\(h)\" style=\"aspect-ratio:\(w)/\(h)\""
        }
        if r.remote {
            return "<span class=\"remote-img\" data-tag=\"img\" data-src=\"\(HTML.escape(r.url))\" data-alt=\"\(alt)\"></span>"
        }
        return "<img src=\"\(HTML.escape(r.url))\" alt=\"\(alt)\"\(title)\(dims) loading=\"lazy\" decoding=\"async\">"
    }

    /// GFM extended autolinks: http(s) URLs, `www.` hosts and email addresses.
    /// Trailing punctuation (ASCII and CJK) is left out of the link, and so
    /// are the private-use tokens standing for math and footnote references.
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"\b(?:https?|ftp)://[^\s<>"'`\x{E000}-\x{E004}]+[^\s<>"'`\x{E000}-\x{E004}.,;:!?)\]}，。；：！？）】]"#
            + #"|(?<![\w.@/:-])www\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*(?:[/?#][^\s<>"'`\x{E000}-\x{E004}]*[^\s<>"'`\x{E000}-\x{E004}.,;:!?)\]}，。；：！？）】])?"#
            + #"|(?<![\w.+-])[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9_-]+)*\.[A-Za-z0-9_-]*[A-Za-z](?![-_\w])"#)

    /// `&amp;` followed by letters and digits just before a `;` reads as an entity reference: GFM leaves it out of the link.
    private static let trailingEntity = try! NSRegularExpression(pattern: #"&[A-Za-z0-9]+$"#)

    /// Escapes text and links bare URLs, `www.` hosts and emails (GFM autolink extension).
    private func autolink(_ text: String) -> String {
        guard text.utf8.contains(0x3A) /* ":" */ || text.utf8.contains(0x40) /* "@" */ || text.contains("www.")
        else { return HTML.escape(text) }
        let ns = text as NSString
        let fullLength = ns.length
        var out = ""
        var last = 0
        for m in HTMLRenderer.urlRegex.matches(in: text, range: NSRange(location: 0, length: fullLength)) {
            out += HTML.escape(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            // The regex strips every trailing ")", but GFM keeps balanced
            // ones: https://en.wikipedia.org/wiki/X_(film) must link fully.
            // Reclaim ")" chars that follow the match while parens balance.
            var url = ns.substring(with: m.range)
            var end = m.range.location + m.range.length
            var open = 0
            for ch in url.utf16 {
                if ch == 0x28 { open += 1 } else if ch == 0x29 { open -= 1 }
            }
            while open > 0, end < fullLength, ns.character(at: end) == 0x29 /* ")" */ {
                url.append(")")
                end += 1
                open -= 1
            }
            if end < fullLength, ns.character(at: end) == 0x3B /* ";" */,
               let e = HTMLRenderer.trailingEntity.firstMatch(in: url, range: NSRange(location: 0, length: (url as NSString).length)) {
                end -= e.range.length
                url = (url as NSString).substring(to: e.range.location)
            }
            let href = url.hasPrefix("www.") ? "http://" + url
                : (url.contains("@") && !url.contains("://") ? "mailto:" + url : url)
            out += "<a href=\"\(HTML.escape(href))\">\(Self.breakable(url))</a>"
            last = end
        }
        out += HTML.escape(ns.substring(from: last))
        return out
    }

    /// A long URL's visible text with break opportunities (`<wbr>`) after
    /// `/`, `?`, `&` and `=` past the scheme, so it wraps at its parts
    /// instead of overflowing or breaking anywhere. The link itself is unchanged.
    static func breakable(_ url: String) -> String {
        guard url.count > 40 else { return HTML.escape(url) }
        var out = ""
        let start = url.range(of: "://")?.upperBound ?? url.startIndex
        var i = url.startIndex
        while i < url.endIndex {
            let c = url[i]
            out += HTML.escape(String(c))
            let next = url.index(after: i)
            if i >= start, next < url.endIndex, c == "/" || c == "?" || c == "&" || c == "=" { out += "<wbr>" }
            i = next
        }
        return out
    }

    /// Every line of the paragraph (at least two) reads `Key: value`
    /// (`Run: make test` / `Expected: ok`, `状态：完成`, `**Key:** value`): a
    /// short label, then an ASCII colon and white space, or a fullwidth colon.
    static func isKeyValueLines(_ p: Paragraph) -> Bool {
        // One source line: no line break (cheap, before walking the inlines).
        if let r = p.range, r.upperBound.line <= r.lowerBound.line { return false }
        guard p.children.contains(where: { $0 is SoftBreak || $0 is LineBreak }) else { return false }
        var lines = [""]
        for child in p.children {
            if child is SoftBreak || child is LineBreak { lines.append("") } else { lines[lines.count - 1] += MarkdownParser.headingText(child) }
        }
        return lines.count >= 2 && lines.allSatisfy(isKeyValueLine)
    }

    static func isKeyValueLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let colon = t.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let key = t[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.count <= 24, key.split(separator: " ").count <= 4,
              key.contains(where: { $0.isLetter || $0.isNumber }),
              !key.contains(where: { ",;!?。，；！？、".contains($0) }), !key.contains(". ") else { return false }
        if t[colon] == "：" { return true }
        let after = t.index(after: colon)
        return after == t.endIndex || t[after] == " " || t[after] == "\t"
    }

    /// The paragraph ends with a colon (`:` or `：`, emphasis around it
    /// allowed): it leads into what follows, and the page sets a list right
    /// under it close to it, as one unit (`p.lead`).
    static func isLeadIn(_ p: Paragraph) -> Bool {
        guard let last = p.children.reversed().first(where: { !($0 is SoftBreak || $0 is LineBreak) }),
              let c = edge(last, last: true) else { return false }
        return c == 0x3A || c == 0xFF1A
    }

    /// The paragraph holds one image and nothing else (a link around it allowed).
    static func isImageOnly(_ p: Paragraph) -> Bool {
        func content(_ m: Markup) -> [Markup] {
            m.children.filter { !($0 is SoftBreak) && !(($0 as? Text)?.string.allSatisfy(\.isWhitespace) ?? false) }
        }
        guard p.childCount <= 3 else { return false }   // an image, and white space or breaks around it
        let kids = content(p)
        guard kids.count == 1 else { return false }
        if kids[0] is Image { return true }
        guard let link = kids[0] as? Link else { return false }
        let inner = content(link)
        return inner.count == 1 && inner[0] is Image
    }

    // MARK: Blocks

    func block(_ node: Markup, tight: Bool = false) -> String {
        switch node {
        case let p as Paragraph:
            var r = self
            if Self.isKeyValueLines(p) { r.softBreak = "<br>" }
            let body = r.inline(p)
            if tight { return body }
            if Self.isImageOnly(p) { return "<p class=\"img-only\">\(body)</p>" }
            return Self.isLeadIn(p) ? "<p class=\"lead\">\(body)</p>" : "<p>\(body)</p>"
        case let h as Heading:
            return "<h\(h.level)>\(inline(h))</h\(h.level)>"
        case let q as BlockQuote:
            return "<blockquote>\(children(q))</blockquote>"
        case let c as CodeBlock:
            return codeBlock(language: c.language, code: c.code)
        case is ThematicBreak:
            return "<hr>"
        case let h as HTMLBlock:
            return HTML.sanitize(h.html, resolver: resolver)
        case let l as UnorderedList:
            let tight = isTight(l)
            return "<ul>" + l.listItems.map { listItem($0, tight: tight) }.joined() + "</ul>"
        case let l as OrderedList:
            let tight = isTight(l)
            let start = l.startIndex == 1 ? "" : " start=\"\(l.startIndex)\""
            let width = Self.numberWidthClass(start: Int(l.startIndex), count: l.childCount).map { " class=\"\($0)\"" } ?? ""
            return "<ol\(width)\(start)>" + l.listItems.map { listItem($0, tight: tight) }.joined() + "</ol>"
        case let t as Table:
            return table(t)
        default:
            return children(node)
        }
    }

    /// `ol-w3`, `ol-w4` or `ol-w5` (5 and more) for an ordered list whose
    /// largest number has that many digits, so its markers get room; nil up to 99.
    static func numberWidthClass(start: Int, count: Int) -> String? {
        let digits = String(max(start, start + count - 1)).count
        return digits >= 3 ? "ol-w\(min(digits, 5))" : nil
    }

    func children(_ node: Markup, tight: Bool = false) -> String {
        node.children.map { block($0, tight: tight) }.joined(separator: tight ? "\n" : "")
    }

    func listItem(_ item: ListItem, tight: Bool) -> String {
        var body = ""
        var cls = ""
        if let cb = item.checkbox {
            cls = " class=\"task\""
            body += "<span class=\"task-box\(cb == .checked ? " checked" : "")\" aria-hidden=\"true\"></span>"
        }
        body += children(item, tight: tight)
        return "<li\(cls)>\(body)</li>"
    }

    func codeBlock(language: String?, code: String) -> String {
        let lang = (language ?? "").split(separator: " ").first.map(String.init) ?? ""
        var code = code
        if code.hasSuffix("\n") { code.removeLast() }
        // Terminal colours pasted from a shell (`ESC[1;32m`) are not text.
        if code.utf8.contains(0x1B) { code = code.replacingOccurrences(of: "\u{1B}\\[[0-9;:]*m", with: "", options: .regularExpression) }
        let langAttr = lang.isEmpty ? "" : " data-lang=\"\(HTML.escape(lang.lowercased()))\""
        return "<div class=\"code-block\"\(langAttr)><pre><code>\(HTML.escape(code))</code></pre></div>"
    }

    func table(_ t: Table) -> String {
        let aligns = t.columnAlignments
        func align(_ i: Int) -> String {
            guard i < aligns.count, let a = aligns[i] else { return "" }
            switch a {
            case .left: return " style=\"text-align:left\""
            case .center: return " style=\"text-align:center\""
            case .right: return " style=\"text-align:right\""
            }
        }
        // Columns without an alignment whose body cells are all numbers (or
        // empty or a placeholder, at least one a number): class "num", aligned right by the page.
        var numeric = Set<Int>()
        let columns = max(aligns.count, t.head.childCount)
        for i in 0..<columns where i >= aligns.count || aligns[i] == nil {
            var sawNumber = false, allNumbers = true
            for row in t.body.rows {
                guard let c = row.child(at: i) as? Table.Cell else { continue }
                let text = c.plainText.trimmingCharacters(in: .whitespaces)
                if text.isEmpty || Self.isPlaceholder(text) { continue }
                if Self.isNumber(text) { sawNumber = true } else { allNumbers = false; break }
            }
            if sawNumber && allNumbers { numeric.insert(i) }
        }
        func cellAttrs(_ c: Table.Cell, _ i: Int) -> String {
            var s = numeric.contains(i) ? " class=\"num\"" : align(i)
            if c.colspan > 1 { s += " colspan=\"\(c.colspan)\"" }
            if c.rowspan > 1 { s += " rowspan=\"\(c.rowspan)\"" }
            return s
        }
        var out = "<div class=\"table-wrap\"><table><thead><tr>"
        for (i, c) in t.head.cells.enumerated() where c.colspan > 0 {
            out += "<th\(cellAttrs(c, i))>\(inline(c))</th>"
        }
        out += "</tr></thead><tbody>"
        for row in t.body.rows {
            out += "<tr>"
            for (i, c) in row.cells.enumerated() where c.colspan > 0 && c.rowspan > 0 {
                out += "<td\(cellAttrs(c, i))>\(inline(c))</td>"
            }
            out += "</tr>"
        }
        out += "</tbody></table></div>"
        return out
    }

    /// A number as tables hold them: an optional sign, currency or
    /// approximation, digits with separators, an optional unit or `%`, and
    /// an optional footnote star (`12 ms`, `−3%`, `$5`, `~10k`, `3 GiB`, `2.5×`).
    /// At most one decimal point and none at the end, commas only between
    /// groups of three: versions, addresses and list-like steps (`1.0.0`,
    /// `10.0.0.1`, `1.`) are not numbers.
    private static let numberPattern = try! NSRegularExpression(
        pattern: #"^[-+−$€£¥~≈<>]?\s*(?:(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|\.\d+)\s*(?:%|ms|[µμ]s|s|x|×|[KMGT]i?B|k|M)?\*?$"#)

    /// What a table puts where a number is missing: `-`, `–`, `—`, `N/A`, `TBD`.
    static func isPlaceholder(_ text: String) -> Bool {
        text == "-" || text == "–" || text == "—" || text.caseInsensitiveCompare("N/A") == .orderedSame
            || text.caseInsensitiveCompare("TBD") == .orderedSame
    }

    static func isNumber(_ text: String) -> Bool {
        guard text.utf8.count <= 40, text.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 }) else { return false }
        return numberPattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// cmark-gfm's tightness is not exposed by swift-markdown, so infer it from the source:
    /// a list is loose if a blank line separates two items, or two direct children of an item.
    func isTight(_ list: ListItemContainer) -> Bool {
        var first = true
        for item in list.listItems {
            guard let r = item.range else { continue }
            if !first && isBlank(r.lowerBound.line - 1) { return false }
            first = false
            var firstChild = true
            for child in item.children {
                guard let cr = child.range else { continue }
                if !firstChild && isBlank(cr.lowerBound.line - 1) { return false }
                firstChild = false
            }
        }
        return true
    }
}

extension HTMLBlock {
    /// The raw HTML without the blank lines cmark keeps at its end or not,
    /// depending on what follows the block.
    var html: String {
        var s = rawHTML
        while s.hasSuffix("\n\n") { s.removeLast() }
        return s
    }
}
