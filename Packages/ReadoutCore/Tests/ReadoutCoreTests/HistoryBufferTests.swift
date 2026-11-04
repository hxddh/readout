import Foundation
import Testing
@testable import ReadoutCore

/// A file's history in memory, written at most every 5 s (`HistoryBuffer`).
@Suite struct HistoryBufferTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// An agent streaming a 1 MB document in, a version recorded each
    /// second for a minute: the history is written at most once every 5 s,
    /// and what was recorded last is written in the end.
    @Test func aStreamedMegabyteDocumentIsWrittenAtMostEveryFiveSeconds() {
        var buffer = HistoryBuffer(DocumentHistory())
        var paragraphs: [String] = []
        let paragraph = String(repeating: "streamed words ", count: 70)   // ~1 KB
        var writes: [Date] = []
        var due: Date?
        for second in 0..<60 {
            let now = t0.addingTimeInterval(Double(second))
            // About 17 KB a second: 1 MB in a minute.
            for _ in 0..<17 { paragraphs.append(paragraph + "\(paragraphs.count)") }
            let keys = MarkdownParser.parse(paragraphs.joined(separator: "\n\n")).blocks.map(BlockKey.init)
            buffer.record(keys, at: now)
            // The store's timer: one write when it is due.
            if due == nil { due = buffer.writeDue(now: now) }
            if let d = due, d <= now { writes.append(now); buffer.wrote(at: now); due = nil }
        }
        #expect(paragraphs.joined().utf8.count > 1_000_000)
        #expect(writes.count >= 2 && writes.count <= 13)
        for (a, b) in zip(writes, writes.dropFirst()) { #expect(b.timeIntervalSince(a) >= HistoryBuffer.writeInterval) }
        // Closing the window: what is left is written now.
        #expect(buffer.dirty)
        let end = t0.addingTimeInterval(60)
        #expect(buffer.writeDue(now: end).map { $0 >= end } == true)
    }

    @Test func nothingRecordedIsNothingToWrite() {
        var buffer = HistoryBuffer(DocumentHistory())
        #expect(buffer.writeDue(now: t0) == nil)
        let keys = MarkdownParser.parse("# Plan\n").blocks.map(BlockKey.init)
        buffer.record(keys, at: t0)
        #expect(buffer.writeDue(now: t0) == t0)   // the first write: at once
        buffer.wrote(at: t0)
        #expect(buffer.writeDue(now: t0) == nil)
        // The same blocks again: no change, nothing to write.
        #expect(!buffer.record(keys, at: t0.addingTimeInterval(1)))
        #expect(buffer.writeDue(now: t0.addingTimeInterval(1)) == nil)
        buffer.record(MarkdownParser.parse("# Plan\n\nMore.\n").blocks.map(BlockKey.init), at: t0.addingTimeInterval(2))
        #expect(buffer.writeDue(now: t0.addingTimeInterval(2)) == t0.addingTimeInterval(5))
    }

    @Test func theLastTwentyVersionsAreKept() {
        var h = DocumentHistory()
        for i in 0..<30 {
            h.record(MarkdownParser.parse("# Plan\n\nStep \(i).\n").blocks.map(BlockKey.init), at: t0.addingTimeInterval(Double(i) * 60))
        }
        #expect(h.versions.count == 20)
        #expect(h.versions.first?.at == t0.addingTimeInterval(10 * 60))
    }
}
