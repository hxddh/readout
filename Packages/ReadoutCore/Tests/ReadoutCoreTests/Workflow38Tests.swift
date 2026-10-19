import Foundation
import Testing
@testable import ReadoutCore

/// 3.8 agent workflow: restored tabs, a new document waiting for the reader,
/// the commit notices, Compare with Last Commit, a quiet launch at login.
@Suite struct Workflow38Tests {
    // MARK: U1 restored tabs

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

    // MARK: U2 a document opened behind and not looked at yet

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

    /// The Dock badge counts the documents whose tabs show the dot: unread
    /// changes, or opened behind and not looked at yet.
    @Test func theDockBadgeCountsDocumentsWaiting() {
        let docs: [(unread: Int, lookedAt: Bool)] = [(0, false), (2, true), (0, true), (1, false)]
        let n = docs.filter { CrossDocument.needsAttention(unread: $0.unread, lookedAt: $0.lookedAt) }.count
        #expect(CrossDocument.badgeLabel(waiting: n) == "3")
        #expect(CrossDocument.badgeLabel(waiting: 0) == nil)
    }

    // MARK: U4 quoting the focused block

    /// Text selected and a focused block are told apart: the context menu
    /// offers Copy as Quote for a text selection only (a right click elsewhere
    /// leaves the focus on the block N went to), the Edit menu for either.
    @Test func theSelectionMessageTellsTextFromAFocusedBlock() {
        #expect(PageMessage(["type": "selection", "has": false, "focused": true]) == .selection(has: false, focused: true))
        #expect(PageMessage(["type": "selection", "has": NSNumber(value: true), "focused": NSNumber(value: false)]) == .selection(has: true, focused: false))
        #expect(PageMessage(["type": "selection", "has": true]) == .selection(has: true, focused: false))
    }

    // MARK: U12 the commit notices

    /// A first open whose committed version is mostly different: no marks
    /// (a rewrite), and the notice says it was rewritten since the last
    /// commit, not only "This file was rewritten" (3.7: nothing said so).
    @Test func aFirstOpenMostlyRewrittenSinceTheCommitSaysSo() {
        let head = (1...8).map { "Committed paragraph number \($0) about the old plan." }.joined(separator: "\n\n")
        let now = (1...8).map { "The agent's new paragraph \($0) for a different plan entirely." }.joined(separator: "\n\n")
        let s = DocumentSession()
        let patch = s.load(MarkdownParser.parse(now), baseline: MarkdownParser.parse(head).blocks.map(BlockKey.init))
        #expect(patch.rewrite && s.unreadCount == 0)
        #expect(CommitNotice.after(rewrite: patch.rewrite, unread: s.unreadCount) == .rewritten)
        #expect(CommitNotice.after(rewrite: false, unread: 2) == .marked)
        #expect(CommitNotice.after(rewrite: false, unread: 0) == nil)
    }

    // MARK: N1 Compare with Last Commit

    struct FakeGit: GitRunning {
        var output: [String: Data] = [:]   // "dir|args" -> stdout
        func run(_ arguments: [String], in directory: String) -> Data? { output[directory + "|" + arguments.joined(separator: " ")] }
    }

