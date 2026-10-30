import Foundation
import Testing
@testable import ReadoutCore

/// Helpers shared by suites in several files.

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
