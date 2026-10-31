import Foundation
import Testing
@testable import ReadoutCore

/// The versions of a file Readout keeps (`DocumentHistory`): each state the
/// file rested in, blocks shared between versions, within its limits.
@Suite struct DocumentHistoryTests {
    func keys(_ s: String) -> [BlockKey] { MarkdownParser.parse(s).blocks.map(BlockKey.init) }

    let v1 = "# Plan\n\nFirst step.\n\nSecond step.\n"
    let v2 = "# Plan\n\nFirst step, revised.\n\nSecond step.\n"
    let v3 = "# Plan\n\nFirst step, revised.\n\nSecond step.\n\nThird step.\n"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let roomy = DocumentHistory.Limits(maxAge: 1e9, maxVersions: 1000, maxTextBytes: 1 << 30, settle: 10)

    @Test func eachStateIsAVersionAndTheSameStateIsNotRecordedTwice() {
        var h = DocumentHistory()
        let first = h.record(keys(v1), at: t0, limits: roomy)
        let again = h.record(keys(v1), at: t0.addingTimeInterval(60), limits: roomy)
        let second = h.record(keys(v2), at: t0.addingTimeInterval(120), limits: roomy)
        #expect(first && !again && second)
        #expect(h.versions.count == 2)
        #expect(h.keys(of: 0) == keys(v1))
        #expect(h.keys(of: 1) == keys(v2))
        #expect(h.latest == keys(v2))
    }

    @Test func blocksUnchangedBetweenVersionsAreKeptOnce() {
        var h = DocumentHistory()
        h.record(keys(v1), at: t0, limits: roomy)
        h.record(keys(v2), at: t0.addingTimeInterval(60), limits: roomy)
        h.record(keys(v3), at: t0.addingTimeInterval(120), limits: roomy)
        // # Plan, First step., Second step., First step, revised., Third step.
        #expect(h.pool.count == 5)
        #expect(h.versions[1].blocks[0] == h.versions[0].blocks[0])
        #expect(h.versions[2].blocks[2] == h.versions[0].blocks[2])
    }

    @Test func aWriteStillStreamingInReplacesTheVersionBeforeItButNeverTheFirst() {
        var h = DocumentHistory()
        h.record(keys(v1), at: t0, limits: roomy)
        // The first write, 2 s after the file was seen: a version of its own.
        h.record(keys(v2), at: t0.addingTimeInterval(2), limits: roomy)
        // More of the same write, 4 s later: it replaces that version.
        let draft = "# Plan\n\nFirst step, draft.\n\nSecond step.\n"
        h.record(keys(draft), at: t0.addingTimeInterval(4), limits: roomy)
        h.record(keys(v3), at: t0.addingTimeInterval(6), limits: roomy)
        #expect(h.versions.count == 2)
        #expect(h.keys(of: 0) == keys(v1))
        #expect(h.keys(of: 1) == keys(v3))
        #expect(h.versions[1].at == t0.addingTimeInterval(6))
        // The block only a replaced version had is gone from the pool.
        #expect(!h.pool.contains { $0.wholeText.contains("draft") })
        #expect(h.pool.count == 5)
        // After a pause, the next write is a version again.
        h.record(keys(v1), at: t0.addingTimeInterval(60), limits: roomy)
        #expect(h.versions.count == 3)
    }

    @Test func theOldestVersionsGoPastTheCountTheAgeOrTheSizeAndTheNewestStays() {
        var byCount = DocumentHistory()
        var limits = roomy
        limits.maxVersions = 2
        for (i, v) in [v1, v2, v3].enumerated() { byCount.record(keys(v), at: t0.addingTimeInterval(Double(i) * 60), limits: limits) }
        #expect(byCount.versions.map(\.at) == [t0.addingTimeInterval(60), t0.addingTimeInterval(120)])
        #expect(byCount.pool.count == 4)   // "First step." is gone with v1

        var byAge = DocumentHistory()
        limits = roomy
        limits.maxAge = 3600
        byAge.record(keys(v1), at: t0, limits: limits)
        byAge.record(keys(v2), at: t0.addingTimeInterval(7200), limits: limits)
        #expect(byAge.versions.count == 1)
        byAge.trim(now: t0.addingTimeInterval(100_000), limits: limits)
        #expect(byAge.versions.count == 1)   // the newest stays, however old

        var bySize = DocumentHistory()
        limits = roomy
        let big = String(repeating: "word ", count: 400)
        limits.maxTextBytes = big.utf8.count * 3
        for i in 0..<5 { bySize.record(keys("\(big)\(i)\n"), at: t0.addingTimeInterval(Double(i) * 60), limits: limits) }
        #expect(bySize.textBytes <= limits.maxTextBytes)
        #expect(bySize.versions.count >= 1)
        #expect(bySize.latest == keys("\(big)4\n"))
    }

    @Test func aVersionHoldsTheFilesBlocksNeverAnUnreadDeletion() {
        let session = DocumentSession()
        _ = session.load(MarkdownParser.parse(v3))
        _ = session.update(MarkdownParser.parse(v2))   // "Third step." deleted, unread
        let baseline = session.baseline
        #expect(baseline.contains { $0.removed == true })
        var h = DocumentHistory()
        h.record(baseline, at: t0, limits: roomy)
        #expect(h.pool.allSatisfy { $0.removed == nil })
    }

    @Test func itRoundTripsAndAnUnreadableFileIsAnEmptyHistory() throws {
        var h = DocumentHistory()
        h.record(keys(v1), at: t0, limits: roomy)
        h.record(keys(v2), at: t0.addingTimeInterval(60), limits: roomy)
        let data = try JSONEncoder().encode(h)
        #expect(DocumentHistory.decode(data) == h)
        #expect(DocumentHistory.decode(nil).isEmpty)
        #expect(DocumentHistory.decode(Data("{".utf8)).isEmpty)
        // A version pointing past the pool (a damaged file) is no history, not a crash.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["pool"] = []
        #expect(DocumentHistory.decode(try JSONSerialization.data(withJSONObject: object)).isEmpty)
    }

    @Test func theTimelineListsEveryOtherVersionNewestFirstWithWhatDiffers() {
        var h = DocumentHistory()
        h.record(keys(v1), at: t0, limits: roomy)
        h.record(keys(v2), at: t0.addingTimeInterval(60), limits: roomy)
        h.record(keys(v3), at: t0.addingTimeInterval(120), limits: roomy)
        #expect(h.earlier(than: keys(v3)) == [1, 0])
        #expect(h.earlier(than: keys(v1)) == [2, 1])
        // v1 → v3: one paragraph changed (one each way), one added.
        let d = DocumentHistory.difference(from: h.keys(of: 0), to: keys(v3))
        #expect(d.added == 2 && d.removed == 1)
        let same = DocumentHistory.difference(from: keys(v3), to: keys(v3))
        #expect(same.added == 0 && same.removed == 0)
    }

    @Test func aVersionReadsBackAsTheSameBlocks() {
        var h = DocumentHistory()
        let text = "# Plan\n\n- [x] first\n- [ ] second\n\n```swift\nlet a = 1\n```\n\n> quoted *text*\n"
        h.record(keys(text), at: t0, limits: roomy)
        #expect(keys(h.markdown(of: 0)) == keys(text))
    }
}