    @Test func comparingWithTheLastCommit() {
        let show = "/w/app/docs|--no-pager show HEAD:./plan.md"
        let git = FakeGit(output: [show: Data("# Plan\n\nOld.\n".utf8)])
        let exists = { (p: String) in p == "/w/app/.git" }
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", current: "# Plan\n\nNew.\n", git: git, exists: exists) == .baseline("# Plan\n\nOld.\n"))
        // As committed (line endings aside): nothing to mark, and it says so.
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", current: "# Plan\r\n\r\nOld.\r\n", git: git, exists: exists) == .unchanged)
        // Not committed, outside a repository: unavailable.
        #expect(GitBaseline.compare(path: "/w/app/docs/new.md", current: "x", git: git, exists: exists) == .unavailable)
        #expect(GitBaseline.compare(path: "/elsewhere/plan.md", current: "x", git: git, exists: exists) == .unavailable)
        // What is never compared is not "unchanged".
        let lfs = FakeGit(output: [show: Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\n".utf8)])
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", current: "# Plan", git: lfs, exists: exists) == .unavailable)
        let binary = FakeGit(output: [show: Data([0x23, 0x00, 0x41])])
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", current: "# Plan", git: binary, exists: exists) == .unavailable)
        // Committed empty (git succeeded, no bytes): a baseline, or unchanged; not "not in the commit".
        let empty = FakeGit(output: [show: Data()])
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", current: "# Plan\n\nNew.\n", git: empty, exists: exists) == .baseline(""))
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", current: "", git: empty, exists: exists) == .unchanged)
        #expect(GitBaseline.headText(for: "/w/app/docs/plan.md", current: "# Plan\n\nNew.\n", git: empty, exists: exists) == "")
    }

    /// A UTF-16 file (as Windows tools write) has NUL bytes in its blob: it is
    /// decoded as the app decodes the file, not taken for a binary.
    @Test func aUTF16CommittedFileIsCompared() {
        let show = "/w/app/docs|--no-pager show HEAD:./plan.md"
        let exists = { (p: String) in p == "/w/app/.git" }
        let old = "# Plan\n\nOld.\n"
        var bom = Data([0xFF, 0xFE])
        for u in old.utf16 { bom.append(UInt8(u & 0xFF)); bom.append(UInt8(u >> 8)) }
        var noBOM = Data()
        for u in old.utf16 { noBOM.append(UInt8(u >> 8)); noBOM.append(UInt8(u & 0xFF)) }   // UTF-16BE, no BOM
        for blob in [bom, noBOM] {
            let git = FakeGit(output: [show: blob])
            #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", current: "# Plan\n\nNew.\n", git: git, exists: exists) == .baseline(old))
            #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", current: old, git: git, exists: exists) == .unchanged)
            // The first open (3.7's GitBaseline) too.
            #expect(GitBaseline.headText(for: "/w/app/docs/plan.md", current: "# Plan\n\nNew.\n", git: git, exists: exists) == old)
        }
        // A binary still is not compared.
        #expect(GitBaseline.committedText(head: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x1A, 0x0A, 0x00, 0x0D])) == nil)
    }

    /// A file committed empty, written since: its first open marks every block new.
    @Test func aFileCommittedEmptyIsMarkedAllNew() {
        let s = DocumentSession()
        let patch = s.load(MarkdownParser.parse("# Plan\n\nOne.\n\nTwo.\n"), baseline: MarkdownParser.parse("").blocks.map(BlockKey.init))
        #expect(!patch.rewrite && s.unreadCount == 3)
        #expect(CommitNotice.after(rewrite: patch.rewrite, unread: s.unreadCount) == .marked)
    }

    /// Compare with Last Commit's result applies only to the file it was asked
    /// for: a window whose symlink was retargeted meanwhile drops it.
    @Test func aComparisonAppliesOnlyToTheFileItWasAskedFor() {
        #expect(CommitComparison.applies(askedFor: "/w/runs/run-41.md", showing: "/w/runs/run-41.md", retargeting: false))
        #expect(!CommitComparison.applies(askedFor: "/w/runs/run-41.md", showing: "/w/runs/run-42.md", retargeting: false))
        #expect(!CommitComparison.applies(askedFor: "/w/runs/run-41.md", showing: "/w/runs/run-41.md", retargeting: true))
    }

    /// Re-marked against the commit after everything was read, then ⌘Z: the
    /// marks of the commit, then the reading state from before again.
    @Test func comparingReMarksTheDocumentAndUndoBringsTheReadStateBack() {
        let head = "# Plan\n\nKeep this.\n\nRun the migration on staging first, then on production.\n"
        let now = "# Plan\n\nKeep this.\n\nRun the migration on staging first, then on production at night.\n\nAdded too.\n"
        let s = DocumentSession()
        _ = s.load(MarkdownParser.parse(now))
        #expect(s.unreadCount == 0)
        let read = s.baseline
        let patch = s.reload(baseline: MarkdownParser.parse(head).blocks.map(BlockKey.init))
        #expect(patch.reset && !patch.rewrite && s.unreadCount == 2)
        #expect(CommitNotice.after(rewrite: patch.rewrite, unread: s.unreadCount) == .marked)
        _ = s.reload(baseline: read)
        #expect(s.unreadCount == 0)
    }

    // MARK: U9 a quiet launch at login

    @Test func aLoginItemLaunchShowsNoWelcomeWindow() {
        // The Apple Event codes, as AE/AERegistry.h has them.
        #expect(LaunchWelcome.launchedAsLogInItem == 0x6C67_6974)   // 'lgit'
        #expect(LaunchWelcome.openApplication == 0x6F61_7070)       // 'oapp'
        #expect(LaunchWelcome.isLoginItemLaunch(eventID: 0x6F61_7070, propData: 0x6C67_6974))
        #expect(!LaunchWelcome.isLoginItemLaunch(eventID: 0x6F61_7070, propData: nil))
        #expect(!LaunchWelcome.isLoginItemLaunch(eventID: 0x6F64_6F63, propData: 0x6C67_6974))   // 'odoc'
        #expect(!LaunchWelcome.isLoginItemLaunch(eventID: nil, propData: nil))
        #expect(LaunchWelcome.shows(openedAtLaunch: false, windowsOpen: false, loginItem: false))
        #expect(!LaunchWelcome.shows(openedAtLaunch: false, windowsOpen: false, loginItem: true))
        #expect(!LaunchWelcome.shows(openedAtLaunch: true, windowsOpen: false, loginItem: false))
        #expect(!LaunchWelcome.shows(openedAtLaunch: false, windowsOpen: true, loginItem: false))
    }
}
