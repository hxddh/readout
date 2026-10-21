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
        if FastBytes.contains(source, 0x0D) {
            source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        // Split on bytes: Character iteration is several times slower.
        return FastBytes.lines(source)
    }

    /// Adds document-wide context to fragments' blocks, in order: absolute
    /// line numbers, heading paths, unique heading anchors (and the heading
    /// HTML that carries them) and the document title.
    /// The blocks of a run of lines and the footnote definitions it holds.
    struct Fragment: Sendable {
        var blocks: [Block]
        var notes: [Footnotes.Note] = []
        /// Render-cache keys of its blocks' HTML: a fragment reused unchanged
        /// keeps them alive (`RenderCache.keep`), so an edit to it later
        /// re-renders only the blocks that changed.
        var cacheKeys: [String] = []
        /// The link reference definitions it holds (`ParsedDocument.links`).
        var links: [LinkDefinition] = []
    }

    static func assemble(_ fragments: [(offset: Int, fragment: Fragment)]) -> ParsedDocument {
        var asm = Assembler()
        asm.mixedIsCJK = Assembler.mixedIsCJK(fragments.lazy.map(\.fragment))
        for (offset, fragment) in fragments { asm.add(offset: offset, fragment: fragment) }
        return asm.finish()
    }

    /// Assembly as a resumable state machine. `assemble` above is one run of
    /// it; `IncrementalParser` keeps a checkpoint per fragment and resumes
    /// after the unchanged start of the document (`IncrementalParser.splice`).
    struct Assembler {
        var out: [Block] = []
        var numbering = Footnotes.Numbering()
        var notes: [Footnotes.Note] = []
        var links: [LinkDefinition] = []
        var headingStack: [(level: Int, title: String)] = []
        var currentPath: [String] = []   // headingStack's titles, shared by the blocks under it
        var slugger = Slugger()
        var title: String? = nil
        var mixedIsCJK = false
        var memo: Slugger.Memo? = nil
        /// Each anchor given, to take back (nil: not kept).
        var slugLog: [Slugger.Undo]? = nil

        /// The state before a fragment: blocks so far, the headings above,
        /// the title, and how many anchors were given (`slugLog`).
        struct Checkpoint {
            var blocks: Int
            var headingStack: [(level: Int, title: String)]
            var currentPath: [String]
            var title: String?
            var slugs: Int
        }
        var checkpoint: Checkpoint {
            Checkpoint(blocks: out.count, headingStack: headingStack, currentPath: currentPath, title: title, slugs: slugLog?.count ?? 0)
        }

        /// Takes back the anchors given after `checkpoint` (its `slugs`), as if assembly had stopped there.
        mutating func rewindSlugs(to count: Int) {
            guard var log = slugLog else { return }
            slugLog = nil
            while log.count > count { slugger.undo(log.removeLast()) }
            slugLog = log
        }

        /// Prose counts deciding `mixedIsCJK`.
        static func counts(_ fragment: Fragment) -> (cjk: Int, other: Int) {
            var c = 0, o = 0
            for b in fragment.blocks where !b.cjkMixed && b.kind != .code && b.kind != .mermaid && b.kind != .math
                && b.kind != .frontMatter && b.kind != .rule {
                if b.cjk { c += 1 } else { o += 1 }
            }
            return (c, o)
        }
        // Mixed blocks (`Task 2: 更新 README.md`) read as CJK in a document
        // whose other prose is mostly CJK.
        static func mixedIsCJK<S: Sequence>(_ fragments: S) -> Bool where S.Element == Fragment {
            var cjkProse = 0, otherProse = 0
            for f in fragments { let (c, o) = counts(f); cjkProse += c; otherProse += o }
            return cjkProse > otherProse
        }

        mutating func add(offset: Int, fragment: Fragment) {
            links += fragment.links
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
                    let a = slugger.next(titleText, memo: memo, log: &slugLog)
                    anchor = a
                    html = "<h\(level) id=\"\(HTML.escape(a))\">\(html)</h\(level)>"
                    headingStack.append((level, titleText))
                    currentPath = headingStack.map(\.title)
                    // An H1 with no text (`#`, `# ![](logo.png)`) names nothing: the app falls back to the file name.
                    if title == nil && level == 1 && !titleText.isEmpty { title = titleText }
                } else {
                    path = b.kind == .footnotes || b.kind == .frontMatter ? [] : currentPath
                }
                var nb = Block(kind: b.kind, headingPath: path, lines: lines, fingerprint: b.fingerprint,
                               taskState: b.taskState, html: html, text: b.text, source: b.source,
                               headingLevel: b.headingLevel, headingTitle: b.headingTitle, anchor: anchor)
                nb.cjk = b.cjk || (b.cjkMixed && mixedIsCJK)
                nb.cjkMixed = b.cjkMixed
                nb.rawSource = b.rawSource
                out.append(nb)
            }
        }

        mutating func finish() -> ParsedDocument {
            if let section = numbering.section(notes) { out.append(section) }
            var doc = ParsedDocument(blocks: out, title: title)
            doc.links = links
            return doc
        }
    }

    /// Blocks of one run of lines, independent of the rest of the document.
    /// Lines are 1-based within the run. Headings carry their inner HTML only.
    /// `footnoteIDs`: the ids defined anywhere in the document (default: in
    /// this run), which decide what `[^id]` refers to.
    static func parseFragment(_ lines: [String], atDocumentStart: Bool, footnoteIDs: Set<String>? = nil,
                              resolver: ResourceResolver?, cache: RenderCache?, emphasisExcluded: Set<Int> = []) -> Fragment {
        var blocks: [Block] = []
        var cacheKeys: [String] = []

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
        // The lines of blocks whose source holds a CJK emphasis marker
        // character itself: no markers there (see the end).
        math.emphasisExcludedLines = emphasisExcluded
        var protected = math.protect(parseLines.joined(separator: "\n"))
        // Nesting too deep to parse on a small stack, flattened (`NestingCap`).
        var flattened: Set<Int> = []
        if let capped = NestingCap.apply(protected) { protected = capped.text; flattened = capped.lines }
        // Definitions are protected with the same protector before the
        // renderer copies it (one block each: no markers in one holding a marker character).
        let protectedDefinitions = definitions.map { def -> (def: Footnotes.Definition, source: String) in
            var m = math
            m.emphasisExcludedLines = []
            m.emphasisEnabled = !CJKEmphasis.containsMarker(CollectionOfOne(def.text))
            let source = m.protect(def.text)
            math = m
            return (def, NestingCap.apply(source)?.text ?? source)
        }
        let document = Document(parsing: protected, options: [.disableSmartOpts])
        let probe = resolver.map(ResolverProbe.init)
        var renderer = HTMLRenderer(math: math, resolver: probe)
        renderer.sourceLines = FastBytes.lineSlices(protected)

        func sourceSlice(_ range: ClosedRange<Int>) -> ArraySlice<String> {
            let lo = max(range.lowerBound - 1, 0), hi = min(range.upperBound - 1, lines.count - 1)
            return lo <= hi ? lines[lo...hi] : []
        }

        // A node without a source range (cmark-gfm's table extension leaves
        // the text before a table without one) takes the line where the next
        // node starts, else where the previous one ended.
        // An empty ATX heading after indentation (` #`) has no range either:
        // it is the first non-blank line after the previous node (what
        // follows it may lie outside this run of lines).
        var lastLine = 1
        var previousEnd = 0
        var nextStart: Int? = nil
        func lineRange(_ node: Markup) -> ClosedRange<Int> {
            guard let r = node.range else {
                var l = nextStart ?? lastLine
                if node is Heading {
                    l = previousEnd + 1
                    while l < parseLines.count, parseLines[l - 1].allSatisfy({ $0 == " " || $0 == "\t" }) { l += 1 }
                    l = max(1, min(l, parseLines.count))
                    previousEnd = l
                }
                return l...l
            }
            lastLine = max(r.lowerBound.line, r.upperBound.line)
            previousEnd = lastLine
            return r.lowerBound.line...lastLine
        }

        // Which `[^id]` are references depends on the defined ids.
        let footnoteKey = ids.isEmpty ? "" : "|fn:\(XXHash64.hash(ids.sorted().joined(separator: "\u{1F}")))"
        // Where `[text][ref]` and `[ref]` point depends on the document's link definitions.
        let refsKey = IncrementalParser.linkDefinitionsHash(parseLines).map { "|refs:\($0)" } ?? ""

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
            // A checkbox needs `[ ]`, `[x]` or `[X]` in the block's source:
            // without one, no walk over its Markdown tree (most blocks have none).
            if slice.contains(where: FastBytes.mayHaveCheckbox) {
                if let node { collectTasks(node, into: &tasks) }
                for n in taskNodes { collectTasks(n, into: &tasks) }
            }
            // Kind participates in the fingerprint so a paragraph and a heading with the same text differ.
            let fp = XXHash64.hash(kind.rawValue + "\u{1F}" + normalized)
            // The rendered HTML depends on the exact source (incl. task state) plus positional context.
            let source = slice.joined(separator: "\n")
            let refs = refsKey.isEmpty || !source.utf8.contains(0x5B) /* [ */ ? "" : refsKey
            // Flattened lines render from what they became, which a run of lines decides.
            var flat = ""
            if !flattened.isEmpty, range.contains(where: { flattened.contains($0 - 1) }) {
                let lo = max(range.lowerBound - 1, 0), hi = min(range.upperBound, renderer.sourceLines.count)
                flat = "|flat:\(XXHash64.hash(lo < hi ? renderer.sourceLines[lo..<hi].joined(separator: "\n") : ""))"
            }
            // Code not closed before blank lines (a fence open to the end)
            // holds them, which its source does not.
            let open = kind == .code && hi < rawRange.upperBound ? "|open:\(rawRange.upperBound - hi)" : ""
            let cacheKey = "\(XXHash64.hash(source))|\(kind.rawValue)|\(extra)\(footnoteKey)\(refs)\(flat)\(open)"
            let rendered: String
            // Not cached when the source holds an emphasis marker character (rare):
            // a first parse may still have put markers in it.
            let marked = math.emphasisMarks > 0 && CJKEmphasis.containsMarker(slice)
            if !marked, let cached = cache?.lookup(cacheKey) { rendered = cached; cacheKeys.append(cacheKey) }
            else {
                let reads = probe?.fileSystemReads ?? 0
                // Markers come out, unless the block's source holds such a character itself.
                rendered = math.emphasisMarks > 0 && !marked ? CJKEmphasis.strip(html()) : html()
                // Not kept when it depends on files (image sizes, which paths exist).
                if let cache, !marked, (probe?.fileSystemReads ?? 0) == reads { cache.store(cacheKey, rendered); cacheKeys.append(cacheKey) }
            }
            var b = Block(kind: kind, headingPath: [], lines: range, fingerprint: fp,
                          taskState: tasks, html: rendered, text: normalized, source: shownSource(slice, source),
                          headingLevel: heading?.0, headingTitle: heading?.1, anchor: heading?.2)
            if b.source != source { b.rawSource = source }
            if kind == .code || kind == .mermaid || kind == .math {
                b.cjk = CJK.ratio(normalized) > 0.3
            } else {
                (b.cjk, b.cjkMixed) = CJK.prose(normalized)
            }
            return b
        }

        func appendListItems(_ list: ListItemContainer, ordered: Bool, start: Int) {
            let tight = renderer.isTight(list)
            let items = Array(list.listItems)
            // Every item of a list numbered past 99 gets the same marker width.
            let width = ordered ? HTMLRenderer.numberWidthClass(start: start, count: items.count) : nil
            for (i, item) in items.enumerated() {
                var cls = "li-block"
                if i == 0 { cls += " li-first" }
                if i == items.count - 1 { cls += " li-last" }
                if !tight { cls += " li-loose" }
                if let width { cls += " " + width }
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
        // HTML comments: no block, but no definition either.
        var comments: [ClosedRange<Int>] = []
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
                    } else {
                        // A `</details>` inside a block (`Some text</details>`, an
                        // indented close in a list item) ends the disclosure there
                        // too, as in a browser, instead of it taking in the rest of the document.
                        // Only closing counts: a disclosure opened inside a block is
                        // not joined (FenceTracker, which the fragmenter follows, agrees).
                        depth += min(0, Self.nestedDetailsDepth(next))
                        if depth <= 0 { inner.append(next); break }
                    }
                    inner.append(next)
                }
                func html() -> String {
                    HTML.sanitize(h.html, resolver: probe) + inner.map { n -> String in
                        if let nh = n as? HTMLBlock { return HTML.sanitize(nh.html, resolver: probe) }
                        return renderer.block(n)
                    }.joined() + HTML.sanitize(closing, resolver: probe)
                }
                blocks.append(make(.html, h, range: range.lowerBound...last, html: html(), taskNodes: inner))
                continue
            }
            switch node {
            case let h as Heading:
                // The anchor, and the <hN id> carrying it, are added by `assemble`.
                var titleText = math.restore(plain: Self.headingText(h)).trimmingCharacters(in: .whitespaces)
                if math.emphasisMarks > 0, !CJKEmphasis.containsMarker(sourceSlice(range)) { titleText = CJKEmphasis.strip(titleText) }
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
                // A paragraph that is one `$$…$$` (on one line or several) is a math block.
                let lo = max(range.lowerBound - 1, 0), hi = min(range.upperBound, renderer.sourceLines.count)
                let protectedSource = lo < hi ? renderer.sourceLines[lo..<hi].joined(separator: "\n") : ""
                if let tex = math.soleDisplayMath(protectedSource) {
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
                if trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->") { comments.append(range); continue }
                blocks.append(make(.html, h, range: range, html: HTML.sanitize(h.html, resolver: probe)))
            default:
                blocks.append(make(.paragraph, node, range: range, html: renderer.block(node)))
            }
        }

        // Definitions are numbered and shown by `assemble`, which sees every reference.
        let notes = protectedDefinitions.map { entry in
            // A list in the note is tight or loose by the note's own lines, not the document's.
            var noteRenderer = renderer
            noteRenderer.sourceLines = FastBytes.lineSlices(entry.source)
            let html = noteRenderer.children(Document(parsing: entry.source, options: [.disableSmartOpts]))
            return Footnotes.Note(id: entry.def.id, lines: entry.def.lines, text: entry.def.text,
                                  html: math.emphasisMarks > 0 && !CJKEmphasis.containsMarker(CollectionOfOne(entry.def.text))
                                    ? CJKEmphasis.strip(html) : html)
        }
        // A block whose source holds a CJK emphasis marker character itself is
        // not stripped (`make`), so it must get no markers: when one did, parse
        // again without markers on its lines (rare). Decided by the block's own
        // source, like its cache key, so every parse agrees.
        if math.emphasisMarks > 0, CJKEmphasis.containsMarker(lines) {
            var excluded = emphasisExcluded
            for b in blocks {
                let lo = b.lines.lowerBound - 1, hi = b.lines.upperBound - 1
                guard lo >= 0, lo <= hi, hi < lines.count, hi < renderer.sourceLines.count,
                      CJKEmphasis.markerCount(lines[lo...hi]) > 0,
                      CJKEmphasis.markerCount(renderer.sourceLines[lo...hi]) > CJKEmphasis.markerCount(lines[lo...hi]) else { continue }
                excluded.formUnion(lo...hi)
            }
            if excluded != emphasisExcluded {
                return parseFragment(lines, atDocumentStart: atDocumentStart, footnoteIDs: footnoteIDs,
                                     resolver: resolver, cache: cache, emphasisExcluded: excluded)
            }
        }
        // Definitions are not blocks: copying a block that uses one appends it.
        let links = refsKey.isEmpty ? [] : IncrementalParser.linkDefinitions(
            parseLines, blocks: blocks.map { ($0.lines, $0.kind) } + comments.map { ($0, .html) })
        return Fragment(blocks: blocks, notes: notes, cacheKeys: cacheKeys, links: links)
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
        /// Carries entries into this generation without a lookup (for fragments reused whole).
        func keep<S: Sequence>(_ keys: S) where S.Element == String {
            lock.lock(); defer { lock.unlock() }
            for key in keys where next[key] == nil {
                if let v = current[key] { next[key] = v }
            }
        }
        /// A splice keeps the previous generation whole (the unchanged blocks
        /// are not walked to keep their entries); `drop` then removes those
        /// of the fragments it replaced.
        func resume() {
            lock.lock()
            for (k, v) in next where current[k] == nil { current[k] = v }
            next = current; current = [:]
            lock.unlock()
        }
        func drop<S: Sequence>(_ keys: S) where S.Element == String {
            lock.lock(); for k in keys { next[k] = nil }; lock.unlock()
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
        if FastBytes.contains(lower, bytes: "<!--") {
            lower = lower.replacingOccurrences(of: #"<!--[\s\S]*?(-->|$)"#, with: "", options: .regularExpression)
        }
        // Whole tags only: <details-card> or <detailsx> is another element.
        func count(_ re: NSRegularExpression) -> Int {
            re.numberOfMatches(in: lower, range: NSRange(location: 0, length: (lower as NSString).length))
        }
        return count(detailsOpen) - count(detailsClose)
    }
    /// A heading's text as it reads (GitHub builds the anchor from it): code
    /// without its backticks, raw HTML tags left out, an image as its alt text.
    static func headingText(_ node: Markup) -> String {
        switch node {
        case let t as Text: return t.string
        case let c as InlineCode: return c.code
        case is InlineHTML: return ""
        case is SoftBreak, is LineBreak: return " "
        case let s as SymbolLink: return s.destination ?? ""
        default: return node.children.map(headingText).joined()
        }
    }

    /// Net `<details>` opened by the raw HTML inside a block (inline HTML,
    /// HTML blocks in list items or quotes); code is not HTML.
    static func nestedDetailsDepth(_ node: Markup) -> Int {
        switch node {
        case let h as InlineHTML: return h.rawHTML.utf8.count >= 9 ? detailsDepth(h.rawHTML) : 0
        case let h as HTMLBlock: return detailsDepth(h.rawHTML)
        case is CodeBlock, is InlineCode, is Text: return 0
        default: return node.children.reduce(0) { $0 + nestedDetailsDepth($1) }
        }
    }

    private static let detailsOpen = try! NSRegularExpression(pattern: #"<details(?=[\s>/])"#)
    private static let detailsClose = try! NSRegularExpression(pattern: #"</details(?=[\s>])"#)

    static func mathHTML(_ tex: String) -> String {
        let t = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<div class=\"math-block\" data-tex=\"\(HTML.escape(t))\">\(HTML.escape(t))</div>"
    }

    static func looksLikeDisplayMath(_ code: String) -> Bool {
        !code.contains("\\documentclass") && !code.contains("\\begin{document}")
    }

    /// Index of the line closing YAML front matter, if the document opens with it.
    /// It must read as YAML: right after the opening `---`, and with a
    /// `key: value` line (or a `#` comment) before the close. Otherwise `---` is a thematic
    /// break (and `---` / text / `---` a setext heading), as in CommonMark.
    /// The fences may carry trailing spaces or tabs.
    static func frontMatterEnd(_ lines: [String]) -> Int? {
        func fence(_ line: String, _ marks: String...) -> Bool {
            guard line.utf8.count >= 3, line.utf8.count < 64 else { return false }
            var s = Substring(line)
            while let last = s.last, last == " " || last == "\t" { s.removeLast() }
            return marks.contains { s == $0 }
        }
        guard let first = lines.first, fence(first, "---"), lines.count > 2,
              !lines[1].allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        guard let end = lines.indices.dropFirst().prefix(300).first(where: { fence(lines[$0], "---", "...") }) else { return nil }
        return lines[1..<end].contains(where: { looksLikeYAMLKey($0) || $0.hasPrefix("#") }) ? end : nil
    }

    /// `key: value` or `key:` at the start of a line (no space before the colon in the key's first word).
    private static func looksLikeYAMLKey(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return false }
        let key = line[..<colon]
        guard let first = key.first, first != " ", first != "\t", first != "#", first != "-" else { return false }
        let after = line[line.index(after: colon)...]
        return after.isEmpty || after.first == " " || after.first == "\t"
    }

    /// Top-level `key: value` pairs. A block scalar (`key: >` folded, `key: |`
    /// literal) takes the indented lines under it, and a key with no value
    /// takes the items of a YAML list under it (`- Read`), joined with commas.
    static func frontMatterBlock(_ body: [String], lines: ClosedRange<Int>) -> Block {
        var items = ""
        var i = 0
        while i < body.count {
            let line = body[i]
            i += 1
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Lines under the key: indented, or list items (YAML allows `- x` at the key's indentation), or blank.
            var nested: [String] = []
            while i < body.count, body[i].hasPrefix(" ") || body[i].hasPrefix("\t") || body[i].hasPrefix("- ") || body[i] == "-"
                    || (body[i].allSatisfy({ $0 == " " || $0 == "\t" }) && i + 1 < body.count && body[i + 1].hasPrefix(" ")) {
                nested.append(body[i])
                i += 1
            }
            let trimmed = nested.map { $0.trimmingCharacters(in: .whitespaces) }
            var html: String? = nil
            if let indicator = value.first, indicator == ">" || indicator == "|",
               value.dropFirst().allSatisfy({ $0 == "-" || $0 == "+" || $0.isNumber }) {
                // Block scalar: folded lines join with spaces (a blank line is a break), literal lines keep their breaks.
                var paragraphs: [[String]] = [[]]
                for t in trimmed { if t.isEmpty { paragraphs.append([]) } else { paragraphs[paragraphs.count - 1].append(t) } }
                let parts = paragraphs.filter { !$0.isEmpty }
                html = parts.map { p in
                    indicator == ">" ? HTML.escape(p.joined(separator: " ")) : p.map(HTML.escape).joined(separator: "<br>")
                }.joined(separator: "<br>")
                value = ""
            } else if value.isEmpty {
                let list = trimmed.filter { $0.hasPrefix("- ") }.map { item -> String in
                    var v = item.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if v.count > 1, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                        v = String(v.dropFirst().dropLast())
                    }
                    return v
                }.filter { !$0.isEmpty }
                if !list.isEmpty, list.count == trimmed.filter({ !$0.isEmpty }).count {
                    html = HTML.escape(list.joined(separator: ", "))
                }
            }
            if value.count > 1, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            let shown = html ?? HTML.escape(value)
            guard !key.isEmpty, !shown.isEmpty else { continue }
            items += "<span class=\"fm-item\"><span class=\"fm-key\">\(HTML.escape(key))</span> <span class=\"fm-val\">\(shown)</span></span>"
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

    /// A block's source as shown and compared: its lines without trailing white space.
    static func shownSource(_ lines: ArraySlice<String>, _ joined: String) -> String {
        guard lines.contains(where: { $0.last == " " || $0.last == "\t" }) else { return joined }
        return lines.map { line -> Substring in
            var l = Substring(line)
            while let last = l.last, last == " " || last == "\t" { l.removeLast() }
            return l
        }.joined(separator: "\n")
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
