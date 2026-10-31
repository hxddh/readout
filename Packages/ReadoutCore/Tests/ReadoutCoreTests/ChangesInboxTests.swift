import Foundation
import Testing
@testable import ReadoutCore

/// The changes inbox (`ChangesInbox`): what waits for the reader across
/// open documents and the watched folders, newest first.
@Suite struct ChangesInboxTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func openDocumentsWaitByTheirDotAndFilesNotOpenWhenChangedSinceRead() {
        let read: [String: (at: Date, unread: Int)] = ["/b/notes.md": (at(35), 0), "/b/old.md": (at(6), 0), "/b/left.md": (at(9), 2)]
        let entries = ChangesInbox.entries(
            open: [("/a/plan.md", 3, true, at(10)),       // unread changes
                   ("/a/done.md", 0, true, at(50)),       // read: not waiting
                   ("/a/new.md", 0, false, at(20))],      // opened behind, not looked at
            recent: [("/a/plan.md", at(10)),              // open: counted once
                     ("/b/notes.md", at(40)),             // changed after it was read
                     ("/b/old.md", at(5)),                // read since it changed
                     ("/b/fresh.md", at(30)),             // never read
                     ("/b/left.md", at(8))],              // closed with changes unread
            lastRead: { read[$0] })
        #expect(entries.map(\.path) == ["/b/notes.md", "/b/fresh.md", "/a/new.md", "/a/plan.md", "/b/left.md"])
        #expect(entries.map(\.unread) == [nil, nil, 0, 3, nil])
    }

    @Test func nothingWaitingIsAnEmptyInbox() {
        let entries = ChangesInbox.entries(open: [("/a/x.md", 0, true, at(1))], recent: [("/a/x.md", at(1))], lastRead: { _ in (at: at(2), unread: 0) })
        #expect(entries.isEmpty)
    }
}
