import Foundation
import Testing
@testable import ReadoutCore

@Suite struct IncrementalParserTests {
    /// Deterministic generator, so a failure always reproduces.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Lines chosen to open and close every construct the fragmenter tracks.
    static let palette = [
        "", "", "", "# New heading", "## Section", "Plain paragraph text.", "中文段落，带标点。", "- item", "* item",
        "1. first", "2) second", "    indented code", "> quote", "> [!NOTE]", "| a | b |", "|---|---|",
        "```", "```js", "~~~", "````", "<details>", "</details>", "<summary>More</summary>", "<!--", "-->",
        "<pre>", "</pre>", "<div>", "$$", "x = $a$ and $$b$$", "---", "***", "===", "Setext", "- [ ] task",
        "- [x] done", "text with <details> inline", "  - nested", "\tTabbed", "<script>", "</script>", "<br>", "<span class=\"x\">", "  <div>",
        "<source>", "####### seven", "<!doctype", "<!DOCTYPE note", ">",
        "See note[^n].", "Again[^m] and[^n].", "[^n]: The note.", "[^m]: Another, citing[^n].", "    continued note",
    ]

    static func mutate(_ lines: inout [String], rng: inout SplitMix64) {
        let at = lines.isEmpty ? 0 : Int.random(in: 0..<lines.count, using: &rng)
        switch Int.random(in: 0..<5, using: &rng) {
        case 0, 1: lines.insert(palette.randomElement(using: &rng)!, at: at)
        case 2: if !lines.isEmpty { lines.remove(at: at) }
        case 3: if !lines.isEmpty { lines[at] += " edited" }
        default: if !lines.isEmpty { lines.insert(lines[at], at: at) }
        }
    }

    func expectSame(_ text: String, _ incremental: IncrementalParser, _ note: @autoclosure () -> String) {
        let full = MarkdownParser.parse(text)
        let inc = incremental.parse(text)
        #expect(inc.title == full.title, "\(note())")
        #expect(inc.blocks.count == full.blocks.count, "\(note())")
        if inc.blocks != full.blocks {
            if let dump = ProcessInfo.processInfo.environment["INC_DUMP"] { try? text.write(toFile: dump, atomically: true, encoding: .utf8) }
            let i = zip(inc.blocks, full.blocks).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(inc.blocks.count, full.blocks.count)
            Issue.record("\(note()): first difference at block \(i)\nincremental: \(i < inc.blocks.count ? String(describing: inc.blocks[i]) : "-")\nfull: \(i < full.blocks.count ? String(describing: full.blocks[i]) : "-")")
        }
    }

    /// The property: after any sequence of edits, the incremental result is
    /// exactly the full parse of the same text.
    @Test(arguments: CorpusTests.documents().map(\.lastPathComponent))
    func randomEditsMatchAFullParse(_ name: String) throws {
        let url = CorpusTests.corpus.appendingPathComponent(name)
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        var rng = SplitMix64(state: XXHash64.hash(name + (ProcessInfo.processInfo.environment["INC_SEED"] ?? "")))
        let parser = IncrementalParser()
        expectSame(lines.joined(separator: "\n"), parser, "\(name) v0")
        for step in 1...40 {
            for _ in 0..<Int.random(in: 1...3, using: &rng) { Self.mutate(&lines, rng: &rng) }
            expectSame(lines.joined(separator: "\n"), parser, "\(name) after edit \(step)")
        }
    }

    @Test func reusesUnchangedFragments() {
        let parser = IncrementalParser()
        var doc = (1...200).map { "## Part \($0)\n\nParagraph \($0) of the plan.\n" }.joined(separator: "\n")
        _ = parser.parse(doc)
        doc = doc.replacingOccurrences(of: "Paragraph 100 of", with: "Paragraph 100 (revised) of")
        _ = parser.parse(doc)
        #expect((parser.lastParsed ?? 99) <= 2)
        #expect(parser.lastReused > 300)
    }

