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
    }

    @Test func tabIndentedLineInListItemFence() {
        let h = html("- Run this:\n\n  ```sh\n\tcp $SRC/$NAME.md $DEST/\n  ```\n")
        #expect(h.contains("cp $SRC/$NAME.md $DEST/"), "\(h)")
        expectIncrementalMatchesFull("1. Build it:\n   ```go\n\tx := m[$a$]\n\n# not a heading\n   ```\n2. Done\n")
    }
}
