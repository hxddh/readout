import Foundation
import Markdown
import Testing
@testable import ReadoutCore

/// 3.6 performance work (P4, P5, G): the cheaper paths give the same results
/// as the ones they replace, and the page's patches carry only what it reads.
@Suite struct PerfFixes36Tests {
    typealias RNG = IncrementalParserTests.SplitMix64

    // MARK: P5: byte line splits

    @Test func lineSlicesSplitLikeCharacters() {
        let texts = [
            "", "\n", "\n\n", "a", "a\n", "\na", "a\nb\n\nc", "  - [ ] x\n> quote\n",
            "é\n\u{301}combining after a line break\n", "全角\n\u{3000}\n", "👩‍👩‍👧\n🇸🇬\n", "tab\there\n\t\n",
            "\u{E004}filler\n$$\nx\n$$",
        ]
        for t in texts {
            let reference = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            #expect(FastBytes.lineSlices(t).map(String.init) == reference, "\(t.debugDescription)")
        }
    }

    @Test func checkboxProbe() {
        for s in ["- [ ] a", "- [x] a", "- [X] a", "> 1. [ ] a", "x [ ]"] { #expect(FastBytes.mayHaveCheckbox(s), "\(s)") }
        for s in ["", "- a", "- [] a", "- [y] a", "- [\t] a", "[link](x)", "[", "]", "- [  ] a"] {
            #expect(!FastBytes.mayHaveCheckbox(s), "\(s)")
        }
    }

    /// Checkboxes the parser reports, against every list item swift-markdown
    /// finds with one, over random documents of task lists in the containers
    /// a block can hold them in.
    @Test func tasksFoundWithoutWalkingEveryBlock() {
        let palette = [
            "- [ ] open", "- [x] done", "* [X] Done", "1. [ ] first", "+ [x] plus", "  - [ ] nested", "    - [x] deeper",
            "> - [ ] quoted", "- plain item", "- [] not a box", "- [y] not a box", "Paragraph with [ ] brackets",
            "", "", "<details>", "<summary>S</summary>", "</details>", "```", "- [ ] in code", "| a | b |", "|---|---|",
            "| [ ] | x |", "# Heading", "- [ ]", "- [x]", "Text [x] inline", "  continued",
        ]
        var rng = RNG(state: 36)
        for _ in 0..<300 {
            let lines = (0..<Int.random(in: 1..<30, using: &rng)).map { _ in palette.randomElement(using: &rng)! }
            let text = lines.joined(separator: "\n")
            var reference = 0
            func walk(_ m: Markup) {
                if let li = m as? ListItem, li.checkbox != nil { reference += 1 }
                for c in m.children { walk(c) }
            }
            walk(Document(parsing: text, options: [.disableSmartOpts]))
            #expect(MarkdownParser.parse(text).tasks.total == reference, "\(text)")
        }
    }

    /// The byte checks before the path pattern say no exactly where the
    /// Character checks they replace did, or the pattern cannot match.
    @Test func pathPrecheckMatchesCharacterChecks() {
        let resolver = FileResolver(baseDirectory: URL(fileURLWithPath: "/tmp"))
        let codes = ["a.swift", "src/a.swift:12", "a b.swift", "README", "1.2.3", "x/y", " \u{301}a.md", "a\u{301}.md",
                     String(repeating: "a", count: 299) + ".md", String(repeating: "é", count: 297) + ".md",
                     String(repeating: "e\u{301}", count: 297) + ".md", "~/notes.txt", "全角.md", "a.md "]
        for code in codes {
            let characterChecks = code.count <= 300 && !code.contains(" ") && (code.contains(".") || code.contains("/"))
            if characterChecks != FileResolver.mayBePath(code) {
                // Only where no path can be found anyway.
                #expect(resolver.pathReference(code) == nil, "\(code.debugDescription)")
            }
        }
        #expect(FileResolver.mayBePath("src/a.swift:12"))
        #expect(!FileResolver.mayBePath("a b.swift"))
        #expect(FileResolver.mayBePath(String(repeating: "e\u{301}", count: 297) + ".md"))   // 300 characters, 894 bytes
        #expect(!FileResolver.mayBePath(String(repeating: "e\u{301}", count: 298) + ".md"))
    }

    // MARK: G: block keys kept with the blocks

    /// Keys reused from the previous version are the keys built afresh, over
    /// random edit sequences (blocks edited, inserted, removed, duplicated, moved).
    @Test func reusedKeysAreFreshKeys() {
        var rng = RNG(state: 12)
        for _ in 0..<150 {
            var lines = (0..<Int.random(in: 0..<40, using: &rng)).map { _ in DifferentialFuzzTests.palette.randomElement(using: &rng)! }
            var old = MarkdownParser.parse(lines.joined(separator: "\n")).blocks
            for _ in 0..<12 {
                for _ in 0..<Int.random(in: 1..<4, using: &rng) { DifferentialFuzzTests.mutate(&lines, rng: &rng) }
                if Int.random(in: 0..<4, using: &rng) == 0, lines.count > 6 {
                    // A run of lines moved elsewhere.
                    let run = Array(lines[1..<4]); lines.removeSubrange(1..<4); lines += run
                }
                let new = MarkdownParser.parse(lines.joined(separator: "\n")).blocks
                let fresh = new.map(BlockKey.init)
                #expect(DocumentSession.keys(new, reusing: old, old.map(BlockKey.init)) == fresh)
                old = new
            }
        }
    }

    /// A session updated many times has the baseline a fresh load computes.
    @Test func sessionBaselineMatchesFreshKeys() {
        var rng = RNG(state: 55)
        var lines = (0..<30).map { _ in DifferentialFuzzTests.palette.randomElement(using: &rng)! }
        let session = DocumentSession()
        let parser = IncrementalParser()
        _ = session.load(parser.parse(lines.joined(separator: "\n")))
        for _ in 0..<60 {
            DifferentialFuzzTests.mutate(&lines, rng: &rng)
            let doc = parser.parse(lines.joined(separator: "\n"))
            _ = session.update(doc)
            session.markAllRead()
            #expect(session.baseline == session.blocks.map(BlockKey.init))
        }
    }

    // MARK: P4: the page's patch

    static func object(_ value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try #require(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
    }

    /// The page gets the patch without the outline, task counts and title
    /// (web/src/reader/patch.js reads none of them); everything else is the same JSON.
    @Test func pagePayloadIsThePatchWithoutAppFields() throws {
        let session = DocumentSession()
        let first = session.load(MarkdownParser.parse("# Title\n\n- [ ] a\n\n## B\n\ntext"))
        let second = try #require(session.update(MarkdownParser.parse("# Title\n\n- [x] a\n\n## B\n\ntext\n\nmore")))
        for patch in [first, second] {
            let page = try Self.object(patch.page)
            var full = try Self.object(patch)
            #expect(full["toc"] != nil && full["tasks"] != nil && full["title"] != nil)
            full["toc"] = nil; full["tasks"] = nil; full["title"] = nil
            #expect(NSDictionary(dictionary: page) == NSDictionary(dictionary: full))
            #expect(Set(page.keys) == ["version", "reset", "rewrite", "ops", "marks", "deletions"])
        }
    }

    /// An agent appending one paragraph to a 1 MB document: the page's patch
    /// is that paragraph, not the document's whole outline (142 KB before).
    @Test func appendPatchToThePageIsSmall() throws {
        let doc = PerformanceBudgetTests.document(bytes: 1_000_000)
        let session = DocumentSession()
        let parser = IncrementalParser()
        _ = session.load(parser.parse(doc))
        let patch = try #require(session.update(parser.parse(doc + "\n\nThe agent appended this new paragraph describing the next step of the plan.\n")))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let bytes = try encoder.encode(patch.page).count
        #expect(patch.ops.count == 1)
        #expect(bytes < 1_000, "page payload \(bytes) bytes")
        #expect(try encoder.encode(patch).count > 100_000)   // the app's model still gets the outline
    }
}