    @Test func linkReferenceDefinitionsParseInFull() {
        #expect(IncrementalParser.needsFullParse(["See [x].", "", "[x]: https://example.com"]))
        #expect(IncrementalParser.needsFullParse(["See [x].", "", "- [x]: https://example.com"]))
        #expect(IncrementalParser.needsFullParse(["See [x].", "", ">[x]: https://example.com"]))
        #expect(IncrementalParser.needsFullParse(["See [x].", "", "> 1. [x]: https://example.com"]))
        #expect(IncrementalParser.needsFullParse(["See [a\\]].", "", "[a\\]]: /target"]))
        #expect(!IncrementalParser.needsFullParse(["<!--", "[x]: inside a comment", "-->", "```", "[y]: in code", "```"]))
        #expect(!IncrementalParser.needsFullParse(["A [link](https://x.y) and a: colon.", "- [ ] task"]))
        let parser = IncrementalParser()
        _ = parser.parse("See [x].\n\n[x]: https://example.com\n")
        #expect(parser.lastParsed == nil)
    }

    @Test func footnotesRenumberAcrossFragments() {
        let parser = IncrementalParser()
        let tail = (1...30).map { "## Part \($0)\n\nText \($0)." }.joined(separator: "\n\n")
        let v1 = "# Doc\n\nFirst[^b].\n\n" + tail + "\n\nLater[^a].\n\n[^a]: A\n[^b]: B\n"
        _ = parser.parse(v1)
        #expect(parser.lastParsed != nil)
        // A new earlier reference renumbers a fragment that did not change.
        let v2 = v1.replacingOccurrences(of: "First[^b].", with: "First[^a][^b].")
        let doc = parser.parse(v2)
        #expect(doc.blocks == MarkdownParser.parse(v2).blocks)
        #expect((parser.lastParsed ?? 99) <= 2)
        let later = doc.blocks.first { $0.text.hasPrefix("Later") }!
        #expect(later.html.contains(">1</a>") && later.html.contains("user-content-fnref-a-2"))
    }

    /// Cases found by review: each version must equal a full parse.
    @Test func reviewedCases() {
        let versions = [
            ["See [x].\n\n- [x]: https://e.com\n\nz\n", "See [x].\n\nedited\n\n- [x]: https://e.com\n\nz\n"],
            ["para\n<source>\n```\n\na\n```\n\nb\n\nc\n```\n\nend\n"],
            ["para\n<search>\n```\n\na\n```\n\nb\n\nc\n```\n\nend\n"],
            ["- <!--\n\nx\n\ny -->\n\nz\n"],
            ["<!doctype\ntext $x$\n\n```\n\ncode\n```\n>\n"],
            ["<!DOCTYPE\ntext\n\n```\n\ncode\n```\n>\n"],
            ["####### text\n<span>\n$x$\n\nafter\n"],
            ["<![cdata[\n$x$\n]]>\n\nz\n", "<![CDATA[\n$x$\n]]>\n\nz\n"],
            ["<//div>\n$x$\n\nz\n"],
            ["---\ntitle: t\n[^x]: metadata\n---\n\nbody[^x]\n\nmore\n"],
        ]
        for sequence in versions {
            let parser = IncrementalParser()
            for text in sequence { expectSame(text, parser, text) }
        }
    }

