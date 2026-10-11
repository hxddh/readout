import Foundation
import Markdown

/// Parses Markdown source into a flat sequence of `Block`s.
///
/// Parsing has two stages so that `IncrementalParser` can redo only part of
/// a document: `parseFragment` turns a run of lines into blocks that depend
/// on nothing outside it (line numbers relative to the run, headings without
/// their anchor, footnote references as placeholders), and `assemble` adds
/// everything that depends on the whole document: line offsets, heading
/// paths, de-duplicated heading anchors, footnote numbers and the footnotes
/// section, and the title. A full parse is one fragment.
public enum MarkdownParser {
    public static func parse(_ rawSource: String, resolver: ResourceResolver? = nil,
                             cache: RenderCache? = nil) -> ParsedDocument {
        let lines = sourceLines(rawSource)
        return assemble([(offset: 0, fragment: parseFragment(lines, atDocumentStart: true, resolver: resolver, cache: cache))])
    }

    /// Normalized source lines: no BOM, LF line endings.
    static func sourceLines(_ rawSource: String) -> [String] {
        var source = rawSource
        if source.utf8.starts(with: [0xEF, 0xBB, 0xBF]) { source.removeFirst() }
        if source.utf8.contains(0x0D) {
            source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        // Split on bytes: Character iteration is several times slower.
        return source.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { String(Substring($0)) }
    }

    /// Adds document-wide context to fragments' blocks, in order: absolute
    /// line numbers, heading paths, unique heading anchors (and the heading
    /// HTML that carries them) and the document title.
    /// The blocks of a run of lines and the footnote definitions it holds.
    struct Fragment: Sendable {
        var blocks: [Block]
        var notes: [Footnotes.Note] = []
    }

    static func assemble(_ fragments: [(offset: Int, fragment: Fragment)]) -> ParsedDocument {
        var out: [Block] = []
        out.reserveCapacity(fragments.reduce(0) { $0 + $1.fragment.blocks.count } + 1)
        var numbering = Footnotes.Numbering()
        var notes: [Footnotes.Note] = []
        var headingStack: [(level: Int, title: String)] = []
        var currentPath: [String] = []   // headingStack's titles, shared by the blocks under it
        var slugger = Slugger()
        var title: String? = nil
        for (offset, fragment) in fragments {
            for var n in fragment.notes {
                n.lines = (n.lines.lowerBound + offset)...(n.lines.upperBound + offset)
                notes.append(n)
            }
            for b in fragment.blocks {
                let lines = (b.lines.lowerBound + offset)...(b.lines.upperBound + offset)
                var html = numbering.fill(b.html)
                var anchor: String? = nil
                let path: [String]
                if b.kind == .heading, let level = b.headingLevel, let titleText = b.headingTitle {
                    while let last = headingStack.last, last.level >= level { headingStack.removeLast() }
                    path = headingStack.map(\.title)
                    let a = slugger.next(titleText)
                    anchor = a
                    html = "<h\(level) id=\"\(HTML.escape(a))\">\(html)</h\(level)>"
                    headingStack.append((level, titleText))
                    currentPath = headingStack.map(\.title)
                    if title == nil && level == 1 { title = titleText }
                } else {
                    path = b.kind == .footnotes || b.kind == .frontMatter ? [] : currentPath
                }
                var nb = Block(kind: b.kind, headingPath: path, lines: lines, fingerprint: b.fingerprint,
                               taskState: b.taskState, html: html, text: b.text,
                               headingLevel: b.headingLevel, headingTitle: b.headingTitle, anchor: anchor)
                nb.cjk = b.cjk
                out.append(nb)
            }
        }
        if let section = numbering.section(notes) { out.append(section) }
        return ParsedDocument(blocks: out, title: title)
    }

    /// Blocks of one run of lines, independent of the rest of the document.
    /// Lines are 1-based within the run. Headings carry their inner HTML only.
    /// `footnoteIDs`: the ids defined anywhere in the document (default: in
    /// this run), which decide what `[^id]` refers to.
    static func parseFragment(_ lines: [String], atDocumentStart: Bool, footnoteIDs: Set<String>? = nil,
                              resolver: ResourceResolver?, cache: RenderCache?) -> Fragment {
        var blocks: [Block] = []

        // Front matter.
        var parseLines = lines
        if atDocumentStart, let end = frontMatterEnd(lines) {
            do {
                let body = Array(lines[1..<end])
                blocks.append(frontMatterBlock(body, lines: 1...(end + 1)))
                for i in 0...end { parseLines[i] = "" }
            }
        }

        // Footnote definitions come out of the flow (their lines blanked, so
        // line numbers stay true) and are rendered as one block at the end.
        let definitions = Footnotes.extract(&parseLines)

        var math = MathProtector()
        let ids = footnoteIDs ?? Set(definitions.map(\.id))
        math.footnoteIDs = ids
        let protected = math.protect(parseLines.joined(separator: "\n"))
        // Definitions are protected with the same protector before the
        // renderer copies it.
        let protectedDefinitions = definitions.map { (def: $0, source: math.protect($0.text)) }
        let document = Document(parsing: protected, options: [.disableSmartOpts])
        var renderer = HTMLRenderer(math: math, resolver: resolver)
        renderer.sourceLines = protected.split(separator: "\n", omittingEmptySubsequences: false)

        func sourceSlice(_ range: ClosedRange<Int>) -> ArraySlice<String> {
            let lo = max(range.lowerBound - 1, 0), hi = min(range.upperBound - 1, lines.count - 1)
            return lo <= hi ? lines[lo...hi] : []
        }

        // A node without a source range (cmark-gfm's table extension leaves
        // the text before a table without one) takes the line where the next
        // node starts, else where the previous one ended.
        var lastLine = 1
        var nextStart: Int? = nil
        func lineRange(_ node: Markup) -> ClosedRange<Int> {
            guard let r = node.range else {
                let l = nextStart ?? lastLine
                return l...l
            }
            lastLine = max(r.lowerBound.line, r.upperBound.line)
            return r.lowerBound.line...lastLine
        }

        // Which `[^id]` are references depends on the defined ids.
        let footnoteKey = ids.isEmpty ? "" : "|fn:\(XXHash64.hash(ids.sorted().joined(separator: "\u{1F}")))"

        func make(_ kind: BlockKind, _ node: Markup?, range rawRange: ClosedRange<Int>, html: @autoclosure () -> String,
                  extra: String = "", heading: (Int, String, String)? = nil, taskNodes: [Markup] = []) -> Block {
            // cmark extends some nodes (a list's last item) over the blank
            // line after them, depending on what follows. A block's lines
            // stop at its last non-blank line, so they never depend on that
            // (blank as the Markdown parser saw it: footnote definitions are blanked).
            var hi = rawRange.upperBound
            while hi > rawRange.lowerBound, hi - 1 < parseLines.count, parseLines[hi - 1].allSatisfy({ $0 == " " || $0 == "\t" }) { hi -= 1 }
            let range = rawRange.lowerBound...hi
            let slice = sourceSlice(range)
            let normalized = normalize(slice, kind: kind)
            var tasks: [Bool] = []
            if let node { collectTasks(node, into: &tasks) }
            for n in taskNodes { collectTasks(n, into: &tasks) }
            // Kind participates in the fingerprint so a paragraph and a heading with the same text differ.
            let fp = XXHash64.hash(kind.rawValue + "\u{1F}" + normalized)
            // The rendered HTML depends on the exact source (incl. task state) plus positional context.
            let cacheKey = "\(XXHash64.hash(slice.joined(separator: "\n")))|\(kind.rawValue)|\(extra)\(footnoteKey)"
            let rendered: String
            if let cached = cache?.lookup(cacheKey) { rendered = cached }
            else { rendered = html(); cache?.store(cacheKey, rendered) }
            var b = Block(kind: kind, headingPath: [], lines: range, fingerprint: fp,
                          taskState: tasks, html: rendered, text: normalized,
                          headingLevel: heading?.0, headingTitle: heading?.1, anchor: heading?.2)
            b.cjk = CJK.ratio(normalized) > 0.3
            return b
        }

        func appendListItems(_ list: ListItemContainer, ordered: Bool, start: Int) {
            let tight = renderer.isTight(list)
            let items = Array(list.listItems)
            for (i, item) in items.enumerated() {
                var cls = "li-block"
                if i == 0 { cls += " li-first" }
                if i == items.count - 1 { cls += " li-last" }
                if !tight { cls += " li-loose" }
                func html() -> String {
                    let li = renderer.listItem(item, tight: tight)
                    return ordered
                        ? "<ol class=\"\(cls)\" start=\"\(start + i)\">\(li)</ol>"
                        : "<ul class=\"\(cls)\">\(li)</ul>"
                }
                blocks.append(make(.listItem, item, range: lineRange(item), html: html(), extra: "\(cls)|\(ordered ? start + i : 0)"))
            }
        }

        let nodes = Array(document.children)
        var index = 0
        while index < nodes.count {
            let node = nodes[index]
            index += 1
            nextStart = index < nodes.count ? nodes[index].range?.lowerBound.line : nil
            let range = lineRange(node)
            // `<details>` and its Markdown content arrive as separate top-level
            // nodes (an HTML block ends at the first blank line). Gather them
            // back into one block so the disclosure actually folds.
            if let h = node as? HTMLBlock, Self.detailsDepth(h.rawHTML) > 0 {
                var depth = Self.detailsDepth(h.rawHTML)
                var inner: [Markup] = []
                var closing = ""
                var last = range.upperBound
                while index < nodes.count, depth > 0 {
                    let next = nodes[index]
                    index += 1
                    last = lineRange(next).upperBound
                    if let nh = next as? HTMLBlock {
                        depth += Self.detailsDepth(nh.rawHTML)
                        if depth <= 0 { closing = nh.html; break }
                    }
                    inner.append(next)
                }
                func html() -> String {
                    HTML.sanitize(h.html) + inner.map { n -> String in
                        if let nh = n as? HTMLBlock { return HTML.sanitize(nh.html) }
                        return renderer.block(n)
                    }.joined() + HTML.sanitize(closing)
                }
                blocks.append(make(.html, h, range: range.lowerBound...last, html: html(), taskNodes: inner))
                continue
            }
            switch node {
            case let h as Heading:
                // The anchor, and the <hN id> carrying it, are added by `assemble`.
                let titleText = math.restore(plain: h.plainText).trimmingCharacters(in: .whitespaces)
                blocks.append(make(.heading, h, range: range, html: renderer.inline(h),
                                   heading: (h.level, titleText, "")))

            case let list as UnorderedList:
                appendListItems(list, ordered: false, start: 1)
            case let list as OrderedList:
                appendListItems(list, ordered: true, start: Int(list.startIndex))

            case let q as BlockQuote:
                let alert = alertKind(q)
                func html() -> String {
                    guard let alert else { return renderer.block(q) }
                    let inner = renderer.children(q)
                    let stripped = inner.replacingOccurrences(
                        of: #"^<p>\[![A-Za-z]+\]\s*(<br>)?\s*"#, with: "<p>", options: .regularExpression)
                        .replacingOccurrences(of: "^<p></p>", with: "", options: .regularExpression)
                    let label = alert.prefix(1).uppercased() + alert.dropFirst()
                    return "<div class=\"alert alert-\(alert)\"><p class=\"alert-title\">\(label)</p>\(stripped)</div>"
                }
                blocks.append(make(alert == nil ? .quote : .alert, q, range: range, html: html()))

            case let c as CodeBlock:
                let lang = (c.language ?? "").lowercased().split(separator: " ").first.map(String.init) ?? ""
                if lang == "mermaid" {
                    let src = c.code.trimmingCharacters(in: .newlines)
                    let html = "<div class=\"mermaid-block\"><pre class=\"mermaid-src\">\(HTML.escape(src))</pre></div>"
                    blocks.append(make(.mermaid, c, range: range, html: html))
                } else if lang == "math" || (lang == "latex" && looksLikeDisplayMath(c.code)) {
                    blocks.append(make(.math, c, range: range, html: mathHTML(c.code)))
                } else {
                    blocks.append(make(.code, c, range: range, html: renderer.codeBlock(language: c.language, code: c.code)))
                }

            case let p as Paragraph:
                let raw = sourceSlice(range).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.hasPrefix("$$") && raw.hasSuffix("$$") && raw.count > 4 {
                    let tex = String(raw.dropFirst(2).dropLast(2))
                    blocks.append(make(.math, p, range: range, html: mathHTML(tex)))
                } else {
                    blocks.append(make(.paragraph, p, range: range, html: renderer.block(p)))
                }

            case let t as Table:
                blocks.append(make(.table, t, range: range, html: renderer.table(t)))
            case is ThematicBreak:
                blocks.append(make(.rule, node, range: range, html: "<hr>"))
            case let h as HTMLBlock:
                // HTML comments are invisible; skip them so they never produce empty blocks.
                let trimmed = h.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->") { continue }
                blocks.append(make(.html, h, range: range, html: HTML.sanitize(h.html)))
            default:
                blocks.append(make(.paragraph, node, range: range, html: renderer.block(node)))
            }
        }

        // Definitions are numbered and shown by `assemble`, which sees every reference.
        let notes = protectedDefinitions.map { entry in
            Footnotes.Note(id: entry.def.id, lines: entry.def.lines, text: entry.def.text,
                           html: renderer.children(Document(parsing: entry.source, options: [.disableSmartOpts])))
        }
        return Fragment(blocks: blocks, notes: notes)
    }

    /// Two-generation cache of rendered block HTML, keyed by exact block source and context.
    /// Entries not used during a parse are dropped at the next `beginGeneration()`.
    public final class RenderCache: @unchecked Sendable {
        private var current: [String: String] = [:]
        private var next: [String: String] = [:]
        private let lock = NSLock()
        public init() {}
        func lookup(_ key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            if let v = next[key] ?? current[key] { next[key] = v; return v }
            return nil
        }
        func store(_ key: String, _ value: String) {
            lock.lock(); next[key] = value; lock.unlock()
        }
        /// Call before each parse of the same document.
        public func beginGeneration() {
            lock.lock(); current = next; next = [:]; lock.unlock()
        }
        public func clear() { lock.lock(); current = [:]; next = [:]; lock.unlock() }
    }

    /// Net `<details>` opened by a raw HTML fragment (opens minus closes).
    /// Tags inside HTML comments do not count.
    static func detailsDepth(_ html: String) -> Int {
        var lower = html.lowercased()
        if lower.contains("<!--") {
            lower = lower.replacingOccurrences(of: #"<!--[\s\S]*?(-->|$)"#, with: "", options: .regularExpression)
        }
        func count(_ needle: String) -> Int { lower.components(separatedBy: needle).count - 1 }
        return count("<details") - count("</details")
    }

    static func mathHTML(_ tex: String) -> String {
        let t = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<div class=\"math-block\" data-tex=\"\(HTML.escape(t))\">\(HTML.escape(t))</div>"
    }

    static func looksLikeDisplayMath(_ code: String) -> Bool {
        !code.contains("\\documentclass") && !code.contains("\\begin{document}")
    }

    /// Index of the line closing YAML front matter, if the document opens with it.
    static func frontMatterEnd(_ lines: [String]) -> Int? {
        guard lines.first == "---" else { return nil }
        return lines.indices.dropFirst().prefix(300).first(where: { lines[$0] == "---" || lines[$0] == "..." })
    }

    static func frontMatterBlock(_ body: [String], lines: ClosedRange<Int>) -> Block {
        var items = ""
        for line in body {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("#") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count > 1, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            items += "<span class=\"fm-item\"><span class=\"fm-key\">\(HTML.escape(key))</span> \(HTML.escape(value))</span>"
        }
        let text = body.joined(separator: "\n")
        let html = items.isEmpty ? "" : "<div class=\"front-matter\">\(items)</div>"
        return Block(kind: .frontMatter, headingPath: [], lines: lines,
                     fingerprint: XXHash64.hash("frontMatter\u{1F}" + text),
                     taskState: [], html: html, text: text)
    }

    static func alertKind(_ q: BlockQuote) -> String? {
        guard let p = q.child(at: 0) as? Paragraph, let t = p.child(at: 0) as? Text else { return nil }
        let s = t.string
        guard s.hasPrefix("[!"), let end = s.firstIndex(of: "]") else { return nil }
        let name = s[s.index(s.startIndex, offsetBy: 2)..<end].lowercased()
        return ["note", "tip", "important", "warning", "caution"].contains(name) ? name : nil
    }

    static func collectTasks(_ node: Markup, into out: inout [Bool]) {
        if let li = node as? ListItem, let cb = li.checkbox { out.append(cb == .checked) }
        for c in node.children { collectTasks(c, into: &out) }
    }

    private static let listMarker = try! NSRegularExpression(pattern: #"^(\s*)(?:[-*+]|\d{1,9}[.)])(\s+)(?:\[[ xX]\]\s)?"#)

    /// Normalization for fingerprints: strip trailing whitespace, collapse blank lines,
    /// unify list markers, drop ordered-list numbers and checkbox state.
    static func normalize(_ lines: ArraySlice<String>, kind: BlockKind) -> String {
        var out: [String] = []
        var blank = false
        let normalizeLists = kind == .listItem || kind == .quote || kind == .alert
        for raw in lines {
            var line = raw
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            if kind != .code && kind != .mermaid && kind != .math {
                if line.isEmpty { if blank { continue }; blank = true } else { blank = false }
            }
            if normalizeLists, let first = line.utf8.first(where: { $0 != 0x20 && $0 != 0x09 }),
               first == 0x2D || first == 0x2A || first == 0x2B || (first >= 0x30 && first <= 0x39) {
                let ns = line as NSString
                line = listMarker.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length),
                                                           withTemplate: "$1- ")
            }
            out.append(line)
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
