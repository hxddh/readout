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
        "<source>", "<!doctype", "<!DOCTYPE note", ">",
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
}