    @Test func aNewResolverReusesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inc-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "See `src/main.swift`.\n\nOther.\n"
        let parser = IncrementalParser()
        let cache = MarkdownParser.RenderCache()
        cache.beginGeneration()
        let before = parser.parse(text, resolver: FileResolver(baseDirectory: nil), cache: cache)
        #expect(!before.blocks[0].html.contains("path-link"))
        cache.beginGeneration()
        let after = parser.parse(text, resolver: FileResolver(baseDirectory: dir), cache: cache)
        #expect(after.blocks[0].html.contains("path-link"))
    }

    /// Eight or more new fragments are parsed concurrently: the blocks come
    /// out in document order, the same as a full parse, every time.
    @Test func manyNewFragmentsParseConcurrentlyInOrder() {
        let parser = IncrementalParser()
        let cache = MarkdownParser.RenderCache()
        func doc(_ v: Int) -> String {
            (1...60).map { "## Part \($0)\n\nParagraph \($0), version \(v), with $x_\($0)$ and `code`.\n\n- item \($0)\n" }
                .joined(separator: "\n")
        }
        for v in 0..<6 {
            cache.beginGeneration()
            let inc = parser.parse(doc(v), cache: cache)
            #expect((parser.lastParsed ?? 0) >= 8)
            #expect(inc.blocks == MarkdownParser.parse(doc(v)).blocks, "version \(v)")
        }
    }

    @Test func fragmentsCoverEveryLineOnce() {
        let lines = ["# A", "", "text", "", "```", "", "code", "", "```", "", "- a", "", "  b", "", "c", "", "<details>", "", "x", "", "</details>", "", "d"]
        let parts = IncrementalParser.fragments(lines)
        #expect(parts.first?.lowerBound == 0 && parts.last?.upperBound == lines.count)
        #expect(zip(parts, parts.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        // No cut inside the fence, the list item's continuation, or <details>.
        let cuts = Set(parts.map(\.lowerBound))
        #expect(!cuts.contains(6) && !cuts.contains(12) && !cuts.contains(18))
        #expect(cuts.contains(2) && cuts.contains(14) && cuts.contains(22))
    }

    @Test func emptyListItemMatchesIncremental() {
        expectIncrementalMatchesFull("-\r\n  ```\r\n\t]\r\n  ```\r\n```\r\n\r\n#")
        expectIncrementalMatchesFull("1.\n   ```\n   code\n\n   more\n   ```\n\nafter\n")
        expectIncrementalMatchesFull("2) d\n-\n[\n<e>\n```\n\nt")
    }

    @Test func setextDashUnderlineMatchesIncremental() {
        expectIncrementalMatchesFull("x\n-\n<e>\n```\n\n```\n\nx")
        expectIncrementalMatchesFull("Title\n--\n<span>x</span>\n```\n\nin code?\n```\n\nend\n")
    }

    @Test func multiLineDisplayMathMatchesIncremental() {
        expectIncrementalMatchesFull("$$\n1. $$\n<n s=\"\">\n```\n\nh")
        expectIncrementalMatchesFull("$$\nf(x) = x^2\n- 2x + 1\n$$\n<custom>\n```\nx\n\ny\n```\n")
        expectIncrementalMatchesFull("Intro\n\n$$\nf(x) = x^2\n- 2x + 1\n$$\n\n```\ncode\n\n# not a heading\n```\n")
    }

    /// Found by `DifferentialFuzzTests`.
    @Test func fuzzedCasesMatchIncremental() {
        expectIncrementalMatchesFull("1. <t>\ne\n<n s=\"\">\n<script\n\nx")             // HTML right after a list marker
        expectIncrementalMatchesFull("[^n]\n[^n]:\n#\n-\t\n<g c=\"\">\n$$ $$")          // empty item with a tab
        expectIncrementalMatchesFull("-\n\t```\n\n\ne")                                   // tab-indented fence in an item
        expectIncrementalMatchesFull("```\r\n```\r\n1.     ,\r\n<t>\r\n,\r\n```<details\r\n```\r\n\r\nd")   // `1.     code`
        expectIncrementalMatchesFull("<details\n\n#")                                        // `<details` at the end of a line
        expectIncrementalMatchesFull("[^n]\n[^n]:\n#\n-\t1\n<g c=\"\">\n$$ $$")          // a tab after the marker
        expectIncrementalMatchesFull("-\t\tcode\n<g c=\"\">\n$x$\n\nend")                 // a tab after the marker, then code
        expectIncrementalMatchesFull("> 1.     code\n> <g c=\"\">\n> $x$\n\nend")             // `1.     code` in a quote
        expectIncrementalMatchesFull("1. ---\nd\n<e>\n<!X\n\na")                           // an item holding a break
        expectIncrementalMatchesFull("- # Title\nd\n<e>\n<!X\n\na")                        // an item holding a heading
        expectIncrementalMatchesFull(" #\n\nn")                                             // an empty heading after a space
        expectIncrementalMatchesFull("- -\n>\n  ~~~\nd\n[^n]:\n#")                          // `>` alone ends the item
        expectIncrementalMatchesFull("d\n>     d\ne\n<r>\n```\n\ne")                        // indented code in a new quote
        expectIncrementalMatchesFull("- 1.\nd\n  ```\n]\n\nn")                              // an empty item in an item
        expectIncrementalMatchesFull(">-\nd\n<r>\n```\n\ne")                                // an empty item in a quote
        expectIncrementalMatchesFull(">#\n.\n<e>\n```\n\n#")                                // a heading in a quote
        expectIncrementalMatchesFull(">d\n>-\nd\n<e>\n```\n\n#")                           // a setext underline in a quote
        expectIncrementalMatchesFull("[^n]:\n<r>\n<!X\n\n#\n<e>\n[^n]:")                     // a footnote definition, then raw HTML
        expectIncrementalMatchesFull("[^n]:\n<m>\n<!--\n\ne\n<?\n-->\n[^n]:")
        expectIncrementalMatchesFull("1.\r\n    1. <v>\r\n#######\r\n<i>\r\nd\r\n<!A\r\n\r\n#")    // a nested item indented 4
        // A line left of a nested item's content may still be in the outer item.
        expectIncrementalMatchesFull("-\n  -\n  ```\n```\n\n#")
        expectIncrementalMatchesFull("- Step one\n  - detail\n  ```bash\n  make $X\n\n  # not a heading\n  ```\n- Step two\n")
        // A block quote right after a list marker.
        expectIncrementalMatchesFull("1. >```\nx\n<t>\n```\n\n\u{8667}")
        expectIncrementalMatchesFull("1. >\n\u{FF1A}\n<m>\n<!E\n\n#")
        // Raw HTML in a block quote ends with the quote.
        expectIncrementalMatchesFull("[^n]\n[^n]:\n#\n><!A\n>$]")
        expectIncrementalMatchesFull("><!A\nD\n<t>\n```\n\ne")
        expectIncrementalMatchesFull("[^n]\n[^n]:\na\n><p\n\t$$ $$")
        expectIncrementalMatchesFull("> <details>\n> <summary>More</summary>\n>\n> Price $x$ inside.\n>\n> </details>\n\nAfter $y$.\n")
    }

    /// Found by the test above: a fence left open to the end holds the
    /// blank lines after its last line, and its cached HTML (keyed by its
    /// source, which stops at the last non-blank line) was that of the same
    /// code with more or fewer of them.
    @Test func openFenceAtTheEndRendersAsTheFullParse() {
        let a = "Intro.\n\n```\ncode\n- item\n\n", b = "Intro.\n\n```\ncode\n- item", c = a + "\n"
        for (x, y) in [(a, b), (b, a), (a, c), (c, a)] {
            let p = IncrementalParser(), cache = MarkdownParser.RenderCache()
            cache.beginGeneration(); _ = p.parse(x, cache: cache)
            cache.beginGeneration()
            #expect(p.parse(y, cache: cache).blocks == MarkdownParser.parse(y).blocks, "\(y.debugDescription)")
        }
    }

    /// Also found by the long fuzz runs (grown palette): the fragmenter read
    /// HTML starts and ends by Character, so `>` followed by a variation
    /// selector was no `>` to it (cmark-gfm reads bytes) and an HTML block
    /// ended, or started, elsewhere than in the full parse.
    @Test func variationSelectorAfterAnHTMLTagMatchesTheFullParse() {
        for t in ["<details>\u{FE0F}\n\n#", "<script>\u{FE0F}\n\ne", "<!E\n>\u{FE0F}\n~~~\n>\n\n#",
                  "<pre>\u{FE0F}\n[^n]:\nx", "<pre>\nx</pre>\u{FE0F}\n\nAfter.", "<!-- c -->\u{FE0F}\n\nAfter."] {
            #expect(IncrementalParser().parse(t).blocks == MarkdownParser.parse(t).blocks, "\(t.debugDescription)")
        }
    }

    /// cmark-gfm takes `- <NBSP>` for a list item (only space and tab are
    /// white space there); the fragmenter took it for a paragraph, so an HTML
    /// block opened in it ended elsewhere and text the full parse keeps in
    /// an open comment showed.
    @Test func nbspItemThenHTMLMatchesTheFullParse() {
        let text = "- \u{00A0}\n  <tr\n<!--\n\nText after.\n"
        let inc = IncrementalParser().parse(text), full = MarkdownParser.parse(text)
        #expect(inc.blocks == full.blocks)   // 3.7: incremental ends the comment at line 3, full at 5
        for t in ["- \u{00A0}\n  <div>\n\nAfter.", "- \u{3000}\n  ```\n\nx\n", "1. \u{00A0}x\n2. y\n\nz"] {
            #expect(IncrementalParser().parse(t).blocks == MarkdownParser.parse(t).blocks, "\(t)")
        }
    }

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
