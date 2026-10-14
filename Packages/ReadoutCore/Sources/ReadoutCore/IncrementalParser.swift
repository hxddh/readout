import Foundation

/// Re-parses only what changed between versions of one document.
///
/// The source is cut into fragments at blank lines where the Markdown parser
/// is in a neutral state: not inside fenced code, raw HTML, a `<details>`
/// the parser joins, a list or a block quote. Each fragment
/// is parsed on its own (`MarkdownParser.parseFragment`) and kept by content
/// hash; on the next version, fragments whose text is unchanged are reused
/// wherever they now sit, and only new text is parsed (concurrently when
/// there are many fragments, as on first open). `assemble` then adds
/// the document-wide parts (line offsets, heading paths, anchors, title).
///
/// The result is identical to `MarkdownParser.parse` (property-tested on the
/// real-agent corpus). Footnotes are numbered when the document is assembled;
/// fragments that may reference one are keyed by the set of defined ids.
/// Documents with link reference definitions are parsed in full.
///
/// Not thread-safe: use one instance per document, from one queue.
public final class IncrementalParser: @unchecked Sendable {
    private var resolver: ResourceResolver?
    private var resolverID = "none"
    /// Fragment blocks from the previous version, by fragment key.
    private var previous: [FragmentKey: MarkdownParser.Fragment] = [:]
    /// Fragments reused in the last parse (for tests).
    private(set) var lastReused = 0
    /// Fragments parsed in the last parse (for tests). Nil after a full parse.
    private(set) var lastParsed: Int? = nil

    struct FragmentKey: Hashable {
        let hash: UInt64
        let lineCount: Int
        let atStart: Bool
        /// The defined footnote ids, for fragments that may reference one.
        let footnotes: UInt64
    }

    public init(resolver: ResourceResolver? = nil) {
        self.resolver = resolver
        self.resolverID = resolver.map { "resolver:" + $0.identity } ?? "none"
    }

    /// Parses with a (possibly changed) resolver: nothing resolved against
    /// a different one (other search folders) is reused, neither fragments
    /// nor the rendered HTML in `cache`.
    public func parse(_ rawSource: String, resolver: ResourceResolver?, cache: MarkdownParser.RenderCache? = nil) -> ParsedDocument {
        self.resolver = resolver
        return parse(rawSource, cache: cache)
    }

    /// Parses with the current resolver, whose identity is checked on every
    /// call (a resolver may change its configuration).
    public func parse(_ rawSource: String, cache: MarkdownParser.RenderCache? = nil) -> ParsedDocument {
        let id = resolver.map { "resolver:" + $0.identity } ?? "none"
        if id != resolverID {
            previous = [:]
            cache?.clear()
            resolverID = id
        }
        let lines = MarkdownParser.sourceLines(rawSource)
        // Footnote definitions leave the flow (as in `parseFragment`); the
        // fragmenter reads the lines the Markdown parser will see.
        var flow = lines
        // Front matter is not Markdown: no definitions come from it (as in parseFragment).
        let frontMatter = MarkdownParser.frontMatterEnd(lines)
        if let end = frontMatter { for i in 0...end { flow[i] = "" } }
        let definitions = flow.contains(where: { Footnotes.mentions($0) }) ? Footnotes.extract(&flow) : []
        if let end = frontMatter { for i in 0...end { flow[i] = lines[i] } }
        guard !Self.needsFullParse(flow) else {
            previous = [:]
            lastReused = 0
            lastParsed = nil
            return MarkdownParser.assemble([(offset: 0, fragment: MarkdownParser.parseFragment(
                lines, atDocumentStart: true, resolver: resolver, cache: cache))])
        }
        let ids = Set(definitions.map(\.id))
        let idsHash = ids.isEmpty ? 0 : XXHash64.hash(ids.sorted().joined(separator: "\u{1F}"))
        var entries: [(offset: Int, slice: [String], key: FragmentKey)] = []
        for range in Self.fragments(flow) {
            let slice = Array(lines[range])
            let text = slice.joined(separator: "\n")
            let key = FragmentKey(hash: XXHash64.hash(text), lineCount: slice.count, atStart: range.lowerBound == 0,
                                  footnotes: idsHash != 0 && Footnotes.mentions(text) ? idsHash : 0)
            entries.append((range.lowerBound, slice, key))
        }
        // Fragments not in the previous version, each parsed once (the same
        // text may occur twice), concurrently: they depend on nothing outside them.
        var next: [FragmentKey: MarkdownParser.Fragment] = [:]
        var jobs: [(slice: [String], key: FragmentKey)] = []
        var queued = Set<FragmentKey>()
        for e in entries where previous[e.key] == nil && queued.insert(e.key).inserted { jobs.append((e.slice, e.key)) }
        let parsedFragments = Self.parseFragments(jobs.map { ($0.slice, $0.key.atStart) }, footnoteIDs: ids,
                                                  resolver: resolver, cache: cache)
        for (job, fragment) in zip(jobs, parsedFragments) { next[job.key] = fragment }
        // Reused fragments keep their blocks' HTML in the render cache.
        var keep: [String] = []
        var parts: [(offset: Int, fragment: MarkdownParser.Fragment)] = []
        parts.reserveCapacity(entries.count)
        for e in entries {
            if let fragment = next[e.key] {
                parts.append((e.offset, fragment))
            } else if let fragment = previous[e.key] {
                next[e.key] = fragment
                keep += fragment.cacheKeys
                parts.append((e.offset, fragment))
            }
        }
        cache?.keep(keep)
        previous = next
        lastReused = entries.count - jobs.count
        lastParsed = jobs.count
        return MarkdownParser.assemble(parts)
    }

