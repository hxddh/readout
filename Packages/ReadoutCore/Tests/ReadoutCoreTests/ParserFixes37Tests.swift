import Foundation
import Testing
@testable import ReadoutCore

/// 3.7 parser and rendering fixes. Each test failed on 3.6.0.
@Suite struct ParserFixes37Tests {
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

    // MARK: L1: a tab-indented line after a table

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
