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

    /// The most a tree gets past the guard: lists and items (16 each), a
    /// table (4), 16 inline levels, the document and the text.
    static let deepest = 2 * NestingCap.containers + 4 + NestingCap.inlines + 2

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
        for k in 0..<120 {
            let levels = Int.random(in: 20...300, using: &rng)
            var text = ""
            switch k % 4 {
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
            #expect(d <= Self.deepest, "shape \(k % 4), \(levels) levels: depth \(d)")
            if d > Self.deepest { return }
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
