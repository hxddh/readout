import Foundation

public enum BlockKind: String, Codable, Sendable {
    case heading, paragraph, quote, alert, code, mermaid, math, listItem, table, rule, html, frontMatter, footnotes
}

/// One renderable unit of a document. Identity across versions is the `slot`,
/// assigned by `Differ`; content identity is the `fingerprint`.
public struct Block: Sendable, Equatable {
    public var slot: Int = 0
    /// Mostly CJK text: rendered with CJK line height.
    public var cjk: Bool = false
    /// Prose that reads as CJK only in a mostly CJK document (`CJK.prose`).
    var cjkMixed: Bool = false
    public let kind: BlockKind
    /// Titles of the enclosing headings (outermost first). A heading's own path excludes itself.
    public let headingPath: [String]
    /// 1-based source line range.
    public let lines: ClosedRange<Int>
    public let fingerprint: UInt64
    /// Checkbox states of task items in this block (excluded from the fingerprint).
    public let taskState: [Bool]
    public let html: String
    /// Normalized plain-ish text used for similarity matching.
    public let text: String
    /// The block's Markdown source as written (list markers, numbers and
    /// checkboxes included; trailing white space left out): what a
    /// comparison or a removed block shows.
    public let source: String
    /// The source with its lines' trailing white space, when it had some
    /// (two spaces at the end of a line are a hard break): what copying the
    /// block keeps. Nil when it equals `source`.
    var rawSource: String? = nil
    /// Heading metadata.
    public let headingLevel: Int?
    public let headingTitle: String?
    public let anchor: String?

    public init(kind: BlockKind, headingPath: [String], lines: ClosedRange<Int>, fingerprint: UInt64,
                taskState: [Bool], html: String, text: String, source: String? = nil,
                headingLevel: Int? = nil, headingTitle: String? = nil, anchor: String? = nil) {
        self.kind = kind
        self.headingPath = headingPath
        self.lines = lines
        self.fingerprint = fingerprint
        self.taskState = taskState
        self.html = html
        self.text = text
        // The same string when nothing was normalized away (shares its storage).
        self.source = source.map { $0 == text ? text : $0 } ?? text
        self.headingLevel = headingLevel
        self.headingTitle = headingTitle
        self.anchor = anchor
    }
}

extension Block {
    /// What copying the whole block (⌘C, Copy as Quote) puts on the
    /// clipboard: its source as written, trailing white space included;
    /// front matter with its `---` fences (its source is the body).
    public var copySource: String {
        kind == .frontMatter ? "---\n" + source + "\n---" : rawSource ?? source
    }
}

/// A link reference definition (`[label]: destination "title"`). It is not a
/// block, so copying a block that uses it (`[text][label]`) appends it.
public struct LinkDefinition: Codable, Sendable, Equatable {
    /// The label as references match it: case-folded, white space collapsed.
    public let label: String
    /// The definition as written, without the quote or list markers before it.
    public let md: String

    public init(label: String, md: String) {
        self.label = Self.normalize(label)
        self.md = md
    }

    /// CommonMark's label matching: trimmed, inner white space one space, case-folded.
    static func normalize(_ label: String) -> String {
        label.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ").lowercased()
    }
}

public struct TaskStats: Codable, Sendable, Equatable {
    public var done: Int
    public var total: Int
    public init(done: Int = 0, total: Int = 0) { self.done = done; self.total = total }
}

public struct TocEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { slot }
    public let slot: Int
    public let level: Int
    public let title: String
    public let anchor: String
    public let tasks: TaskStats
}

public struct ParsedDocument: Sendable {
    public var blocks: [Block]
    public let title: String?
    /// The document's link reference definitions, in source order.
    public var links: [LinkDefinition] = []
    /// An `IncrementalParser` result's identity (0: none).
    var generation: UInt64 = 0
    /// What a splice (`IncrementalParser`) kept of the result `base`: its
    /// first `prefix` blocks as they were, and its last `suffix` blocks as
    /// they were but for their line numbers. `DocumentSession` skips them
    /// when it compares this version with that one.
    var splice: Splice? = nil

    struct Splice: Sendable, Equatable {
        let base: UInt64
        let prefix: Int
        let suffix: Int
    }

    public var tasks: TaskStats {
        var s = TaskStats()
        for b in blocks { for t in b.taskState { s.total += 1; if t { s.done += 1 } } }
        return s
    }

    /// The deepest heading level the outline lists.
    public static let tocMaxLevel = 4

    /// Table of contents (levels 1–4). Requires slots to be assigned.
    public func toc(maxLevel: Int = tocMaxLevel) -> [TocEntry] {
        var result: [TocEntry] = []
        for (i, b) in blocks.enumerated() {
            guard b.kind == .heading, let level = b.headingLevel, level <= maxLevel else { continue }
            var stats = TaskStats()
            var j = i + 1
            while j < blocks.count {
                let n = blocks[j]
                if n.kind == .heading, let l = n.headingLevel, l <= level { break }
                for t in n.taskState { stats.total += 1; if t { stats.done += 1 } }
                j += 1
            }
            result.append(TocEntry(slot: b.slot, level: level, title: b.headingTitle ?? "",
                                   anchor: b.anchor ?? "", tasks: stats))
        }
        return result
    }
}
