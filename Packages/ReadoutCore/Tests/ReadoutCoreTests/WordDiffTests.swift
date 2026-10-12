import Foundation
import Testing
@testable import ReadoutCore

@Suite struct WordDiffTests {
    typealias S = WordDiff.Segment

    @Test func mixedChineseAndEnglish() {
        let segs = WordDiff.segments(old: "使用 Redis 缓存会话数据", new: "使用 Postgres 存储会话数据")
        #expect(segs == [.equal("使用 "), .deleted("Redis 缓"), .inserted("Postgres 储"), .equal("存会话数据")]
                || segs == [.equal("使用 "), .deleted("Redis 缓存"), .inserted("Postgres 存储"), .equal("会话数据")])
        // Chinese compares character by character, English word by word.
        let words = WordDiff.segments(old: "the quick fox", new: "the slow fox")
        #expect(words == [.equal("the "), .deleted("quick"), .inserted("slow"), .equal(" fox")])
    }

    @Test func punctuationOnly() {
        let segs = WordDiff.segments(old: "Done, finally.", new: "Done; finally!")
        #expect(segs == [.equal("Done"), .deleted(","), .inserted(";"), .equal(" finally"), .deleted("."), .inserted("!")])
        let cjk = WordDiff.segments(old: "完成，然后发布。", new: "完成；然后发布！")
        #expect(cjk == [.equal("完成"), .deleted("，"), .inserted("；"), .equal("然后发布"), .deleted("。"), .inserted("！")])
    }

    @Test func wholeRewriteIsOneDeletionAndOneInsertion() {
        let segs = WordDiff.segments(old: "Ship it on Monday after review.", new: "Hold the launch until QA signs off.")
        let deleted = segs.compactMap { if case let .deleted(t) = $0 { t } else { nil } }.joined()
        let inserted = segs.compactMap { if case let .inserted(t) = $0 { t } else { nil } }.joined()
        #expect(deleted.contains("Ship it on Monday after review"))
        #expect(inserted.contains("Hold the launch until QA signs off"))
        #expect(segs.filter { if case .equal = $0 { true } else { false } }.allSatisfy {
            if case let .equal(t) = $0 { t.count <= 2 } else { false } })
    }

    @Test func tableCellChange() {
        let old = "| Tigris | 支持 | 未知 | 最终一致 | 33 |"
        let new = "| Tigris | 支持 | 不支持 | 最终一致 | 33 |\n| Ceph RGW | 支持 | 支持 | 强一致 | 27 |"
        let html = WordDiff.html(old: old, new: new)
        #expect(html.contains("<del>未知</del>"))
        #expect(html.contains("<ins>不支持</ins>"))
        #expect(html.contains("<ins>\n| Ceph RGW | 支持 | 支持 | 强一致 | 27 |</ins>"))
    }

    @Test func htmlIsEscaped() {
        let html = WordDiff.html(old: "use <b>bold</b> & co", new: "use <i>it</i> & co")
        #expect(!html.contains("<b>") && !html.contains("<i>"))
        #expect(html.contains("&lt;"))
        #expect(html.contains("&amp; co"))
        #expect(html.contains("<del>") && html.contains("<ins>"))
    }

    @Test func longUnchangedRunsAreShortened() {
        let long = String(repeating: "word ", count: 100)
        let html = WordDiff.html(old: long + "old " + long, new: long + "new " + long)
        #expect(html.contains("…"))
        #expect(html.count < 500)
        #expect(html.contains("<del>old</del><ins>new</ins>"))
    }

    @Test func decomposedHangulComparesBySyllable() {
        // 한국 → 한글 in decomposed form (NFD): only the second syllable changed.
        let old = "한국".decomposedStringWithCanonicalMapping, new = "한글".decomposedStringWithCanonicalMapping
        let segs = WordDiff.segments(old: old, new: new)
        #expect(segs.first == .equal("한".decomposedStringWithCanonicalMapping), "\(segs)")
        #expect(segs.contains(.deleted("국".decomposedStringWithCanonicalMapping)) && segs.contains(.inserted("글".decomposedStringWithCanonicalMapping)), "\(segs)")
    }

    @Test func charactersAreNeverSplit() {
        for (a, b) in [("hi 👋🏻 there", "hi 👋🏿 there"), ("love ❤️ it", "love ❤ it"), ("key 1️⃣ ok", "key 2️⃣ ok"),
                       ("cafe\u{301} au lait", "cafe\u{300} au lait"), ("今日は良い天気", "今日は悪い天気"),
                       ("→\u{1AB0} x", "→\u{1AB1} x"), ("a→\u{1AB0}", "a→\u{1AB1}"),
                       ("xa\u{1AB0}y", "xa\u{1AB1}y"), ("say xa\u{1AB0} now", "say xa\u{1AB1} now"),
                       ("a\u{20DD} b", "a\u{20DE} b"), ("नमस्ते दुनिया", "नमस्ता दुनिया"),
                       ("  ", "  \u{093F}"), ("\u{1100}가", "가"), ("x \u{1100}\u{1161}\u{11A8} y", "x \u{1100}\u{1161} y")] {
            let segs = WordDiff.segments(old: a, new: b)
            let old = segs.map { if case let .equal(t) = $0 { t } else if case let .deleted(t) = $0 { t } else { "" } }.joined()
            let new = segs.map { if case let .equal(t) = $0 { t } else if case let .inserted(t) = $0 { t } else { "" } }.joined()
            #expect(old == a && new == b)
            // Every cut falls on a character boundary of both texts.
            var oldAt = a.startIndex, newAt = b.startIndex
            for seg in segs {
                switch seg {
                case let .equal(t):
                    oldAt = a.utf8.index(oldAt, offsetBy: t.utf8.count); newAt = b.utf8.index(newAt, offsetBy: t.utf8.count)
                case let .deleted(t): oldAt = a.utf8.index(oldAt, offsetBy: t.utf8.count)
                case let .inserted(t): newAt = b.utf8.index(newAt, offsetBy: t.utf8.count)
                }
                #expect(oldAt == a.endIndex || a.indices.contains(oldAt), "\(a) → \(segs)")
                #expect(newAt == b.endIndex || b.indices.contains(newAt), "\(b) → \(segs)")
            }
            // Every piece starts on a character boundary of its text.
            for seg in segs {
                if case let .equal(t) = seg { #expect(t.unicodeScalars.first.map { $0.properties.generalCategory != .nonspacingMark && $0.value != 0xFE0F && $0.value != 0x20E3 && !(0x1F3FB...0x1F3FF).contains($0.value) } ?? true, "\(a) → \(segs)") }
            }
            // Deletions come before insertions.
            for (x, y) in zip(segs, segs.dropFirst()) {
                if case .inserted = x, case .deleted = y { Issue.record("insertion before deletion: \(segs)") }
            }
        }
    }

    @Test func wholeRewritesOfLargeBlocksAreShownReplaced() {
        // Past the edit budget the comparison gives up rather than stall:
        // checked by its result, not by timing (which depends on the machine).
        let a = (1...4000).map { "row \($0 % 7) alpha" }.joined(separator: "\n")
        let b = (1...4000).map { "row \($0 % 5) beta" }.joined(separator: "\n")
        let segs = WordDiff.segments(old: a, new: b)
        #expect(segs.filter { if case .equal = $0 { false } else { true } }.count <= 2)
        #expect(WordDiff.html(old: a, new: b).count < 6000)   // long changes show their two ends
        // Same lines, another order.
        let lines = (1...4000).map { "step \($0) done" }
        let reordered = WordDiff.segments(old: lines.joined(separator: "\n"), new: lines.reversed().joined(separator: "\n"))
        #expect(reordered.filter { if case .equal = $0 { false } else { true } }.count <= 2)
    }

    @Test func oneWorkBudgetCoversTheWholeBlock() {
        // Many rewritten lines between unchanged ones: each run is compared within
        // what is left of one budget for the block, so the later runs are shown
        // replaced whole instead of each getting a full allowance of its own.
        var seed: UInt64 = 7
        func punct(_ n: Int) -> String {
            let chars = Array("!#$%&*+,-./:;<=>?@^~|")
            return String((0..<n).map { _ in seed = seed &* 6364136223846793005 &+ 1442695040888963407; return chars[Int(seed >> 33) % chars.count] })
        }
        var old: [String] = [], new: [String] = []
        for i in 0..<50 {
            // Each rewrite on its own is within reach (about 630 differences of 3,800 tokens).
            let line = punct(1900)
            let edited = String(line.enumerated().map { $0.offset % 6 == 0 ? "a" : $0.element })
            old.append("same line \(i)"); new.append("same line \(i)"); old.append(line); new.append(edited)
        }
        let segs = WordDiff.segments(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        let lastOld = old[old.count - 1], lastNew = new[new.count - 1]
        #expect(segs.contains { if case let .deleted(t) = $0 { t.contains(lastOld.prefix(1800)) } else { false } })
        #expect(segs.contains { if case let .inserted(t) = $0 { t.contains(lastNew.prefix(1800)) } else { false } })
        // The first run was compared token by token.
        #expect(segs.contains { if case .inserted("a") = $0 { true } else { false } })
        // Still a faithful comparison of the two texts.
        let o = segs.map { if case let .equal(t) = $0 { t } else if case let .deleted(t) = $0 { t } else { "" } }.joined()
        let n = segs.map { if case let .equal(t) = $0 { t } else if case let .inserted(t) = $0 { t } else { "" } }.joined()
        #expect(o == old.joined(separator: "\n") && n == new.joined(separator: "\n"))
    }

    @Test func myersIsMinimalAndConsistent() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let a = (0..<Int.random(in: 0...30, using: &rng)).map { _ in Int.random(in: 0...4, using: &rng) }
            let b = (0..<Int.random(in: 0...30, using: &rng)).map { _ in Int.random(in: 0...4, using: &rng) }
            guard let (removed, added) = WordDiff.myers(a, b, maxD: 100) else { Issue.record("gave up"); continue }
            // Kept tokens pair up in order and are equal.
            let keptA = a.indices.filter { !removed[$0] }.map { a[$0] }
            let keptB = b.indices.filter { !added[$0] }.map { b[$0] }
            #expect(keptA == keptB)
            // As few edits as the standard library's difference.
            #expect(removed.filter { $0 }.count + added.filter { $0 }.count == b.difference(from: a).count)
        }
        #expect(WordDiff.myers([1, 2, 3], [4, 5, 6], maxD: 2) == nil)
    }

    @Test func longBlocksCompareLinesThenWords() {
        let lines = (1...8000).map { "line \($0) of the log" }
        var edited = lines
        // Changes at both ends: everything between them is compared.
        edited[0] = "line 1 of the LOG"
        edited[4000] = "line 4001 of the LOG"
        edited[7999] = "line 8000 of the LOG"
        let segs = WordDiff.segments(old: lines.joined(separator: "\n"), new: edited.joined(separator: "\n"))
        #expect(segs.filter { $0 == .deleted("log") }.count == 3)
        #expect(segs.filter { $0 == .inserted("LOG") }.count == 3)
        #expect(segs.count == 9)
    }
}

