import Foundation
import Testing
@testable import ReadoutCore

/// Across documents (`CrossDocument`, `UnreadDisplay`): where N goes next, Open
/// Latest Agent File, the tab dot and Dock badge, the unread count held back.
@Suite struct CrossDocumentTests {
    @Test func nGoesOnToTheTabsAfterThisOneThenTheOtherWindows() {
        let groups = [["a", "b", "c"], ["d"], ["e", "f"]]
        #expect(CrossDocument.order(after: "b", groups: groups) == ["c", "a", "d", "e", "f"])
        #expect(CrossDocument.order(after: "e", groups: groups) == ["f", "a", "b", "c", "d"])
        #expect(CrossDocument.order(after: "d", groups: groups) == ["a", "b", "c", "e", "f"])
        // Not among them (a window being closed): every other one, in order.
        #expect(CrossDocument.order(after: "x", groups: groups) == ["a", "b", "c", "d", "e", "f"])
        #expect(CrossDocument.order(after: "a", groups: [["a"]]) == [])
    }

    /// N with nothing unread left goes on to a document opened behind and not
    /// looked at yet as to one with unread changes, whichever comes first; it
    /// lands where it shows (nothing is marked), not at a first change.
    @Test func nGoesOnToADocumentNotLookedAtYet() {
        // Tabs a b c in one window, d in another; b: new, never looked at; d: unread changes.
        let waiting: [String: (unread: Int, lookedAt: Bool)] = ["a": (0, true), "b": (0, false), "c": (0, true), "d": (3, true)]
        let wait = { (id: String) in CrossDocument.needsAttention(unread: waiting[id]!.unread, lookedAt: waiting[id]!.lookedAt) }
        #expect(CrossDocument.next(after: "a", groups: [["a", "b", "c"], ["d"]], waiting: wait) == "b")
        #expect(CrossDocument.next(after: "b", groups: [["a", "b", "c"], ["d"]], waiting: wait) == "d")
        // Before 3.8 only unread changes counted: from a, N skipped b for d.
        #expect(CrossDocument.next(after: "a", groups: [["a", "b", "c"], ["d"]], waiting: { waiting[$0]!.unread > 0 }) == "d")
        #expect(CrossDocument.next(after: "a", groups: [["a", "c"]], waiting: wait) == nil)
        #expect(CrossDocument.arrival(unread: 0) == .whereItShows)
        #expect(CrossDocument.arrival(unread: 2) == .firstChange)
    }

    @Test func openLatestPrefersTheNewestDocumentWaitingForTheReader() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        // All with unread changes: the newest.
        #expect(CrossDocument.newestNeedingAttention([("/p/a.md", t, 2, true), ("/p/b.md", t + 60, 1, true), ("/p/c.md", t + 5, 4, true)]) == "/p/b.md")
        #expect(CrossDocument.newestNeedingAttention([]) == nil)
        // Plan A has unread edits from 10:00; plan B, written at 10:05, was
        // opened behind and never looked at (no baseline: nothing unread). B.
        #expect(CrossDocument.newestNeedingAttention([("/p/a.md", t, 3, true), ("/p/b.md", t + 300, 0, false)]) == "/p/b.md")
        // A newer document already looked at, nothing unread: not waiting, A.
        #expect(CrossDocument.newestNeedingAttention([("/p/a.md", t, 3, true), ("/p/c.md", t + 300, 0, true)]) == "/p/a.md")
        // Nothing waiting: nil (the newest file on disk is opened instead).
        #expect(CrossDocument.newestNeedingAttention([("/p/c.md", t, 0, true)]) == nil)
    }

    @Test func needsAttentionIsTheTabDotsRule() {
        #expect(CrossDocument.needsAttention(unread: 1, lookedAt: true))
        #expect(CrossDocument.needsAttention(unread: 0, lookedAt: false))
        #expect(CrossDocument.needsAttention(unread: 2, lookedAt: false))
        #expect(!CrossDocument.needsAttention(unread: 0, lookedAt: true))
    }

    /// The Dock badge counts the documents whose tabs show the dot: unread
    /// changes, or opened behind and not looked at yet.
    @Test func theDockBadgeCountsDocumentsWaiting() {
        let docs: [(unread: Int, lookedAt: Bool)] = [(0, false), (2, true), (0, true), (1, false)]
        let n = docs.filter { CrossDocument.needsAttention(unread: $0.unread, lookedAt: $0.lookedAt) }.count
        #expect(CrossDocument.badgeLabel(waiting: n) == "3")
        #expect(CrossDocument.badgeLabel(waiting: 0) == nil)
    }

    @Test func increasesWaitAndDecreasesShowAtOnce() {
        let shown = UnreadDisplay(count: 2, sections: [1, 5], dot: true)
        // A paragraph arrived in section 9: nothing changes yet.
        var r = UnreadDisplay.next(shown: shown, actual: UnreadDisplay(count: 3, sections: [1, 5, 9], dot: true))
        #expect(r.show == shown && r.held)
        // One read in section 1 while another arrived in 9: the read shows, the arrival waits.
        r = UnreadDisplay.next(shown: shown, actual: UnreadDisplay(count: 2, sections: [5, 9], dot: true))
        #expect(r.show == UnreadDisplay(count: 2, sections: [5], dot: true) && r.held)
        // All read: at once, nothing held.
        r = UnreadDisplay.next(shown: shown, actual: UnreadDisplay(count: 0, sections: [], dot: false))
        #expect(r.show == UnreadDisplay(count: 0, sections: [], dot: false) && !r.held)
        // The tab's dot appearing is an increase too.
        r = UnreadDisplay.next(shown: UnreadDisplay(), actual: UnreadDisplay(count: 1, sections: [2], dot: true))
        #expect(r.show == UnreadDisplay() && r.held)
    }
}
