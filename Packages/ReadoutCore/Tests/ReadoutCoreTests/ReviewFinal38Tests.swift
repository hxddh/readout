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
        #expect(capped.lines.count == 150 - (NestingCap.containers - (name == "quote-in-quote-4sp-150" ? 2 : 1)), "\(name): \(capped.lines.sorted().prefix(3))")
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
    /// from 8 on) run on large stacks, not GCD's (512 KB on macOS), whatever
    /// thread asks: every iteration once, all of them before it returns.
    @Test func concurrentFragmentsRunOnLargeStacks() {
        final class Seen: @unchecked Sendable { let lock = NSLock(); var sizes: [Int: Int] = [:] }
        let seen = Seen()
        #expect(CoreFixes38Tests.onSmallStack {
            ParseThread.concurrentPerform(iterations: 64) { k in
                let size = Thread.current.stackSize
                seen.lock.lock(); seen.sizes[k, default: 0] += size; seen.lock.unlock()
            }
        })
        #expect(seen.sizes.count == 64)
        #expect(seen.sizes.values.allSatisfy { $0 >= ParseThread.stackSize }, "\(Set(seen.sizes.values))")
        // Many batches, from several threads at once: each returns with its own done (its closure released).
        final class Sum: @unchecked Sendable { let lock = NSLock(); var total = 0 }
        let sum = Sum()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            for n in 1...200 {
                ParseThread.concurrentPerform(iterations: n % 17 + 1) { _ in sum.lock.lock(); sum.total += 1; sum.lock.unlock() }
            }
        }
        #expect(sum.total == 4 * (1...200).reduce(0) { $0 + $1 % 17 + 1 })
        // A document of many fragments, each nested deep in a quote, asked from a small stack.
        let text = (0..<12).map { "Section \($0).\n\n" + (0..<60).map { "> " + String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n") }
            .joined(separator: "\n\n")
        nonisolated(unsafe) var full: [String] = [], incremental: [String] = []
        #expect(CoreFixes38Tests.onSmallStack {
            full = MarkdownParser.parse(text).blocks.map(\.html)
            incremental = IncrementalParser().parse(text).blocks.map(\.html)
        })
        #expect(!full.isEmpty && full == incremental)
    }

    /// A batch asked for from inside a batch (review of #76) runs: on a
    /// pool of one thread, that thread would otherwise wait on itself.
    static func completes(within seconds: Double = 20, _ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        ParseThread.start { body(); done.signal() }
        return done.wait(timeout: .now() + seconds) == .success
    }

    @Test func aNestedBatchCompletes() {
        final class Count: @unchecked Sendable { let lock = NSLock(); var n = 0; func add() { lock.lock(); n += 1; lock.unlock() } }
        let one = ParsePool(width: 1), count = Count()
        // From a thread that is not a ParseThread: only the pool's one thread runs the outer batch.
        let other = DispatchSemaphore(value: 0)
        Thread { one.perform(8) { _ in one.perform(4) { _ in count.add() } }; other.signal() }.start()
        #expect(other.wait(timeout: .now() + 20) == .success, "a nested batch on a pool of one thread never ended")
        #expect(count.n == 32)
        // The shared pool, nested from a ParseThread, as the review ran it.
        let shared = Count()
        #expect(Self.completes {
            ParseThread.concurrentPerform(iterations: 64) { _ in ParseThread.concurrentPerform(iterations: 4) { _ in shared.add() } }
        }, "concurrentPerform(64) { concurrentPerform(4) } never ended")
        #expect(shared.n == 256)
    }

    /// A caller on a large stack takes iterations itself, as GCD's does.
    @Test func aLargeStackCallerTakesIterations() {
        final class Seen: @unchecked Sendable { let lock = NSLock(); var callerRan = 0; var caller: Thread? }
        let one = ParsePool(width: 1), seen = Seen()
        #expect(Self.completes {
            seen.caller = Thread.current
            one.perform(16) { _ in
                usleep(2_000)
                if Thread.current === seen.caller { seen.lock.lock(); seen.callerRan += 1; seen.lock.unlock() }
            }
        })
        #expect(seen.callerRan > 0, "the calling ParseThread took no iteration")
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
    /// called (CommitBaseline.queue, a GCD thread), not on a ParseThread as
    /// the first-open baseline (#75) does.
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
    /// for ⌘C (the reset patch carries them) and Copy as Quote (`session.links`).
    @Test func reloadKeepsTheLinkDefinitions() {
        let text = "See [the spec][spec] first.\n\n[spec]: https://example.com/spec \"Spec\"\n"
        let s = DocumentSession()
        let opened = s.load(MarkdownParser.parse(text))
        #expect(opened.links?.count == 1)
        #expect(s.links.count == 1)
        let reloaded = s.reload(baseline: [])
        #expect(s.links.count == 1, "session.links after reload: \(s.links)")
        #expect(reloaded.links?.count == 1, "reset patch after reload carries links: \(String(describing: reloaded.links))")
        let quote = QuoteFormatter.quote(blocks: s.blocks, slots: Set(s.blocks.map(\.slot)), path: "plan.md", links: s.links) ?? ""
        #expect(quote.contains("[spec]: https://example.com/spec"), "\(quote)")
    }
}
