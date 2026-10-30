import Foundation
import Testing
@testable import ReadoutCore

/// Copy as Quote (`QuoteFormatter`): whole blocks with their file lines and
/// section, and the source a copy keeps (hard breaks, front matter, definitions).
@Suite struct QuoteFormatterTests {
    static let plan = """
        ---
        title: Plan
        ---
        # Rollout

        Intro paragraph
        over two lines.

        ## Risks

        - first risk
        - second risk
          continued

        | a | b |
        |---|---|
        | 1 | 2 |
        """

    func blocks(_ text: String = Self.plan) -> [Block] {
        var b = MarkdownParser.parse(text).blocks
        for i in b.indices { b[i].slot = i + 1 }
        return b
    }

    func slot(_ blocks: [Block], _ match: (Block) -> Bool) -> Int { blocks.first(where: match)!.slot }

    func parse(_ text: String) -> [Block] { MarkdownParser.parse(text).blocks }

    @Test func copySourceKeepsHardBreaksAndFrontMatterFences() {
        let b = parse("---\ntitle: T\n---\n\nFirst line,  \nsecond line.\n\nPlain.\n")
        #expect(b[0].kind == .frontMatter)
        #expect(b[0].copySource == "---\ntitle: T\n---")
        // `source` (comparisons, removed text) drops trailing white space; a copy keeps the hard break.
        #expect(b[1].source == "First line,\nsecond line.")
        #expect(b[1].copySource == "First line,  \nsecond line.")
        #expect(b[1].html.contains("<br"))
        // Nothing trailing: no second copy of the source.
        #expect(b[2].rawSource == nil && b[2].copySource == "Plain.")
    }

    @Test func copyAsQuoteQuotesTheWholeBlocksWithTheirFileLines() throws {
        let b = blocks()
        // Lines are the file's, front matter included: the paragraph is on lines 6–7.
        let intro = slot(b) { $0.source.hasPrefix("Intro") }
        #expect(QuoteFormatter.quote(blocks: b, slots: [intro], path: "docs/plan.md")
                == "> Intro paragraph\n> over two lines.\n— docs/plan.md#L6-L7 (§ Rollout)")
        // Two list items on consecutive lines stay one tight list; the nearest heading is the section's.
        let items = Set(b.filter { $0.kind == .listItem }.map(\.slot))
        #expect(QuoteFormatter.quote(blocks: b, slots: items, path: "p.md")
                == "> - first risk\n> - second risk\n>   continued\n— p.md#L11-L13 (§ Risks)")
        // A heading and the table after a blank line: a blank quoted line between them.
        let risks = slot(b) { $0.kind == .heading && $0.headingTitle == "Risks" }
        let table = slot(b) { $0.kind == .table }
        let quote = try #require(QuoteFormatter.quote(blocks: b, slots: [risks, table], path: "p.md"))
        #expect(quote.hasPrefix("> ## Risks\n>\n> | a | b |\n> |---|---|\n> | 1 | 2 |\n"))
        #expect(quote.hasSuffix("\n— p.md#L9-L17 (§ Risks)"))
        // One line: a single line reference.
        let rollout = slot(b) { $0.headingTitle == "Rollout" }
        #expect(QuoteFormatter.quote(blocks: b, slots: [rollout], path: "p.md") == "> # Rollout\n— p.md#L4 (§ Rollout)")
        #expect(QuoteFormatter.quote(blocks: b, slots: [999], path: "p.md") == nil)
    }

    @Test func copyAsQuoteBeforeTheFirstHeadingNamesNoSection() {
        let b = blocks("Just a note.\n\n# Later\n")
        #expect(QuoteFormatter.quote(blocks: b, slots: [b[0].slot], path: "n.md") == "> Just a note.\n— n.md#L1")
    }

    @Test func theQuoteNamesTheFileRelativeToItsProjectElseWithTilde() {
        #expect(QuoteFormatter.displayPath("/w/app/docs/plan.md", projectRoot: "/w/app", home: "/Users/me") == "docs/plan.md")
        #expect(QuoteFormatter.displayPath("/w/app/docs/plan.md", projectRoot: "/w/app/", home: "/Users/me") == "docs/plan.md")
        // A plan outside its project (~/.claude/plans): its own path, ~-abbreviated.
        #expect(QuoteFormatter.displayPath("/Users/me/.claude/plans/p.md", projectRoot: "/w/app", home: "/Users/me") == "~/.claude/plans/p.md")
        // A sibling folder that merely starts the same is not inside.
        #expect(QuoteFormatter.displayPath("/w/application/a.md", projectRoot: "/w/app", home: "/Users/me") == "/w/application/a.md")
        #expect(QuoteFormatter.displayPath("/Users/me/n.md", projectRoot: nil, home: "/Users/me") == "~/n.md")
    }

    @Test func blockquotesMarkBlankLinesToo() {
        #expect(QuoteFormatter.blockquote("a\n\nb") == "> a\n>\n> b")
        #expect(QuoteFormatter.blockquote("> nested") == "> > nested")
    }

    @Test func copyAsQuoteKeepsHardBreaksFrontMatterAndReferenceDefinitions() throws {
        var b = MarkdownParser.parse("---\nstatus: draft\n---\n\n# Plan\n\nLine one,  \nline two with [the spec][spec].\n\n[spec]: https://example.com/spec\n")
        for i in b.blocks.indices { b.blocks[i].slot = i + 1 }
        // The definitions the blocks use come from the page (`quoteSelection`, as ⌘C's: web/test/flow.test.mjs).
        let quote = try #require(QuoteFormatter.quote(blocks: b.blocks, slots: [1, 3], path: "p.md", definitions: b.links.map(\.md)))
        // (Written with \n: an editor would strip the hard break's two spaces from a literal.)
        #expect(quote == "> ---\n> status: draft\n> ---\n>\n> Line one,  \n> line two with [the spec][spec].\n>\n"
                + "> [spec]: https://example.com/spec\n— p.md#L1-L8")
    }
}
