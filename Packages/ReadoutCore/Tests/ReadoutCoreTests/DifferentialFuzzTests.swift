import Foundation
import Testing
@testable import ReadoutCore

/// Differential fuzzing of `IncrementalParser` against `MarkdownParser.parse`:
/// random documents of constructs the fence tracker follows (and corpus
/// documents), edited line by line and character by character; after every
/// edit the incremental result must be exactly the full parse.
///
/// Deterministic: seeds `READOUT_FUZZ_FIRST` ..< +`READOUT_FUZZ_SEEDS`
/// (default 0 ..< 300), `READOUT_FUZZ_STEPS` edit rounds each (default 40).
/// For a longer local run: `READOUT_FUZZ_SEEDS=2000 READOUT_FUZZ_STEPS=80`.
/// `READOUT_FUZZ_DUMP=<dir>` writes each failing text there, and
/// `READOUT_FUZZ_MIN=<file>` shrinks one to a minimal failing text (`<file>.min`).
@Suite struct DifferentialFuzzTests {
    typealias RNG = IncrementalParserTests.SplitMix64
    static let env = ProcessInfo.processInfo.environment

    static let palette: [String] = IncrementalParserTests.palette + [
        "---", "title: x", "...", "<textarea>", "</textarea>", "<?php", "?>", "<![CDATA[", "]]>", "<!X decl", "<style>", "</style>",
        "<custom-tag>", "</custom-tag>", "<kbd>K</kbd> key", "<img src=\"a.png\">", "<sub>2</sub>", "  ", "\t", " \t ",
        "$$", "a + b", "$$ x $$", "\\[", "\\]", "Price $5 and $10", "`$x$`", "\\$ escaped", "[link](#a)", "[^n]", "[^x]: undefined",
        "    - deep", "   - three", "10. ten", "1.", "-", "+ plus", "> - quoted item", "> ```", ">> deep", "Term", ": def",
        "Title\u{00A0}", "\u{3000}全角", "| x |", "a | b", "--- | ---", "<details open>", "<summary>S</summary>", "</details> trailing",
        "<div>", "</div>", "<!-- c -->", "# H1", "## H1", "#", "# ![](logo.png)", "```mermaid", "graph TD", "```math",
        "~~~~", "````md", "\\", "***bold***", "_x_", "<br/>", "&amp;", "[^n]: note", "[^n]:", "    indented after note",
        "2. ```bash", "- ```text", "> ```sh", "> - ```", "  ```", "\tcp $SRC/$NAME", "--", "=", "- 2x + 1", "Run: make", "Expected: ok",
    ]

    static func mutate(_ lines: inout [String], rng: inout RNG) {
        let at = lines.isEmpty ? 0 : Int.random(in: 0..<lines.count, using: &rng)
        switch Int.random(in: 0..<8, using: &rng) {
        case 0, 1: lines.insert(palette.randomElement(using: &rng)!, at: at)
        case 2: if !lines.isEmpty { lines.remove(at: at) }
        case 3: if !lines.isEmpty { lines[at] += " edited" }
        case 4: if !lines.isEmpty { lines.insert(lines[at], at: at) }
        case 5:
            // One character deleted or inserted.
            if !lines.isEmpty, !lines[at].isEmpty {
                var s = Array(lines[at])
                let k = Int.random(in: 0..<s.count, using: &rng)
                if Bool.random(using: &rng) { s.remove(at: k) } else {
                    s.insert(["$", "`", "<", ">", " ", "*", "[", "]", "|", "-", "#", "\t", "~"].randomElement(using: &rng)!, at: k)
                }
                lines[at] = String(s)
            }
        case 6:
            // Indentation or a container marker before a line.
            if !lines.isEmpty { lines[at] = ["  ", "    ", "> ", "- ", "1. ", "\t"].randomElement(using: &rng)! + lines[at] }
        default:
            // Two lines joined.
            if at + 1 < lines.count { lines[at] += lines.remove(at: at + 1) }
        }
    }

