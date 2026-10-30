import Foundation
import Markdown
import Testing
@testable import ReadoutCore

/// Byte-level shortcuts (`FastBytes`) give what the Character and tree walks they
/// replace gave.
@Suite struct FastBytesTests {
    typealias RNG = IncrementalParserTests.SplitMix64

    @Test func lineSlicesSplitLikeCharacters() {
        let texts = [
            "", "\n", "\n\n", "a", "a\n", "\na", "a\nb\n\nc", "  - [ ] x\n> quote\n",
            "é\n\u{301}combining after a line break\n", "全角\n\u{3000}\n", "👩‍👩‍👧\n🇸🇬\n", "tab\there\n\t\n",
            "\u{E004}filler\n$$\nx\n$$",
        ]
        for t in texts {
            let reference = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            #expect(FastBytes.lineSlices(t).map(String.init) == reference, "\(t.debugDescription)")
        }
    }

    @Test func checkboxProbe() {
        for s in ["- [ ] a", "- [x] a", "- [X] a", "> 1. [ ] a", "x [ ]"] { #expect(FastBytes.mayHaveCheckbox(s), "\(s)") }
        for s in ["", "- a", "- [] a", "- [y] a", "- [\t] a", "[link](x)", "[", "]", "- [  ] a"] {
            #expect(!FastBytes.mayHaveCheckbox(s), "\(s)")
        }
    }

    /// Checkboxes the parser reports, against every list item swift-markdown
    /// finds with one, over random documents of task lists in the containers
    /// a block can hold them in.
    @Test func tasksFoundWithoutWalkingEveryBlock() {
        let palette = [
            "- [ ] open", "- [x] done", "* [X] Done", "1. [ ] first", "+ [x] plus", "  - [ ] nested", "    - [x] deeper",
            "> - [ ] quoted", "- plain item", "- [] not a box", "- [y] not a box", "Paragraph with [ ] brackets",
            "", "", "<details>", "<summary>S</summary>", "</details>", "```", "- [ ] in code", "| a | b |", "|---|---|",
            "| [ ] | x |", "# Heading", "- [ ]", "- [x]", "Text [x] inline", "  continued",
        ]
        var rng = RNG(state: 36)
        for _ in 0..<300 {
            let lines = (0..<Int.random(in: 1..<30, using: &rng)).map { _ in palette.randomElement(using: &rng)! }
            let text = lines.joined(separator: "\n")
            var reference = 0
            func walk(_ m: Markup) {
                if let li = m as? ListItem, li.checkbox != nil { reference += 1 }
                for c in m.children { walk(c) }
            }
            walk(Document(parsing: text, options: [.disableSmartOpts]))
            #expect(MarkdownParser.parse(text).tasks.total == reference, "\(text)")
        }
    }
}
