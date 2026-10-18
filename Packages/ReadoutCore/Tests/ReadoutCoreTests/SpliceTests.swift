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
        // throughout), nor those changed before a `]:` or `[^` (04-rou3 has `([^x]*)`
        // half way down: 46 of its 114 versions are spliced).
        if !IncrementalParser.needsFullParse(MarkdownParser.sourceLines(versions.last ?? "")) {
            #expect(spliced * 3 >= versions.count, "spliced \(spliced) of \(versions.count)")
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
