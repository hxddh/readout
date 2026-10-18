import Foundation
import Testing
@testable import ReadoutCore

/// 3.7 agent workflow: Copy as Quote, cross-document N, the held-back unread
/// count, the first open marked against the last commit, plans that know
/// their project, links found where code-span paths are, window restoration.
@Suite struct AgentFlow37Tests {
    static let plan = """
        ---
        title: Plan
        ---
        # Rollout

        Intro paragraph
        over two lines.

        ## Risks

        - first risk
        - second risk
          continued

        | a | b |
        |---|---|
        | 1 | 2 |
        """

    func blocks(_ text: String = Self.plan) -> [Block] {
        var b = MarkdownParser.parse(text).blocks
        for i in b.indices { b[i].slot = i + 1 }
        return b
    }

    func slot(_ blocks: [Block], _ match: (Block) -> Bool) -> Int { blocks.first(where: match)!.slot }

    // MARK: Copy as Quote

    @Test func copyAsQuoteQuotesTheWholeBlocksWithTheirFileLines() throws {
        let b = blocks()
        // Lines are the file's, front matter included: the paragraph is on lines 6–7.
        let intro = slot(b) { $0.source.hasPrefix("Intro") }
        #expect(QuoteFormatter.quote(blocks: b, slots: [intro], path: "docs/plan.md")
                == "> Intro paragraph\n> over two lines.\n— docs/plan.md#L6-L7 (§ Rollout)")
        // Two list items on consecutive lines stay one tight list; the nearest heading is the section's.
        let items = Set(b.filter { $0.kind == .listItem }.map(\.slot))
        #expect(QuoteFormatter.quote(blocks: b, slots: items, path: "p.md")
                == "> - first risk\n> - second risk\n>   continued\n— p.md#L11-L13 (§ Risks)")
        // A heading and the table after a blank line: a blank quoted line between them.
        let risks = slot(b) { $0.kind == .heading && $0.headingTitle == "Risks" }
        let table = slot(b) { $0.kind == .table }
        let quote = try #require(QuoteFormatter.quote(blocks: b, slots: [risks, table], path: "p.md"))
        #expect(quote.hasPrefix("> ## Risks\n>\n> | a | b |\n> |---|---|\n> | 1 | 2 |\n"))
        #expect(quote.hasSuffix("\n— p.md#L9-L17 (§ Risks)"))
        // One line: a single line reference.
        let rollout = slot(b) { $0.headingTitle == "Rollout" }
        #expect(QuoteFormatter.quote(blocks: b, slots: [rollout], path: "p.md") == "> # Rollout\n— p.md#L4 (§ Rollout)")
        #expect(QuoteFormatter.quote(blocks: b, slots: [999], path: "p.md") == nil)
    }

    @Test func copyAsQuoteBeforeTheFirstHeadingNamesNoSection() {
        let b = blocks("Just a note.\n\n# Later\n")
        #expect(QuoteFormatter.quote(blocks: b, slots: [b[0].slot], path: "n.md") == "> Just a note.\n— n.md#L1")
    }

    @Test func theQuoteNamesTheFileRelativeToItsProjectElseWithTilde() {
        #expect(QuoteFormatter.displayPath("/w/app/docs/plan.md", projectRoot: "/w/app", home: "/Users/me") == "docs/plan.md")
        #expect(QuoteFormatter.displayPath("/w/app/docs/plan.md", projectRoot: "/w/app/", home: "/Users/me") == "docs/plan.md")
        // A plan outside its project (~/.claude/plans): its own path, ~-abbreviated.
        #expect(QuoteFormatter.displayPath("/Users/me/.claude/plans/p.md", projectRoot: "/w/app", home: "/Users/me") == "~/.claude/plans/p.md")
        // A sibling folder that merely starts the same is not inside.
        #expect(QuoteFormatter.displayPath("/w/application/a.md", projectRoot: "/w/app", home: "/Users/me") == "/w/application/a.md")
        #expect(QuoteFormatter.displayPath("/Users/me/n.md", projectRoot: nil, home: "/Users/me") == "~/n.md")
    }

    @Test func blockquotesMarkBlankLinesToo() {
        #expect(QuoteFormatter.blockquote("a\n\nb") == "> a\n>\n> b")
        #expect(QuoteFormatter.blockquote("> nested") == "> > nested")
    }

    // MARK: Cross-document N

    @Test func nGoesOnToTheTabsAfterThisOneThenTheOtherWindows() {
        let groups = [["a", "b", "c"], ["d"], ["e", "f"]]
        #expect(CrossDocument.order(after: "b", groups: groups) == ["c", "a", "d", "e", "f"])
        #expect(CrossDocument.order(after: "e", groups: groups) == ["f", "a", "b", "c", "d"])
        #expect(CrossDocument.order(after: "d", groups: groups) == ["a", "b", "c", "e", "f"])
        // Not among them (a window being closed): every other one, in order.
        #expect(CrossDocument.order(after: "x", groups: groups) == ["a", "b", "c", "d", "e", "f"])
        #expect(CrossDocument.order(after: "a", groups: [["a"]]) == [])
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

    // MARK: U11: more unread waits for the page

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

    @Test func thePageSaysWhenToShowWhatItAdded() {
        #expect(PageMessage(["type": "showUnread"]) == .showUnread)
        // N with nothing unread left says so (on to the next document); D's "nothing" is a beep.
        #expect(PageMessage(["type": "nothing", "jump": NSNumber(value: true)]) == .noUnread)
        #expect(PageMessage(["type": "nothing", "jump": true]) == .noUnread)
        #expect(PageMessage(["type": "nothing"]) == .nothing)
        #expect(PageMessage(["type": "selection", "has": NSNumber(value: true)]) == .selection(has: true))
        #expect(PageMessage(["type": "selection", "has": false]) == .selection(has: false))
        #expect(PageMessage(["type": "selection"]) == nil)
    }

    // MARK: First open marked against the last commit

    struct FakeGit: GitRunning {
        var output: [String: Data] = [:]   // "dir|args" -> stdout
        func run(_ arguments: [String], in directory: String) -> Data? { output[directory + "|" + arguments.joined(separator: " ")] }
    }

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
        #expect(GitBaseline.baselineText(head: Data(), current: "# Plan") == nil)
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

    @Test func processRunnerKeepsToItsTimeAndSizeLimits() {
        #expect(ProcessRunner.run("/bin/sh", ["-c", "printf hello"], timeout: 5, limit: 100) == Data("hello".utf8))
        // Fails: nil.
        #expect(ProcessRunner.run("/bin/sh", ["-c", "exit 3"], timeout: 5, limit: 100) == nil)
        // Too slow: stopped at the limit, not waited for.
        let start = Date()
        #expect(ProcessRunner.run("/bin/sh", ["-c", "sleep 5"], timeout: 0.3, limit: 100) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
        // Too much: stopped.
        #expect(ProcessRunner.run("/bin/sh", ["-c", "head -c 200000 /dev/zero"], timeout: 5, limit: 1000) == nil)
        // Not there: nil.
        #expect(ProcessRunner.run("/nonexistent/git", [], timeout: 1, limit: 10) == nil)
        #expect(GitTools.available(xcodeSelect: "/nonexistent/xcode-select") == false)
    }

    // MARK: Plans know their project

    @Test func aPlanOutsideItsProjectNamesIt() {
        #expect(ReaderChrome.projectName(path: "/Users/me/.claude/plans/p.md", projectRoot: "/w/readout") == "readout")
        // Inside its project, or without one: nothing changes.
        #expect(ReaderChrome.projectName(path: "/w/readout/docs/p.md", projectRoot: "/w/readout") == nil)
        #expect(ReaderChrome.projectName(path: "/w/readout/docs/p.md", projectRoot: "/w/readout/") == nil)
        #expect(ReaderChrome.projectName(path: "/w/p.md", projectRoot: nil) == nil)
        #expect(ReaderChrome.subtitle(status: nil, tasks: TaskStats(done: 3, total: 7), path: "/p/p.md", showsTabBar: true, project: "readout")
                == .projectTasks(project: "readout", done: 3, total: 7))
        #expect(ReaderChrome.subtitle(status: nil, tasks: TaskStats(), path: "/p/p.md", showsTabBar: true, project: "readout") == .folder("readout"))
        #expect(ReaderChrome.subtitle(status: "The file was deleted.", tasks: TaskStats(), path: "/p/p.md", showsTabBar: true, project: "readout")
                == .status("The file was deleted."))
    }

    // MARK: U2: links to source files are looked for where code-span paths are

    @Test func linksToSourceFilesResolveInTheProject() {
        let plan = URL(fileURLWithPath: "/Users/me/.claude/plans/p.md")
        let resolver = FileResolver(baseDirectory: plan.deletingLastPathComponent(), searchRoots: [URL(fileURLWithPath: "/w/app")],
                                    projectRoot: URL(fileURLWithPath: "/w/app"))
        let existing: Set<String> = ["/w/app/src/a.ts", "/w/app/docs/design.md"]
        func resolve(_ href: String) -> LinkTarget? {
            LinkTarget.resolve(href, from: plan, markdownExtensions: ["md"], fileExists: { existing.contains($0.path) },
                               candidates: resolver.candidates(for:))
        }
        #expect(resolve("src/a.ts#L42") == .source(URL(fileURLWithPath: "/w/app/src/a.ts"), line: 42, column: 0))
        #expect(resolve("src/a.ts:7") == .source(URL(fileURLWithPath: "/w/app/src/a.ts"), line: 7, column: 0))
        #expect(resolve("a.ts:7") == .external(URL(string: "a.ts:7")!))   // only the file name: not in the project root
        #expect(resolve("src/a.ts") == .file(URL(fileURLWithPath: "/w/app/src/a.ts")))
        #expect(resolve("docs/design.md#goals") == .markdown(URL(fileURLWithPath: "/w/app/docs/design.md"), fragment: "goals"))
        // Nowhere: missing, beside the document as before.
        #expect(resolve("src/gone.ts#L3") == .missing(URL(fileURLWithPath: "/Users/me/.claude/plans/src/gone.ts")))
        // Without candidates, as before.
        #expect(LinkTarget.resolve("src/a.ts#L42", from: plan, markdownExtensions: ["md"], fileExists: { existing.contains($0.path) })
                == .missing(URL(fileURLWithPath: "/Users/me/.claude/plans/src/a.ts")))
    }

    @Test func aFileNameWithALineIsFoundInTheProjectToo() {
        let plan = URL(fileURLWithPath: "/plans/p.md")
        let existing: Set<String> = ["/w/app/main.swift"]
        let target = LinkTarget.resolve("main.swift:42", from: plan, markdownExtensions: ["md"], fileExists: { existing.contains($0.path) },
                                        candidates: { [URL(fileURLWithPath: "/plans/" + $0), URL(fileURLWithPath: "/w/app/" + $0)] })
        #expect(target == .source(URL(fileURLWithPath: "/w/app/main.swift"), line: 42, column: 0))
        // A URL scheme stays a URL.
        #expect(LinkTarget.resolve("tel:5551234", from: plan, markdownExtensions: ["md"], fileExists: { _ in false },
                                   candidates: { _ in [] }) == .external(URL(string: "tel:5551234")!))
    }

    // MARK: Window restoration

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
}