    /// Parses fragments, concurrently from 8 on; the results are in the jobs' order.
    static func parseFragments(_ jobs: [(slice: [String], atStart: Bool)], footnoteIDs: Set<String>,
                               resolver: ResourceResolver?, cache: MarkdownParser.RenderCache?) -> [MarkdownParser.Fragment] {
        @Sendable func parse(_ k: Int) -> MarkdownParser.Fragment {
            MarkdownParser.parseFragment(jobs[k].slice, atDocumentStart: jobs[k].atStart, footnoteIDs: footnoteIDs,
                                         resolver: resolver, cache: cache)
        }
        guard jobs.count >= 8 else { return jobs.indices.map(parse) }
        let results = UnsafeMutableBufferPointer<MarkdownParser.Fragment?>.allocate(capacity: jobs.count)
        results.initialize(repeating: nil)
        defer { results.deinitialize(); results.deallocate() }
        // Each iteration writes only its own element.
        nonisolated(unsafe) let slots = results
        DispatchQueue.concurrentPerform(iterations: jobs.count) { k in slots[k] = parse(k) }
        return results.map { $0! }
    }

    // MARK: Fragmenting

    /// Link reference definitions reach across the whole document, also
    /// from inside a list item or block quote.
    private static let documentWide = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*(?:>|(?:[-*+]|\d{1,9}[.)])(?=[ \t]|$)))*[ \t]*\[(?:\\.|[^\]\\])+\]:"#)

    /// True when `lines` (footnote definitions taken out) define link
    /// references outside code and raw HTML.
    static func needsFullParse(_ lines: [String]) -> Bool {
        var fences = FenceTracker()
        for line in lines.dropFirst(MarkdownParser.frontMatterEnd(lines).map { $0 + 1 } ?? 0) {
            if fences.consume(line) { continue }
            if FastBytes.contains(line, 0x5D, 0x3A) {   // "]:"
                let ns = line as NSString
                if documentWide.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil { return true }
            }
        }
        return false
    }

    /// A hash of the link reference definitions in `lines` (each definition
    /// line and the line after it, where a title may continue), nil without any.
    static func linkDefinitionsHash(_ lines: [String]) -> UInt64? {
        func mentionsDefinition(_ line: String) -> Bool { FastBytes.contains(line, 0x5D, 0x3A) }   // "]:"
        guard lines.contains(where: mentionsDefinition) else { return nil }
        var fences = FenceTracker()
        var text = ""
        var found = false
        for (i, line) in lines.enumerated() {
            if fences.consume(line) { continue }
            guard mentionsDefinition(line) else { continue }
            let ns = line as NSString
            guard documentWide.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil else { continue }
            found = true
            text += line + "\n" + (i + 1 < lines.count ? lines[i + 1] : "") + "\n"
        }
        return found ? XXHash64.hash(text) : nil
    }

    private static let listMarker = try! NSRegularExpression(pattern: #"^\d{1,9}[.)](?:[ \t]|$)"#)

    /// True when a line can begin a fresh top-level block that nothing before
    /// a blank line can continue: it starts at column 0 and is not a list
    /// item, quote, table row, HTML, fence, link definition, thematic break
    /// or setext underline.
    static func startsFresh(_ line: String) -> Bool {
        guard let c = line.unicodeScalars.first else { return false }
        switch c {
        case " ", "\t", "-", "*", "+", ">", "|", "<", "`", "~", "[", "=", "_", "$", "\\", ":": return false
        default: break
        }
        if ("0"..."9").contains(c) {
            let ns = line as NSString
            if listMarker.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil { return false }
        }
        return true
    }

    /// Line ranges of the fragments, covering every line exactly once.
    static func fragments(_ lines: [String]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        var fences = FenceTracker()
        // Front matter is never cut (and never read as Markdown).
        var i = MarkdownParser.frontMatterEnd(lines).map { $0 + 1 } ?? 0
        while i < lines.count {
            let line = lines[i]
            if fences.consume(line) {
                i += 1
                continue
            }
            // A neutral boundary: this line is blank, the next non-blank line
            // starts fresh, and nothing is open (code, raw HTML, <details>).
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) && !fences.isOpen {
                var j = i + 1
                while j < lines.count && lines[j].allSatisfy({ $0 == " " || $0 == "\t" }) { j += 1 }
                if j < lines.count && startsFresh(lines[j]) && j > start {
                    out.append(start..<j)
                    start = j
                    i = j
                    continue
                }
            }
            i += 1
        }
        if start < lines.count || out.isEmpty { out.append(start..<max(lines.count, start)) }
        return out
    }
}
