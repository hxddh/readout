import Foundation
import Testing
@testable import ReadoutCore

/// Where math is recognized (and where it is not): nested list items,
/// display math in containers and next to text, addresses, escapes.
@Suite struct MathTests {
    func html(_ s: String) -> String { MarkdownParser.parse(s).blocks.map(\.html).joined() }

    // MARK: Indented code is relative to the list item

    @Test func nestedListItemsKeepMathAndFootnotes() {
        let doc = MarkdownParser.parse("""
        - Top level $a$
            - Nested with $x_1$ and a note[^1]
                - Deeper $y$

        1. Step
            Continuation with $z$ math

        [^1]: The note.
        """)
        let all = doc.blocks.map(\.html).joined()
        for tex in ["a", "x_1", "y", "z"] { #expect(all.contains("data-tex=\"\(tex)\""), "missing \(tex)") }
        #expect(!all.contains("$x_1$") && !all.contains("[^1]"))
        #expect(doc.blocks.last?.kind == .footnotes)
    }

    @Test func indentedCodeIsStillLeftAlone() {
        // At the margin, and 4 columns past a list item's content.
        #expect(html("Para.\n\n    echo $a_b$\n").contains("echo $a_b$"))
        #expect(html("\techo $a_b$\n").contains("echo $a_b$"))
        #expect(html("- item\n\n      echo $a_b$\n").contains("<pre><code>echo $a_b$"))
        // A paragraph's indented continuation line is not code.
        #expect(html("Para\n    with $x$\n").contains("data-tex=\"x\""))
    }

    // MARK: $$ display math

    @Test func displayMathAfterATextLine() {
        let h = html("The formula:\n$$\nE = m_1 c^2 + m_2\n$$\n")
        #expect(h.contains("<p>The formula:\n<span class=\"math math-display\" data-tex=\"E = m_1 c^2 + m_2\">"))
        #expect(!h.contains("$$") && !h.contains("<em>"))
    }

    @Test func displayMathInListItemsAndQuotes() {
        let item = html("1. Energy:\n\n   $$\n   E = mc^2\n   $$\n")
        #expect(item.contains("math-display\" data-tex=\"E = mc^2\""))
        let quote = html("> $$\n> a_1 + a_2\n> $$\n")
        #expect(quote.contains("<blockquote><p><span class=\"math math-display\" data-tex=\"a_1 + a_2\">"))
        #expect(!item.contains("$$") && !quote.contains("$$"))
    }

    @Test func twoDisplaySpansOnALineStayTwo() {
        let doc = MarkdownParser.parse("$$a$$ and $$b$$\n")
        #expect(doc.blocks.count == 1 && doc.blocks[0].kind == .paragraph)
        #expect(doc.blocks[0].html.contains("data-tex=\"a\"") && doc.blocks[0].html.contains("data-tex=\"b\""))
        #expect(doc.blocks[0].html.contains(" and "))
    }

    @Test func displayMathHoldsWhatWouldBeAList() {
        let doc = MarkdownParser.parse("$$\na\n+ b\n$$\n")
        #expect(doc.blocks.count == 1)
        #expect(doc.blocks[0].kind == .math)
        #expect(doc.blocks[0].lines == 1...4)
        #expect(doc.blocks[0].html.contains("data-tex=\"a\n+ b\""))
    }

    @Test func wholeParagraphDisplayMathIsStillABlock() {
        for src in ["$$\n\\sum_i x_i\n$$\n", "$$E = mc^2$$\n", "$$ x * y * z $$\n", "$$\nx * y * z\n$$\n"] {
            let doc = MarkdownParser.parse(src)
            #expect(doc.blocks.count == 1 && doc.blocks[0].kind == .math, "\(src.debugDescription)")
        }
        // Unclosed, or ended by a blank line: text.
        #expect(MarkdownParser.parse("$$\na\n\nb\n$$\n").blocks.allSatisfy { $0.kind == .paragraph })
    }

    @Test func multiLineDisplayMathIsTheSameIncrementally() {
        let v1 = "# T\n\nIntro.\n\n- item:\n  $$\n  a\n  + b\n  $$\n\nAfter $x$.\n"
        let v2 = v1 + "\nMore:\n$$\nc_1\n$$\n"
        let p = IncrementalParser()
        _ = p.parse(v1)
        #expect(p.parse(v2).blocks.map(\.html) == MarkdownParser.parse(v2).blocks.map(\.html))
    }

    // MARK: Addresses

    @Test func dollarsInLinkDestinationsAreNotMath() {
        let h = html("[x](https://h/People?$filter=Age&$top=5) and [y](http://x.com/$a$b)\n")
        #expect(h.contains("href=\"https://h/People?$filter=Age&amp;$top=5\""))
        #expect(h.contains("href=\"http://x.com/$a$b\""))
        #expect(!h.contains("math"))
    }

    @Test func dollarsInBareURLsAndAutolinksAreNotMath() {
        let bare = html("Bare https://services.odata.org/People?$filter=Name&$top=5 here.\n")
        #expect(bare.contains("href=\"https://services.odata.org/People?$filter=Name&amp;$top=5\""))
        #expect(!bare.contains("math"))
        let auto = html("See <https://h/a?$x=1&$y=2> now, and $z$.\n")
        #expect(auto.contains("href=\"https://h/a?$x=1&amp;$y=2\""))
        #expect(auto.contains("data-tex=\"z\""))
        #expect(!auto.contains("data-tex=\"x"))
    }

    // MARK: \( and \[

    @Test func escapedBracketsInProseAreNotMath() {
        let h = html("See \\[WIP\\] and \\[x\\] done, \\(sic\\).\n")
        #expect(h == "<p>See [WIP] and [x] done, (sic).</p>")
    }

    @Test func texInBracketsIsStillMath() {
        #expect(html("Einstein said \\[E = mc^2\\] loudly.\n").contains("math-display\" data-tex=\"E = mc^2\""))
        #expect(html("Let \\(x\\) and \\(a_1 + b\\) be.\n").contains("data-tex=\"a_1 + b\""))
        #expect(html("Let \\(x\\) be.\n").contains("math-inline\" data-tex=\"x\""))
    }

    /// CommonMark spec examples 308, 504 and 506.
    @Test func commonMarkEscapes() {
        #expect(html("\\!\\\"\\#\\$\\%\\&\\'\\(\\)\\*\\+\\,\\-\\.\\/\\:\\;\\<\\=\\>\\?\\@\\[\\\\\\]\\^\\_\\`\\{\\|\\}\\~\n")
            == "<p>!&quot;#$%&amp;&#39;()*+,-./:;&lt;=&gt;?@[\\]^_`{|}~</p>")
        #expect(html("[link](\\(foo\\))\n") == "<p><a href=\"(foo)\">link</a></p>")
        #expect(html("[link](foo\\(and\\(bar\\))\n") == "<p><a href=\"foo(and(bar)\">link</a></p>")
    }

    @Test func manyUnmatchedOpenersStayLinear() {
        let line = String(repeating: "a \\( b ", count: 4000) + "\n"
        let start = DispatchTime.now().uptimeNanoseconds
        let h = html(line)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        #expect(!h.contains("math"))
        // It took seconds when every opener scanned the rest of the line.
        #expect(ms < 2000, "\(ms) ms")
    }
}
