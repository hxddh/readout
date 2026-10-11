import Foundation

/// Re-parses only what changed between versions of one document.
///
/// The source is cut into fragments at blank lines where the Markdown parser
/// is in a neutral state: not inside fenced code, an HTML block that spans
/// blank lines, a list or a block quote. Each fragment
/// is parsed on its own (`MarkdownParser.parseFragment`) and kept by content
/// hash; on the next version, fragments whose text is unchanged are reused
/// wherever they now sit, and only new text is parsed. `assemble` then adds
/// the document-wide parts (line offsets, heading paths, anchors, title).
///
/// The result is identical to `MarkdownParser.parse` (property-tested on the
/// real-agent corpus). Documents that use syntax with document-wide effects
/// (link reference definitions, footnotes, `<details>`) are parsed in full.
///
/// Not thread-safe: use one instance per document, from one queue.
public final class IncrementalParser: @unchecked Sendable {
    private var resolver: ResourceResolver?
    private var resolverID = ""
    /// Fragment blocks from the previous version, by fragment key.
    private var previous: [FragmentKey: [Block]] = [:]
    /// Fragments reused in the last parse (for tests).
    private(set) var lastReused = 0
    /// Fragments parsed in the last parse (for tests). Nil after a full parse.
    private(set) var lastParsed: Int? = nil

    struct FragmentKey: Hashable {
        let hash: UInt64
        let lineCount: Int
        let atStart: Bool
    }

    public init(resolver: ResourceResolver? = nil) {
        self.resolver = resolver
        self.resolverID = String(describing: resolver)
    }

    /// Parses with a (possibly changed) resolver: fragments resolved against
    /// a different one (other search folders) are not reused.
    public func parse(_ rawSource: String, resolver: ResourceResolver?, cache: MarkdownParser.RenderCache? = nil) -> ParsedDocument {
        let id = String(describing: resolver)
        if id != resolverID {
            previous = [:]
            resolverID = id
        }
        self.resolver = resolver
        return parse(rawSource, cache: cache)
    }

    public func parse(_ rawSource: String, cache: MarkdownParser.RenderCache? = nil) -> ParsedDocument {
        let lines = MarkdownParser.sourceLines(rawSource)
        guard !Self.needsFullParse(lines) else {
            previous = [:]
            lastReused = 0
            lastParsed = nil
            return MarkdownParser.assemble([(offset: 0, blocks: MarkdownParser.parseFragment(
                lines, atDocumentStart: true, resolver: resolver, cache: cache))])
        }
        var next: [FragmentKey: [Block]] = [:]
        var parts: [(offset: Int, blocks: [Block])] = []
        var reused = 0, parsed = 0
        for range in Self.fragments(lines) {
            let slice = Array(lines[range])
            let key = FragmentKey(hash: XXHash64.hash(slice.joined(separator: "\n")), lineCount: slice.count,
                                  atStart: range.lowerBound == 0)
            let blocks: [Block]
            if let known = next[key] ?? previous[key] {
                blocks = known
                reused += 1
            } else {
                blocks = MarkdownParser.parseFragment(slice, atDocumentStart: key.atStart, resolver: resolver, cache: cache)
                parsed += 1
            }
            next[key] = blocks
            parts.append((offset: range.lowerBound, blocks: blocks))
        }
        previous = next
        lastReused = reused
        lastParsed = parsed
        return MarkdownParser.assemble(parts)
    }

    // MARK: Fragmenting

    /// Syntax whose meaning reaches across the whole document.
    private static let documentWide = try! NSRegularExpression(
        pattern: #"^ {0,3}\[(?:\^[^\]]+|[^\]]+)\]:"#)

    /// Link reference definitions and footnotes reach across the whole
    /// document. Raw HTML blocks (a line opening with a tag) are parsed in
    /// full too: whether a tag line starts an HTML block, which then hides
    /// fences until it ends, depends on the paragraph state around it, and
    /// `<details>` joins every block up to its closing tag. HTML comments
    /// are tracked exactly.
    static func needsFullParse(_ lines: [String]) -> Bool {
        var fences = FenceTracker()
        for line in lines {
            if fences.consume(line) { continue }
            if line.contains("]:") {
                let ns = line as NSString
                if documentWide.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil { return true }
            }
            let trimmed = line.drop(while: { $0 == " " })
            if line.count - trimmed.count < 4, trimmed.hasPrefix("<") {
                let rest = trimmed.dropFirst().drop(while: { $0 == "/" })
                if let c = rest.first, c.isASCII, c.isLetter { return true }
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
        var frontMatter = lines.first == "---"
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if frontMatter {
                if i > 0 && (line == "---" || line == "...") { frontMatter = false }
                i += 1
                continue
            }
            if fences.consume(line) {
                i += 1
                continue
            }
            // A neutral boundary: this line is blank, the next non-blank line
            // starts fresh, and nothing is open.
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
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
