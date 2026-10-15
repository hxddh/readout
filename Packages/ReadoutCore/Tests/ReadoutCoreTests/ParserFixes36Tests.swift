import Foundation
import Testing
@testable import ReadoutCore

/// 3.6 parser fixes. Each test failed on 3.5.0.
@Suite struct ParserFixes36Tests {
    func html(_ md: String) -> String { MarkdownParser.parse(md).blocks.map(\.html).joined(separator: "\n") }

    /// The incremental parser (fresh, and after an edit from a neutral
    /// version) gives exactly the full parse.
    func expectIncrementalMatchesFull(_ text: String, _ note: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        let full = MarkdownParser.parse(text)
        let fresh = IncrementalParser().parse(text)
        #expect(fresh.blocks == full.blocks && fresh.title == full.title, note, sourceLocation: sourceLocation)
        let warm = IncrementalParser()
        _ = warm.parse("Intro.\n\n" + text)
        let edited = warm.parse(text)
        #expect(edited.blocks == full.blocks && edited.title == full.title, note, sourceLocation: sourceLocation)
    }

    // MARK: B1: fenced code after a quote or list marker on the same line

    @Test func dollarsInFenceAfterListMarkerStayCode() {
        let h = html("1. Copy the file:\n\n2. ```bash\n   cp $SRC/$NAME.md $DEST/\n   ```\n")
        #expect(h.contains("cp $SRC/$NAME.md $DEST/"), "\(h)")
    }

    @Test func dollarsInFenceAfterBulletStayCode() {
        let h = html("- ```sh\n  price=$5; total=$10\n  echo $x$ and $$y$$\n  ```\n- next\n")
        #expect(h.contains("price=$5; total=$10"), "\(h)")
        #expect(h.contains("echo $x$ and $$y$$"), "\(h)")
        #expect(!h.contains("math"), "\(h)")
    }

    @Test func dollarsInQuotedFenceStayCode() {
        let h = html("> ```bash\n> cp $SRC/$NAME.md $DEST/\n> ```\n")
        #expect(h.contains("cp $SRC/$NAME.md $DEST/"), "\(h)")
    }

    @Test func dollarsInQuotedFenceInListItemStayCode() {
        let h = html("1. > ```bash\n   > cp $SRC/$NAME.md $DEST/\n   > ```\n")
        #expect(h.contains("cp $SRC/$NAME.md $DEST/"), "\(h)")
    }

    @Test func dollarsInFenceInQuotedListItemStayCode() {
        let h = html("> - ```bash\n>   cp $SRC/$NAME.md $DEST/\n>   ```\n")
        #expect(h.contains("cp $SRC/$NAME.md $DEST/"), "\(h)")
    }

    @Test func footnoteDefinitionInFenceAfterListMarkerStaysCode() {
        let doc = MarkdownParser.parse("1. ```text\n   [^1]: not a footnote\n   ```\n\nSee [^1].\n")
        #expect(!doc.blocks.contains { $0.kind == .footnotes })
        #expect(doc.blocks.first?.html.contains("[^1]: not a footnote") == true)
    }

    @Test func footnoteDefinitionInQuotedFenceStaysCode() {
        let doc = MarkdownParser.parse("> ```text\n> [^1]: not a footnote\n> ```\n\nSee [^1].\n")
        #expect(!doc.blocks.contains { $0.kind == .footnotes })
        #expect(doc.blocks.first?.html.contains("[^1]: not a footnote") == true)
    }

    /// A quoted fence ends with the quote: the next line without `>` is
    /// Markdown again (fenced code has no lazy continuation lines).
    @Test func quotedFenceEndsWithTheQuote() {
        let doc = MarkdownParser.parse("> ```\n> code\nPrice $x$ here\n")
        let h = doc.blocks.map(\.html).joined()
        #expect(h.contains("class=\"math"), "\(h)")
        expectIncrementalMatchesFull("> ```python\n> def f():\n>     return 1\n> ```\nAfter the quote, lazy text\n<span>tag line</span>\n```\ncode\n\nmore code\n```\n")
        expectIncrementalMatchesFull(">```\nx\n<r>\n<textarea\n\nx")
    }

    @Test func fenceAfterListMarkerMatchesIncremental() {
        expectIncrementalMatchesFull("- ```\r\n\r\n\r\n#")
        expectIncrementalMatchesFull("1. Copy the file:\n\n2. ```bash\n   cp $SRC/$NAME.md $DEST/\n\n# not a heading\n   ```\n\nafter\n")
        expectIncrementalMatchesFull("- ```text\n  [^1]: x\n\n  <div>\n\n  ```\n\n<div>\n\nend\n")
    }

    // MARK: B3: lists in footnotes are tight or loose by their own lines

    @Test func tightListInFootnoteStaysTight() {
        let h = html("See the note[^a].\n\n[^a]: Note with a list:\n    - one\n    - two\n")
        #expect(h.contains("<li>one</li>"), "\(h)")
    }

    @Test func looseListInFootnoteStaysLooseWhateverPrecedesIt() {
        let h = html("Intro line one\nline two\nline three\nSee the note[^a].\n\n[^a]: Note with a list:\n\n    - one\n\n    - two\n")
        #expect(h.contains("<li><p>one</p></li>"), "\(h)")
    }

    // MARK: B5: front matter

    @Test func frontMatterWithTrailingSpaceOnFence() {
        let doc = MarkdownParser.parse("--- \ntitle: Plan\n---\t\n\nBody\n")
        #expect(doc.blocks.first?.kind == .frontMatter)
        #expect(doc.blocks.first?.html.contains("Plan") == true)
        #expect(doc.blocks.count == 2)
        expectIncrementalMatchesFull("--- \ntitle: Plan\n---\n\nBody\n\nMore\n")
    }

    @Test func frontMatterBlockScalarsAndLists() {
        let doc = MarkdownParser.parse("---\nname: reviewer\ndescription: >\n  Reviews pull requests\n  for style.\ntools:\n  - Read\n  - Grep\nnotes: |\n  line one\n  line two\n---\n\nBody\n")
        let h = doc.blocks.first?.html ?? ""
        #expect(h.contains("Reviews pull requests for style."), "\(h)")
        #expect(!h.contains("&gt;<"), "\(h)")
        #expect(h.contains("Read, Grep"), "\(h)")
        #expect(h.contains("line one<br>line two"), "\(h)")
    }

    // MARK: B8: incremental and full parses agree

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

    /// A nested item indented past 3 columns (under `1. `) with a fence on its marker line.
    @Test func dollarsInFenceAfterDeeplyNestedMarkerStayCode() {
        let h = html("1. Install:\n    - ```bash\n      cp $SRC/$NAME.md $DEST/\n      ```\n")
        #expect(h.contains("cp $SRC/$NAME.md $DEST/"), "\(h)")
    }

    @Test func tabIndentedLineInListItemFence() {
        let h = html("- Run this:\n\n  ```sh\n\tcp $SRC/$NAME.md $DEST/\n  ```\n")
        #expect(h.contains("cp $SRC/$NAME.md $DEST/"), "\(h)")
        expectIncrementalMatchesFull("1. Build it:\n   ```go\n\tx := m[$a$]\n\n# not a heading\n   ```\n2. Done\n")
    }
}