    static func differs(_ text: String, _ p: IncrementalParser = IncrementalParser()) -> Bool {
        let full = MarkdownParser.parse(text), inc = p.parse(text)
        return inc.title != full.title || inc.blocks != full.blocks
    }

    func check(_ text: String, _ p: IncrementalParser, _ note: String) -> Bool {
        let full = MarkdownParser.parse(text)
        let inc = p.parse(text)
        guard inc.title != full.title || inc.blocks != full.blocks else { return true }
        if let dir = Self.env["READOUT_FUZZ_DUMP"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? text.write(toFile: dir + "/\(note).md", atomically: true, encoding: .utf8)
        }
        let i = zip(inc.blocks, full.blocks).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(inc.blocks.count, full.blocks.count)
        Issue.record("""
            \(note): incremental and full parses differ (title \(String(describing: inc.title)) / \(String(describing: full.title))), first at block \(i)
            incremental: \(i < inc.blocks.count ? String(describing: inc.blocks[i]) : "-")
            full: \(i < full.blocks.count ? String(describing: full.blocks[i]) : "-")
            text: \(String(reflecting: text.count > 2000 ? String(text.prefix(2000)) + "…" : text))
            """)
        return false
    }

    static let first = Int(env["READOUT_FUZZ_FIRST"] ?? "") ?? 0
    static let seeds = Int(env["READOUT_FUZZ_SEEDS"] ?? "") ?? 300
    static let steps = Int(env["READOUT_FUZZ_STEPS"] ?? "") ?? 40

    @Test(arguments: first..<(first + seeds))
    func incrementalMatchesFull(_ seed: Int) {
        var rng = RNG(state: UInt64(seed) &* 7919 &+ 17)
        var lines: [String] = (0..<Int.random(in: 5...60, using: &rng)).map { _ in Self.palette.randomElement(using: &rng)! }
        // Every 15th sequence edits a real document instead (slower: a full parse of it per step).
        if seed % 15 == 0, let doc = CorpusTests.documents().randomElement(using: &rng),
           let s = try? String(contentsOf: doc, encoding: .utf8) { lines = s.components(separatedBy: "\n") }
        let p = IncrementalParser()
        let crlf = seed % 5 == 4
        let bom = seed % 7 == 6
        func text() -> String { (bom ? "\u{FEFF}" : "") + lines.joined(separator: crlf ? "\r\n" : "\n") }
        guard check(text(), p, "seed\(seed)-v0") else { return }
        for step in 0..<Self.steps {
            for _ in 0..<Int.random(in: 1...4, using: &rng) { Self.mutate(&lines, rng: &rng) }
            guard check(text(), p, "seed\(seed)-step\(step + 1)") else { return }
        }
    }

    /// Shrinks the text in `READOUT_FUZZ_MIN` to a minimal one on which a
    /// fresh incremental parse still differs; writes `<file>.min`.
    @Test func minimize() throws {
        guard let path = Self.env["READOUT_FUZZ_MIN"] else { return }
        var lines = try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n")
        func differs(_ l: [String]) -> Bool { Self.differs(l.joined(separator: "\n")) }
        guard differs(lines) else { Issue.record("a fresh incremental parse does not differ"); return }
        var changed = true
        while changed {
            changed = false
            var chunk = max(1, lines.count / 2)
            while chunk >= 1 {
                var k = 0
                while k < lines.count {
                    var t = lines
                    t.removeSubrange(k..<min(lines.count, k + chunk))
                    if differs(t) { lines = t; changed = true } else { k += chunk }
                }
                chunk /= 2
            }
            for idx in lines.indices {
                var c = 0
                while c < lines[idx].count {
                    var t = lines
                    t[idx].remove(at: t[idx].index(t[idx].startIndex, offsetBy: c))
                    if differs(t) { lines = t; changed = true } else { c += 1 }
                }
            }
        }
        try lines.joined(separator: "\n").write(toFile: path + ".min", atomically: true, encoding: .utf8)
    }
}
