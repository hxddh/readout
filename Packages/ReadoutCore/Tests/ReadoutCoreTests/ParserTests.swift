import Foundation
import Testing
@testable import ReadoutCore

@Suite struct HashTests {
    @Test func knownVectors() {
        #expect(XXHash64.hash("") == 0xEF46DB3751D8E999)
        #expect(XXHash64.hash("abc") == 0x44BC2CF5AD770999)
        let long = String(repeating: "Nobody inspects the spammish repetition", count: 3)
        #expect(XXHash64.hash(long) == XXHash64.hash(long))
        #expect(XXHash64.hash(long) != XXHash64.hash(long + "!"))
    }
}

@Suite struct ParserTests {
    func parse(_ s: String) -> ParsedDocument { MarkdownParser.parse(s) }

    @Test func splitsTopLevelBlocksAndListItems() {
        let doc = parse("""
        # Plan

        Intro paragraph.

        - one
        - two
        - [x] three

        ```swift
        let x = 1
        ```
        """)
        #expect(doc.blocks.map(\.kind) == [.heading, .paragraph, .listItem, .listItem, .listItem, .code])
        #expect(doc.title == "Plan")
        #expect(doc.blocks[0].anchor == "plan")
        #expect(doc.blocks[4].taskState == [true])
        #expect(doc.tasks == TaskStats(done: 1, total: 1))
        #expect(doc.blocks[1].headingPath == ["Plan"])
        #expect(doc.blocks[5].html.contains("data-lang=\"swift\""))
    }

    @Test func tightListsHaveNoParagraphs() {
        let tight = parse("- a\n- b\n")
        #expect(!tight.blocks[0].html.contains("<p>"))
        let loose = parse("- a\n\n- b\n")
        #expect(loose.blocks[0].html.contains("<p>"))
    }

    @Test func orderedListNumberingIsNotPartOfFingerprint() {
        let a = parse("1. first\n2. second\n")
        let b = parse("1. zero\n2. first\n3. second\n")
        #expect(a.blocks[0].fingerprint == b.blocks[1].fingerprint)
        #expect(a.blocks[0].html != b.blocks[1].html) // start number differs
    }

    @Test func checkboxStateIsNotPartOfFingerprint() {
        let a = parse("- [ ] ship it\n")
        let b = parse("- [x] ship it\n")
        #expect(a.blocks[0].fingerprint == b.blocks[0].fingerprint)
        #expect(a.blocks[0].taskState != b.blocks[0].taskState)
    }

    @Test func inlineMathIsProtected() {
        let doc = parse("Energy $E = m_c^2$ and $x_1$ cost $5 and $10.")
        let html = doc.blocks[0].html
        #expect(html.contains("data-tex=\"E = m_c^2\""))
        #expect(html.contains("data-tex=\"x_1\""))
        #expect(!html.contains("<em>"))
        #expect(html.contains("$5 and $10"))
    }

    @Test func mathInsideCodeIsUntouched() {
        let doc = parse("Use `$HOME/x_y` here.\n\n```sh\necho $a_b$\n```")
        #expect(doc.blocks[0].html.contains("<code>$HOME/x_y</code>"))
        #expect(doc.blocks[1].html.contains("echo $a_b$"))
    }

    @Test func displayMathBlock() {
        let doc = parse("$$\n\\sum_{i=1}^n x_i\n$$\n")
        #expect(doc.blocks.count == 1)
        #expect(doc.blocks[0].kind == .math)
        #expect(doc.blocks[0].html.contains("\\sum_{i=1}^n x_i"))
    }

    @Test func mermaidBlock() {
        let doc = parse("```mermaid\ngraph TD; A-->B\n```")
        #expect(doc.blocks[0].kind == .mermaid)
        #expect(doc.blocks[0].html.contains("A--&gt;B"))
    }

    @Test func alerts() {
        let doc = parse("> [!WARNING]\n> Do not run in prod.\n")
        #expect(doc.blocks[0].kind == .alert)
        #expect(doc.blocks[0].html.contains("alert-warning"))
        #expect(!doc.blocks[0].html.contains("[!WARNING]"))
        #expect(doc.blocks[0].html.contains("Do not run in prod."))
    }

    @Test func frontMatter() {
        let doc = parse("---\ntitle: \"Spec\"\nstatus: draft\n---\n\n# Body\n")
        #expect(doc.blocks[0].kind == .frontMatter)
        #expect(doc.blocks[0].html.contains("Spec"))
        #expect(doc.blocks[1].kind == .heading)
        #expect(doc.blocks[1].lines.lowerBound == 6)
    }

    @Test func tables() {
        let doc = parse("| a | b |\n|:--|--:|\n| 1 | 2 |\n")
        #expect(doc.blocks[0].kind == .table)
        #expect(doc.blocks[0].html.contains("text-align:right"))
        #expect(doc.blocks[0].html.contains("<td style=\"text-align:left\">1</td>"))
    }

