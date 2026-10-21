import Foundation
import Testing
@testable import ReadoutCore

/// 3.7 app shell: tab titles, the ⌘E line, the Sublime Text URL, the landing announcement.
@Suite struct AppShell37Tests {
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

    @Test func theSublimeURLKeepsTheWholePathInsideItsUrlValue() throws {
        let url = try #require(EditorURL.sublime(path: "/tmp/a&line=9 b=c#d?.md", line: 4))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        // One url= and one line=: "&" and "=" in the path do not start parameters of their own.
        #expect(items.map(\.name) == ["url", "line"])
        #expect(items[0].value == URL(fileURLWithPath: "/tmp/a&line=9 b=c#d?.md").absoluteString)
        #expect(items[1].value == "4")
        #expect(EditorURL.sublime(path: "/tmp/plain.md", line: 0)?.absoluteString == "subl://open?url=file%3A%2F%2F%2Ftmp%2Fplain.md")
    }

    @Test func aLandingOnAChangeDecodes() {
        #expect(PageMessage(["type": "landed", "index": NSNumber(value: 2), "total": NSNumber(value: 5), "kind": "railEdited"])
                == .landed(index: 2, total: 5, kind: "railEdited"))
        #expect(PageMessage(["type": "landed", "index": NSNumber(value: 6), "total": NSNumber(value: 5), "kind": "railEdited"]) == nil)
        #expect(PageMessage(["type": "landed", "index": NSNumber(value: 0), "total": NSNumber(value: 5), "kind": "railAdded"]) == nil)
        #expect(PageMessage(["type": "landed", "index": NSNumber(value: 1), "total": NSNumber(value: 1)]) == nil)
    }

    @Test func aFindCountDecodes() {
        #expect(PageMessage(["type": "found", "current": NSNumber(value: 3), "total": NSNumber(value: 12)]) == .found(current: 3, total: 12))
        #expect(PageMessage(["type": "found", "current": NSNumber(value: 0), "total": NSNumber(value: 0)]) == .found(current: 0, total: 0))
        #expect(PageMessage(["type": "found", "current": NSNumber(value: 4), "total": NSNumber(value: 3)]) == nil)
        #expect(PageMessage(["type": "found", "total": NSNumber(value: 3)]) == nil)
    }
}
