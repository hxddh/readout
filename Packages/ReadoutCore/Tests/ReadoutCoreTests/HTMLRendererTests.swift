import Foundation
import Testing
@testable import ReadoutCore

/// How blocks render (`HTMLRenderer`): `Key: value` lines, lead-ins, image-only
/// paragraphs, long URLs and paths, terminal colours, numeric columns.
@Suite struct HTMLRendererTests {
    func html(_ md: String) -> String { MarkdownParser.parse(md).blocks.map(\.html).joined(separator: "\n") }

    /// The text a reader sees (and copies): the markup without its tags.
    func text(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&amp;", with: "&")
    }

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

    @Test func paragraphsEndingWithAColonAreLeadIns() {
        #expect(html("优势：\n\n- 代码复用高\n- 职责清晰\n").hasPrefix("<p class=\"lead\">优势：</p>"))
        #expect(html("The steps:\n\n1. one\n2. two\n").hasPrefix("<p class=\"lead\">The steps:</p>"))
        #expect(html("**Files changed:**\n\n- a\n").hasPrefix("<p class=\"lead\"><strong>Files changed:</strong></p>"))
        #expect(html("Two lines,\nthe second ending so:\n\n- a\n").hasPrefix("<p class=\"lead\">"))
        // Not a colon at the end, a colon in code, or a time.
        #expect(html("A plain paragraph.\n\n- a\n").hasPrefix("<p>A plain"))
        #expect(html("Run `make:`\n\n- a\n").hasPrefix("<p>Run"))
        #expect(html("Starts at 10:30\n\n- a\n").hasPrefix("<p>Starts"))
        // In a loose list item and a quote too (the page tightens the list under it).
        #expect(html("- Note:\n\n  - sub\n").contains("<p class=\"lead\">Note:</p>"))
        #expect(html("> Options:\n>\n> - a\n").contains("<blockquote><p class=\"lead\">Options:</p><ul>"))
        // An alert whose first paragraph is a lead-in still loses its marker
        // (corpus 31: `> [!NOTE]` then `> Build the reader before running the tests:`).
        #expect(html("> [!NOTE]\n> Build the reader before running the tests:\n>\n> ```sh\nmake\n```\n")
            .hasPrefix("<div class=\"alert alert-note\"><p class=\"alert-title\">Note</p><p class=\"lead\">Build the reader before running the tests:</p>"))
        #expect(html("> [!TIP] Steps:\n>\n> - a\n").hasPrefix("<div class=\"alert alert-tip\"><p class=\"alert-title\">Tip</p><p class=\"lead\">Steps:</p><ul>"))
        #expect(!html("> [!WARNING]:\n").contains("[!WARNING]"))
    }

    @Test func imageOnlyParagraphsAreMarked() {
        #expect(html("![Diagram](d.png)\n") == "<p class=\"img-only\"><img src=\"d.png\" alt=\"Diagram\" loading=\"lazy\"></p>")
        #expect(html("[![Badge](b.svg)](https://example.com)\n").hasPrefix("<p class=\"img-only\"><a href="))
        #expect(html("Text and ![icon](i.png) inline.\n").hasPrefix("<p>Text"))
        #expect(html("![a](a.png) ![b](b.png)\n").hasPrefix("<p>"))
    }

    @Test func longAutolinksGetBreakOpportunities() {
        let url = "https://github.com/hxddh/readout/blob/main/docs/design.md?plain=1&line=16"
        let h = html("See \(url) for details.\n")
        #expect(h.contains("<a href=\"\(url.replacingOccurrences(of: "&", with: "&amp;"))\">"), "\(h)")
        #expect(h.contains(">https://github.com/<wbr>hxddh/<wbr>readout/<wbr>blob/<wbr>main/<wbr>docs/<wbr>design.md?<wbr>plain=<wbr>1&amp;<wbr>line=<wbr>16</a>"), "\(h)")
        // Short ones are left alone, and so is link text written by the author.
        #expect(html("See https://example.com/a/b for it.\n").contains(">https://example.com/a/b</a>"))
        #expect(!html("[\(url)](\(url))\n").contains("<wbr>"))
    }

    // No break opportunities of ReadoutCore's own in code or in a bare path
    // (4.0, #99): every form measured slowed the page in WebKit against 3.9
    // (<wbr> scrolling and find, a zero-width space or soft hyphen jumps), so
    // a long one wraps as 3.9's did, the page's emergency wrap (overflow-wrap)
    // keeping it inside the column. A bare URL keeps its own breaks (3.6).
    @Test func codeAndBarePathsCarryNoBreakMarkup() {
        for md in ["`docs/superpowers/plans/2026-08-08-stresseur-phase0-1.md`", "`std::collections::HashMap<K, V>`",
                   "`--dangerously-skip-permissions`", "`glyphicon-arrow-left`",
                   "Add it to docs/superpowers/specs/phase0-bench-report.md and commit.",
                   "更新 00-Prerequisites/deep-learning-basics/README.md 文件"] {
            let h = html(md + "\n")
            #expect(!h.contains("<wbr>") && !h.contains("\u{200B}") && !h.contains("\u{00AD}") && !h.contains("nb"), "\(h)")
            #expect(text(h).replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">") == md.replacingOccurrences(of: "`", with: ""), "\(h)")
        }
        #expect(html("`apps/cli/internal/loadrun.Run`\n") == "<p><code>apps/cli/internal/loadrun.Run</code></p>")
        #expect(html("See https://github.com/hxddh/readout/blob/main/docs/design.md for it.\n")
            .contains(">https://github.com/<wbr>hxddh/<wbr>readout/<wbr>blob/<wbr>main/<wbr>docs/<wbr>design.md</a>"))
    }

    @Test func ansiColourCodesAreStrippedFromCode() {
        let h = html("```\n\u{1B}[1;32m✓\u{1B}[0m 12 tests passed\n\u{1B}[31merror\u{1B}[m: none\n```\n")
        #expect(h == "<div class=\"code-block\"><pre><code>✓ 12 tests passed\nerror: none</code></pre></div>", "\(h)")
    }

    @Test func placeholdersKeepAColumnNumeric() {
        let h = html("| Method | Calls | p99 |\n| --- | --- | --- |\n| get | 1,204 | 12 ms |\n| put | N/A | — |\n| list | - | TBD |\n| head | 87 | – |\n")
        #expect(h.contains("<th class=\"num\">Calls</th>") && h.contains("<th class=\"num\">p99</th>"), "\(h)")
        #expect(h.contains("<td class=\"num\">N/A</td>") && h.contains("<td class=\"num\">TBD</td>"), "\(h)")
        // A column of placeholders only is not numeric.
        #expect(!html("| A | B |\n| --- | --- |\n| x | - |\n| y | N/A |\n").contains("class=\"num\""))
    }
}