@Suite struct SessionDiffTests {
    func doc(_ s: String) -> ParsedDocument { MarkdownParser.parse(s) }

    @Test func modifiedMarksCarryTheComparisonWithWhatWasRead() throws {
        let session = DocumentSession()
        _ = session.load(doc("# T\n\nThe plan uses Redis.\n\nOther text.\n"))
        let p1 = try #require(session.update(doc("# T\n\nThe plan uses Postgres.\n\nOther text.\n")))
        let m1 = try #require(p1.marks.first { $0.kind == .modified })
        #expect(m1.diff == "The plan uses <del>Redis</del><ins>Postgres</ins>.")
        // A second edit is still compared with the text as read, not the previous edit.
        let p2 = try #require(session.update(doc("# T\n\nThe plan uses Postgres 16.\n\nOther text.\n")))
        let m2 = try #require(p2.marks.first { $0.kind == .modified })
        #expect(m2.diff == "The plan uses <del>Redis</del><ins>Postgres 16</ins>.")
        // Once read, the next change starts from there.
        session.markAllRead()
        let p3 = try #require(session.update(doc("# T\n\nThe plan uses Postgres 17.\n\nOther text.\n")))
        #expect(p3.marks.first { $0.kind == .modified }?.diff == "The plan uses Postgres <del>16</del><ins>17</ins>.")
        // Inserted blocks have no comparison.
        let p4 = try #require(session.update(doc("# T\n\nThe plan uses Postgres 17.\n\nOther text.\n\nNew one.\n")))
        #expect(p4.marks.first { $0.kind == .inserted }?.diff == nil)
        // Changed back to what was read: no longer marked.
        let p5 = try #require(session.update(doc("# T\n\nThe plan uses Postgres 16.\n\nOther text.\n\nNew one.\n")))
        #expect(!p5.marks.contains { $0.kind == .modified })
        // Edited, then removed before being read: the deletion shows what was read.
        _ = session.update(doc("# T\n\nThe plan uses Postgres 18.\n\nOther text.\n\nNew one.\n"))
        let p6 = try #require(session.update(doc("# T\n\nOther text.\n\nNew one.\n")))
        #expect(p6.deletions.last?.preview == "The plan uses Postgres 16.")
    }

