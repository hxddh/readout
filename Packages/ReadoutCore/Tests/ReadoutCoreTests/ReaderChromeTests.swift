import Foundation
import Testing
@testable import ReadoutCore

@Suite struct ReaderChromeTests {
    @Test func theSubtitleShowsStatusFirstThenTasksAndTheFolderOnlyWithoutATabBar() {
        let tasks = TaskStats(done: 2, total: 5)
        for tabs in [true, false] {
            #expect(ReaderChrome.subtitle(status: "The file was deleted.", tasks: tasks, path: "/a/runs/plan.md", showsTabBar: tabs) == .status("The file was deleted."))
            #expect(ReaderChrome.subtitle(status: nil, tasks: tasks, path: "/a/runs/plan.md", showsTabBar: tabs) == .tasks(done: 2, total: 5))
            // A failed first read has no tasks and must still say why the window is blank.
            #expect(ReaderChrome.subtitle(status: "The file could not be read.", tasks: TaskStats(), path: "/a/plan.md", showsTabBar: tabs) == .status("The file could not be read."))
        }
        // Nothing to report with a tab bar: no subtitle (the tab's tooltip has the path).
        #expect(ReaderChrome.subtitle(status: "", tasks: TaskStats(), path: "/a/runs/plan.md", showsTabBar: true) == nil)
        // A window of its own (no tab bar, no tooltip): the folder tells two plan.md apart.
        #expect(ReaderChrome.subtitle(status: nil, tasks: TaskStats(), path: "/a/runs/plan.md", showsTabBar: false) == .folder("runs"))
        #expect(ReaderChrome.subtitle(status: nil, tasks: TaskStats(), path: "/plan.md", showsTabBar: false) == nil)
    }

    @Test func theTabToolTipIsThePathWithHomeAsTilde() {
        #expect(ReaderChrome.tabToolTip(path: "/Users/rust/.claude/plans/plan.md", home: "/Users/rust") == "~/.claude/plans/plan.md")
        #expect(ReaderChrome.tabToolTip(path: "/Users/rust/.claude/plans/plan.md", home: "/Users/rust/") == "~/.claude/plans/plan.md")
        // Only a whole folder name: /Users/rustacean is not under /Users/rust.
        #expect(ReaderChrome.tabToolTip(path: "/Users/rustacean/plan.md", home: "/Users/rust") == "/Users/rustacean/plan.md")
        #expect(ReaderChrome.tabToolTip(path: "/tmp/run/plan.md", home: "/Users/rust") == "/tmp/run/plan.md")
        #expect(ReaderChrome.tabToolTip(path: "/tmp/plan.md", home: "/") == "/tmp/plan.md")
    }

    @Test func recentTitlesNameTheFolderOnlyWhenNamesCollide() {
        let titles = ReaderChrome.recentTitles(["/w/app/plan.md", "/w/web/PLAN.md", "/w/notes.md", "/w/x/README.md"])
        #expect(titles == ["plan.md — app", "PLAN.md — web", "notes.md", "README.md"])
        #expect(ReaderChrome.recentTitles([]) == [])
    }

