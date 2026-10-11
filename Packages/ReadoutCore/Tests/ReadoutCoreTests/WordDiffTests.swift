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
}

private extension Data {
    /// Drops the "full" key, as a baseline written before it existed.
    func replacingFull() -> Data {
        var array = (try? JSONSerialization.jsonObject(with: self)) as? [[String: Any]] ?? []
        for i in array.indices { array[i]["full"] = nil }
        return (try? JSONSerialization.data(withJSONObject: array)) ?? self
    }
}
