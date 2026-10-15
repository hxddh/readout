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
            for key in ["⌘E", "⇧⌘R", "⌥⌘C", "⌘P", "⌥⌘W", "⌘K", "⇧⌘K", "⌥⌘\\"] {
                #expect(text.contains(key), "\(name) lacks \(key)")
            }
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
}
