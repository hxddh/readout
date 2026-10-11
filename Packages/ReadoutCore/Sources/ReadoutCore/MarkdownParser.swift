import Foundation
import Markdown

/// Parses Markdown source into a flat sequence of `Block`s.
public enum MarkdownParser {
    public static func parse(_ rawSource: String, resolver: ResourceResolver? = nil,
                             cache: RenderCache? = nil) -> ParsedDocument {
        usleep(20_000)  // DELIBERATE SLOWDOWN: demonstrates the speed budget fails CI; reverted next commit
        var source = rawSource
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        if source.contains("\r") {
            source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var blocks: [Block] = []

        // Front matter.
        var parseLines = lines
        if lines.first == "---" {
            if let end = lines.indices.dropFirst().prefix(300).first(where: { lines[$0] == "---" || lines[$0] == "..." }) {
                let body = Array(lines[1..<end])
                blocks.append(frontMatterBlock(body, lines: 1...(end + 1)))
                for i in 0...end { parseLines[i] = "" }
            }
        }

        var math = MathProtector()
        let protected = math.protect(parseLines.joined(separator: "\n"))
        let document = Document(parsing: protected, options: [.disableSmartOpts])
        var renderer = HTMLRenderer(math: math, resolver: resolver)
        renderer.sourceLines = protected.split(separator: "\n", omittingEmptySubsequences: false)

        var headingStack: [(level: Int, title: String)] = []
        var slugger = Slugger()
        var title: String? = nil

        func sourceSlice(_ range: ClosedRange<Int>) -> ArraySlice<String> {
            let lo = max(range.lowerBound - 1, 0), hi = min(range.upperBound - 1, lines.count - 1)
            return lo <= hi ? lines[lo...hi] : []
        }

        func lineRange(_ node: Markup) -> ClosedRange<Int> {
            guard let r = node.range else { return 1...1 }
            return r.lowerBound.line...max(r.lowerBound.line, r.upperBound.line)
        }

        func make(_ kind: BlockKind, _ node: Markup?, range: ClosedRange<Int>, html: @autoclosure () -> String,
                  extra: String = "", heading: (Int, String, String)? = nil) -> Block {
            let slice = sourceSlice(range)
            let normalized = normalize(slice, kind: kind)
            var tasks: [Bool] = []
            if let node { collectTasks(node, into: &tasks) }
            // Kind participates in the fingerprint so a paragraph and a heading with the same text differ.
            let fp = XXHash64.hash(kind.rawValue + "\u{1F}" + normalized)
            // The rendered HTML depends on the exact source (incl. task state) plus positional context.
            let cacheKey = "\(XXHash64.hash(slice.joined(separator: "\n")))|\(kind.rawValue)|\(extra)"
            let rendered: String
            if let cached = cache?.lookup(cacheKey) { rendered = cached }
            else { rendered = html(); cache?.store(cacheKey, rendered) }
            var b = Block(kind: kind, headingPath: headingStack.map(\.title), lines: range, fingerprint: fp,
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

        for node in document.children {
            let range = lineRange(node)
            switch node {
            case let h as Heading:
                let titleText = math.restore(plain: h.plainText).trimmingCharacters(in: .whitespaces)
                while let last = headingStack.last, last.level >= h.level { headingStack.removeLast() }
                let anchor = slugger.next(titleText)
                blocks.append(make(.heading, h, range: range,
                                   html: "<h\(h.level) id=\"\(HTML.escape(anchor))\">\(renderer.inline(h))</h\(h.level)>",
                                   extra: anchor, heading: (h.level, titleText, anchor)))
                headingStack.append((h.level, titleText))
                if title == nil && h.level == 1 { title = titleText }

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
                blocks.append(make(.html, h, range: range, html: HTML.sanitize(h.rawHTML)))
            default:
                blocks.append(make(.paragraph, node, range: range, html: renderer.block(node)))
            }
        }

        return ParsedDocument(blocks: blocks, title: title)
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

    static func mathHTML(_ tex: String) -> String {
        let t = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<div class=\"math-block\" data-tex=\"\(HTML.escape(t))\">\(HTML.escape(t))</div>"
    }

    static func looksLikeDisplayMath(_ code: String) -> Bool {
        !code.contains("\\documentclass") && !code.contains("\\begin{document}")
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
