import Foundation
import Testing
@testable import ReadoutCore

/// The saved reading state (`ReadingRecord`): only what 3.6 and later write is read;
/// an older record is no reading state at all, and the file opens as if it were new.
@Suite struct ReadingRecordTests {
    func doc(_ s: String) -> ParsedDocument { MarkdownParser.parse(s) }

    let v1 = "# Plan\n\n1. First step of the plan.\n2. Second step of the plan.\n\nClosing words.\n"

    let v2 = "# Plan\n\n1. First step of the plan, revised.\n2. Second step of the plan.\n"

    func record(_ baseline: [BlockKey], index: Int?, excerpt: String?, at savedAt: Date) throws -> Data {
        try JSONEncoder().encode(ReadingRecord(baseline: baseline, topBlockIndex: index, topOffset: 0, topExcerpt: excerpt, savedAt: savedAt))
    }

    func position(index: Int, excerpt: String?, at savedAt: Date) throws -> Data {
        try JSONEncoder().encode(ReadingRecord.Position(ReadingRecord(baseline: [], topBlockIndex: index, topOffset: 12,
                                                                      topExcerpt: excerpt, savedAt: savedAt)))
    }

    /// `data` with `field` dropped from the block keys `which` selects, as a version before that field wrote them.
    func dropping(_ field: String, from data: Data, where which: (Int) -> Bool = { _ in true }) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var keys = try #require(object["baseline"] as? [[String: Any]])
        for i in keys.indices where which(i) { keys[i][field] = nil }
        object["baseline"] = keys
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func aRecordSavedBefore36IsIgnoredWholeWithItsPosition() throws {
        let read = DocumentSession()
        _ = read.load(doc(v1))
        let now = Date()
        let current = try record(read.baseline, index: 1, excerpt: "First step", at: now)
        let pos = try position(index: 2, excerpt: "Second step", at: now.addingTimeInterval(10))
        // Written by 3.5: no block sources (and nothing else differs).
        let old = try dropping("source", from: current)
        #expect(ReadingRecord.decode(record: old, position: pos) == nil)
        #expect(ReadingRecord.decode(record: old, position: nil) == nil)
        // Saved before whole texts were kept (no `full`, no `source`): ignored too.
        #expect(ReadingRecord.decode(record: try dropping("full", from: old), position: pos) == nil)
        // One old key among current ones (a block read under 3.5, still unread
        // since): the whole record goes, never part of it.
        let mixed = try dropping("source", from: current, where: { $0 == 1 })
        #expect(ReadingRecord.decode(record: mixed, position: pos) == nil)
        // Nothing readable at all: no record, no crash.
        for bytes in [Data(), Data("{".utf8), Data("[]".utf8), Data("{\"baseline\": 3}".utf8)] {
            #expect(ReadingRecord.decode(record: bytes, position: pos) == nil)
        }
        // The current format loads, with the position saved since.
        let loaded = try #require(ReadingRecord.decode(record: current, position: pos))
        #expect(loaded.baseline == read.baseline)
        #expect(loaded.topBlockIndex == 2 && loaded.topExcerpt == "Second step" && loaded.topOffset == 12)
        // A position older than the record is not applied.
        let stale = try position(index: 3, excerpt: "Closing", at: now.addingTimeInterval(-10))
        #expect(ReadingRecord.decode(record: current, position: stale)?.topBlockIndex == 1)
    }

    @Test func theFileThenOpensAsIfItWereNew() throws {
        let read = DocumentSession()
        _ = read.load(doc(v1))
        let old = try dropping("source", from: record(read.baseline, index: 2, excerpt: nil, at: Date()))
        let record = ReadingRecord.decode(record: old, position: nil)
        #expect(record == nil)
        // What the window does with no record: no marks, no deletions, no notice,
        // the same page as a file never opened, read from the top.
        let opened = DocumentSession()
        let p = opened.load(doc(v2), baseline: record?.baseline)
        let fresh = DocumentSession().load(doc(v2))
        #expect(p.marks.isEmpty && p.deletions.isEmpty && !p.rewrite && opened.unreadCount == 0)
        #expect(p.ops.map(\.html) == fresh.ops.map(\.html))
        #expect(ExcerptAnchor.resumeIndex(excerpt: record?.topExcerpt, index: record?.topBlockIndex,
                                          in: opened.blocks.map(\.text), rewritten: false) == nil)
        // Its next save is a current record: read back, it marks nothing.
        let saved = try #require(ReadingRecord.decode(record: try self.record(opened.baseline, index: 0, excerpt: "Plan", at: Date()), position: nil))
        #expect(DocumentSession().load(doc(v2), baseline: saved.baseline).marks.isEmpty)
    }

    @Test func aCurrentRecordComparesWithTheSourceAsRead() throws {
        // What 3.6+ records give 4.0: the source as read, so a long edited
        // block is compared whole (no "earlier text not kept" case is left).
        let long = String(repeating: "alpha beta gamma ", count: 40)   // over 500 characters
        let first = DocumentSession()
        _ = first.load(doc("Intro.\n\n- " + long + "\n"))
        let data = try record(first.baseline, index: 0, excerpt: "Intro.", at: Date())
        let loaded = try #require(ReadingRecord.decode(record: data, position: nil))
        let s = DocumentSession()
        let p = s.load(doc("Intro.\n\n- " + long + "delta\n"), baseline: loaded.baseline)
        let diff = try #require(p.marks.first { $0.kind == .modified }?.diff)
        #expect(diff.hasSuffix("<ins> delta</ins>"), "\(diff)")
        // Removed before it was read: the whole text as read, never cut.
        let removed = try #require(s.update(doc("Intro.\n")))
        let preview = try #require(removed.deletions.first?.preview)
        #expect(!preview.contains("delta") && !preview.hasSuffix(" …") && preview.hasPrefix("- alpha beta gamma"))
    }
}
