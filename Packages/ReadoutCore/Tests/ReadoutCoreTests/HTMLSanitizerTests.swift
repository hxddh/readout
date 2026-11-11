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

    /// Handlers go from tags, attribute by attribute: the text between tags
    /// and the rest of every value stay as written (5.2 cut `once = true`
    /// from a <pre> and the closing quote from `href="/x/online=1"`).
    @Test func onlyATagsOwnHandlersAreRemoved() {
        #expect(HTML.scrubTags("<pre>retry once = true</pre>") == "<pre>retry once = true</pre>")
        #expect(HTML.scrubTags("<td>only=1</td> javascript: is a scheme") == "<td>only=1</td> javascript: is a scheme")
        #expect(HTML.scrubTags(#"<a href="/x/online=1" title="turn on = yes">x</a>"#) == #"<a href="/x/online=1" title="turn on = yes">x</a>"#)
        #expect(HTML.scrubTags(#"<img src="a.png" onerror="alert(1)" alt="a">"#) == #"<img src="a.png" alt="a">"#)
        #expect(HTML.scrubTags("<img/onerror=alert(1)>") == "<img>")
        #expect(HTML.scrubTags("<b ONCLICK = 'x()' class=k onload>") == "<b class=k>")
        #expect(HTML.scrubTags(#"<a href="JavaScript:alert(1)">x</a>"#) == #"<a href="blocked:alert(1)">x</a>"#)
        #expect(HTML.scrubTags(#"<p id="ro-doc" name=mmd-1 class="ro-x">"#) == #"<p id="h-ro-doc" name=h-mmd-1 class="ro-x">"#)
        // A `>` in a quoted value does not end the tag; one never closed is read to the end.
        #expect(HTML.scrubTags(#"<a title="a > b" onclick=x()>t</a>"#) == #"<a title="a > b">t</a>"#)
        #expect(HTML.scrubTags("a < b and <i onmouseover=x") == "a < b and <i")
        #expect(HTML.scrubTags("中文 <b onclick=x>粗</b> 文字") == "中文 <b>粗</b> 文字")
        let block = MarkdownParser.parse("<pre>\nretry once = true\n</pre>\n").blocks[0].html
        #expect(block.contains("retry once = true"))
    }
}
