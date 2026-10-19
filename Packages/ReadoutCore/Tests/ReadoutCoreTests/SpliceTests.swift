import Foundation
import Testing
@testable import ReadoutCore

/// 3.7 P1/P2: a version that differs from the previous one in one run of
/// lines is spliced into it (`IncrementalParser.splice`), and the session
/// skips the blocks the splice kept (`DocumentSession.apply`). Both must be
/// exactly what parsing in full and comparing everything give.
@Suite struct SpliceTests {
    typealias RNG = IncrementalParserTests.SplitMix64
    /// Bounded for CI; `READOUT_FUZZ_SEEDS=2000` for a longer local run.
    static let seeds = Int(ProcessInfo.processInfo.environment["READOUT_FUZZ_SEEDS"] ?? "") ?? 80

    static func corpusText(bytes: Int) -> String {
        let docs = CorpusTests.documents().compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.replacingOccurrences(of: "\r", with: "") }
            // Link definitions make a document parse in full.
            .filter { !IncrementalParser.needsFullParse(MarkdownParser.sourceLines($0)) }
        var out = ""
        var i = 0
        while out.utf8.count < bytes { out += docs[i % docs.count] + "\n\n"; i += 1 }
        return out
    }

    func same(_ text: String, _ p: IncrementalParser, _ note: String) -> Bool {
        let inc = p.parse(text), full = MarkdownParser.parse(text)
        guard inc.title != full.title || inc.blocks != full.blocks else { return true }
        if let dir = ProcessInfo.processInfo.environment["READOUT_FUZZ_DUMP"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? text.write(toFile: dir + "/\(note).md", atomically: true, encoding: .utf8)
        }
        let i = zip(inc.blocks, full.blocks).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(inc.blocks.count, full.blocks.count)
        Issue.record("""
            \(note) (spliced: \(p.lastSpliced)): differs at block \(i)
            splice: \(i < inc.blocks.count ? String(describing: inc.blocks[i]) : "-")
            full: \(i < full.blocks.count ? String(describing: full.blocks[i]) : "-")
            """)
        return false
    }

    // MARK: What is spliced

    /// An agent writing on: a paragraph appended to a long document parses
    /// the last fragment and the new one, and keeps every block before them;
    /// the session compares only those after them.
    @Test func appendIsSplicedAndTheSessionSkipsTheStart() throws {
        let text = Self.corpusText(bytes: 150_000)
        let p = IncrementalParser(), s = DocumentSession()
        _ = s.load(p.parse(text))
        let next = text + "\n\nThe agent appended this paragraph about the next step."
        let doc = p.parse(next)
        #expect(p.lastSpliced)
        #expect((p.lastParsed ?? 99) <= 2)
        #expect(doc.blocks == MarkdownParser.parse(next).blocks)
        let n = doc.blocks.count
        let patch = try #require(s.update(doc))
        #expect(s.lastShared.prefix > n - 20)
        #expect(patch.ops.map(\.op) == [.insert])
        #expect(s.marks.values.sorted { $0.rawValue < $1.rawValue } == [.inserted])
    }

    /// Streaming mid-line: the last paragraph grows by a few words.
    @Test func tailGrowthIsSpliced() throws {
        let text = Self.corpusText(bytes: 150_000) + "The agent writes"
        let p = IncrementalParser(), s = DocumentSession()
        _ = s.load(p.parse(text))
        let next = text + " another clause"
        let doc = p.parse(next)
        #expect(p.lastSpliced)
        #expect(doc.blocks == MarkdownParser.parse(next).blocks)
        let patch = try #require(s.update(doc))
        #expect(s.lastShared.prefix > doc.blocks.count - 20)
        #expect(patch.ops.map(\.op) == [.replace])
    }

    /// An edit in the middle that changes no heading keeps the blocks after
    /// it too, moved by the lines it added.
    @Test func middleEditKeepsTheEnd() throws {
        var paragraphs = Self.corpusText(bytes: 80_000).components(separatedBy: "\n\n")
        let p = IncrementalParser(), s = DocumentSession()
        _ = s.load(p.parse(paragraphs.joined(separator: "\n\n")))
        let k = try #require(paragraphs.indices.dropFirst(paragraphs.count / 2).first {
            paragraphs[$0].first?.isLetter == true && !paragraphs[$0].contains("\n") && paragraphs[$0].count > 40
        })
        paragraphs[k] += "\nwith a second line added"
        let next = paragraphs.joined(separator: "\n\n")
        let doc = p.parse(next)
        #expect(p.lastSpliced)
        #expect(doc.blocks == MarkdownParser.parse(next).blocks)
        #expect((doc.splice?.suffix ?? 0) > 10)
        _ = s.update(doc)
        #expect(s.lastShared.suffix > 10)
    }

    /// A heading added before others with the same title: the anchors after
    /// it move on (`notes-1` becomes `notes-2`), so nothing after it is kept as it was.
    @Test func headingBeforeOthersReassemblesTheRest() {
        let body = (0..<30).map { "## Notes\n\nParagraph \($0) under a heading of the same name." }
        let text = "# Doc\n\nIntro.\n\n" + body.joined(separator: "\n\n")
        let p = IncrementalParser()
        _ = p.parse(text)
        let next = text.replacingOccurrences(of: "Paragraph 10 under", with: "Paragraph 10\n\n## Notes\n\nunder")
        let doc = p.parse(next)
        #expect(p.lastSpliced)
        #expect(doc.blocks == MarkdownParser.parse(next).blocks)
        #expect(doc.blocks.last { $0.kind == .heading }?.anchor == "notes-30")
        #expect(doc.splice?.suffix == 0)
    }

    /// A preamble (badges, a logo, an intro) before the first H1, edited
    /// outside the first fragment: the kept rest holds the H1, and the
    /// spliced result keeps its title, exactly as the full parse.
    @Test func titleAfterAnEditedPreambleIsKept() throws {
        let preamble = (0..<6).map { "Preamble paragraph \($0) before the title." }.joined(separator: "\n\n")
        let body = (0..<6).map { "Body paragraph \($0)." }.joined(separator: "\n\n")
        let text = preamble + "\n\n# Real Title\n\n" + body
        let p = IncrementalParser()
        #expect(p.parse(text).title == "Real Title")
        var next = text.replacingOccurrences(of: "Preamble paragraph 3 before", with: "Preamble paragraph 3 edited before")
        var doc = p.parse(next)
        #expect(p.lastSpliced)
        #expect((doc.splice?.suffix ?? 0) > 0)
        #expect(doc.title == "Real Title")
        #expect(doc.blocks == MarkdownParser.parse(next).blocks)
        // And on through later heading-free splices, lines added too.
        next = next.replacingOccurrences(of: "Preamble paragraph 4 before", with: "Preamble paragraph 4\nwith a line before")
        doc = p.parse(next)
        #expect(p.lastSpliced)
        #expect(doc.title == MarkdownParser.parse(next).title)
        #expect(doc.title == "Real Title")
    }

    /// 3.8 P4: in a document that defines no footnotes (and no links: it
    /// would parse in full), `[^` and `]:` after the change are text, not a
    /// reason to parse in full: regex classes, index signatures, citations.
    /// 3.7 parsed every version changed before such a line in full.
    @Test func definitionLikeTextAfterTheChangeIsSpliced() throws {
        let tail = "Match `([^/]*)` and `{ [key: string]: T }`, see [^1] and [x]: not at a line start.\n\n"
            + "```ts\n[k]: v\ntype M = { [key: string]: number }\n```\n\n"
            + (0..<20).map { "Later paragraph \($0) with a `[^a-z]+` class." }.joined(separator: "\n\n")
        let text = "# Doc\n\n" + (0..<20).map { "Paragraph \($0)." }.joined(separator: "\n\n") + "\n\n" + tail
        let p = IncrementalParser()
        _ = p.parse(text)
        for (i, next) in [
            text.replacingOccurrences(of: "Paragraph 10.", with: "Paragraph 10, edited."),
            text.replacingOccurrences(of: "Paragraph 10.", with: "Paragraph 10, edited.\n\nA new paragraph [^2] in between."),
            text.replacingOccurrences(of: "Paragraph 19.", with: "Paragraph 19 and [a]: b mid-line."),
        ].enumerated() {
            _ = p.parse(text)
            let doc = p.parse(next)
            #expect(p.lastSpliced, "\(i)")
            #expect(doc.blocks == MarkdownParser.parse(next).blocks && doc.title == MarkdownParser.parse(next).title, "\(i)")
        }
        // 04-rou3 has `([^x]*)` half way down: 46 of its 114 streaming versions spliced in 3.7.
        let k = try #require(CorpusTests.documents().firstIndex { $0.lastPathComponent.hasPrefix("04-") })
        let q = IncrementalParser()
        let versions = try Self.stream(k)
        var spliced = 0
        for (i, v) in versions.enumerated() {
            guard same(v, q, "rou3-\(i)") else { return }
            if q.lastSpliced { spliced += 1 }
        }
        #expect(spliced * 10 >= versions.count * 9, "spliced \(spliced) of \(versions.count)")
    }

    /// A change that makes a definition, its own or one it brings out of
    /// code (a fence closed or opened), is not spliced.
    @Test func aDefinitionTheChangeMakesIsNotSpliced() {
        let body = (0..<12).map { "Paragraph \($0) cites [ref] and [^n]." }.joined(separator: "\n\n")
        let text = "# Doc\n\nIntro.\n\n" + body + "\n\n```\n[ref]: https://example.com\n[^n]: in code\n```\n\nEnd."
        for next in [
            text.replacingOccurrences(of: "Paragraph 5 cites", with: "[ref]: https://example.com\n\nParagraph 5 cites"),
            text.replacingOccurrences(of: "Paragraph 5 cites", with: "[^n]: a note\n\nParagraph 5 cites"),
            text.replacingOccurrences(of: "Paragraph 5 cites", with: "  - [ref]: /in-a-list\n\nParagraph 5 cites"),
            // The fence before the definitions taken away: they are definitions now.
            text.replacingOccurrences(of: "\n\n```\n[ref]", with: "\n\n[ref]"),
            // A fence opened above them: closed by theirs, the old closing fence opens one.
            text.replacingOccurrences(of: "Paragraph 11 cites", with: "```\nParagraph 11 cites"),
        ] {
            let p = IncrementalParser()
            _ = p.parse(text)
            let doc = p.parse(next)
            let full = MarkdownParser.parse(next)
            #expect(doc.blocks == full.blocks && doc.title == full.title, "\(next.suffix(120))")
            #expect(!p.lastSpliced, "\(next.suffix(120))")
        }
    }

    /// A link definition whose label spans lines (`[foo` / `bar]: url`, the
    /// 3.8 review): the document parses in full, as for any definition, and
    /// a change that makes one is not spliced. 3.7 cut it into fragments, so
    /// a reference in another one did not link.
    @Test func aDefinitionWithItsLabelOnTwoLinesParsesInFull() {
        let defined = "Intro.\n\n[foo\nbar]: https://example.com\n\nSee [foo bar] here.\n\nMore."
        #expect(IncrementalParser.needsFullParse(MarkdownParser.sourceLines(defined)))
        #expect(IncrementalParser().parse(defined).blocks == MarkdownParser.parse(defined).blocks)
        #expect(MarkdownParser.parse(defined).blocks.contains { $0.html.contains("href=\"https://example.com\"") })
        let text = "# Doc\n\n" + (0..<12).map { "Paragraph \($0) cites [foo bar]." }.joined(separator: "\n\n")
        let p = IncrementalParser()
        _ = p.parse(text)
        let next = text.replacingOccurrences(of: "Paragraph 6 cites", with: "[foo\nbar]: https://example.com\n\nParagraph 6 cites")
        let doc = p.parse(next)
        #expect(!p.lastSpliced)
        #expect(doc.blocks == MarkdownParser.parse(next).blocks)
        // Not every `]:` after a `[` is one, but taking it for one only parses in full.
        let plain = "A [note that\ngoes on]: and more.\n\nNext."
        #expect(IncrementalParser().parse(plain).blocks == MarkdownParser.parse(plain).blocks)
    }

    /// `ParsedDocument.links` (Copy) after every kind of change to a link
    /// definition: one added, removed or edited, and one brought out of code
    /// by an edit elsewhere (a fence taken away or opened above it), each
    /// as the full parse has them; and a spliced document defines none.
    @Test func linksAfterAChangeAreTheFullParses() {
        let body = (0..<10).map { "Paragraph \($0) cites [x] and [y]." }.joined(separator: "\n\n")
        let code = "```\n[y]: https://y.example\n```"
        let plain = "# Doc\n\nIntro.\n\n" + body + "\n\n" + code + "\n\nEnd."
        let defined = plain.replacingOccurrences(of: "Paragraph 4 cites", with: "[x]: https://x.example\n\nParagraph 4 cites")
        let versions = [
            plain,
            defined,                                                                          // added
            defined.replacingOccurrences(of: "https://x.example", with: "https://x2.example"),  // edited
            plain,                                                                            // removed
            plain.replacingOccurrences(of: "\n\n```\n[y]", with: "\n\n[y]"),                  // out of code: fence taken away
            plain,
            plain.replacingOccurrences(of: "Paragraph 9 cites", with: "```\nParagraph 9 cites"),  // a fence opened above it
            plain + "\n\nMore after.",
        ]
        let p = IncrementalParser()
        for (i, v) in versions.enumerated() {
            let doc = p.parse(v), full = MarkdownParser.parse(v)
            #expect(doc.links == full.links, "version \(i): \(doc.links) vs \(full.links)")
            #expect(doc.blocks == full.blocks, "version \(i)")
            if p.lastSpliced { #expect(doc.links.isEmpty, "version \(i)") }
        }
        #expect(!MarkdownParser.parse(versions[1]).links.isEmpty && !MarkdownParser.parse(versions[4]).links.isEmpty)
    }

    /// What splicing does not cover parses as before.
    @Test(arguments: [
        ("crlf", "\r\nA new line."),
        ("marker", "\n\nA paragraph holding \u{E005} itself, *强调*的。"),
        ("link definition", "\n\n[ref]: https://example.com"),
        ("footnote", "\n\nA note.[^n]\n\n[^n]: The note."),
    ])
    func notSpliced(_ c: (String, String)) {
        let text = Self.corpusText(bytes: 30_000)
        let p = IncrementalParser()
        _ = p.parse(text)
        let next = text + c.1
        let doc = p.parse(next)
        #expect(!p.lastSpliced, "\(c.0)")
        #expect(doc.blocks == MarkdownParser.parse(next).blocks, "\(c.0)")
    }

    @Test func frontMatterEditIsNotSpliced() {
        let text = "---\ntitle: a\n---\n\n# T\n\n" + Self.corpusText(bytes: 20_000)
        let p = IncrementalParser()
        _ = p.parse(text)
        let next = text.replacingOccurrences(of: "title: a", with: "title: b")
        _ = p.parse(next)
        #expect(!p.lastSpliced)
        #expect(p.parse(next + "\n\nMore.").blocks == MarkdownParser.parse(next + "\n\nMore.").blocks)
        #expect(p.lastSpliced)
    }

    // MARK: Against the full parse

    /// The differential fuzzer's documents and edits (LF only; CRLF and BOM
    /// documents never splice): after every edit, exactly the full parse.
    @Test(arguments: 0..<seeds)
    func fuzz(_ seed: Int) {
        var rng = RNG(state: UInt64(seed) &* 7919 &+ 17)
        var lines: [String] = (0..<Int.random(in: 5...90, using: &rng)).map { _ in DifferentialFuzzTests.palette.randomElement(using: &rng)! }
        if seed % 8 == 0, let doc = CorpusTests.documents().randomElement(using: &rng),
           let s = try? String(contentsOf: doc, encoding: .utf8) { lines = s.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") }
        let p = IncrementalParser()
        guard same(lines.joined(separator: "\n"), p, "fuzz\(seed)-v0") else { return }
        for step in 0..<30 {
            for _ in 0..<Int.random(in: 1...3, using: &rng) { DifferentialFuzzTests.mutate(&lines, rng: &rng) }
            guard same(lines.joined(separator: "\n"), p, "fuzz\(seed)-step\(step)") else { return }
        }
    }

    /// Documents whose first H1 comes after a preamble (the fuzz palette's
    /// documents rarely have one), edited mostly in the preamble: the title
    /// is compared with the full parse's after every edit.
    @Test(arguments: 0..<seeds)
    func preambleFuzz(_ seed: Int) {
        var rng = RNG(state: UInt64(seed) &* 104_729 &+ 3)
        let intro = ["[![CI](https://example.com/badge.svg)](https://example.com)", "<p align=\"center\"><img src=\"logo.png\"></p>",
                     "An intro paragraph before the title.", "> [!NOTE]", "> A callout before the title.", "- a list item", "Plain text."]
        var lines: [String] = []
        for _ in 0..<Int.random(in: 3...12, using: &rng) { lines += [intro.randomElement(using: &rng)!, ""] }
        let h1 = lines.count
        lines += ["# Real Title", ""]
        lines += (0..<Int.random(in: 5...40, using: &rng)).map { _ in DifferentialFuzzTests.palette.randomElement(using: &rng)! }
        let p = IncrementalParser()
        guard same(lines.joined(separator: "\n"), p, "preamble\(seed)-v0") else { return }
        for step in 0..<20 {
            if Bool.random(using: &rng), min(h1, lines.count) > 2 {
                // An edit in the preamble, after its first lines.
                let at = Int.random(in: 2..<min(h1, lines.count), using: &rng)
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: lines[at] += " edited"
                case 1: lines.insert(intro.randomElement(using: &rng)!, at: at)
                default: lines.insert("", at: at)
                }
            } else {
                DifferentialFuzzTests.mutate(&lines, rng: &rng)
            }
            guard same(lines.joined(separator: "\n"), p, "preamble\(seed)-step\(step)") else { return }
        }
    }

    /// The versions of an agent writing a corpus document out: the text grows
    /// by up to a few hundred bytes at a time, cut anywhere (mid-line,
    /// mid-fence, mid-character), and now and then a line further up is edited.
    static func stream(_ k: Int) throws -> [String] {
        let docs = CorpusTests.documents()
        let full = try String(contentsOf: docs[k % docs.count], encoding: .utf8).replacingOccurrences(of: "\r", with: "")
        let bytes = Array(full.utf8)
        var rng = RNG(state: UInt64(k) &+ 99)
        var out: [String] = []
        var at = min(bytes.count, 300)
        var edits = 0
        let step = max(40, bytes.count / 60)
        while at < bytes.count {
            at = min(bytes.count, at + Int.random(in: 1...step, using: &rng))
            var text = String(decoding: bytes[..<at], as: UTF8.self)
            if Int.random(in: 0..<8, using: &rng) == 0, text.count > 200 {
                var ls = text.components(separatedBy: "\n")
                let i = Int.random(in: 0..<ls.count, using: &rng)
                ls[i] += " (edit \(edits))"; edits += 1
                text = ls.joined(separator: "\n")
            }
            out.append(text)
        }
        return out
    }

    @Test(arguments: 0..<12)
    func streaming(_ k: Int) throws {
        guard k < CorpusTests.documents().count else { return }
        let p = IncrementalParser()
        var spliced = 0
        let versions = try Self.stream(k)
        for (i, text) in versions.enumerated() {
            guard same(text, p, "stream\(k)-\(i)") else { return }
            if p.lastSpliced { spliced += 1 }
        }
        // Many versions are spliced: not those with link definitions (parsed in full
        // throughout), nor, in a document defining footnotes, those changed before a
        // `]:` or `[^` (definitionLikeTextAfterTheChangeIsSpliced).
        if !IncrementalParser.needsFullParse(MarkdownParser.sourceLines(versions.last ?? "")) {
            #expect(spliced * 3 >= versions.count, "spliced \(spliced) of \(versions.count)")
        }
    }

    /// The 3.8 audit's grown palette (`bugs/AuditB38Tests.swift`): CJK
    /// emphasis and emoji, footnotes and link definitions, HTML and details
    /// blocks, tabs, NBSP and ideographic space, nested containers, setext
    /// and math; and deep nesting (`NestingCap`). With its edits, front
    /// matter, a preamble, corpus documents, CRLF and BOM now and then.
    static let grownPalette: [String] = DifferentialFuzzTests.palette + [
        "**注意：**这里", "这是**加粗（括号）**的", "中文*强调*文字", "（*片*）", "**提示**：内容", "前文__下划线__后文",
        "- **项目：**说明", "> **提示：**内容", "1. **步骤一：**运行", "| **列：**值 | b |", "# 标题 **强调：**后",
        "## 小节", "## 小节", "emoji 😀 **粗体**😀", "👨‍👩‍👧 family **x**", "café\u{0301} *é*", "⚠️ **警告**：",
        "“**引号**”中文", "‘︁*x*’︁中", "漢\u{FE00}*字*", "**注意：**`code`后", "**注意：**$x$后", "**注意：**[^n]",
        "中文**\u{FE01}中文", "**注意**\u{FE0E}中文",
        "参考[^1]。", "[^1]: 脚注", "[^1]: 脚注 **强调：**后", "[^a]: note a", "Cite[^a] here.", "[ref]: https://example.com",
        "[ref]", "[text][ref]", "  [ref2]: <https://x.y> \"title\"", "- [def]: http://x", "> [q]: /quoted",
        "[链接](https://例子.com/路径)", "<https://example.com/**a**>", "https://example.com/注意：**x**",
        "Match `([^/]*)` here", "type M = { [key: string]: T }", "`[x]: y` in code",
        "<details>", "<summary>概要</summary>", "</details>", "<div align=\"center\">", "</div>", "<pre>", "</pre>",
        "<script>", "</script>", "<style>", "</style>", "<!--", "-->", "<img src=\"（*片*）.png\">", "<p>**注意：**中</p>",
        "<table>", "<tr><td>x</td></tr>", "</table>", "<?xml?>",
        "\t- tab item", "-\tdash tab", "- \tx", "  \t  ", "\u{00A0}", "- \u{00A0}", "- \u{3000}", "1.\tone", "*\tstar",
        "> > - nested", "> - > deep", "    > code?", "- > quoted", "  1. two", "     five", "\tcode", "| |", "|---|",
        "| | |", "|-|-|", "\t\tdouble tab", "- - - dash", "* * *", "+ [ ] plus task", "- [ ]\t tabbed task",
        "Setext", "===", "---", "+++", "title = \"x\"", "___", "***", "- - -",
        "$$", "\\begin{aligned}", "\\end{aligned}", "$$x$$", "\\(a\\)", "\\[b\\]",
        String(repeating: ">", count: 40) + " deep", String(repeating: "> - ", count: 12) + "x",
        String(repeating: "  ", count: 20) + "- deep item", String(repeating: "    ", count: 10) + "1. deep",
        String(repeating: "*a **b ", count: 12), String(repeating: "** b*", count: 12), String(repeating: "[![", count: 12) + "x",
        String(repeating: "](a.png)](b)", count: 12), String(repeating: "~~s ", count: 20), String(repeating: " t~~", count: 20),
        "", "", "",
    ]

    static func grownMutate(_ lines: inout [String], rng: inout RNG) {
        let at = lines.isEmpty ? 0 : Int.random(in: 0..<lines.count, using: &rng)
        switch Int.random(in: 0..<10, using: &rng) {
        case 0, 1: lines.insert(grownPalette.randomElement(using: &rng)!, at: at)
        case 2: if !lines.isEmpty { lines.remove(at: at) }
        case 3: if !lines.isEmpty { lines[at] += [" edited", "，改了", " 😀", "**", "：**这", "\t", "\u{FE0F}*"].randomElement(using: &rng)! }
        case 4: if !lines.isEmpty { lines.insert(lines[at], at: at) }
        case 5:
            if !lines.isEmpty, !lines[at].isEmpty {
                var s = Array(lines[at])
                let k = Int.random(in: 0..<s.count, using: &rng)
                if Bool.random(using: &rng) { s.remove(at: k) } else {
                    s.insert(["$", "`", "<", ">", " ", "*", "[", "]", "|", "-", "#", "\t", "~", "_", "中", "：", "（", "😀", "\u{3000}", "^", ":"]
                        .randomElement(using: &rng)!, at: k)
                }
                lines[at] = String(s)
            }
        case 6:
            if !lines.isEmpty { lines[at] = ["  ", "    ", "> ", "- ", "1. ", "\t", "-\t", "> > ", "   "].randomElement(using: &rng)! + lines[at] }
        case 7:
            // A line split in two.
            if !lines.isEmpty, lines[at].count > 1 {
                let s = Array(lines[at]); let k = Int.random(in: 1..<s.count, using: &rng)
                lines[at] = String(s[..<k]); lines.insert(String(s[k...]), at: at + 1)
            }
        case 8:
            // An agent writing on.
            lines += ["", ["The agent writes on.", "代理继续写，**注意：**这里。", "- next item", "## Next", "```", "| a | b |"].randomElement(using: &rng)!]
        default:
            if at + 1 < lines.count { lines[at] += lines.remove(at: at + 1) }
        }
    }

    /// Bounded for CI (`READOUT_FUZZ_SEEDS`); the audit ran 1,500 seeds of 40-60 steps.
    @Test(arguments: 0..<seeds)
    func grownFuzz(_ seed: Int) {
        var rng = RNG(state: UInt64(seed) &* 6_700_417 &+ 11)
        var lines: [String] = (0..<Int.random(in: 5...80, using: &rng)).map { _ in Self.grownPalette.randomElement(using: &rng)! }
        if seed % 6 == 1 { lines = ["---", "title: t", "---", ""] + lines }
        if seed % 6 == 2 { lines = ["[![CI](b.svg)](x)", "", "Intro **注意：**这里。", "", "# Title", ""] + lines }
        if seed % 10 == 3, let doc = CorpusTests.documents().randomElement(using: &rng),
           let s = try? String(contentsOf: doc, encoding: .utf8) { lines = s.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") }
        let crlf = seed % 11 == 10, bom = seed % 13 == 12
        func text() -> String { (bom ? "\u{FEFF}" : "") + lines.joined(separator: crlf ? "\r\n" : "\n") }
        let p = IncrementalParser()
        guard same(text(), p, "grown\(seed)-v0") else { return }
        for step in 0..<30 {
            for _ in 0..<Int.random(in: 1...3, using: &rng) { Self.grownMutate(&lines, rng: &rng) }
            guard same(text(), p, "grown\(seed)-step\(step)") else { return }
        }
    }

    // MARK: The session

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    /// One session given the splice's hints and one without them see the
    /// same versions, with reads in between: every patch, the marks, the
    /// baseline (and a relaunch from it) are the same.
    func sessionsAgree(_ versions: [String], seed: Int) {
        var rng = RNG(state: UInt64(seed) &+ 5)
        let p = IncrementalParser()
        let hinted = DocumentSession(), plain = DocumentSession()
        var first = p.parse(versions[0])
        _ = hinted.load(first)
        first.splice = nil; first.generation = 0
        _ = plain.load(first)
        var shared = 0
        for (i, text) in versions.dropFirst().enumerated() {
            let doc = p.parse(text)
            var bare = doc
            bare.splice = nil
            let a = hinted.update(doc), b = plain.update(bare)
            if hinted.lastShared.prefix + hinted.lastShared.suffix > 0 { shared += 1 }
            let ja = a.map { try! Self.encoder.encode($0) }, jb = b.map { try! Self.encoder.encode($0) }
            guard ja == jb, hinted.marks == plain.marks, hinted.deletions == plain.deletions,
                  hinted.baseline == plain.baseline, hinted.blocks == plain.blocks else {
                Issue.record("seed \(seed) step \(i): sessions differ\nhinted: \(ja.map { String(decoding: $0, as: UTF8.self).prefix(600) } ?? "nil")\nplain:  \(jb.map { String(decoding: $0, as: UTF8.self).prefix(600) } ?? "nil")")
                return
            }
            // Now and then the reader reads some of it, or all.
            switch Int.random(in: 0..<6, using: &rng) {
            case 0:
                let slots = hinted.marks.keys.sorted().filter { _ in Bool.random(using: &rng) }
                let ids = hinted.deletions.map(\.id).filter { _ in Bool.random(using: &rng) }
                hinted.markRead(slots: slots, deletionIDs: ids); plain.markRead(slots: slots, deletionIDs: ids)
            case 1:
                hinted.markAllRead(); plain.markAllRead()
            default: break
            }
            #expect(hinted.baseline == plain.baseline)
        }
        // A relaunch from either baseline marks the same.
        let last = MarkdownParser.parse(versions.last!)
        let r1 = DocumentSession(), r2 = DocumentSession()
        let pa = r1.load(last, baseline: SessionFixes37Tests.roundTrip(hinted.baseline))
        let pb = r2.load(last, baseline: SessionFixes37Tests.roundTrip(plain.baseline))
        #expect(try! Self.encoder.encode(pa) == (try! Self.encoder.encode(pb)))
        #expect(shared > 0 || versions.count < 4)
    }

    @Test(arguments: 0..<12)
    func sessionStreaming(_ k: Int) throws {
        guard k < CorpusTests.documents().count else { return }
        sessionsAgree(try Self.stream(k), seed: k)
    }

    @Test(arguments: 0..<(seeds / 2))
    func sessionFuzz(_ seed: Int) {
        var rng = RNG(state: UInt64(seed) &* 31 &+ 7)
        // Prose and headings with repeats (fingerprints occur more than once), tasks, lists.
        let palette = ["# Title", "## Notes", "## Steps", "Same paragraph.", "Same paragraph.", "- [ ] task", "- [x] done",
                       "Another paragraph here.", "```\ncode\n```", "> quote", "1. one", "Text with *emphasis*.", "| a | b |\n|---|---|\n| 1 | 2 |"]
        var paragraphs = (0..<Int.random(in: 30...60, using: &rng)).map { _ in palette.randomElement(using: &rng)! }
        var versions = [paragraphs.joined(separator: "\n\n")]
        for step in 0..<40 {
            let at = Int.random(in: 0...paragraphs.count, using: &rng)
            switch Int.random(in: 0..<7, using: &rng) {
            case 0, 1: paragraphs.append("Appended \(step).")
            case 2: paragraphs.insert(palette.randomElement(using: &rng)!, at: at)
            case 3: if at < paragraphs.count { paragraphs.remove(at: at) }
            case 4: if at < paragraphs.count { paragraphs[at] += " edited" }
            case 5: if at < paragraphs.count { paragraphs[at] = paragraphs[at].replacingOccurrences(of: "[ ]", with: "[x]") }
            default: if !paragraphs.isEmpty { paragraphs[paragraphs.count - 1] += " more" }
            }
            versions.append(paragraphs.joined(separator: "\n\n"))
        }
        sessionsAgree(versions, seed: seed)
    }
}
