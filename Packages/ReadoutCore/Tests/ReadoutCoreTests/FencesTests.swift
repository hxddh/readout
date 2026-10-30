import Foundation
import Testing
@testable import ReadoutCore

/// Fenced code the line tracker (`FenceTracker`) must see: after a list or quote
/// marker, in quoted items, with tab indentation; and the incremental parse agreeing.
@Suite struct FencesTests {
    func html(_ md: String) -> String { MarkdownParser.parse(md).blocks.map(\.html).joined(separator: "\n") }

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

    /// A nested item indented past 3 columns (under `1. `) with a fence on its marker line.
    @Test func dollarsInFenceAfterDeeplyNestedMarkerStayCode() {
        let h = html("1. Install:\n    - ```bash\n      cp $SRC/$NAME.md $DEST/\n      ```\n")
        #expect(h.contains("cp $SRC/$NAME.md $DEST/"), "\(h)")
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

    /// The list indentation before a quoted fence's lines may be a tab.
    @Test func quotedFenceInListItemWithTabIndentation() {
        let h = html("- > ```sh\n\t> cp $SRC/$NAME.md $DEST/\n\t> ```\n")
        #expect(h.contains("cp $SRC/$NAME.md $DEST/"), "\(h)")
        expectIncrementalMatchesFull("- > ```sh\n\t> cp $SRC/$NAME\n\t>\n\t> # not a heading\n\t> ```\n\n<div>\n\nafter\n")
    }

    /// A tab right after `>` gives one column as the marker's space: `>\t```` closes the fence.
    @Test func quotedFenceWithTabsAfterTheMarker() {
        let h = html(">\t```\n>\tcode\n>\t```\n> Price $x$ here\n")
        #expect(h.contains("class=\"math"), "\(h)")
        expectIncrementalMatchesFull(">\t```\n>\tcode\n>\t```\n> $x$\n\n<div>\n\nafter\n")
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

    @Test func fenceAfterListMarkerMatchesIncremental() {
        expectIncrementalMatchesFull("- ```\r\n\r\n\r\n#")
        expectIncrementalMatchesFull("1. Copy the file:\n\n2. ```bash\n   cp $SRC/$NAME.md $DEST/\n\n# not a heading\n   ```\n\nafter\n")
        expectIncrementalMatchesFull("- ```text\n  [^1]: x\n\n  <div>\n\n  ```\n\n<div>\n\nend\n")
    }

    @Test func tabIndentedLineInListItemFence() {
        let h = html("- Run this:\n\n  ```sh\n\tcp $SRC/$NAME.md $DEST/\n  ```\n")
        #expect(h.contains("cp $SRC/$NAME.md $DEST/"), "\(h)")
        expectIncrementalMatchesFull("1. Build it:\n   ```go\n\tx := m[$a$]\n\n# not a heading\n   ```\n2. Done\n")
    }

    /// A line indented by a tab (4 columns) after a table is not a row: the
    /// fence tracker counted spaces only and saw a row where cmark ends the
    /// table, so a fence after it split differently (fuzz seeds 480 and 530).
    @Test func tabIndentedLineAfterTableMatchesIncremental() {
        expectIncrementalMatchesFull("x|d\n-|-\n\td\n$$\n<a>\n```\n\ne")
        expectIncrementalMatchesFull("$$ $$\n```\n```\n\nn|||\n-|-|-\n\t[^3]\n[^3]:")
        expectIncrementalMatchesFull("| a | b |\n| - | - |\n\tcode\n```\nx\n```\n\nafter")
        expectIncrementalMatchesFull("||\n|-|\n\tx\n```\n\ny")
    }
}