    @Test func sanitizesHTML() {
        let doc = parse("<div onclick=\"x()\">hi</div>\n\n<script>alert(1)</script>\n")
        let html = doc.blocks.map(\.html).joined()
        #expect(!html.contains("onclick"))
        #expect(!html.contains("<script"))
    }

    @Test func remoteMediaRequiresConsent() {
        let doc = parse("<img src=\"https://evil.example/x.png\" alt=\"x\">\n\n<video src=\"https://evil.example/v.mp4\"></video>\n\n<img src=\"local/pic.png\">\n")
        let html = doc.blocks.map(\.html).joined()
        // No remote URL may remain in a loadable attribute; placeholders carry it in data-src only.
        #expect(!html.contains(" src=\"https://"))
        #expect(!html.contains(" src='https://"))
        #expect(!html.contains("<video"))
        #expect(html.contains("remote-img"))
        #expect(html.contains("data-src=\"https://evil.example/x.png\""))
        #expect(html.contains("local/pic.png"))
    }

    @Test func autolinksBareURLs() {
        let doc = parse("See https://example.com/a_b, then stop.")
        #expect(doc.blocks[0].html.contains("<a href=\"https://example.com/a_b\">"))
    }

    @Test func autolinkKeepsBalancedParens() {
        let doc = parse("See https://en.wikipedia.org/wiki/X_(film) end.")
        #expect(doc.blocks[0].html.contains("<a href=\"https://en.wikipedia.org/wiki/X_(film)\">"))
        let wrapped = parse("(see https://example.com/foo) done.")
        #expect(wrapped.blocks[0].html.contains("<a href=\"https://example.com/foo\">"))
        #expect(!wrapped.blocks[0].html.contains("foo)</a>"))
    }

    @Test func displayMathBrackets() {
        let doc = parse("Einstein said \\[E = mc^2\\] loudly.\n")
        #expect(doc.blocks[0].html.contains("data-tex=\"E = mc^2\""))
        #expect(!doc.blocks[0].html.contains("\\["))
    }

    @Test func duplicateHeadingSlugs() {
        let doc = parse("## Notes\n\n## Notes\n\n## 实现 细节\n")
        #expect(doc.blocks.map { $0.anchor } == ["notes", "notes-1", "实现-细节"])
    }

    @Test func reservedNamespaceEscapesWithHPrefix() {
        // UI element ids live under ro-*: document slugs must never enter it.
        var s = Slugger()
        #expect(s.next("RO Doc") == "h-ro-doc")
        #expect(s.next("Notice") == "notice")
        #expect(s.next("RO Doc") == "h-ro-doc-1")
    }

    @Test func explicitSlugCollisionStaysUnique() {
        let doc = parse("## Notes\n\n## Notes-1\n\n## Notes\n")
        let anchors = doc.blocks.map { $0.anchor }
        #expect(anchors[0] == "notes")
        #expect(anchors[1] == "notes-1")
        #expect(anchors[2] != "notes-1")
        #expect(Set(anchors).count == 3)
    }

    @Test func cjkDetection() {
        let doc = parse("这是一个中文段落，包含 English words。\n\nPlain English paragraph here.")
        #expect(doc.blocks[0].cjk)
        #expect(!doc.blocks[1].cjk)
    }

    @Test func tocWithSectionTasks() {
        var doc = parse("# A\n\n## B\n\n- [x] t1\n- [ ] t2\n\n## C\n\n- [ ] t3\n")
        for i in doc.blocks.indices { doc.blocks[i].slot = i + 1 }
        let toc = doc.toc()
        #expect(toc.map(\.title) == ["A", "B", "C"])
        #expect(toc[0].tasks == TaskStats(done: 1, total: 3))
        #expect(toc[1].tasks == TaskStats(done: 1, total: 2))
    }

    @Test func pathReferences() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("readout-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolver = FileResolver(baseDirectory: dir)
        let doc = MarkdownParser.parse("Look at `src/main.swift:42` and `1.2.3` and `missing/file.ts`.", resolver: resolver)
        let html = doc.blocks[0].html
        #expect(html.contains("class=\"path-link\""))
        #expect(html.contains("data-line=\"42\""))
        #expect(html.contains("<code>1.2.3</code>"))
        #expect(html.contains("<code>missing/file.ts</code>"))
    }

    @Test func imageSizes() {
        // 1x1 PNG header
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        png += [0, 0, 0x02, 0x80, 0, 0, 0x01, 0xE0] + [UInt8](repeating: 0, count: 10)
        #expect(ImageSize.parse(png)! == (640, 480))
        let gif: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x20, 0x00, 0x10, 0x00] + [UInt8](repeating: 0, count: 20)
        #expect(ImageSize.parse(gif)! == (32, 16))
    }
}
