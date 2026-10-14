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

    @Test func neutralizesNavigationTags() {
        // Task G probe: <meta http-equiv=refresh> navigates out when injected
        // raw. The product pipeline never executes it — sanitize escapes
        // every navigation-capable tag, and WKWebView cancels non-readout
        // navigations — but pin the sanitize behavior so it cannot regress.
        let doc = parse("<meta http-equiv=\"refresh\" content=\"0;url=https://evil.example/\">\n\n<base href=\"https://evil.example/\">\n\n<form action=\"https://evil.example/\"><input type=\"text\"></form>\n\n<link rel=\"stylesheet\" href=\"https://evil.example/x.css\">\n")
        let html = doc.blocks.map(\.html).joined()
        #expect(!html.contains("<meta"))
        #expect(!html.contains("<base"))
        #expect(!html.contains("<form"))
        #expect(!html.contains("<link"))
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

    /// Chinese items that name English identifiers read as CJK, whatever the
    /// identifiers' length or whether they are in inline code (corpus 21, 25, 27, 29).
    @Test func mixedChineseAndEnglishItemsClassifyTheSame() {
        let doc = parse("""
        - 将 PromptManager 重命名为 AbstractPromptManager 并抽象化
        - 修正 Gemini 直连 grounding 来源 index。
        - `ApiHandler` 收到 `WebSearchResults` 后会直接覆盖 `updatedMessage.webSearchResults`
        - helper MUST 不再读取、解析、缓存或依赖 TRUSTED_HTTP_PROXY_TERMINAL_IDS。
        - Use the 读取 helper for every request in the pipeline.
        - Plain English item with `代码` in code.
        """)
        #expect(doc.blocks.map(\.cjk) == [true, true, true, true, false, false])
    }

    /// English lines that mention a CJK word stay Latin: a run of CJK
    /// characters counts about one unit per two characters, like a word.
    @Test func englishLinesMentioningACJKWordStayLatin() {
        let doc = parse("""
        # Glossary

        - Translate 你好 as hello
        - Click 保存 to save the file.
        - Japanese: 日本語 means Japanese language.
        - 用 Swift 编写
        - 使用 `npm install` 安装依赖
        - Save often.
        """)
        #expect(doc.blocks.map(\.cjk) == [false, false, false, false, true, true, false])
        // Such a line in a Chinese document reads like its neighbours (corpus 21, 27, 29).
        let zh = parse("## Task 2: 更新 README.md\n\n这是一个中文段落。\n\n另一个中文段落。\n\n- Translate 你好 as hello\n")
        #expect(zh.blocks.map(\.cjk) == [true, true, true, true])
        let en = parse("## Task 2: 更新 README.md\n\nAn English paragraph.\n")
        #expect(en.blocks.map(\.cjk) == [false, false])
    }

    @Test func numberedListsWithWideNumbersCarryTheirWidth() {
        let wide = parse("98. a\n99. b\n100. c\n")
        #expect(wide.blocks.count == 3)
        #expect(wide.blocks.allSatisfy { $0.html.hasPrefix("<ol class=\"li-block") && $0.html.contains(" ol-w3\"") })
        #expect(parse("9998. a\n9999. b\n").blocks.allSatisfy { $0.html.contains(" ol-w4\"") })
        #expect(parse("123456. a\n").blocks[0].html.contains(" ol-w5\""))
        let narrow = parse("1. a\n2. b\n").blocks.map(\.html).joined()
        #expect(!narrow.contains("ol-w"))
        // A nested list is sized by its own numbers.
        let nested = parse("1. a\n\n   100. b\n   101. c\n").blocks[0].html
        #expect(nested.contains("<ol class=\"ol-w3\" start=\"100\">"))
    }

    @Test func numericColumnsAreMarked() {
        let doc = parse("""
        | Name | Time | Share | Size | Note | Price |
        |------|------|-------|-----:|------|-------|
        | a | 12 ms | 45% | 3 GiB | v2 | $5 |
        | b | 1,204.5 ms | −3% | 512 MB | 7 | ~10k |
        | c |  | 0.5% | 1 KB | x | ≈ 2.5× |
        """)
        let h = doc.blocks[0].html
        #expect(h.contains("<th>Name</th><th class=\"num\">Time</th><th class=\"num\">Share</th><th style=\"text-align:right\">Size</th><th>Note</th><th class=\"num\">Price</th>"))
        #expect(h.contains("<td>a</td><td class=\"num\">12 ms</td><td class=\"num\">45%</td><td style=\"text-align:right\">3 GiB</td><td>v2</td><td class=\"num\">$5</td>"))
        #expect(h.contains("<td class=\"num\"></td>"))
        // A column with no numbers at all is not numeric.
        #expect(!parse("| a |\n|---|\n|  |\n").blocks[0].html.contains("num"))
    }

    @Test func rawHTMLSrcsetCandidatesResolve() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("readout-srcset-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolver = FileResolver(baseDirectory: dir)
        let a = ReadoutURL.file(dir.appendingPathComponent("a.png").standardizedFileURL.path)
        let b = ReadoutURL.file(dir.appendingPathComponent("b.png").standardizedFileURL.path)
        let h = MarkdownParser.parse("<img srcset=\"a.png 2x, b.png 1x\" src=\"a.png\">\n", resolver: resolver).blocks[0].html
        #expect(h.trimmingCharacters(in: .newlines) == "<img srcset=\"\(a) 2x, \(b) 1x\" src=\"\(a)\">")
        // A remote candidate anywhere in the tag needs consent.
        let remote = MarkdownParser.parse("<img src=\"a.png\" srcset=\"https://example.com/a.png 2x\">\n", resolver: resolver).blocks[0].html
        #expect(remote.contains("class=\"remote-img\"") && remote.contains("data-src=\"https://example.com/a.png\""))
        #expect(!remote.contains("<img"))
        // A `>` inside a quoted path is part of it.
        let gt = ReadoutURL.file(dir.appendingPathComponent("a>b.png").standardizedFileURL.path)
        let quoted = MarkdownParser.parse("<img src=\"a>b.png\" alt=\"x\">\n", resolver: resolver).blocks[0].html
        #expect(quoted.trimmingCharacters(in: .newlines) == "<img src=\"\(HTML.escape(gt))\" alt=\"x\">")
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

    @Test func localImagesWithQueryFragmentOrRawHTMLResolve() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("readout-img-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        png += [0, 0, 0x02, 0x80, 0, 0, 0x01, 0xE0] + [UInt8](repeating: 0, count: 10)
        try Data(png).write(to: dir.appendingPathComponent("shot.png"))
        let resolver = FileResolver(baseDirectory: dir)
        let file = ReadoutURL.file(dir.appendingPathComponent("shot.png").standardizedFileURL.path)
        for src in ["shot.png?raw=true", "shot.png#gh-dark-mode-only"] {
            let r = resolver.image(src)
            #expect(r.url == file, "\(src)")
            #expect(r.width == 640 && r.height == 480, "\(src)")
        }
        let doc = MarkdownParser.parse("""
        <p align="center"><img src="shot.png" width="200"></p>

        Inline <img src='./shot.png?raw=true'> and <img src="https://example.com/x.png"> and <img src="data:image/png;base64,AA==">.
        """, resolver: resolver)
        #expect(doc.blocks[0].html.hasPrefix("<p align=\"center\"><img src=\"\(file)\" width=\"200\"></p>"))
        let inline = doc.blocks[1].html
        #expect(inline.contains("<img src=\"\(file)\">"))
        #expect(inline.contains("class=\"remote-img\""))
        #expect(inline.contains("src=\"data:image/png;base64,AA==\""))
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

@Suite struct EdgeCaseTests35 {
    func parse(_ s: String, resolver: ResourceResolver? = nil) -> ParsedDocument { MarkdownParser.parse(s, resolver: resolver) }

    @Test func unbalancedQuoteDoesNotSwallowAcrossTags() {
        let resolver = FileResolver(baseDirectory: URL(fileURLWithPath: "/tmp/readout-doc"))
        let local = ReadoutURL.file("/tmp/readout-doc/local.png")
        let h = HTML.sanitize("<p><img alt='it's fine' src=\"local.png\"> Don't miss this. <img src=\"https://x/y.png\"></p>",
                              resolver: resolver)
        #expect(h == "<p><img alt='it's fine' src=\"\(HTML.escape(local))\"> Don't miss this. "
                + "<span class=\"remote-img\" data-tag=\"img\" data-src=\"https://x/y.png\" data-alt=\"\"></span></p>")
        // An unbalanced quote after the source: the tag still ends at its `>`.
        let after = HTML.sanitize("<img src=\"https://x/a.png\" alt='it's'> Don't <b>go</b>")
        #expect(after == "<span class=\"remote-img\" data-tag=\"img\" data-src=\"https://x/a.png\" data-alt=\"\"></span> Don't <b>go</b>")
        // Through the parser (in an HTML block), too: the text and the local image survive.
        let md = parse("<div>\n<img alt='it's fine' src=\"local.png\"> Don't miss this. <img src=\"https://x/y.png\">\n</div>\n",
                       resolver: resolver).blocks[0].html
        #expect(md.contains("Don't miss this."))
        #expect(md.contains("src=\"\(HTML.escape(local))\""))
        #expect(md.components(separatedBy: "remote-img").count == 2)
    }

    @Test func quotedValuesStillHoldGtAndBareLt() {
        let gt = HTML.sanitize("<img alt=\"x > y\" src=\"https://e.com/a.png\">")
        #expect(gt == "<span class=\"remote-img\" data-tag=\"img\" data-src=\"https://e.com/a.png\" data-alt=\"\"></span>")
        let lt = HTML.sanitize("<img alt=\"a < b\" src=\"https://e.com/a.png\">")
        #expect(lt == "<span class=\"remote-img\" data-tag=\"img\" data-src=\"https://e.com/a.png\" data-alt=\"\"></span>")
        // `src=` inside a quoted value of a tag whose quotes pair up is text, not a source.
        let titled = "<video title=\"example src=https://e/x\"><source src=\"local.mp4\"></video>"
        #expect(HTML.sanitize(titled) == titled)
        // A tag-like `<` inside a quoted value stays in it, before or after the source.
        let ltTag = "<span class=\"remote-img\" data-tag=\"img\" data-src=\"https://e/x.png\" data-alt=\"\"></span>"
        #expect(HTML.sanitize("<img src=\"https://e/x.png\" alt=\"x<y\">") == ltTag)
        #expect(HTML.sanitize("<img alt=\"x<y\" src=\"https://e/x.png\">") == ltTag)
        // An unbalanced quote at the end of the input does not swallow the text after the tag.
        #expect(HTML.sanitize("<img src=\"https://e/x.png\" alt='it's'>Don't") == ltTag + "Don't")
        // A tag cut short at the end of the input is still gated.
        #expect(HTML.sanitize("<img src=\"https://e.com/a.png\"").contains("remote-img"))
    }

    @Test func unbalancedQuotesStayLinear() {
        // Quadratic scanning would take minutes here; linear takes milliseconds.
        let body = (0..<20000).map { _ in "<img alt=\"a\" width=\"10\">" }.joined(separator: "\n")
        for variant in ["<img alt=\"oops>\n", "<img alt='it>\n", "<img src=\"a.png\" alt='it>\n"] {
            let t0 = Date()
            let out = HTML.sanitize("<div>\n" + variant + body + "\n</div>")
            #expect(Date().timeIntervalSince(t0) < 2)
            #expect(out.hasSuffix("</div>"))
        }
    }

    @Test func emptyHeadingIsNoTitle() {
        #expect(parse("#\n\ntext").title == nil)
        #expect(parse("# <img src=\"logo.png\">\n\ntext").title == nil)
        #expect(parse("# ![](logo.png)\n\nx").title == nil)
        #expect(parse("#   \n## Real\n").title == nil)
        // The first H1 with text names the document.
        #expect(parse("# ![](logo.png)\n\n# Readout\n").title == "Readout")
        #expect(IncrementalParser().parse("# ![](logo.png)\n\ntext").title == nil)
    }

    @Test func mathInTitleLosesDelimiters() {
        #expect(parse("# $O(n^2)$ plan\n").title == "O(n^2) plan")
        #expect(parse("# \\(O(n)\\) plan\n").title == "O(n) plan")
        #expect(parse("# Cost $x$ and $y$\n").title == "Cost x and y")
    }

    @Test func versionsAndIDsAreNotNumbers() {
        for s in ["1.0.0", "10.0.0.1", "1.", "2.", "1,23", "12,34,567", "1,2345", "1.2.3 ms", "3.4."] {
            #expect(!HTMLRenderer.isNumber(s), "\(s)")
        }
        for s in ["3.4", "1,234", "12 ms", "98%", "-0.5", "1,204.5 ms", "1,234,567", ".5", "2026", "~10k", "$5", "−3%", "0.5%"] {
            #expect(HTMLRenderer.isNumber(s), "\(s)")
        }
        let versions = parse("| Version | Notes |\n|---|---|\n| 1.0.0 | first |\n| 1.1.0 | second |\n").blocks[0].html
        #expect(!versions.contains("num"))
        let steps = parse("| Step | What |\n|---|---|\n| 1. | Do it |\n| 2. | Then |\n").blocks[0].html
        #expect(!steps.contains("num"))
    }
}
