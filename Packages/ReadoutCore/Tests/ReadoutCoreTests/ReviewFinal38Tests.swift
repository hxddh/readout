import Foundation
import Testing
@testable import ReadoutCore

/// Independent 3.8 release review: deep nesting NestingCap does not see.
@Suite struct ReviewFinal38Tests {
    /// Lists nested by indentation inside one block quote: every line has
    /// one `>` and one `-`, so NestingCap counts two levels; cmark nests 150.
    static let listsInQuote = (0..<150).map { "> " + String(repeating: "  ", count: $0) + "- item \($0)" }.joined(separator: "\n")

    @Test func nestingCapSeesListsNestedInsideAQuote() {
        // The cap leaves the text alone: nothing is flattened.
        #expect(NestingCap.apply(Self.listsInQuote) != nil, "NestingCap flattens nothing")
    }

    @Test func listsNestedInsideAQuoteParseOnASmallStack() {
        nonisolated(unsafe) var blocks = -1
        let text = Self.listsInQuote
        #expect(CoreFixes38Tests.onSmallStack { blocks = MarkdownParser.parse(text).blocks.count })
        #expect(blocks > 0)
    }

    /// The other shapes of the same (the review's p/*-in-quote*.md): ordered
    /// items in a quote, items in a quote in an item, 4-space items in `> >`.
    /// Each is flattened, parses on a 512 KB stack, and incrementally as in full.
    @Test(arguments: ["lists-in-quote-150", "ordered-in-quote-150", "list-in-list-quote-150", "quote-in-quote-4sp-150"])
    func listsInQuotesAreCapped(_ name: String) throws {
        let text = try #require(CoreFixes38Tests.deep.first { $0.name == name }).text
        let capped = try #require(NestingCap.apply(text), "\(name): NestingCap flattens nothing")
        // From the 17th level on: the items are at the quote's level plus one (plus two in a quote in a quote, or in a quote in an item).
        let before = name == "quote-in-quote-4sp-150" || name == "list-in-list-quote-150" ? 2 : 1
        #expect(capped.lines.count == 150 - (NestingCap.containers - before), "\(name): \(capped.lines.sorted().prefix(3))")
        nonisolated(unsafe) var full: [String] = [], incremental: [String] = []
        #expect(CoreFixes38Tests.onSmallStack {
            full = MarkdownParser.parse(text).blocks.map(\.html)
            incremental = IncrementalParser().parse(text).blocks.map(\.html)
        }, "\(name)")
        #expect(!full.isEmpty && full == incremental, "\(name)")
        // Nothing is dropped: every item's text is still there.
        #expect(full.joined().components(separatedBy: "item").count - 1 == 150, "\(name)")
    }

    /// What quotes really hold is left alone: an outline a quote deep, at any
    /// indentation, as many levels as fit (`containers`, the quote one of them).
    @Test func quotedOutlinesAreUntouched() {
        for width in [2, 3, 4] {
            let levels = NestingCap.containers - 1
            let item = { (k: Int) in String(repeating: " ", count: width * k) + (width == 3 ? "1. step" : "- step") }
            let quoted = (0..<levels).map { "> " + item($0) }.joined(separator: "\n")
            #expect(NestingCap.apply(quoted) == nil, "\(width) spaces in a quote")
            let nested = (0..<(levels - 1)).map { "> > " + item($0) }.joined(separator: "\n")
            #expect(NestingCap.apply(nested) == nil, "\(width) spaces in a quote in a quote")
            let inItem = "- top\n" + (0..<(levels - 1)).map { "  > " + item($0) }.joined(separator: "\n")
            #expect(NestingCap.apply(inItem) == nil, "\(width) spaces in a quote in an item")
            // Loose, and a quote's items after the quote's own paragraph.
            let loose = "> Intro.\n>\n" + (0..<levels).map { "> " + item($0) }.joined(separator: "\n>\n")
            #expect(NestingCap.apply(loose) == nil, "\(width) spaces, loose, in a quote")
        }
        // Items outside the quote and in it do not add up.
        let outside = (0..<15).map { String(repeating: "  ", count: $0) + "- level" }.joined(separator: "\n")
        #expect(NestingCap.apply(outside + "\n\n> - quoted\n>   - deeper") == nil)
        #expect(NestingCap.apply("> " + outside.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n- after\n  - after") == nil)
    }

    /// Fragments parsed concurrently (`IncrementalParser.parseFragments`,
    /// from 8 on) run on GCD's threads, 512 KB on macOS: a document of many
    /// fragments, each nested deep in a quote, asked from a small stack.
    @Test func concurrentFragmentsParseOnSmallStacks() {
        let text = (0..<12).map { "Section \($0).\n\n" + (0..<60).map { "> " + String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n") }
            .joined(separator: "\n\n")
        nonisolated(unsafe) var full: [String] = [], incremental: [String] = []
        #expect(CoreFixes38Tests.onSmallStack {
            full = MarkdownParser.parse(text).blocks.map(\.html)
            incremental = IncrementalParser().parse(text).blocks.map(\.html)
        })
        #expect(!full.isEmpty && full == incremental)
    }

    /// A line escaped at a later marker keeps its earlier item open (review
    /// of #76): `- > x` under `- > x` nests a level each line.
    @Test(arguments: ["item-quote-150", "quoted-item-quote-150"])
    func escapedLinesKeepTheirItems(_ name: String) throws {
        let text = try #require(CoreFixes38Tests.deep.first { $0.name == name }).text
        let capped = try #require(NestingCap.apply(text), "\(name): NestingCap flattens nothing")
        // From the first escaped line on, every line is escaped: none nests deeper than `containers`.
        let first = try #require(capped.lines.min())
        #expect(capped.lines.count == 150 - first, "\(name): \(capped.lines.sorted().prefix(4))")
        nonisolated(unsafe) var full: [String] = [], incremental: [String] = []
        #expect(CoreFixes38Tests.onSmallStack {
            full = MarkdownParser.parse(text).blocks.map(\.html)
            incremental = IncrementalParser().parse(text).blocks.map(\.html)
        }, "\(name)")
        #expect(!full.isEmpty && full == incremental, "\(name)")
        let words = name == "item-quote-150" ? "x" : "item"
        #expect(full.joined().components(separatedBy: words).count - 1 >= 150, "\(name)")
    }

    /// Compare with Last Commit (#72) parses the committed text where it is
    /// called (CommitBaseline.queue, a GCD thread).
    struct Git: GitRunning {
        let text: String
        func run(_ arguments: [String], in directory: String) -> Data? { Data(text.utf8) }
    }

    @Test func compareWithTheLastCommitParsesOnASmallStack() {
        let git = Git(text: Self.listsInQuote)
        nonisolated(unsafe) var result: CommitComparison? = nil
        #expect(CoreFixes38Tests.onSmallStack {
            result = GitBaseline.compare(path: "/repo/plan.md", displayed: [], git: git, exists: { $0 == "/repo/.git" })
        })
        #expect(result != nil)
    }

    /// Compare with Last Commit (#72) and Mark All as Read's undo reload the
    /// session (`reload(baseline:)`): the link definitions (#74) must survive,
    /// for ⌘C and Copy as Quote (the reset patch carries them to the page).
    @Test func reloadKeepsTheLinkDefinitions() {
        let text = "See [the spec][spec] first.\n\n[spec]: https://example.com/spec \"Spec\"\n"
        let s = DocumentSession()
        let opened = s.load(MarkdownParser.parse(text))
        #expect(opened.links?.count == 1)
        #expect(s.links.count == 1)
        let reloaded = s.reload(baseline: [])
        #expect(s.links.count == 1, "session.links after reload: \(s.links)")
        #expect(reloaded.links == opened.links, "reset patch after reload carries links: \(String(describing: reloaded.links))")
    }
}
