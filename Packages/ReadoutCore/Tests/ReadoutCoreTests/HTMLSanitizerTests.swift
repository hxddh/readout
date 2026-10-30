import Foundation
import Testing
@testable import ReadoutCore

/// Links that would run code are blocked (`HTML.safeLink`).
@Suite struct HTMLSanitizerTests {
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
