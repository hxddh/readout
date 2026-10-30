import Foundation
import Testing
@testable import ReadoutCore

/// Window restoration (`ReaderRestorationState`): file, project, tab group, and
/// whether the tab was looked at.
@Suite struct ReaderRestorationStateTests {
    @Test func restoredWindowsKeepTheirFileProjectAndTabs() {
        let s = ReaderRestorationState(path: "/w/p.md", projectRoot: "/w/app", group: "g1", tabIndex: 2, selected: false)
        let back = ReaderRestorationState.restorable(s.dictionary, exists: { _ in true }, isDirectory: { _ in true })
        #expect(back == s)
        // The file is gone: the window does not come back.
        #expect(ReaderRestorationState.restorable(s.dictionary, exists: { _ in false }, isDirectory: { _ in true }) == nil)
        // The project folder is gone: the window comes back without it.
        #expect(ReaderRestorationState.restorable(s.dictionary, exists: { _ in true }, isDirectory: { _ in false })?.projectRoot == nil)
        #expect(ReaderRestorationState.restorable(["readout.path": "relative.md"], exists: { _ in true }, isDirectory: { _ in true }) == nil)
        // NSNumber values, as a coder hands them back.
        let coded: [String: Any] = ["readout.path": "/w/q.md", "readout.tabIndex": NSNumber(value: 1), "readout.tabSelected": NSNumber(value: true)]
        #expect(ReaderRestorationState.restorable(coded, exists: { _ in true }, isDirectory: { _ in true })
                == ReaderRestorationState(path: "/w/q.md", tabIndex: 1, selected: true))
    }

    @Test func tabsComeBackInTheirGroupsInOrder() {
        let states = [
            ReaderRestorationState(path: "/a", group: "x", tabIndex: 1),
            ReaderRestorationState(path: "/b", group: nil),
            ReaderRestorationState(path: "/c", group: "x", tabIndex: 0),
            ReaderRestorationState(path: "/d", group: "y", tabIndex: 0),
            ReaderRestorationState(path: "/e", group: "z", tabIndex: 0),
            ReaderRestorationState(path: "/f", group: "z", tabIndex: 3),
        ]
        // A group of one is a window of its own.
        #expect(ReaderRestorationState.tabGroups(states) == [[2, 0], [4, 5]])
    }

    /// 3.7 brought every restored tab that did not become key back as "not
    /// looked at" (its dot, and first for Open Latest Agent File). Whether it
    /// was looked at is kept now; a state kept by 3.7 has no flag: looked at.
    @Test func restoredTabsKeepWhetherTheyWereLookedAt() {
        let unseen = ReaderRestorationState(path: "/w/p.md", group: "g", tabIndex: 1, selected: false, seen: false)
        #expect(ReaderRestorationState.restorable(unseen.dictionary, exists: { _ in true }, isDirectory: { _ in true })?.seen == false)
        let seen = ReaderRestorationState(path: "/w/q.md", group: "g", tabIndex: 0, selected: true)
        #expect(seen.seen)
        #expect(ReaderRestorationState.restorable(seen.dictionary, exists: { _ in true }, isDirectory: { _ in true }) == seen)
        // As a coder hands it back (NSNumber), and a 3.7 state without the flag.
        let coded: [String: Any] = ["readout.path": "/w/r.md", "readout.seen": NSNumber(value: false)]
        #expect(ReaderRestorationState.restorable(coded, exists: { _ in true }, isDirectory: { _ in true })?.seen == false)
        let old: [String: Any] = ["readout.path": "/w/r.md", "readout.tabIndex": NSNumber(value: 1), "readout.tabSelected": NSNumber(value: false)]
        #expect(ReaderRestorationState.restorable(old, exists: { _ in true }, isDirectory: { _ in true })?.seen == true)
        // Looked at before the quit: no dot, not "waiting" (lookedAt comes from seen).
        #expect(!CrossDocument.needsAttention(unread: 0, lookedAt: seen.seen))
        #expect(CrossDocument.needsAttention(unread: 0, lookedAt: unseen.seen))
    }
}
