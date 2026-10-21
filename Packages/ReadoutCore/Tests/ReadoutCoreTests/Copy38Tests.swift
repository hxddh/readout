import Foundation
import Testing
@testable import ReadoutCore

/// 3.8 copy: what the page and Copy as Quote get to copy whole blocks as
/// written (C1, C4), and the link reference definitions they append (C5).
@Suite struct Copy38Tests {
    func parse(_ text: String) -> [Block] { MarkdownParser.parse(text).blocks }

    // MARK: The source a copy keeps (C4)

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

    /// The splice keeps the raw source of the blocks it keeps: before the
    /// change, and after it when they move by the lines added.
    @Test func theSpliceCarriesTheRawSource() throws {
        var paragraphs = (0..<60).map { "Paragraph \($0) of the plan with some words in it." }
        paragraphs[40] = "Hard break here,  \nthen the next line."
        let text = paragraphs.joined(separator: "\n\n") + "\n"
        let p = IncrementalParser()
        _ = p.parse(text)
        // Two lines added before it: it is kept, moved down.
        var edited = paragraphs
        edited[20] = "Paragraph 20 grew\nby a line\nand another."
        let next = edited.joined(separator: "\n\n") + "\n"
        let doc = p.parse(next)
        #expect(p.lastSpliced)
        #expect(doc.blocks == MarkdownParser.parse(next).blocks)
        let hard = try #require(doc.blocks.first { $0.source.hasPrefix("Hard break") })
        #expect(hard.copySource == "Hard break here,  \nthen the next line.")
        // An append after it: kept as it was.
        let appended = next + "\nOne more paragraph.\n"
        let doc2 = p.parse(appended)
        #expect(p.lastSpliced)
        #expect(doc2.blocks.first { $0.source.hasPrefix("Hard break") }?.copySource == hard.copySource)
    }

    // MARK: What the page is sent (C1)

    @Test func opsCarryTheSourceAndWhetherABlankLineCameBefore() throws {
        let s = DocumentSession()
        let patch = s.load(MarkdownParser.parse("**Files:**\n- a  \n- b\n\nAfter.\n"))
        let ops = patch.ops
        #expect(ops.map(\.src) == ["**Files:**", "- a  ", "- b", "After."])
        // The list starts on the line after the paragraph; "After." after a blank line.
        #expect(ops.map(\.tight) == [nil, true, true, nil])
    }

    /// A change that renders the same (another list marker, a blank line
    /// added) still reaches the page's copy, without a mark.
    @Test func aSourceOnlyChangeIsASilentReplace() throws {
        let s = DocumentSession()
        _ = s.load(MarkdownParser.parse("Intro.\n\n- a\n- b\n"))
        let p1 = try #require(s.update(MarkdownParser.parse("Intro.\n\n* a\n* b\n")))
        #expect(p1.ops.map(\.op) == [.replace, .replace])
        #expect(p1.ops.allSatisfy { $0.change == .silent })
        #expect(p1.ops.map(\.src) == ["* a", "* b"])
        // Without HTML: the page keeps the blocks as they are and updates their source.
        #expect(p1.ops.allSatisfy { $0.html == nil })
        #expect(s.marks.isEmpty)
        // The blank line before the list goes: its first item is now tight.
        let p2 = try #require(s.update(MarkdownParser.parse("Intro.\n* a\n* b\n")))
        #expect(p2.ops.count == 1 && p2.ops[0].change == .silent && p2.ops[0].tight == true)
        // Nothing changed at all: no patch.
        #expect(s.update(MarkdownParser.parse("Intro.\n* a\n* b\n")) == nil)
    }

    // MARK: Link reference definitions (C5)

