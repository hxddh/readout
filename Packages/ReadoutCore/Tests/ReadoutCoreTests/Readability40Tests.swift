import Foundation
import Testing
@testable import ReadoutCore

/// 4.0 readability (P4): where long paths may break, and lead-in paragraphs.
@Suite struct Readability40Tests {
    func html(_ md: String) -> String { MarkdownParser.parse(md).blocks.map(\.html).joined(separator: "\n") }
    /// The text a reader sees (and copies): the markup without its tags.
    func text(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Long paths and identifiers break after their separators only

    @Test func inlineCodePathsBreakAfterSeparators() {
        // 18-phase0-bench-report: the line used to end in "…-phase0-", leaving "1.md" alone.
        let h = html("This is Phase 0 work item 7 (`docs/superpowers/plans/2026-08-08-stresseur-phase0-1.md` §4.1.7).\n")
        // WebKit breaks after a `-` of its own: a part holding one where no break
        // belongs (a date, `phase0-1.md`) is kept on one line (span.nb).
        #expect(h.contains("<code>docs/<wbr>superpowers/<wbr>plans/<wbr><span class=\"nb\">2026-08-08-</span><wbr>stresseur-<wbr><span class=\"nb\">phase0-1.md</span></code>"), "\(h)")
        #expect(html("`apps/cli/internal/loadrun.Run` and `apps/cli/internal/loadrun`\n")
            == "<p><code>apps/<wbr>cli/<wbr>internal/<wbr>loadrun.Run</code> and <code>apps/<wbr>cli/<wbr>internal/<wbr>loadrun</code></p>")
        // As in a table cell (typography.test.mjs T2): `src/` keeps its one-letter part.
        #expect(html("`src/a/very/long/path/to/some/deeply/nested/module.ts`\n")
            == "<p><code>src/a/<wbr>very/<wbr>long/<wbr>path/<wbr>to/<wbr>some/<wbr>deeply/<wbr>nested/<wbr>module.ts</code></p>")
        // `::`, `.`, `_` and `-` are parts too; a run of separators stays together.
        #expect(html("`std::collections::HashMap`\n") == "<p><code>std::<wbr>collections::<wbr>HashMap</code></p>")
        // (A part after a dot is five characters at least: `boot.` stays with `springframework.`.)
        #expect(html("`org.springframework.boot.autoconfigure`\n") == "<p><code>org.<wbr>springframework.boot.<wbr>autoconfigure</code></p>")
        #expect(html("`E_PROXY_BUCKET_EXHAUSTED_ERROR`\n") == "<p><code>E_PROXY_<wbr>BUCKET_<wbr>EXHAUSTED_<wbr>ERROR</code></p>")
        #expect(html("`--dangerously-skip-permissions`\n") == "<p><code><span class=\"nb\">--dangerously-</span><wbr>skip-<wbr>permissions</code></p>")
        #expect(html("`https://registry.npmjs.org/package`\n").contains("https://<wbr>registry.<wbr>npmjs.org/<wbr>package"))
    }

    @Test func breaksLeaveNoScraps() {
        // Nothing in the first three characters (`~/`, `./`), no part shorter than
        // two (five after a dot: an extension stays with its name), at least five left.
        #expect(html("`~/.codemoss/prompt.json`\n") == "<p><code>~/.codemoss/<wbr>prompt.json</code></p>")
        #expect(html("`./coverage/lcov-report/index.html`\n") == "<p><code>./coverage/<wbr>lcov-<wbr>report/<wbr>index.html</code></p>")
        #expect(html("`app/src/main/AndroidManifest.xml`\n") == "<p><code>app/<wbr>src/<wbr>main/<wbr>AndroidManifest.xml</code></p>")
        #expect(html("`class=\"glyphicon glyphicon-X\"`\n") == "<p><code>class=&quot;glyphicon <span class=\"nb\">glyphicon-X&quot;</span></code></p>")
        // A hidden folder breaks before its dot, not after it.
        #expect(html("`$root/.superpowers/sdd/progress.md`\n") == "<p><code>$root/<wbr>.superpowers/<wbr>sdd/<wbr>progress.md</code></p>")
        // Not between digits: dates, versions, addresses.
        #expect(html("`release-2026-08-08-v1.25.10-final`\n") == "<p><code>release-<wbr><span class=\"nb\">2026-08-08-</span><wbr>v1.25.10-<wbr>final</code></p>")
        #expect(html("`http://127.0.0.1:3000/status/health`\n") == "<p><code>http://<wbr>127.0.0.1:3000/<wbr>status/<wbr>health</code></p>")
        // A single colon is no part (`cli:test`, `//go:build`), punctuation alone has none.
        #expect(html("`//go:build loadbench_integration`\n") == "<p><code>//go:build loadbench_<wbr>integration</code></p>")
        #expect(!html("`!\"#$%&'()*+,-./:;<=>?@[]^_{|}~`\n").contains("<wbr>"))
    }

    @Test func shortCodeAndWordsAreLeftWhole() {
        // Under 20 characters a token moves to the next line whole.
        #expect(html("`loadrun.Run`, `cli:test`, `load run`, `a/b/c/d/e/f/g`\n")
            == "<p><code>loadrun.Run</code>, <code>cli:test</code>, <code>load run</code>, <code>a/b/c/d/e/f/g</code></p>")
        // Each token of a longer span on its own: only the long one gets breaks.
        #expect(html("`grep -n foo skills/subagent-driven-development/SKILL.md`\n")
            == "<p><code>grep -n foo skills/<wbr>subagent-<wbr>driven-<wbr>development/<wbr>SKILL.md</code></p>")
        // An identifier without separators is not broken.
        #expect(!html("`AndroidFloatingWindowManagerImplementation`\n").contains("<wbr>"))
        // Code blocks are not touched.
        #expect(!html("```\ndocs/superpowers/plans/2026-08-08-stresseur-phase0-1.md\n```\n").contains("<wbr>"))
    }

    @Test func bareLongPathsInTextBreakAfterSlashes() {
        let h = html("Add it to docs/superpowers/specs/phase0-bench-report.md and commit.\n")
        #expect(h == "<p>Add it to docs/<wbr>superpowers/<wbr>specs/<wbr>phase0-bench-report.md and commit.</p>", "\(h)")
        // Only tokens with a slash (prose breaks at its own hyphens), only long ones.
        #expect(!html("A state-of-the-art-and-then-some approach, and/or src/a.ts.\n").contains("<wbr>"))
        // Not in link text the author wrote; a bare URL keeps its own breaks (3.6).
        #expect(!html("[docs/superpowers/specs/phase0-bench.md](docs/superpowers/specs/phase0-bench.md)\n").contains("<wbr>"))
        #expect(html("See https://github.com/hxddh/readout/blob/main/docs/design.md for it.\n")
            .contains(">https://github.com/<wbr>hxddh/<wbr>readout/<wbr>blob/<wbr>main/<wbr>docs/<wbr>design.md</a>"))
        // In a CJK sentence too.
        #expect(html("更新 00-Prerequisites/deep-learning-basics/README.md 文件\n")
            .contains("00-Prerequisites/<wbr>deep-learning-basics/<wbr>README.md"))
    }

    @Test func shortHyphenatedCodeStaysOnOneLine() {
        // WebKit would break `glyphicon-|X` or `--|preview` at a line end: a short
        // code span holding such a break is kept whole (code.nb), as any short
        // token moves to the next line whole. Without one, no class.
        #expect(html("`glyphicon-X` and `--preview`\n") == "<p><code class=\"nb\">glyphicon-X</code> and <code class=\"nb\">--preview</code></p>")
        #expect(html("`make`, `-v`, `a-`, `x?`\n") == "<p><code>make</code>, <code>-v</code>, <code>a-</code>, <code>x?</code></p>")
        // In a longer span, the token alone; a part over 30 characters is left to WebKit.
        #expect(html("`git cat-file -t`\n") == "<p><code>git <span class=\"nb\">cat-file</span> -t</code></p>")
        let long = "a-" + String(repeating: "b", count: 40)
        #expect(html("`\(long)`\n") == "<p><code>\(long)</code></p>")
        // Prose keeps the browser's own hyphen breaks.
        #expect(!html("Add docs/superpowers/specs/phase0-bench-report.md here.\n").contains("nb"))
    }

    @Test func breakOpportunitiesAreNoText() {
        // The text the page shows, finds and copies is the source's, to the character.
        for md in ["`docs/superpowers/plans/2026-08-08-stresseur-phase0-1.md`", "`std::collections::HashMap<K, V>`",
                   "`a&b=c&d=e/f/g/h/i/j?k=l#mmmmm`", "docs/superpowers/plans/2026-08-08-stresseur-phase0-1.md"] {
            let h = html(md + "\n")
            #expect(h.contains("<wbr>"), "\(md)")
            #expect(md.hasPrefix("`") || !h.contains("nb"), "\(h)")
            #expect(text(h).replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">") == md.replacingOccurrences(of: "`", with: ""), "\(h)")
        }
    }

    // MARK: A lead-in paragraph and its list

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
