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

    @Test func aReferenceRightAfterAURLStaysOutOfTheLink() {
        let html = parse("See https://example.com/a[^n] and $x$https://b.org.\n\n[^n]: Note.\n").blocks[0].html
        #expect(html.contains(##"<a href="https://example.com/a">https://example.com/a</a><sup class="fn-ref">"##))
        #expect(!html.contains("\u{E000}") && !html.contains("\u{E002}"))
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

    @Test func referencesInsideRawHTMLStayLiteral() {
        let doc = parse("<div>\ntext[^n]\n</div>\n\n[^n]: Note.\n")
        #expect(doc.blocks[0].html.contains("text[^n]"))
        #expect(!doc.blocks[0].html.contains("\u{E000}"))
        #expect(doc.blocks.count == 1)   // never referenced: no footnotes section
    }

    @Test func definitionsInsideLongerFencesAreCode() {
        // A ``` line inside a ```` fence does not close it.
        let doc = parse("See[^n].\n\n````md\n```\n[^n]: inside code\n```\n````\n\n[^n]: real\n")
        #expect(doc.blocks.map(\.kind) == [.paragraph, .code, .footnotes])
        #expect(doc.blocks[1].html.contains("[^n]: inside code"))
        #expect(doc.blocks[2].html.contains("real"))
    }

    @Test func multiLineDefinitionsRenderMarkdown() {
        let doc = parse("See[^long].\n\n[^long]: First line with **bold**\n    and a continuation.\n\n    Second paragraph.\n")
        let notes = doc.blocks.last!.html
        #expect(notes.contains("<strong>bold</strong>"))
        #expect(notes.contains("Second paragraph."))
        #expect(doc.blocks.last!.lines == 3...6)
    }

    @Test func wrappedDefinitionLinesStayInTheNote() {
        let doc = parse("See[^1].\n\n[^1]: First line of the note\ncontinued without indent.\n\nBody again.\n")
        #expect(doc.blocks.map(\.kind) == [.paragraph, .paragraph, .footnotes])
        #expect(doc.blocks.last!.html.contains("continued without indent."))
        #expect(!doc.blocks[1].html.contains("continued"))
        // Text that merely starts with a bracket or a pipe continues it.
        let bracket = parse("See[^1].\n\n[^1]: First line\n[continued] text | more\n")
        #expect(bracket.blocks.last!.html.contains("[continued] text | more"))
        #expect(bracket.blocks.count == 2)
        let inline = parse("See[^1].\n\n[^1]: First line\n<em>continued</em> here\n")
        #expect(inline.blocks.count == 2 && inline.blocks.last!.html.contains("<em>continued</em>"))
        // A new block after the definition is not part of it.
        let list = parse("See[^1].\n\n[^1]: Note\n- item\n")
        #expect(list.blocks.contains { $0.kind == .listItem })
    }

    @Test func labelsMatchWithoutCase() {
        let doc = parse("See[^Note].\n\n[^note]: Found.\n")
        #expect(doc.blocks[0].html.contains("data-footnote-ref>1</a>"))
        #expect(doc.blocks.last!.html.contains("Found."))
    }

    @Test func aCitationFromAnotherNoteGetsAWayBack() {
        let notes = parse("x[^a] y[^b]\n\n[^a]: A.\n[^b]: B cites[^a].\n").blocks.last!.html
        #expect(notes.contains(##"href="#user-content-fnref-a-2""##))
        #expect(notes.contains(##"id="user-content-fnref-a-2""##))
    }

    @Test func everyReferenceGetsAWayBack() {
        let notes = parse("a[^n] b[^n]\n\n[^n]: Note.\n").blocks.last!.html
        #expect(notes.contains(##"href="#user-content-fnref-n""##))
        #expect(notes.contains(##"href="#user-content-fnref-n-2""##))
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

    @Test func onlyRealDetailsTagsCount() {
        #expect(MarkdownParser.detailsDepth("<details-card><details>") == 1)
        #expect(MarkdownParser.detailsDepth("<details open>x<!-- </details> -->") == 1)
        #expect(MarkdownParser.detailsDepth("</details >") == -1)
        let doc = MarkdownParser.parse("<details>\n<summary>S</summary>\n\n<!-- </details> -->\n\nInside.\n\n</details>\n\nAfter.\n")
        #expect(doc.blocks.map(\.kind) == [.html, .paragraph])
    }

    @Test func singleLineDetailsIsUnchanged() {
        let doc = MarkdownParser.parse("<details><summary>S</summary>Body</details>\n\nNext.\n")
        #expect(doc.blocks.map(\.kind) == [.html, .paragraph])
    }

    /// A close that is not a top-level line of its own (inline after text,
    /// indented in a list item) ends the disclosure; the rest of the document stays out.
    @Test func closeInsideABlockEndsTheDisclosure() {
        let cases = [
            "<details>\n<summary>Click</summary>\n\nSome text</details>\n\n## After heading\n\nPara after.\n",
            "<details>\n<summary>x</summary>\n\n- item\n  </details>\n\n## After heading\n\nPara after.\n",
        ]
        for src in cases {
            let doc = MarkdownParser.parse(src)
            #expect(doc.blocks.map(\.kind) == [.html, .heading, .paragraph], "\(src.debugDescription)")
            #expect(doc.blocks[0].html.contains("</details>"))
            #expect(doc.blocks[1].anchor == "after-heading")
            // The incremental parser agrees, also after an edit further down.
            let p = IncrementalParser()
            _ = p.parse(src)
            let edited = src + "\nMore.\n"
            #expect(p.parse(edited).blocks.map(\.html) == MarkdownParser.parse(edited).blocks.map(\.html))
        }
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

    @Test func linkTextIsNotLinkedAgain() {
        let h = html("[www.example.com](https://www.example.com/docs) and [mail a@b.com](mailto:x@y.org)")
        #expect(h.components(separatedBy: "<a ").count == 3)
        #expect(h.contains(##"<a href="https://www.example.com/docs">www.example.com</a>"##))
        #expect(h.contains(##"<a href="mailto:x@y.org">mail a@b.com</a>"##))
    }

    @Test func notLinked() {
        #expect(!html("user@localhost").contains("<a"))
        #expect(!html("a@b.c_").contains("<a"))
        #expect(!html("path/www.no").contains("<a"))
    }
}
