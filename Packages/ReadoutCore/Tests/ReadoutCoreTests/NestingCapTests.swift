import Foundation
import Markdown
import Testing
@testable import ReadoutCore

/// Deep nesting (`NestingCap`): flattened past what a small stack holds, never
/// what real documents nest, the same in full and incremental parses.
@Suite struct NestingCapTests {
    /// The audit's documents (`bugs/B1`): a few hundred bytes of nesting.
    static let deep: [(name: String, text: String)] = [
        ("quotes-400", String(repeating: ">", count: 400) + " x"),
        ("lists-150", (0..<150).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n")),
        ("ordered-150", (0..<150).map { String(repeating: "   ", count: $0) + "1. item" }.joined(separator: "\n")),
        ("loose-lists-150", (0..<150).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n\n")),
        ("loose-4-150", (0..<150).map { String(repeating: "    ", count: $0) + "- item" }.joined(separator: "\n\n")),
        ("mixed-120", String(repeating: "> - ", count: 120) + "x"),
        ("lists-in-quote-150", (0..<150).map { "> " + String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n")),
        ("images-300", String(repeating: "[![", count: 300) + "x" + String(repeating: "](a.png)](b)", count: 300)),
        ("emphasis-4000", String(repeating: "*a **b ", count: 4000) + "c" + String(repeating: "** b*", count: 4000)),
        ("strike-2000", String(repeating: "~~a ", count: 2000) + "c" + String(repeating: " b~~", count: 2000)),
        ("links-300", String(repeating: "[a ", count: 300) + "x" + String(repeating: " b](y)", count: 300)),
        ("emphasis-lines", (0..<2000).map { _ in "*a **b" }.joined(separator: "\n") + "\nc\n" + (0..<2000).map { _ in "b** a*" }.joined(separator: "\n")),
        ("quoted-emphasis", String(repeating: ">", count: 300) + " " + String(repeating: "*a **b ", count: 300) + "c" + String(repeating: "** b*", count: 300)),
        ("note-emphasis", "x[^n]\n\n[^n]: " + String(repeating: "*a **b ", count: 2000) + "c" + String(repeating: "** b*", count: 2000)),
        // The 3.8 release review: lists nested by indentation inside block quotes.
        ("ordered-in-quote-150", (0..<150).map { "> " + String(repeating: "   ", count: $0) + "1. item" }.joined(separator: "\n")),
        ("list-in-list-quote-150", "- top\n" + (0..<150).map { "  > " + String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n")),
        ("quote-in-quote-4sp-150", (0..<150).map { "> > " + String(repeating: "    ", count: $0) + "- item" }.joined(separator: "\n")),
        // A line escaped at its `>` keeps its item open for the lines below (review of #76).
        ("item-quote-150", (0..<150).map { String(repeating: "  ", count: $0) + "- > x" }.joined(separator: "\n")),
        ("quoted-item-quote-150", (0..<150).map { "> " + String(repeating: "  ", count: $0) + "- > item" }.joined(separator: "\n")),
        // 3.9 (audit B2): emphasis around images, which the 3.8 guard under-counted (160 KB; 16 MB stacks overflowed).
        ("emph-image-20000", String(repeating: "*![", count: 20000) + "x" + String(repeating: "](u)*", count: 20000)),
    ]

    /// `body` on a thread with a 512 KB stack (a GCD worker's on macOS,
    /// where `IncrementalParser` parses fragments concurrently): on 3.7 it
    /// crashed the process.
    static func onSmallStack(_ size: Int = 512 * 1024, _ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let t = Thread { body(); done.signal() }
        t.stackSize = size
        t.start()
        return done.wait(timeout: .now() + 60) == .success
    }

    static func depth(_ m: Markup) -> Int { 1 + (m.children.map(depth).max() ?? 0) }

    /// The swift-markdown tree of `text` after the guard, measured on a
    /// thread with a large stack (so a guard that let a deep tree through
    /// fails here instead of crashing the run).
    static func cappedDepth(_ text: String) -> Int {
        nonisolated(unsafe) var d = 0
        let done = DispatchSemaphore(value: 0)
        let t = Thread { d = depth(Document(parsing: NestingCap.apply(text)?.text ?? text, options: [.disableSmartOpts])); done.signal() }
        t.stackSize = 64 << 20
        t.start()
        done.wait()
        return d
    }

    /// The most levels a tree has past the guard.
    static let deepest = NestingCap.levels

    /// Lists nested by indentation inside one block quote: every line has
    /// one `>` and one `-`, so NestingCap counts two levels; cmark nests 150.
    static let listsInQuote = (0..<150).map { "> " + String(repeating: "  ", count: $0) + "- item \($0)" }.joined(separator: "\n")

    /// The deepest documents get past the guard (`NestingCap`): at most
    /// `levels` levels of swift-markdown's tree, which parse on a GCD
    /// thread's 512 KB stack in a debug build too (about 10 KB a level
    /// there, 3.3 KB in a release one). Shapes: 16 list levels with a table
    /// and 16 inline levels in a cell (the inlines go past `levels`: escaped),
    /// 16 list levels with inlines up to the limit, 16 quotes with 16
    /// inlines, and a paragraph continued by indented bullet lines (review
    /// of #83). CI runs this in the release build too (verify.yml).
    static let deepestShapes: [String] = {
        let list = (0..<NestingCap.containers).map { String(repeating: "  ", count: $0) + "- level \($0 + 1)" }.joined(separator: "\n")
        let inline = String(repeating: "*a ![", count: NestingCap.inlines / 2) + "x" + String(repeating: "](u) b*", count: NestingCap.inlines / 2)
        let indent = String(repeating: " ", count: 2 * NestingCap.containers)
        let table = list + "\n\n" + indent + "| h |\n" + indent + "|---|\n" + indent + "| " + inline + " |\n"
        let few = String(repeating: "*a ![", count: 2) + "x" + String(repeating: "](u) b*", count: 2)
        let bullets = "x\n" + String(repeating: "    - *![*![*![*![*![\n", count: 20) + String(repeating: "    - ](u)*](u)*](u)*](u)*](u)*\n", count: 20)
        return [table, list + " " + few, String(repeating: "> ", count: 16) + inline, bullets]
    }()

    @Test func deepNestingParsesOnASmallStack() {
        // The audit's test (bugs/AuditB38ReprosTests.swift).
        let text = String(repeating: ">", count: 400) + " x\n\n" + (0..<150).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n")
        nonisolated(unsafe) var blocks = -1
        #expect(Self.onSmallStack { blocks = MarkdownParser.parse(text).blocks.count })
        #expect(blocks > 0)
        for d in Self.deep {
            nonisolated(unsafe) var full = -1, incremental = -1
            #expect(Self.onSmallStack {
                full = MarkdownParser.parse(d.text).blocks.count
                incremental = IncrementalParser().parse(d.text).blocks.count
            }, "\(d.name)")
            #expect(full > 0 && full == incremental, "\(d.name)")
        }
    }

    /// Flattened, not dropped: the deepest container holds the rest as text.
    @Test func deepNestingKeepsItsText() {
        let quotes = MarkdownParser.parse(String(repeating: ">", count: 400) + " x").blocks
        #expect(quotes.count == 1)
        let html = quotes[0].html
        #expect(html.components(separatedBy: "<blockquote").count - 1 == NestingCap.containers)
        #expect(html.contains(String(repeating: "&gt;", count: 400 - NestingCap.containers) + " x"), "\(html.suffix(200))")
        // Block.source stays what the file says.
        #expect(quotes[0].source == String(repeating: ">", count: 400) + " x")
        let list = MarkdownParser.parse(Self.deep[1].text).blocks
        #expect(list.map(\.text).joined().components(separatedBy: "item").count - 1 == 150)
        let emphasis = MarkdownParser.parse(Self.deep[5].text).blocks[0].html
        #expect(emphasis.contains("c"))
        #expect(emphasis.components(separatedBy: "<em>").count - 1 <= NestingCap.inlines)
    }

    /// What real documents nest is left as it is: no corpus document, and
    /// no ordinary deep list or busy paragraph, is changed.
    @Test func ordinaryNestingIsUntouched() throws {
        for url in CorpusTests.documents() {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(NestingCap.apply(text) == nil, "\(url.lastPathComponent)")
        }
        let ordinary = [
            (0..<8).map { String(repeating: "    ", count: $0) + "- level \($0)" }.joined(separator: "\n"),
            (0..<16).map { String(repeating: "  ", count: $0) + "- level \($0)" }.joined(separator: "\n"),
            String(repeating: "> ", count: 10) + "**quoted** and *deep*",
            (0..<40).map { "**Step \($0):** run `make_\($0)` with *care* and [docs](d\($0).md)" }.joined(separator: " "),
            (0..<40).map { "- **注意：**这里 `~/path/\($0)` ~/home \($0)" }.joined(separator: "\n"),
            "```\n" + String(repeating: ">", count: 100) + "\n" + String(repeating: "[", count: 100) + "\n```",
            "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -",
            "a_b_c " + String(repeating: "snake_case_name ", count: 40),
            String(repeating: "2*3*4 ", count: 40),
        ]
        for text in ordinary { #expect(NestingCap.apply(text) == nil, "\(text.prefix(60))") }
    }

    /// An outline nests 16 levels deep whatever its indentation (2, 3 or 4
    /// spaces, tight or loose) and renders as written; the 17th level is
    /// text. (A first cut counted half the columns as levels: a 4-space
    /// outline stopped at level 9.)
    @Test func outlinesNestSixteenLevelsAtAnyIndentation() {
        for width in [2, 3, 4] {
            for separator in ["\n", "\n\n"] {
                func outline(_ levels: Int) -> String {
                    (0..<levels).map { String(repeating: " ", count: width * $0) + (width == 3 ? "1. " : "- ") + "level \($0 + 1)" }
                        .joined(separator: separator)
                }
                let sixteen = outline(16)
                #expect(NestingCap.apply(sixteen) == nil, "\(width) spaces \(separator.count == 2 ? "loose" : "tight")")
                let html = MarkdownParser.parse(sixteen).blocks.map(\.html).joined()
                #expect(!html.contains("- level") && !html.contains("1. level"), "\(width) \(separator.count)")
                #expect(html.components(separatedBy: "<li").count - 1 == 16, "\(width) \(separator.count)")
                if separator == "\n" {
                    // Tight, the run tells every level: the 17th is text.
                    let text = MarkdownParser.parse(outline(17)).blocks.map(\.html).joined()
                    #expect(text.components(separatedBy: "<li").count - 1 == 16, "\(width)")
                    #expect(text.contains("level 17"), "\(width)")
                }
            }
        }
    }

    /// Flattening is decided per line and per run of non-blank lines, which
    /// fragments never split: incremental and spliced parses (with the render
    /// cache) are the full parse's, across edits in and around deep nesting.
    @Test func flattenedNestingIsTheSameIncrementally() {
        var rng = IncrementalParserTests.SplitMix64(state: 38)
        let pieces = Self.deep.map(\.text).map { String($0.prefix(400)) } + [
            "# Heading", "Plain paragraph.", "- item", "  - nested", "> quote", "```", "code", "", "", "",
            String(repeating: ">", count: 30) + " " + String(repeating: "[", count: 30) + "x" + String(repeating: "](y)", count: 30),
            String(repeating: "  ", count: 20) + "- deep item", "*a **b *c **d *e **f *g **h *i **j", "j** i* h** g* f** e* d** c* b** a*",
        ]
        for round in 0..<6 {
            var lines = (0..<30).map { _ in pieces.randomElement(using: &rng)! }
            let p = IncrementalParser(), cache = MarkdownParser.RenderCache()
            for step in 0..<20 {
                let at = Int.random(in: 0..<lines.count, using: &rng)
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: lines.insert(pieces.randomElement(using: &rng)!, at: at)
                case 1: lines.remove(at: at)
                case 2: lines[at] += " edited"
                default: lines.append(pieces.randomElement(using: &rng)!)
                }
                if lines.isEmpty { lines = ["x"] }
                let text = lines.joined(separator: "\n")
                cache.beginGeneration()
                let inc = p.parse(text, cache: cache), full = MarkdownParser.parse(text)
                #expect(inc.blocks == full.blocks && inc.title == full.title, "round \(round) step \(step) spliced \(p.lastSpliced)")
                if inc.blocks != full.blocks { return }
            }
        }
    }

    @Test(arguments: deepestShapes.indices)
    func theDeepestDocumentsFitASmallStack(_ k: Int) {
        let text = Self.deepestShapes[k]
        #expect(NestingCapTests.cappedDepth(text) <= NestingCap.levels)
        nonisolated(unsafe) var full: [String] = [], incremental: [String] = []
        #expect(Self.onSmallStack {
            full = MarkdownParser.parse(text).blocks.map(\.html)
            incremental = IncrementalParser().parse(text).blocks.map(\.html)
        })
        #expect(!full.isEmpty && full == incremental)
    }

    /// Emphasis around images (`*![` … `](u)*`) passed the 3.8 guard, which
    /// imitated cmark's pairing: the tree was as deep as the input (234 levels
    /// from 200 pairs; 20,000 pairs crashed even a 16 MB stack).
    @Test func emphasisAroundImagesIsCapped() {
        for n in [200, 20000] {
            let text = String(repeating: "*![", count: n) + "x" + String(repeating: "](u)*", count: n)
            #expect(Self.cappedDepth(text) <= Self.deepest, "\(n) pairs")
        }
        // The text is all there, as written.
        let html = MarkdownParser.parse(String(repeating: "*![", count: 40) + "x" + String(repeating: "](u)*", count: 40)).blocks[0].html
        #expect(html.components(separatedBy: "](u)").count - 1 == 40, "\(html.prefix(200))")
    }

    /// Random deep shapes (the audit's cap fuzz): containers on one line and
    /// over many, inline openers over a paragraph's lines, lazy lines under
    /// quotes. Whatever the shape, the tree stays within what a small stack holds.
    @Test func anyShapeIsCapped() {
        var rng = IncrementalParserTests.SplitMix64(state: 4040)
        let openers = ["> ", "- ", "1. ", "* ", "+ ", ">", "  ", "    ", "\t", "> - ", "- > ", "10) ", "-\t",
                       "[", "**", "*", "_", "__", "~~", "![", "<span>", "[^a]: ", "<details>\n\n"]
        let closers = ["](u)", "**", "*", "_", "__", "~~", "](u) ", "</span>"]
        let rounds = Int(ProcessInfo.processInfo.environment["READOUT_CAP_ROUNDS"] ?? "") ?? 150
        for k in 0..<rounds {
            let levels = Int.random(in: 20...300, using: &rng)
            var text = ""
            switch k % 7 {
            case 5, 6:
                // Deep over many lines of one paragraph: inline openers, then
                // closers, a few a line, each line led by what may continue a
                // paragraph (a bullet indented four past its container, `2.`,
                // a lazy line, quote and item prefixes): review of #83.
                let container = ["", "> ", "- ", "> > ", "1. ", "  - "].randomElement(using: &rng)!
                let inside = container.isEmpty ? "" : String(repeating: " ", count: container.count).replacingOccurrences(of: "  ", with: container.hasPrefix(">") ? "> " : "  ")
                let leads = ["    - ", "    * ", "    + ", "2. ", "", "     ", "    1) "]
                text = container + "x\n"
                let per = Int.random(in: 1...6, using: &rng), lines = max(1, levels / per)
                let open = ["*![", "[", "**", "_", "~~", "*["].randomElement(using: &rng)!
                let close = ["](u)*", "](u)", "**", "_", "~~", "](u)*"][["*![", "[", "**", "_", "~~", "*["].firstIndex(of: open)!]
                for _ in 0..<lines { text += (k % 7 == 5 ? inside : container) + leads.randomElement(using: &rng)! + String(repeating: open, count: per) + "\n" }
                for _ in 0..<lines { text += (k % 7 == 5 ? inside : container) + leads.randomElement(using: &rng)! + String(repeating: close, count: per) + "\n" }
            case 4:
                // Tabs and spaces mixed into container prefixes (cmark's
                // columns are bytes on the line: tabs, partial tabs and
                // multibyte text before a marker change nothing).
                let parts = ["\t", " \t", "\t ", "  ", ">", ">\t", "> ", "-\t", "- ", "*\t", "1.\t", "1. ", "中 ", "\t> -\t"]
                var indent = ""
                for i in 0..<levels {
                    var prefix = indent
                    for _ in 0..<Int.random(in: 1...4, using: &rng) { prefix += parts.randomElement(using: &rng)! }
                    text += prefix + ["l\(i)", "*a [x", "中文 **b", ""].randomElement(using: &rng)! + (Int.random(in: 0..<4, using: &rng) == 0 ? "\n\n" : "\n")
                    if Bool.random(using: &rng) { indent += ["\t", " \t", "> ", ">\t", "  "].randomElement(using: &rng)! }
                }
            case 0:
                for _ in 0..<levels { text += openers.randomElement(using: &rng)! }
                text += "x"
                for _ in 0..<Int.random(in: 0...levels, using: &rng) { text += closers.randomElement(using: &rng)! }
            case 1:
                var indent = ""
                for i in 0..<levels {
                    text += indent + openers.prefix(13).randomElement(using: &rng)! + "l\(i)" + (Bool.random(using: &rng) ? "\n" : "\n\n")
                    if Bool.random(using: &rng) { indent += ["  ", "   ", "    ", "\t", "> "].randomElement(using: &rng)! }
                }
            case 2:
                for i in 0..<levels { text += openers[13..<20].randomElement(using: &rng)! + "w\(i)" + (i % 7 == 0 ? "\n" : " ") }
                for _ in 0..<levels { text += closers.randomElement(using: &rng)! }
            default:
                for i in 0..<levels {
                    text += String(repeating: "> ", count: i % 40) + ["- ", "1. ", ""].randomElement(using: &rng)! + "t\(i)\n" + (i % 3 == 0 ? "lazy \(i)\n" : "")
                }
            }
            let d = Self.cappedDepth(text)
            #expect(d <= Self.deepest, "shape \(k % 7), \(levels) levels: depth \(d)")
            if d > Self.deepest { return }
        }
    }

    /// Tabs before deep markers (review of #83): cmark-gfm's start columns
    /// are byte offsets on the line, partial tabs and multibyte text
    /// before a marker included, so the escapes land on the markers.
    @Test func tabsBeforeDeepMarkersAreCapped() {
        let shapes: [String] = [
            String(repeating: ">\t", count: 40) + "x",
            (0..<40).map { _ in " >\t" }.joined() + "x",
            String(repeating: "-\t", count: 40) + "x",
            (0..<60).map { String(repeating: "\t", count: $0) + "- i" }.joined(separator: "\n"),
            (0..<60).map { String(repeating: " \t", count: $0) + "* i" }.joined(separator: "\n"),
            (0..<60).map { _ in String(repeating: ">\t", count: 30) + "q" }.joined(separator: "\n"),
            (0..<80).map { String(repeating: "\t", count: $0) + "-\t>\tx" }.joined(separator: "\n"),
            "- 中文\n" + (0..<60).map { String(repeating: "  ", count: $0) + "- 中文 > x" }.joined(separator: "\n"),
            (0..<60).map { String(repeating: "\t", count: $0) + "1.\t中文 **b" }.joined(separator: "\n"),
        ]
        for text in shapes {
            #expect(Self.cappedDepth(text) <= Self.deepest, "\(text.prefix(40).debugDescription)")
            // Capped: past 16 levels nothing nests (and it parses on a small stack).
            #expect(NestingCap.apply(text) != nil, "\(text.prefix(40).debugDescription)")
            nonisolated(unsafe) var blocks = 0
            #expect(NestingCapTests.onSmallStack { blocks = IncrementalParser().parse(text).blocks.count })
            #expect(blocks > 0)
        }
    }

    /// A paragraph continued by bullet lines indented four columns past its
    /// container (they are its text, not items) nests over all of them: the
    /// pre-check counted from each bullet afresh and let it through (review
    /// of #83: 1 KB, 203 levels, a crash on a 512 KB stack). In a quote and
    /// in an item too.
    @Test func indentedBulletLinesAreOneParagraph() {
        func shape(_ container: String, _ inside: String, _ n: Int) -> String {
            container + "x\n" + String(repeating: inside + "    - *![*![*![*![*![\n", count: n) + String(repeating: inside + "    - ](u)*](u)*](u)*](u)*](u)*\n", count: n)
        }
        for text in [shape("", "", 20), shape("", "", 2000), shape("> ", "> ", 200), shape("- ", "  ", 200), shape("> - ", ">   ", 200)] {
            #expect(Self.cappedDepth(text) <= Self.deepest, "\(text.prefix(30).debugDescription)")
            nonisolated(unsafe) var full = -1, incremental = -1
            #expect(NestingCapTests.onSmallStack {
                full = MarkdownParser.parse(text).blocks.count
                incremental = IncrementalParser().parse(text).blocks.count
            })
            #expect(full > 0 && full == incremental)
        }
    }

