import Foundation
import Testing
@testable import ReadoutCore

/// Link reference definitions (`LinkDefinition`): which lines are definitions, and
/// the patches and reloads that carry them to the page.
@Suite struct LinkDefinitionTests {
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