    @Test func aTickedTaskBackToItsReadTextIsAStateChange() throws {
        let session = DocumentSession()
        _ = session.load(doc("- [ ] write the test\n"))
        _ = session.update(doc("- [ ] write the test EDITED\n"))
        let p = try #require(session.update(doc("- [x] write the test\n")))
        #expect(p.marks.map(\.kind) == [.state])
        // Ticked first, then edited and changed back: still the tick to read.
        let s2 = DocumentSession()
        _ = s2.load(doc("- [ ] write the test\n"))
        _ = s2.update(doc("- [x] write the test\n"))
        _ = s2.update(doc("- [x] write the test EDITED\n"))
        let p2 = try #require(s2.update(doc("- [x] write the test\n")))
        #expect(p2.marks.map(\.kind) == [.state])
    }

    @Test func comparisonsAndRemovedTextsAreSentOnce() throws {
        let session = DocumentSession()
        _ = session.load(doc("# T\n\nThe plan uses Redis.\n\nDrop me.\n\nOther text.\n\nMore.\n\nEnd.\n"))
        let p1 = try #require(session.update(doc("# T\n\nThe plan uses Postgres.\n\nOther text.\n\nMore.\n\nEnd.\n")))
        #expect(p1.marks.first { $0.kind == .modified }?.diff?.contains("<ins>Postgres</ins>") == true)
        #expect(p1.deletions.first?.preview == "Drop me.")
        // A later patch that leaves them alone does not carry them again.
        let p2 = try #require(session.update(doc("# T\n\nThe plan uses Postgres.\n\nOther text.\n\nMore.\n\nEnd, changed.\n")))
        let kept = try #require(p2.marks.first { $0.slot == p1.marks.first { $0.kind == .modified }?.slot })
        #expect(kept.kind == .modified && kept.diff == nil)
        #expect(p2.deletions.count == 1 && p2.deletions[0].preview == nil)
        // A block edited again carries its new comparison.
        let p3 = try #require(session.update(doc("# T\n\nThe plan uses Postgres 16.\n\nOther text.\n\nMore.\n\nEnd, changed.\n")))
        #expect(p3.marks.first { $0.slot == kept.slot }?.diff?.contains("<ins>Postgres 16</ins>") == true)
        // A full payload (a reloaded page) carries everything.
        let full = session.fullPayload(rewrite: false)
        #expect(full.marks.first { $0.slot == kept.slot }?.diff != nil)
        #expect(full.deletions.first?.preview == "Drop me.")
    }

