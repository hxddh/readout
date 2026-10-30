import Foundation
import Testing
@testable import ReadoutCore

/// The last commit as a baseline (`GitBaseline`, `CommitNotice`, `CommitComparison`):
/// the first open marked against it, and Compare with Last Commit.
@Suite struct GitBaselineTests {
    struct FakeGit: GitRunning {
        var output: [String: Data] = [:]   // "dir|args" -> stdout
        func run(_ arguments: [String], in directory: String) -> Data? { output[directory + "|" + arguments.joined(separator: " ")] }
    }

    private func keys(_ text: String) -> [BlockKey] { MarkdownParser.parse(text).blocks.map(BlockKey.init) }

    @Test func theRepositoryIsTheNearestFolderWithGit() {
        let dirs: Set<String> = ["/w/app/.git", "/w/app/vendor/lib/.git"]
        let exists = { (p: String) in dirs.contains(p) }
        #expect(GitBaseline.repository(containing: "/w/app/docs/plan.md", exists: exists) == "/w/app")
        // A submodule (its .git is a file) is its own repository.
        #expect(GitBaseline.repository(containing: "/w/app/vendor/lib/README.md", exists: exists) == "/w/app/vendor/lib")
        // Outside any repository (plans in ~/.claude/plans): none, and git is never run.
        #expect(GitBaseline.repository(containing: "/Users/me/.claude/plans/p.md", exists: exists) == nil)
        #expect(GitBaseline.repository(containing: "/p.md", exists: { _ in true }) == nil)
    }

    @Test func theCommittedTextIsTheBaselineWhenItDiffers() {
        let git = FakeGit(output: ["/w/app/docs|--no-pager show HEAD:./plan.md": Data("# Plan\n\nOld.\n".utf8)])
        let exists = { (p: String) in p == "/w/app/.git" }
        #expect(GitBaseline.headText(for: "/w/app/docs/plan.md", current: "# Plan\n\nNew.\n", git: git, exists: exists) == "# Plan\n\nOld.\n")
        // Unchanged since the commit (line endings aside): nothing to mark.
        #expect(GitBaseline.headText(for: "/w/app/docs/plan.md", current: "# Plan\r\n\r\nOld.\r\n", git: git, exists: exists) == nil)
        // Not committed (git fails): nothing.
        #expect(GitBaseline.headText(for: "/w/app/docs/new.md", current: "x", git: git, exists: exists) == nil)
        // Outside the repository: git is not asked.
        #expect(GitBaseline.headText(for: "/elsewhere/docs/plan.md", current: "x", git: git, exists: exists) == nil)
    }

    @Test func pointersBinariesAndLargeFilesAreNoBaseline() {
        let lfs = Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 12\n".utf8)
        #expect(GitBaseline.baselineText(head: lfs, current: "# Plan") == nil)
        #expect(GitBaseline.baselineText(head: Data([0x23, 0x00, 0x41]), current: "# Plan") == nil)
        #expect(GitBaseline.baselineText(head: Data(count: GitBaseline.sizeLimit + 1), current: "# Plan") == nil)
        // Committed empty (git succeeded with no bytes): everything there now is new.
        #expect(GitBaseline.baselineText(head: Data(), current: "# Plan") == "")
        #expect(GitBaseline.baselineText(head: Data(), current: "") == nil)
        #expect(GitBaseline.baselineText(head: Data("# Old".utf8), current: "# Plan") == "# Old")
    }

    @Test func aDocumentOpenedAgainstTheCommitMarksWhatChangedSince() throws {
        let head = "# Plan\n\nKeep this.\n\nRun the migration on staging first, then on production.\n"
        let now = "# Plan\n\nKeep this.\n\nRun the migration on staging first, then on production at night.\n\nAdded too.\n"
        let baseline = MarkdownParser.parse(head).blocks.map(BlockKey.init)
        let session = DocumentSession()
        let patch = session.load(MarkdownParser.parse(now), baseline: baseline)
        #expect(!patch.rewrite)
        // The edited step and the added paragraph; the rest is read.
        #expect(Set(session.marks.values) == [.modified, .inserted] && session.marks.count == 2 && session.deletions.isEmpty)
        // What it was marked against becomes the reading state saved.
        #expect(session.baseline.count >= 3)
    }

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

    /// A file committed empty, written since: its first open marks every block new.
    @Test func aFileCommittedEmptyIsMarkedAllNew() {
        let s = DocumentSession()
        let patch = s.load(MarkdownParser.parse("# Plan\n\nOne.\n\nTwo.\n"), baseline: MarkdownParser.parse("").blocks.map(BlockKey.init))
        #expect(!patch.rewrite && s.unreadCount == 3)
        #expect(CommitNotice.after(rewrite: patch.rewrite, unread: s.unreadCount) == .marked)
    }

