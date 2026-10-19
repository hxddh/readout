import Foundation
import Testing
@testable import ReadoutCore

/// 3.8 core fixes (audit lane B and P4). Each test failed on 3.7.0.
@Suite struct CoreFixes38Tests {
    // MARK: B1: deep nesting crashed Readout (and, restored, at every launch)

    /// The audit's documents (`bugs/B1`): a few hundred bytes of nesting.
    static let deep: [(name: String, text: String)] = [
        ("quotes-400", String(repeating: ">", count: 400) + " x"),
        ("lists-150", (0..<150).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n")),
        ("ordered-150", (0..<150).map { String(repeating: "   ", count: $0) + "1. item" }.joined(separator: "\n")),
        ("mixed-120", String(repeating: "> - ", count: 120) + "x"),
        ("images-300", String(repeating: "[![", count: 300) + "x" + String(repeating: "](a.png)](b)", count: 300)),
        ("emphasis-4000", String(repeating: "*a **b ", count: 4000) + "c" + String(repeating: "** b*", count: 4000)),
        ("strike-2000", String(repeating: "~~a ", count: 2000) + "c" + String(repeating: " b~~", count: 2000)),
        ("links-300", String(repeating: "[a ", count: 300) + "x" + String(repeating: " b](y)", count: 300)),
        ("emphasis-lines", (0..<2000).map { _ in "*a **b" }.joined(separator: "\n") + "\nc\n" + (0..<2000).map { _ in "b** a*" }.joined(separator: "\n")),
        ("quoted-emphasis", String(repeating: ">", count: 300) + " " + String(repeating: "*a **b ", count: 300) + "c" + String(repeating: "** b*", count: 300)),
        ("note-emphasis", "x[^n]\n\n[^n]: " + String(repeating: "*a **b ", count: 2000) + "c" + String(repeating: "** b*", count: 2000)),
    ]

    /// `body` on a thread with a 512 KB stack (a GCD worker's on macOS,
    /// where `IncrementalParser` parses fragments concurrently): on 3.7 it
    /// crashed the process.
    static func onSmallStack(_ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let t = Thread { body(); done.signal() }
        t.stackSize = 512 * 1024
        t.start()
        return done.wait(timeout: .now() + 60) == .success
    }

    @Test func deepNestingParsesOnASmallStack() {
        // The audit's test (bugs/AuditB38ReprosTests.swift).
        let text = String(repeating: ">", count: 400) + " x\n\n" + (0..<150).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n")
        nonisolated(unsafe) var blocks = -1
        #expect(Self.onSmallStack { blocks = MarkdownParser.parse(text).blocks.count })
        #expect(blocks > 0)
        for d in Self.deep {
            nonisolated(unsafe) var full = -1, incremental = -1
            #expect(Self.onSmallStack {
                full = MarkdownParser.parse(d.text).blocks.count
                incremental = IncrementalParser().parse(d.text).blocks.count
            }, "\(d.name)")
            #expect(full > 0 && full == incremental, "\(d.name)")
        }
    }

    /// Flattened, not dropped: the deepest container holds the rest as text.
    @Test func deepNestingKeepsItsText() {
        let quotes = MarkdownParser.parse(String(repeating: ">", count: 400) + " x").blocks
        #expect(quotes.count == 1)
        let html = quotes[0].html
        #expect(html.components(separatedBy: "<blockquote").count - 1 == NestingCap.containers)
        #expect(html.contains(String(repeating: "&gt;", count: 400 - NestingCap.containers) + " x"), "\(html.suffix(200))")
        // Block.source stays what the file says.
        #expect(quotes[0].source == String(repeating: ">", count: 400) + " x")
        let list = MarkdownParser.parse(Self.deep[1].text).blocks
        #expect(list.map(\.text).joined().components(separatedBy: "item").count - 1 == 150)
        let emphasis = MarkdownParser.parse(Self.deep[5].text).blocks[0].html
        #expect(emphasis.contains("c"))
        #expect(emphasis.components(separatedBy: "<em>").count - 1 <= NestingCap.inlines)
    }

    /// What real documents nest is left as it is: no corpus document, and
    /// no ordinary deep list or busy paragraph, is changed.
    @Test func ordinaryNestingIsUntouched() throws {
        for url in CorpusTests.documents() {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(NestingCap.apply(text) == nil, "\(url.lastPathComponent)")
        }
        let ordinary = [
            (0..<8).map { String(repeating: "    ", count: $0) + "- level \($0)" }.joined(separator: "\n"),
            (0..<16).map { String(repeating: "  ", count: $0) + "- level \($0)" }.joined(separator: "\n"),
            String(repeating: "> ", count: 10) + "**quoted** and *deep*",
            (0..<40).map { "**Step \($0):** run `make_\($0)` with *care* and [docs](d\($0).md)" }.joined(separator: " "),
            (0..<40).map { "- **注意：**这里 `~/path/\($0)` ~/home \($0)" }.joined(separator: "\n"),
            "```\n" + String(repeating: ">", count: 100) + "\n" + String(repeating: "[", count: 100) + "\n```",
            "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -",
            "a_b_c " + String(repeating: "snake_case_name ", count: 40),
            String(repeating: "2*3*4 ", count: 40),
        ]
        for text in ordinary { #expect(NestingCap.apply(text) == nil, "\(text.prefix(60))") }
    }

    /// Flattening is decided per line and per run of non-blank lines, which
    /// fragments never split: incremental and spliced parses (with the render
    /// cache) are the full parse's, across edits in and around deep nesting.
    @Test func flattenedNestingIsTheSameIncrementally() {
        var rng = IncrementalParserTests.SplitMix64(state: 38)
        let pieces = Self.deep.map(\.text).map { String($0.prefix(400)) } + [
            "# Heading", "Plain paragraph.", "- item", "  - nested", "> quote", "```", "code", "", "", "",
            String(repeating: ">", count: 30) + " " + String(repeating: "[", count: 30) + "x" + String(repeating: "](y)", count: 30),
            String(repeating: "  ", count: 20) + "- deep item", "*a **b *c **d *e **f *g **h *i **j", "j** i* h** g* f** e* d** c* b** a*",
        ]
        for round in 0..<6 {
            var lines = (0..<30).map { _ in pieces.randomElement(using: &rng)! }
            let p = IncrementalParser(), cache = MarkdownParser.RenderCache()
            for step in 0..<20 {
                let at = Int.random(in: 0..<lines.count, using: &rng)
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: lines.insert(pieces.randomElement(using: &rng)!, at: at)
                case 1: lines.remove(at: at)
                case 2: lines[at] += " edited"
                default: lines.append(pieces.randomElement(using: &rng)!)
                }
                if lines.isEmpty { lines = ["x"] }
                let text = lines.joined(separator: "\n")
                cache.beginGeneration()
                let inc = p.parse(text, cache: cache), full = MarkdownParser.parse(text)
                #expect(inc.blocks == full.blocks && inc.title == full.title, "round \(round) step \(step) spliced \(p.lastSpliced)")
                if inc.blocks != full.blocks { return }
            }
        }
    }

    /// Found by the test above: a fence left open to the end holds the
    /// blank lines after its last line, and its cached HTML (keyed by its
    /// source, which stops at the last non-blank line) was that of the same
    /// code with more or fewer of them.
    @Test func openFenceAtTheEndRendersAsTheFullParse() {
        let a = "Intro.\n\n```\ncode\n- item\n\n", b = "Intro.\n\n```\ncode\n- item", c = a + "\n"
        for (x, y) in [(a, b), (b, a), (a, c), (c, a)] {
            let p = IncrementalParser(), cache = MarkdownParser.RenderCache()
            cache.beginGeneration(); _ = p.parse(x, cache: cache)
            cache.beginGeneration()
            #expect(p.parse(y, cache: cache).blocks == MarkdownParser.parse(y).blocks, "\(y.debugDescription)")
        }
    }

    /// Document loading parses on a thread with a large stack.
    @Test func parseThreadHasALargeStack() async {
        let text = String(repeating: "  ", count: 1) + "- x"
        let size = ParseThread.sync { (Thread.current.stackSize, MarkdownParser.parse(text).blocks.count) }
        #expect(size.0 >= ParseThread.stackSize && size.1 == 1)
        let n = await ParseThread.run { Thread.current.stackSize }
        #expect(n >= ParseThread.stackSize)
    }

    // MARK: B2: a variation selector after `*` or `_`

    @Test func variationSelectorAfterDelimiterKeepsTheText() {
        let a = MarkdownParser.parse("中文**\u{FE01}中文").blocks[0].html
        #expect(!a.contains("<em></em>"), "\(a)")          // 3.7: <p>中文<em></em>︁中文</p>
        #expect(a == "<p>中文**\u{FE01}中文</p>", "\(a)")   // markdown-it-cjk-friendly: literal **
        let b = MarkdownParser.parse("**注意**\u{FE0E}中文**粗体**").blocks[0].html
        #expect(b == "<p><strong>注意</strong>\u{FE0E}中文<strong>粗体</strong></p>", "\(b)")
        // 3.7: <p><strong>注意<em></em>︎中文</strong>粗体**</p>
    }

    // MARK: B5: a list item whose first content is a no-break space

    /// cmark-gfm takes `- <NBSP>` for a list item (only space and tab are
    /// white space there); the fragmenter took it for a paragraph, so an HTML
    /// block opened in it ended elsewhere and text the full parse keeps in
    /// an open comment showed.
    @Test func nbspItemThenHTMLMatchesTheFullParse() {
        let text = "- \u{00A0}\n  <tr\n<!--\n\nText after.\n"
        let inc = IncrementalParser().parse(text), full = MarkdownParser.parse(text)
        #expect(inc.blocks == full.blocks)   // 3.7: incremental ends the comment at line 3, full at 5
        for t in ["- \u{00A0}\n  <div>\n\nAfter.", "- \u{3000}\n  ```\n\nx\n", "1. \u{00A0}x\n2. y\n\nz"] {
            #expect(IncrementalParser().parse(t).blocks == MarkdownParser.parse(t).blocks, "\(t)")
        }
    }

    // MARK: B4: the repository root, from deep in it

    @Test func repositoryRootIsAlwaysACandidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("b4-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let deep = root + "/repo/docs/a/b/c/d/e/f"
        try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/repo/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/repo/src", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/repo/src/app.ts", atomically: true, encoding: .utf8)
        #expect(FileResolver(baseDirectory: URL(fileURLWithPath: root + "/repo/docs/a")).pathReference("src/app.ts") != nil)
        #expect(FileResolver(baseDirectory: URL(fileURLWithPath: deep)).pathReference("src/app.ts") != nil)   // 3.7: nil
        // The five folders above, then the root (each once), and nothing above it.
        let c = FileResolver(baseDirectory: URL(fileURLWithPath: deep)).candidates(for: "x.md").map(\.path)
        #expect(c.count == 7 && c.last == root + "/repo/x.md", "\(c)")
    }

    // MARK: B6: ProcessRunner keeps to its time limit

    @Test func aProgramPastItsTimeLimitStopsAtTheLimit() {
        let t0 = Date()
        // A shell waiting on its command (as the audit's hanging git).
        #expect(ProcessRunner.run("/bin/sh", ["-c", "sleep 5; echo hi"], timeout: 0.5, limit: 100) == nil)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed < 0.85, "\(elapsed)")   // 3.7: 1.0 (the limit, then half a second more)
    }

    /// A program that exits at once, leaving a child that holds its output
    /// open: its output, when it exits, and no reader left waiting.
    @Test func aChildHoldingTheOutputDoesNotHoldTheResult() async throws {
        let t0 = Date()
        let out = ProcessRunner.run("/bin/sh", ["-c", "echo '# Old'; (sleep 4) & exit 0"], timeout: 1, limit: 100)
        let elapsed = Date().timeIntervalSince(t0)
        #if canImport(Darwin)
        #expect(out == Data("# Old\n".utf8))   // 3.7: nil, after the limit and half a second more
        #expect(elapsed < 0.7, "\(elapsed)")
        #else
        // swift-corelibs-foundation reports the exit only once the child has
        // exited too (it watches a socket the child inherits): at the limit.
        #expect(out == nil)
        #expect(elapsed < 1.3, "\(elapsed)")   // 3.7: 1.5
        #endif
        // 3.7's reader waited for the child, 4 s. (Other tests may run one meanwhile: none for long.)
        var waited = 0
        while ProcessRunner.liveReaders > 0 && waited < 200 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        #expect(ProcessRunner.liveReaders == 0)
        // Output past the limit still stops it at once.
        let t1 = Date()
        #expect(ProcessRunner.run("/bin/sh", ["-c", "head -c 200000 /dev/zero; sleep 5"], timeout: 3, limit: 1000) == nil)
        #expect(Date().timeIntervalSince(t1) < 1)
    }
}
