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
