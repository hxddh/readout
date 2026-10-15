import Foundation
import Testing
@testable import ReadoutCore

/// 3.6 rendering changes. Each test failed on 3.5.0.
@Suite struct RenderingFixes36Tests {
    func html(_ md: String) -> String { MarkdownParser.parse(md).blocks.map(\.html).joined(separator: "\n") }

    // MARK: TA: paragraphs of `Key: value` lines keep their lines

    @Test func keyValueLinesBreak() {
        #expect(html("Run: `swift test`\nExpected: all tests pass\n") == "<p>Run: <code>swift test</code><br>Expected: all tests pass</p>")
        #expect(html("**Status:** done\n**Owner:** Rust\n**Date:** 2026-10-15\n")
            == "<p><strong>Status:</strong> done<br><strong>Owner:</strong> Rust<br><strong>Date:</strong> 2026-10-15</p>")
        #expect(html("状态：已完成\n日期：2026-10-15\n") == "<p>状态：已完成<br>日期：2026-10-15</p>")
        #expect(html("**Files**: `a.swift`\n**Why**: the fence pass\n").contains("</code><br><strong>Why</strong>"))
        // In a list item too.
        #expect(html("- Run: make\n  Expected: ok\n").contains("<li>Run: make<br>Expected: ok</li>"))
        #expect(html("1. Step one\n\n   Run: make\n   Expected: ok\n").contains("<p>Run: make<br>Expected: ok</p>"))
    }

    @Test func proseWithAColonKeepsFlowing() {
        // One line only, or lines that are not all labels.
        #expect(html("Note: this is one line.\n") == "<p>Note: this is one line.</p>")
        #expect(html("Note: the parser reads every line\nand this one continues the sentence.\n")
            == "<p>Note: the parser reads every line\nand this one continues the sentence.</p>")
        // Times, URLs and long phrases before a colon are not labels.
        #expect(html("Meet at 10:30 today\nor at 11:00 tomorrow\n") == "<p>Meet at 10:30 today\nor at 11:00 tomorrow</p>")
        #expect(html("See https://example.com/a for it\nand https://example.com/b too\n").contains("\nand "))
        #expect(html("After a long discussion we agreed on this: ship\nThen we went home and slept: well\n").contains("\nThen"))
        #expect(html("First, we decided: ship it\nSecond, we agreed: test it\n").contains("\nSecond"))
    }

    // MARK: T4: a paragraph holding only an image

    @Test func imageOnlyParagraphsAreMarked() {
        #expect(html("![Diagram](d.png)\n") == "<p class=\"img-only\"><img src=\"d.png\" alt=\"Diagram\" loading=\"lazy\"></p>")
        #expect(html("[![Badge](b.svg)](https://example.com)\n").hasPrefix("<p class=\"img-only\"><a href="))
        #expect(html("Text and ![icon](i.png) inline.\n").hasPrefix("<p>Text"))
        #expect(html("![a](a.png) ![b](b.png)\n").hasPrefix("<p>"))
    }

    // MARK: T6: long bare URLs wrap at their parts

    @Test func longAutolinksGetBreakOpportunities() {
        let url = "https://github.com/hxddh/readout/blob/main/docs/design.md?plain=1&line=16"
        let h = html("See \(url) for details.\n")
        #expect(h.contains("<a href=\"\(url.replacingOccurrences(of: "&", with: "&amp;"))\">"), "\(h)")
        #expect(h.contains(">https://github.com/<wbr>hxddh/<wbr>readout/<wbr>blob/<wbr>main/<wbr>docs/<wbr>design.md?<wbr>plain=<wbr>1&amp;<wbr>line=<wbr>16</a>"), "\(h)")
        // Short ones are left alone, and so is link text written by the author.
        #expect(html("See https://example.com/a/b for it.\n").contains(">https://example.com/a/b</a>"))
        #expect(!html("[\(url)](\(url))\n").contains("<wbr>"))
    }

    // MARK: T7: terminal colours in code

    @Test func ansiColourCodesAreStrippedFromCode() {
        let h = html("```\n\u{1B}[1;32m✓\u{1B}[0m 12 tests passed\n\u{1B}[31merror\u{1B}[m: none\n```\n")
        #expect(h == "<div class=\"code-block\"><pre><code>✓ 12 tests passed\nerror: none</code></pre></div>", "\(h)")
    }

    // MARK: T8: placeholders in numeric columns

    @Test func placeholdersKeepAColumnNumeric() {
        let h = html("| Method | Calls | p99 |\n| --- | --- | --- |\n| get | 1,204 | 12 ms |\n| put | N/A | — |\n| list | - | TBD |\n| head | 87 | – |\n")
        #expect(h.contains("<th class=\"num\">Calls</th>") && h.contains("<th class=\"num\">p99</th>"), "\(h)")
        #expect(h.contains("<td class=\"num\">N/A</td>") && h.contains("<td class=\"num\">TBD</td>"), "\(h)")
        // A column of placeholders only is not numeric.
        #expect(!html("| A | B |\n| --- | --- |\n| x | - |\n| y | N/A |\n").contains("class=\"num\""))
    }
}
