import Foundation
import Testing
@testable import ReadoutCore

@Suite struct FootnoteTests {
    func parse(_ s: String) -> ParsedDocument { MarkdownParser.parse(s) }

    @Test func referencesLinkToNumberedDefinitionsAtTheEnd() {
        let doc = parse("A[^b] then B[^a].\n\n[^a]: Alpha.\n[^b]: Beta.\n")
        #expect(doc.blocks.map(\.kind) == [.paragraph, .footnotes])
        let p = doc.blocks[0].html
        // Numbered by first reference, not by definition order.
        #expect(p.contains(##"<a href="#user-content-fn-b" id="user-content-fnref-b" data-footnote-ref>1</a>"##))
        #expect(p.contains(##"<a href="#user-content-fn-a" id="user-content-fnref-a" data-footnote-ref>2</a>"##))
        let notes = doc.blocks[1].html
        #expect(notes.range(of: "user-content-fn-b")!.lowerBound < notes.range(of: "user-content-fn-a")!.lowerBound)
        #expect(notes.contains(##"href="#user-content-fnref-b" class="fn-back""##))
    }

    @Test func repeatedReferencesGetDistinctIDs() {
        let html = parse("x[^n] y[^n]\n\n[^n]: Note.\n").blocks[0].html
        #expect(html.contains(##"id="user-content-fnref-n""##))
        #expect(html.contains(##"id="user-content-fnref-n-2""##))
    }

    @Test func undefinedReferencesAndCodeStayLiteral() {
        let doc = parse("Missing [^x] and `[^n]` code.\n\n[^n]: Unused here.\n")
        #expect(doc.blocks.count == 1)   // an unreferenced definition shows nothing
        #expect(doc.blocks[0].html.contains("[^x]"))
        #expect(doc.blocks[0].html.contains("<code>[^n]</code>"))
    }

    @Test func definitionsInsideFencesAreCode() {
        let doc = parse("```\n[^n]: not a definition\n```\n")
        #expect(doc.blocks.map(\.kind) == [.code])
    }

    @Test func multiLineDefinitionsRenderMarkdown() {
        let doc = parse("See[^long].\n\n[^long]: First line with **bold**\n    and a continuation.\n\n    Second paragraph.\n")
        let notes = doc.blocks.last!.html
        #expect(notes.contains("<strong>bold</strong>"))
        #expect(notes.contains("Second paragraph."))
        #expect(doc.blocks.last!.lines == 3...6)
    }

    @Test func lineNumbersOfOtherBlocksAreUnchanged() {
        let doc = parse("One[^a].\n\n[^a]: Note.\n\nTwo.\n")
        #expect(doc.blocks.map(\.lines) == [1...1, 5...5, 3...3])
    }

    @Test func renumberingInvalidatesCachedHTML() {
        let cache = MarkdownParser.RenderCache()
        cache.beginGeneration()
        _ = MarkdownParser.parse("Later[^b].\n\n[^a]: A\n[^b]: B\n", cache: cache)
        cache.beginGeneration()
        // A new earlier reference renumbers the existing paragraph.
        let doc = MarkdownParser.parse("First[^a].\n\nLater[^b].\n\n[^a]: A\n[^b]: B\n", cache: cache)
        #expect(doc.blocks[1].html.contains(">2</a>"))
    }
}

@Suite struct DetailsTests {
    @Test func detailsWithMarkdownContentIsOneBlock() {
        let doc = MarkdownParser.parse("<details>\n<summary>Logs</summary>\n\n- [x] one\n- two\n\n```sh\necho hi\n```\n\n</details>\n\nAfter.\n")
        #expect(doc.blocks.map(\.kind) == [.html, .paragraph])
        let html = doc.blocks[0].html
        #expect(html.hasPrefix("<details>"))
        #expect(html.contains("<li class=\"task\">"))
        #expect(html.contains("data-lang=\"sh\""))
        #expect(html.contains("</details>"))
        #expect(doc.blocks[0].lines == 1...11)
        #expect(doc.blocks[0].taskState == [true])
    }

    @Test func nestedDetailsCloseAtTheOuterTag() {
        let doc = MarkdownParser.parse("<details>\n<summary>Outer</summary>\n\n<details>\n<summary>Inner</summary>\n\nText\n\n</details>\n\n</details>\n\nAfter.\n")
        #expect(doc.blocks.map(\.kind) == [.html, .paragraph])
        #expect(doc.blocks[0].html.components(separatedBy: "</details>").count == 3)
    }

    @Test func singleLineDetailsIsUnchanged() {
        let doc = MarkdownParser.parse("<details><summary>S</summary>Body</details>\n\nNext.\n")
        #expect(doc.blocks.map(\.kind) == [.html, .paragraph])
    }

    @Test func unclosedDetailsRunsToTheEnd() {
        let doc = MarkdownParser.parse("<details>\n<summary>S</summary>\n\nBody\n")
        #expect(doc.blocks.count == 1)
        #expect(doc.blocks[0].html.contains("<p>Body</p>"))
    }
}

@Suite struct ExtendedAutolinkTests {
    func html(_ s: String) -> String { MarkdownParser.parse(s).blocks[0].html }

    @Test func wwwAndEmails() {
        #expect(html("www.example.com/a.").contains(##"<a href="http://www.example.com/a">www.example.com/a</a>."##))
        #expect(html("mail me@example.org.").contains(##"<a href="mailto:me@example.org">me@example.org</a>."##))
        #expect(html("参见 www.example.cn。").contains(##"<a href="http://www.example.cn">www.example.cn</a>。"##))
    }

    @Test func notLinked() {
        #expect(!html("user@localhost").contains("<a"))
        #expect(!html("a@b.c_").contains("<a"))
        #expect(!html("path/www.no").contains("<a"))
    }
}