    @Test func nestingCapSeesListsNestedInsideAQuote() {
        // The cap leaves the text alone: nothing is flattened.
        #expect(NestingCap.apply(Self.listsInQuote) != nil, "NestingCap flattens nothing")
    }

    @Test func listsNestedInsideAQuoteParseOnASmallStack() {
        nonisolated(unsafe) var blocks = -1
        let text = Self.listsInQuote
        #expect(NestingCapTests.onSmallStack { blocks = MarkdownParser.parse(text).blocks.count })
        #expect(blocks > 0)
    }

    /// The other shapes of the same (the review's p/*-in-quote*.md): ordered
    /// items in a quote, items in a quote in an item, 4-space items in `> >`.
    /// Each is flattened, parses on a 512 KB stack, and incrementally as in full.
    @Test(arguments: ["lists-in-quote-150", "ordered-in-quote-150", "list-in-list-quote-150", "quote-in-quote-4sp-150"])
    func listsInQuotesAreCapped(_ name: String) throws {
        let text = try #require(NestingCapTests.deep.first { $0.name == name }).text
        let capped = try #require(NestingCap.apply(text), "\(name): NestingCap flattens nothing")
        // From the 17th level on: the items are at the quote's level plus one (plus two in a quote in a quote, or in a quote in an item).
        let before = name == "quote-in-quote-4sp-150" || name == "list-in-list-quote-150" ? 2 : 1
        #expect(capped.lines.count == 150 - (NestingCap.containers - before), "\(name): \(capped.lines.sorted().prefix(3))")
        nonisolated(unsafe) var full: [String] = [], incremental: [String] = []
        #expect(NestingCapTests.onSmallStack {
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
        #expect(NestingCapTests.onSmallStack {
            full = MarkdownParser.parse(text).blocks.map(\.html)
            incremental = IncrementalParser().parse(text).blocks.map(\.html)
        })
        #expect(!full.isEmpty && full == incremental)
    }

    /// A line escaped at a later marker keeps its earlier item open (review
    /// of #76): `- > x` under `- > x` nests a level each line.
    @Test(arguments: ["item-quote-150", "quoted-item-quote-150"])
    func escapedLinesKeepTheirItems(_ name: String) throws {
        let text = try #require(NestingCapTests.deep.first { $0.name == name }).text
        let capped = try #require(NestingCap.apply(text), "\(name): NestingCap flattens nothing")
        // From the first escaped line on, every line is escaped: none nests deeper than `containers`.
        let first = try #require(capped.lines.min())
        #expect(capped.lines.count == 150 - first, "\(name): \(capped.lines.sorted().prefix(4))")
        nonisolated(unsafe) var full: [String] = [], incremental: [String] = []
        #expect(NestingCapTests.onSmallStack {
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
        #expect(NestingCapTests.onSmallStack {
            result = GitBaseline.compare(path: "/repo/plan.md", displayed: [], git: git, exists: { $0 == "/repo/.git" })
        })
        #expect(result != nil)
    }
}