    @Test func oneUpdateSharesOneComparisonBudget() throws {
        // Twenty large code blocks, every third line edited: the first are compared
        // word by word, the rest are shown replaced whole, so the update stays quick.
        func block(_ b: Int, edited: Bool) -> String {
            "```\n" + (0..<1200).map { i in "let v\(b)_\(i) = compute(\(i), \(edited && i % 3 == 0 ? "changed" : "same"))" }
                .joined(separator: "\n") + "\n```"
        }
        let pad = (1...60).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        let v1 = pad + "\n\n" + (0..<20).map { block($0, edited: false) }.joined(separator: "\n\n")
        let v2 = pad + "\n\n" + (0..<20).map { block($0, edited: true) }.joined(separator: "\n\n")
        let session = DocumentSession()
        _ = session.load(doc(v1))
        let p = try #require(session.update(doc(v2)))
        let diffs = p.marks.compactMap(\.diff)
        #expect(diffs.count == 20)
        #expect(diffs.contains { $0.contains("<ins>changed</ins>") })
        #expect(diffs.last.map { !$0.contains("<ins>changed</ins>") } == true)
    }

    @Test func aTaskEditedRevertedAndUntickedIsNotMarked() throws {
        let session = DocumentSession()
        _ = session.load(doc("- [ ] write the test\n- [ ] ship\n"))
        _ = try #require(session.update(doc("- [x] write the test\n- [ ] ship\n")))
        _ = try #require(session.update(doc("- [x] write the tests\n- [ ] ship\n")))
        let back = try #require(session.update(doc("- [x] write the test\n- [ ] ship\n")))
        #expect(back.marks.map(\.kind) == [.state])
        let unticked = try #require(session.update(doc("- [ ] write the test\n- [ ] ship\n")))
        #expect(unticked.marks.isEmpty)
    }