    @Test func comparingWithTheLastCommit() {
        let show = "/w/app/docs|--no-pager show HEAD:./plan.md"
        let git = FakeGit(output: [show: Data("# Plan\n\nOld.\n".utf8)])
        let exists = { (p: String) in p == "/w/app/.git" }
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", displayed: keys("# Plan\n\nNew.\n"), git: git, exists: exists) == .baseline(keys("# Plan\n\nOld.\n")))
        // As committed (line endings aside): nothing to mark, and it says so.
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", displayed: keys("# Plan\r\n\r\nOld.\r\n"), git: git, exists: exists) == .unchanged)
        // Not committed, outside a repository: unavailable.
        #expect(GitBaseline.compare(path: "/w/app/docs/new.md", displayed: keys("x"), git: git, exists: exists) == .unavailable)
        #expect(GitBaseline.compare(path: "/elsewhere/plan.md", displayed: keys("x"), git: git, exists: exists) == .unavailable)
        // What is never compared is not "unchanged".
        let lfs = FakeGit(output: [show: Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\n".utf8)])
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", displayed: keys("# Plan"), git: lfs, exists: exists) == .unavailable)
        let binary = FakeGit(output: [show: Data([0x23, 0x00, 0x41])])
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", displayed: keys("# Plan"), git: binary, exists: exists) == .unavailable)
        // Committed empty (git succeeded, no bytes): a baseline, or unchanged; not "not in the commit".
        let empty = FakeGit(output: [show: Data()])
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", displayed: keys("# Plan\n\nNew.\n"), git: empty, exists: exists) == .baseline(keys("")))
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", displayed: keys(""), git: empty, exists: exists) == .unchanged)
        #expect(GitBaseline.headText(for: "/w/app/docs/plan.md", current: "# Plan\n\nNew.\n", git: empty, exists: exists) == "")
    }

    /// What the window displays is compared, not the file on disk (which a
    /// newer write may have reached first): no read but git's HEAD blob.
    @Test func comparingUsesTheDisplayedVersion() {
        let git = FakeGit(output: ["/w/app/docs|--no-pager show HEAD:./plan.md": Data("# Plan\n\nOld.\n".utf8)])
        let exists = { (p: String) in p == "/w/app/.git" }
        // The file on disk is back to HEAD already; the window still shows the edit.
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", displayed: keys("# Plan\n\nEdited.\n"), git: git, exists: exists)
                == .baseline(keys("# Plan\n\nOld.\n")))
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", displayed: keys("# Plan\n\nOld.\n"), git: git, exists: exists) == .unchanged)
    }

    /// A document that is empty now (or only whitespace: no blocks) is
    /// compared too: what was committed shows as removed; committed empty, unchanged.
    @Test func anEmptyDocumentIsComparedToo() {
        let exists = { (p: String) in p == "/w/app/.git" }
        let show = "/w/app/docs|--no-pager show HEAD:./plan.md"
        let git = FakeGit(output: [show: Data("# Plan\n\nOld.\n".utf8)])
        #expect(keys("  \n\n").isEmpty)
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", displayed: [], git: git, exists: exists) == .baseline(keys("# Plan\n\nOld.\n")))
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", displayed: [], git: FakeGit(output: [show: Data()]), exists: exists) == .unchanged)
        #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", displayed: [], git: FakeGit(output: [show: Data("\n\n".utf8)]), exists: exists) == .unchanged)
        // Marked against the commit: its blocks are removed, unread.
        let s = DocumentSession()
        _ = s.load(MarkdownParser.parse(""))
        let patch = s.reload(baseline: keys("# Plan\n\nOld.\n"))
        #expect(!patch.rewrite && s.deletions.count >= 1 && s.unreadCount >= 1)
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
            #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", displayed: keys("# Plan\n\nNew.\n"), git: git, exists: exists) == .baseline(keys(old)))
            #expect(GitBaseline.compare(path: "/w/app/docs/plan.md", displayed: keys(old), git: git, exists: exists) == .unchanged)
            // The first open (3.7's GitBaseline) too.
            #expect(GitBaseline.headText(for: "/w/app/docs/plan.md", current: "# Plan\n\nNew.\n", git: git, exists: exists) == old)
        }
        // A binary still is not compared.
        #expect(GitBaseline.committedText(head: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x1A, 0x0A, 0x00, 0x0D])) == nil)
    }

    /// Compare with Last Commit's result applies only to the version it was
    /// asked for: a write (or a retargeted symlink's file) read meanwhile
    /// compares once more with what is shown now; changed again, dropped.
    @Test func aComparisonAppliesOnlyToTheVersionItWasAskedFor() {
        #expect(CommitComparison.applies(askedAt: 4, current: 4, retargeting: false, rerun: false) == .apply)
        #expect(CommitComparison.applies(askedAt: 4, current: 5, retargeting: false, rerun: false) == .rerun)
        #expect(CommitComparison.applies(askedAt: 5, current: 5, retargeting: false, rerun: true) == .apply)
        #expect(CommitComparison.applies(askedAt: 5, current: 6, retargeting: false, rerun: true) == .drop)
        #expect(CommitComparison.applies(askedAt: 4, current: 4, retargeting: true, rerun: false) == .drop)
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
}