    @Test func recentTitlesShowMoreOfThePathWhenFoldersCollideToo() {
        // Every agent's plans/plan.md: the folder alone does not tell them apart.
        let titles = ReaderChrome.recentTitles(["/w/app/plans/plan.md", "/w/web/plans/plan.md", "/w/docs/plan.md",
                                                "/x/a/b/runs/plan.md", "/y/a/b/runs/plan.md"])
        #expect(titles == ["plan.md — app/plans", "plan.md — web/plans", "plan.md — docs",
                           "plan.md — x/a/b/runs", "plan.md — y/a/b/runs"])
        // Case-insensitively alike folders count as alike.
        #expect(ReaderChrome.recentTitles(["/a/Runs/plan.md", "/b/runs/plan.md"]) == ["plan.md — a/Runs", "plan.md — b/runs"])
        // A file at the root next to a same-named one in a folder; the same path twice ends.
        #expect(ReaderChrome.recentTitles(["/plan.md", "/x/plan.md"]) == ["plan.md", "plan.md — x"])
        #expect(ReaderChrome.recentTitles(["/a/plan.md", "/a/plan.md"]) == ["plan.md — a", "plan.md — a"])
        #expect(Set(ReaderChrome.recentTitles(["/p/q/plan.md", "/r/q/plan.md", "/s/plan.md"])).count == 3)
    }

    @Test func linkItemsInTheContextMenuStayOnlyForLinksToTheWeb() {
        let inPage = ReaderChrome.blockedContextMenuItems(linkURL: "readout://app/other.md")
        let web = ReaderChrome.blockedContextMenuItems(linkURL: "https://example.com/a")
        let unknown = ReaderChrome.blockedContextMenuItems(linkURL: nil)
        // A relative link resolves to readout://app/...: nothing to copy or open.
        #expect(inPage.contains("WKMenuItemIdentifierCopyLink") && inPage.contains("WKMenuItemIdentifierDownloadLinkedFile"))
        #expect(unknown.contains("WKMenuItemIdentifierCopyLink"))
        #expect(ReaderChrome.blockedContextMenuItems(linkURL: "file:///tmp/x.md").contains("WKMenuItemIdentifierCopyLink"))
        // A web link can be copied (opening it in the web view never works: a click opens it).
        #expect(!web.contains("WKMenuItemIdentifierCopyLink"))
        #expect(!ReaderChrome.blockedContextMenuItems(linkURL: "mailto:a@b.c").contains("WKMenuItemIdentifierCopyLink"))
        for blocked in [inPage, web, unknown] {
            #expect(blocked.isSuperset(of: ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow",
                                        "WKMenuItemIdentifierReload", "WKMenuItemIdentifierCopyImageURL"]))
            #expect(!blocked.contains("WKMenuItemIdentifierCopy") && !blocked.contains("WKMenuItemIdentifierLookUp"))
        }
    }

    @Test func anOutlineUnderASingleTitleIndentsFromItsSections() {
        // # Title, ## A, ### A.1, ## B: the sections start at the left edge.
        #expect(ReaderChrome.outlineBaseLevel([1, 2, 3, 2]) == 2)
        // Several top-level headings, or the top one not first: unchanged.
        #expect(ReaderChrome.outlineBaseLevel([1, 2, 1, 2]) == 1)
        #expect(ReaderChrome.outlineBaseLevel([2, 1, 2]) == 1)
        #expect(ReaderChrome.outlineBaseLevel([2, 3, 3]) == 3)
        #expect(ReaderChrome.outlineBaseLevel([1]) == 1)
        #expect(ReaderChrome.outlineBaseLevel([]) == 1)
    }

    /// 3.9 E12: the task count shows once. The lone title row leaves it to
    /// the window subtitle; its sections keep theirs.
    @Test func theLoneTitleRowShowsNoTaskCount() {
        let base = ReaderChrome.outlineBaseLevel([1, 2, 3, 2])
        #expect(!ReaderChrome.outlineShowsTasks(level: 1, baseLevel: base))
        #expect(ReaderChrome.outlineShowsTasks(level: 2, baseLevel: base))
        #expect(ReaderChrome.outlineShowsTasks(level: 3, baseLevel: base))
        // Several top-level headings: each one's count is its own.
        #expect(ReaderChrome.outlineShowsTasks(level: 1, baseLevel: ReaderChrome.outlineBaseLevel([1, 2, 1, 2])))
    }

    /// Help opens the shortcuts bundled with the app, in Readout, offline
    /// (3.5 opened the README on GitHub in the browser).
    @Test func helpOpensTheKeyboardShortcutsInTheReadersLanguage() {
        #expect(ReaderChrome.helpFileName(preferredLanguages: ["zh-Hans-CN", "en"]) == "Keyboard.zh-Hans.md")
        #expect(ReaderChrome.helpFileName(preferredLanguages: ["zh-Hans"]) == "Keyboard.zh-Hans.md")
        #expect(ReaderChrome.helpFileName(preferredLanguages: ["en-US"]) == "Keyboard.md")
        #expect(ReaderChrome.helpFileName(preferredLanguages: []) == "Keyboard.md")
    }

    /// The bundled help files exist and list the menu shortcuts.
    @Test func theHelpFilesExist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["Keyboard.md", "Keyboard.zh-Hans.md"] {
            let text = try String(contentsOf: root.appendingPathComponent("App/Help/\(name)"), encoding: .utf8)
            for key in ["⌘E", "⇧⌘R", "⌥⌘C", "⌘P", "⌥⌘W", "⌘K"] {
                #expect(text.contains(key), "\(name) lacks \(key)")
            }
            // 4.0: no text-width key (View ▸ Wide Text is gone: the column sizes itself).
            #expect(!text.contains("⌥⌘\\"), "\(name) still lists ⌥⌘\\")
        }
    }

    @Test func aWriteAfterAQuietSpellIsReportedAtOnce() {
        var d = WriteDebounce(trailing: 0.08, maxWait: 0.4)
        #expect(d.event(at: 10.0) == .fire)
        // More events right after (the rename's second notification, a burst): held.
        #expect(d.event(at: 10.03) == .schedule(after: 0.08))
        #expect(d.isHolding)
        #expect(d.event(at: 10.06) == .schedule(after: 0.08))
        d.fired(at: 10.14)
        #expect(!d.isHolding)
        // Still inside the trailing window of the last report: held, not doubled.
        #expect(d.event(at: 10.15) == .schedule(after: 0.08))
        d.fired(at: 10.23)
        // Quiet again: the next write fires immediately.
        #expect(d.event(at: 11.0) == .fire)
    }

    @Test func aContinuousWriteIsReportedWithinMaxWait() {
        var d = WriteDebounce(trailing: 0.08, maxWait: 0.4)
        var fires: [Double] = []
        var deadline: Double?
        // An event every 20 ms for two seconds; a scheduled report runs at its deadline.
        for i in 0..<100 {
            let t = Double(i) * 0.02
            if let due = deadline, due <= t { d.fired(at: due); fires.append(due); deadline = nil }
            switch d.event(at: t) {
            case .fire: fires.append(t)
            case .schedule(let after): deadline = t + after
            }
        }
        #expect(fires.first == 0)
        #expect(fires.count >= 4)
        for (a, b) in zip(fires, fires.dropFirst()) { #expect(b - a <= 0.4 + 0.02 + 1e-9) }
    }

    @Test func tabTitlesNameTheFileOnlyWhenTitlesRepeatInTheGroup() {
        // Two documents titled "Plan" in one tab group: the file names tell
        // them apart, first (3.8, U5: a narrow tab truncates the end, so the
        // 3.7 order "Plan — fix.md" showed the same "Plan —…" on every tab).
        #expect(ReaderChrome.tabTitles(titles: ["Plan", "plan", "Notes"], paths: ["/w/a/fix.md", "/w/b/refactor.md", "/w/notes.md"])
                == ["fix.md — Plan", "refactor.md — plan", "Notes"])
        // Same title and same file name (every agent's plan.md): the folder.
        #expect(ReaderChrome.tabTitles(titles: ["Plan", "Plan"], paths: ["/w/app/plan.md", "/w/web/plan.md"])
                == ["app — Plan", "web — Plan"])
        // Folders that collide too: as much of the path as Open Recent shows.
        #expect(ReaderChrome.tabTitles(titles: ["Plan", "Plan", "Plan"],
                                       paths: ["/x/app/plans/plan.md", "/y/app/plans/plan.md", "/x/notes.md"])
                == ["x/app/plans — Plan", "y/app/plans — Plan", "notes.md — Plan"])
        // Distinct titles stay as they are, and a group of one is untouched.
        #expect(ReaderChrome.tabTitles(titles: ["A", "B"], paths: ["/a.md", "/b.md"]) == ["A", "B"])
        #expect(ReaderChrome.tabTitles(titles: ["Plan"], paths: ["/w/plan.md"]) == ["Plan"])
        #expect(ReaderChrome.tabTitles(titles: [], paths: []) == [])
    }

    @Test func theEditorLineFollowsHowFarTheViewIsIntoTheTopBlock() {
        // A 100-line code block scrolled 40 % under the toolbar opens at line 50 of 10…110.
        #expect(ReaderChrome.editorLine(lines: 10...110, ratio: 0.4) == 50)
        #expect(ReaderChrome.editorLine(lines: 10...110, ratio: 0) == 10)
        #expect(ReaderChrome.editorLine(lines: 10...110, ratio: nil) == 10)
        #expect(ReaderChrome.editorLine(lines: 10...110, ratio: -0.2) == 10)
        #expect(ReaderChrome.editorLine(lines: 10...110, ratio: 1.7) == 110)
        #expect(ReaderChrome.editorLine(lines: 10...110, ratio: .nan) == 10)
        #expect(ReaderChrome.editorLine(lines: 7...7, ratio: 0.9) == 7)
    }

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

    @Test func theFolderListIsAsTallAsItsRows() {
        #expect(ReaderChrome.folderListRows(0) == 2)
        #expect(ReaderChrome.folderListRows(1) == 2)
        #expect(ReaderChrome.folderListRows(4) == 4)
        #expect(ReaderChrome.folderListRows(40) == 6)
    }
}
