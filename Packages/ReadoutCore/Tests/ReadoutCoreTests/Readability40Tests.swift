import Foundation
import Testing
@testable import ReadoutCore

/// 4.0 readability (P4): long paths (no break markup of our own), and lead-in paragraphs.
@Suite struct Readability40Tests {
    func html(_ md: String) -> String { MarkdownParser.parse(md).blocks.map(\.html).joined(separator: "\n") }
    /// The text a reader sees (and copies): the markup without its tags.
    func text(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Long paths and identifiers

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

    // MARK: Lead-ins

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
}
