import Foundation

/// Re-parses only what changed between versions of one document.
///
/// The source is cut into fragments at blank lines where the Markdown parser
/// is in a neutral state: not inside fenced code, raw HTML, a `<details>`
/// the parser joins, a list or a block quote. Each fragment
/// is parsed on its own (`MarkdownParser.parseFragment`) and kept by content
/// hash; on the next version, fragments whose text is unchanged are reused
/// wherever they now sit, and only new text is parsed. `assemble` then adds
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
    private var resolverID = ""
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
        self.resolverID = resolver?.identity ?? ""
    }

    /// Parses with a (possibly changed) resolver: nothing resolved against
    /// a different one (other search folders) is reused, neither fragments
    /// nor the rendered HTML in `cache`.
    public func parse(_ rawSource: String, resolver: ResourceResolver?, cache: MarkdownParser.RenderCache? = nil) -> ParsedDocument {
        let id = resolver?.identity ?? ""
        if id != resolverID {
            previous = [:]
            cache?.clear()
            resolverID = id
        }
        self.resolver = resolver
        return parse(rawSource, cache: cache)
    }

    public func parse(_ rawSource: String, cache: MarkdownParser.RenderCache? = nil) -> ParsedDocument {
        let lines = MarkdownParser.sourceLines(rawSource)
        // Footnote definitions leave the flow (as in `parseFragment`); the
        // fragmenter reads the lines the Markdown parser will see.
        var flow = lines
        let definitions = lines.contains(where: Footnotes.mentions) ? Footnotes.extract(&flow) : []
        guard !Self.needsFullParse(flow) else {
            previous = [:]
            lastReused = 0
            lastParsed = nil
            return MarkdownParser.assemble([(offset: 0, fragment: MarkdownParser.parseFragment(
                lines, atDocumentStart: true, resolver: resolver, cache: cache))])
        }
        let ids = Set(definitions.map(\.id))
        let idsHash = ids.isEmpty ? 0 : XXHash64.hash(ids.sorted().joined(separator: "\u{1F}"))
        var next: [FragmentKey: MarkdownParser.Fragment] = [:]
        var parts: [(offset: Int, fragment: MarkdownParser.Fragment)] = []
        var reused = 0, parsed = 0
        for range in Self.fragments(flow) {
            let slice = Array(lines[range])
            let text = slice.joined(separator: "\n")
            let key = FragmentKey(hash: XXHash64.hash(text), lineCount: slice.count, atStart: range.lowerBound == 0,
                                  footnotes: idsHash != 0 && Footnotes.mentions(text) ? idsHash : 0)
            let fragment: MarkdownParser.Fragment
            if let known = next[key] ?? previous[key] {
                fragment = known
                reused += 1
            } else {
                fragment = MarkdownParser.parseFragment(slice, atDocumentStart: key.atStart, footnoteIDs: ids,
                                                        resolver: resolver, cache: cache)
                parsed += 1
            }
            next[key] = fragment
            parts.append((offset: range.lowerBound, fragment: fragment))
        }
        previous = next
        lastReused = reused
        lastParsed = parsed
        return MarkdownParser.assemble(parts)
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
            if line.contains("]:") {
                let ns = line as NSString
                if documentWide.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil { return true }
            }
        }
        return false
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