    @Test func aLargeLoneChangeIsNotSlid() {
        // A big deletion whose end matches the text before it is left where the
        // comparison put it (sliding it would cost time in proportion to its size).
        #expect(WordDiff.slide([.equal("a -+"), .deleted(String(repeating: "-+", count: 3000)), .equal(" b")])
                == [.equal("a -+"), .deleted(String(repeating: "-+", count: 3000)), .equal(" b")])
        let big = String(repeating: "-+", count: 400_000)
        let a = "start -+" + big + " end", b = "start -+ end"
        let segs = WordDiff.segments(old: a, new: b)
        let o = segs.map { if case let .equal(x) = $0 { x } else if case let .deleted(x) = $0 { x } else { "" } }.joined()
        #expect(o == a)
    }

    @Test func aTaskTickedAndUntickedBeforeReadingIsNotMarked() throws {
        let session = DocumentSession()
        _ = session.load(doc("- [ ] write the test\n- [ ] ship\n"))
        let p1 = try #require(session.update(doc("- [x] write the test\n- [ ] ship\n")))
        #expect(p1.marks.map(\.kind) == [.state])
        let p2 = try #require(session.update(doc("- [ ] write the test\n- [ ] ship\n")))
        #expect(p2.marks.isEmpty)
    }

    @Test func persistedBaselineWithoutWholeTextSaysSo() throws {
        let long = String(repeating: "alpha beta gamma ", count: 40)   // over 500 characters
        let v1 = doc("Intro.\n\n" + long + "\n")
        // A baseline saved by an older version: text cut at 500, no whole text.
        let oldFormat = try JSONDecoder().decode([BlockKey].self, from: JSONEncoder().encode(v1.blocks.map(BlockKey.init))
            .replacingFull())
        #expect(oldFormat.allSatisfy { $0.full == nil })
        let session = DocumentSession()
        let patch = session.load(doc("Intro.\n\n" + long + "delta\n"), baseline: oldFormat)
        #expect(patch.marks.first { $0.kind == .modified }?.diff == "")
        // Removed before opening: the start that was kept, marked as cut.
        let opened = DocumentSession().load(doc("Intro.\n"), baseline: oldFormat)
        #expect(opened.deletions.first?.preview?.hasSuffix(" …") == true)
        // Changed back to what was read: recognised by the block's fingerprint.
        let revert = DocumentSession()
        _ = revert.load(doc("Intro.\n\n" + long + "delta\n"), baseline: oldFormat)
        let back = try #require(revert.update(v1))
        #expect(back.marks.isEmpty)
        // Removed before it was read: the preview is the start that was read, marked
        // as cut, never the unread edit.
        let removed = try #require(session.update(doc("Intro.\n")))
        let preview = try #require(removed.deletions.first?.preview)
        #expect(!preview.contains("delta"))
        #expect(preview.hasSuffix(" …"))
        #expect(preview.hasPrefix("alpha beta gamma"))
        // With a current baseline the comparison is there.
        let session2 = DocumentSession()
        let patch2 = session2.load(doc("Intro.\n\n" + long + "delta\n"), baseline: v1.blocks.map(BlockKey.init))
        #expect(patch2.marks.first { $0.kind == .modified }?.diff?.hasSuffix("<ins> delta</ins>") == true)
    }

    @Test func deletionsShowTheWholeRemovedText() throws {
        let long = String(repeating: "removed words ", count: 60)
        let session = DocumentSession()
        _ = session.load(doc("Keep.\n\n" + long + "\n\nEnd.\n"))
        let p = try #require(session.update(doc("Keep.\n\nEnd.\n")))
        #expect(p.deletions.first?.preview == long.trimmingCharacters(in: .whitespaces))
    }

    @Test func groupedDeletionsKeepEveryBlockOrSaySoMoreWasRemoved() throws {
        // Adjacent removals share one marker: each block's text is in it. Enough
        // blocks stay that the update is not treated as a rewrite.
        let kept = (1...20).map { "Kept \($0)." }.joined(separator: "\n\n")
        let paras = (1...12).map { "Paragraph \($0) " + String(repeating: "text ", count: 50) }
        let session = DocumentSession()
        _ = session.load(doc(kept + "\n\n" + paras.joined(separator: "\n\n") + "\n\nEnd.\n"))
        let p = try #require(session.update(doc(kept + "\n\nEnd.\n")))
        #expect(p.deletions.count == 1)
        let preview = try #require(p.deletions.first?.preview)
        for n in 1...12 { #expect(preview.contains("Paragraph \(n) "), "block \(n)") }

        // Past the bound the marker says more was removed rather than dropping blocks silently.
        let big = (1...5).map { "Section \($0) " + String(repeating: "x", count: 50_000) }
        let s2 = DocumentSession()
        _ = s2.load(doc(kept + "\n\n" + big.joined(separator: "\n\n") + "\n\nEnd.\n"))
        let p2 = try #require(s2.update(doc(kept + "\n\nEnd.\n")))
        let preview2 = try #require(p2.deletions.first?.preview)
        #expect(p2.deletions.first?.count == 5)
        #expect(preview2.hasSuffix("\n\n…"))
        #expect(preview2.components(separatedBy: "\n\n…").count == 2)
        #expect(preview2.utf8.count <= DocumentSession.previewBytes + 5)

        // A huge block after a small one is not appended past the bound either.
        let s3 = DocumentSession()
        let huge = String(repeating: "y", count: 500_000)
        _ = s3.load(doc(kept + "\n\nSmall removed.\n\n" + huge + "\n\nEnd.\n"))
        let p3 = try #require(s3.update(doc(kept + "\n\nEnd.\n")))
        #expect(p3.deletions.first?.preview == "Small removed.\n\n…")

        // A huge first block is cut to the bound too, whatever follows it.
        let s4 = DocumentSession()
        _ = s4.load(doc(kept + "\n\n" + huge + "\n\nSmall removed.\n\nEnd.\n"))
        let p4 = try #require(s4.update(doc(kept + "\n\nEnd.\n")))
        let preview4 = try #require(p4.deletions.first?.preview)
        #expect(preview4.utf8.count <= DocumentSession.previewBytes)
        #expect(preview4.hasSuffix("\n\n…"))
    }
}

private extension Data {
    /// Drops the "full" key, as a baseline written before it existed.
    func replacingFull() -> Data {
        var array = (try? JSONSerialization.jsonObject(with: self)) as? [[String: Any]] ?? []
        for i in array.indices { array[i]["full"] = nil }
        return (try? JSONSerialization.data(withJSONObject: array)) ?? self
    }
}