    @Test func linkDefinitionsAreCollectedOutsideCode() {
        let doc = MarkdownParser.parse("""
            See [the spec][Spec  Doc] and [faq].

            [spec doc]: https://example.com/spec "The spec"
            > [FAQ]:
            > https://example.com/faq
            [title]: https://example.com/t
              'On the next line'

            ```
            [code]: https://example.com/not-a-definition
            ```
            """)
        #expect(doc.links == [
            LinkDefinition(label: "spec doc", md: "[spec doc]: https://example.com/spec \"The spec\""),
            LinkDefinition(label: "faq", md: "[FAQ]: https://example.com/faq"),
            LinkDefinition(label: "title", md: "[title]: https://example.com/t 'On the next line'"),
        ])
        #expect(doc.links[0].label == "spec doc")
        // Without definitions, nothing (and no scan beyond the one parsing does).
        #expect(MarkdownParser.parse("Just [text].\n").links.isEmpty)
    }

    @Test func patchesCarryTheDefinitionsWhenTheyChange() throws {
        let s = DocumentSession()
        let first = s.load(MarkdownParser.parse("Use [x].\n\n[x]: https://one\n"))
        #expect(first.links == [LinkDefinition(label: "x", md: "[x]: https://one")])
        #expect(first.page.links == first.links)
        // An edit elsewhere: the page has them already.
        let p1 = try #require(s.update(MarkdownParser.parse("Use [x] now.\n\n[x]: https://one\n")))
        #expect(p1.links == nil)
        // The definition changed (the paragraph renders a new href too).
        let p2 = try #require(s.update(MarkdownParser.parse("Use [x] now.\n\n[x]: https://two\n")))
        #expect(p2.links == [LinkDefinition(label: "x", md: "[x]: https://two")])
        // A definition no block uses changed: no op, but the patch still goes.
        let p3 = try #require(s.update(MarkdownParser.parse("Use [x] now.\n\n[x]: https://two\n[y]: https://y\n")))
        #expect(p3.ops.isEmpty && p3.links?.count == 2)
        // None left: an empty list clears the page's.
        let p4 = try #require(s.update(MarkdownParser.parse("Use [x] now.\n")))
        #expect(p4.links == [])
        // A document without definitions sends none.
        #expect(DocumentSession().load(MarkdownParser.parse("Plain.\n")).links == nil)
    }

    // MARK: Copy as Quote (C4, C5)

    @Test func copyAsQuoteKeepsHardBreaksFrontMatterAndReferenceDefinitions() throws {
        var b = MarkdownParser.parse("---\nstatus: draft\n---\n\n# Plan\n\nLine one,  \nline two with [the spec][spec].\n\n[spec]: https://example.com/spec\n")
        for i in b.blocks.indices { b.blocks[i].slot = i + 1 }
        // The definitions the blocks use come from the page (`quoteSelection`, as ⌘C's: web/test/flow.test.mjs).
        let quote = try #require(QuoteFormatter.quote(blocks: b.blocks, slots: [1, 3], path: "p.md", definitions: b.links.map(\.md)))
        // (Written with \n: an editor would strip the hard break's two spaces from a literal.)
        #expect(quote == "> ---\n> status: draft\n> ---\n>\n> Line one,  \n> line two with [the spec][spec].\n>\n"
                + "> [spec]: https://example.com/spec\n— p.md#L1-L8")
    }

    // MARK: Safe links (review)

    @Test func markdownLinksThatRunCodeAreBlocked() {
        let html = MarkdownParser.parse("""
            [a](javascript:alert(1)) [b](JavaScript:alert(2)) [c](vbscript:x) [d](data:text/html,x) <javascript:alert(3)>
            [ok](https://example.com) [mail](mailto:a@b.c) [here](#top) [file](./other.md) [colon](notes:1)
            """).blocks[0].html
        for bad in ["javascript:", "JavaScript:", "vbscript:", "data:text"] { #expect(!html.contains("href=\"\(bad)"), "\(bad) in \(html)") }
        #expect(html.components(separatedBy: "href=\"blocked:").count - 1 == 5)
        for ok in ["https://example.com", "mailto:a@b.c", "#top", "./other.md", "notes:1"] { #expect(html.contains("href=\"\(ok)\""), "\(ok)") }
        #expect(HTML.safeLink(" java\tscript:x") == "blocked:x")
    }
}
