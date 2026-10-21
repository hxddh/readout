import Foundation
import Testing
import Markdown
@testable import ReadoutCore

/// 3.9 core fixes (audit lane B, /tmp/claude-0/v40/bugs). Each test failed on 3.8.0.
@Suite struct CoreFixes39Tests {
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

    // MARK: B2, B6: the depth is cmark-gfm's own

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
            #expect(CoreFixes38Tests.onSmallStack { blocks = IncrementalParser().parse(text).blocks.count })
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
            #expect(CoreFixes38Tests.onSmallStack {
                full = MarkdownParser.parse(text).blocks.count
                incremental = IncrementalParser().parse(text).blocks.count
            })
            #expect(full > 0 && full == incremental)
        }
    }

    // MARK: B3, B7: link definitions are the lines the parse made into no block

    @Test func linksAreTheDocumentsDefinitions() {
        // A label over two lines is one.
        #expect(MarkdownParser.parse("See [multi line][].\n\n[multi\nline]: /ml").links.map(\.label) == ["multi line"])
        // An indented code line, or a paragraph's line, is none.
        #expect(MarkdownParser.parse("Use [code] here.\n\n    [code]: /code").links.isEmpty)
        #expect(MarkdownParser.parse("Some text\n[foo]: /url\n\nAnd [foo].").links.isEmpty)
        #expect(MarkdownParser.parse("[x] marks it\n[foo]: /url in a sentence.\n\nAnd [foo].").links.isEmpty)
        // A title over two lines is whole.
        #expect(MarkdownParser.parse("See [m].\n\n[m]: /m \"line one\nline two\"").links.map(\.md) == ["[m]: /m \"line one\nline two\""])
        // Several in a row; one before a paragraph's text; in a quote, an item, after a comment.
        let doc = MarkdownParser.parse("""
            [a]: /a
            [b]:
              /b 'B'
            [c]: /c
            Text using [a], [b], [c], [d], [e], [f].

            > [d]: /d

            - [e]: /e

            <!-- note -->
            [f]: /f
            """)
        // (Before a paragraph's text, in a quote or an item, each is read line by line: a
        // destination on the next line joins it.)
        #expect(doc.links.map(\.md) == ["[a]: /a", "[b]: /b 'B'", "[c]: /c", "[d]: /d", "[e]: /e", "[f]: /f"], "\(doc.links.map(\.md))")
        #expect(doc.links.map(\.label) == ["a", "b", "c", "d", "e", "f"])
        // In a `<details>` the parse gathers into one block (review of #83).
        #expect(MarkdownParser.parse("<details>\n<summary>S</summary>\n\n[a]: /a\n\nInside.\n\n</details>\n\nSee [a].").links.map(\.md) == ["[a]: /a"])
        #expect(MarkdownParser.parse("<details>\n\n> [q]: /q\n\n</details>\n\nSee [q].").links.map(\.md) == ["[q]: /q"])
    }

    // MARK: B5a: a lazy `=` line is no setext underline

    /// Under a list item's paragraph, a lazy `=` is text to cmark-gfm, so
    /// the item stays open and the fence below opens in it (the seed-938
    /// family): the fragmenter closed the item and cut where cmark had code.
    @Test func lazyEqualsIsNoUnderline() {
        for t in ["- a\n=\nk\n  ```\n```\n\ne\n", "- [ ] t\n  =\n\n  =\n==\nlazy\n  ```\n```\n\nafter\n"] {
            let inc = IncrementalParser().parse(t), full = MarkdownParser.parse(t)
            #expect(inc.blocks == full.blocks && inc.title == full.title, "\(t.debugDescription)")
        }
    }
}
