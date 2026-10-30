import Foundation
import Testing
@testable import ReadoutCore

@Suite struct PageMessageTests {
    @Test func decodesWebKitShapes() {
        // WebKit delivers numbers as NSNumber and arrays as [Any].
        #expect(PageMessage(["type": "read", "slots": [NSNumber(value: 3), NSNumber(value: 5)] as [Any], "deletions": [NSNumber(value: 1)] as [Any]])
                == .read(slots: [3, 5], deletions: [1]))
        #expect(PageMessage(["type": "read"]) == .read(slots: [], deletions: []))
        #expect(PageMessage(["type": "activeHeading", "slot": NSNumber(value: 7)]) == .activeHeading(slot: 7))
        #expect(PageMessage(["type": "anchor", "anchor": ["slot": NSNumber(value: 2), "offset": NSNumber(value: 12.5)] as [String: Any]])
                == .anchor(slot: 2, offset: 12.5))
        #expect(PageMessage(["type": "anchor", "anchor": ["slot": NSNumber(value: 2)] as [String: Any]]) == .anchor(slot: 2, offset: 0))
        #expect(PageMessage(["type": "openPath", "path": "a.swift", "line": NSNumber(value: 4)]) == .openPath(path: "a.swift", line: 4, column: 0))
        #expect(PageMessage(["type": "loadRemote", "url": "https://x/a.png", "id": "r1"]) == .loadRemote(url: "https://x/a.png", id: "r1"))
        #expect(PageMessage(["type": "applied", "version": NSNumber(value: 1)]) == .applied)
        #expect(PageMessage(["type": "painted", "version": NSNumber(value: 1)]) == .painted)
        #expect(PageMessage(["type": "setCodeWrap", "on": NSNumber(value: true)]) == .setCodeWrap(on: true))
        #expect(PageMessage(["type": "setCodeWrap"]) == nil)
        // N with no change left: the page says so and the app beeps.
        #expect(PageMessage(["type": "nothing"]) == .nothing)
        #expect(PageMessage(["type": "wrapped"]) == .wrapped)
        // 3.9 E9: a context menu on a heading offers Copy Link to Section;
        // the page says which heading, or none, for every menu.
        #expect(PageMessage(["type": "contextHeading", "anchor": "plan"]) == .contextHeading(anchor: "plan"))
        #expect(PageMessage(["type": "contextHeading", "anchor": ""]) == .contextHeading(anchor: nil))
    }

    @Test func rejectsMalformedMessages() {
        #expect(PageMessage([:]) == nil)
        #expect(PageMessage(["type": "nope"]) == nil)
        #expect(PageMessage(["type": "activeHeading"]) == nil)
        #expect(PageMessage(["type": "anchor", "anchor": NSNull()]) == nil)   // captureAnchor() can be null
        #expect(PageMessage(["type": "contextHeading"]) == nil)
        // The hover § button is gone (3.9 E9): nothing posts copyLink.
        #expect(PageMessage(["type": "copyLink", "anchor": "plan"]) == nil)
        #expect(PageMessage(["type": "loadRemote", "url": "https://x/a.png"]) == nil)
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

    /// Text selected and a focused block are told apart: the context menu
    /// offers Copy as Quote for a text selection only (a right click elsewhere
    /// leaves the focus on the block N went to), the Edit menu for either.
    @Test func theSelectionMessageTellsTextFromAFocusedBlock() {
        #expect(PageMessage(["type": "selection", "has": false, "focused": true]) == .selection(has: false, focused: true))
        #expect(PageMessage(["type": "selection", "has": NSNumber(value: true), "focused": NSNumber(value: false)]) == .selection(has: true, focused: false))
        #expect(PageMessage(["type": "selection", "has": true]) == .selection(has: true, focused: false))
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

@Suite struct LinkTargetTests {
    let doc = URL(fileURLWithPath: "/work/plans/plan.md")
    let md: Set<String> = ["md", "markdown"]

    func resolve(_ href: String, exists: Bool = true) -> LinkTarget? {
        LinkTarget.resolve(href, from: doc, markdownExtensions: md, fileExists: { _ in exists })
    }

    /// Only the listed paths exist.
    func resolve(_ href: String, existing: Set<String>, folders: Set<String> = []) -> LinkTarget? {
        LinkTarget.resolve(href, from: doc, markdownExtensions: md, fileExists: { existing.contains($0.path) || folders.contains($0.path) },
                           isDirectory: { folders.contains($0.path) })
    }

    @Test func externalSchemes() {
        #expect(resolve("https://example.com/a#b") == .external(URL(string: "https://example.com/a#b")!))
        #expect(resolve("mailto:a@b.c") == .external(URL(string: "mailto:a@b.c")!))
    }

    @Test func sameDocumentFragments() {
        #expect(resolve("#risks") == .sameDocument(fragment: "risks"))
        #expect(resolve("#") == nil)
        #expect(resolve("") == nil)
    }

    @Test func markdownFilesWithSections() {
        #expect(resolve("other.md#section") == .markdown(URL(fileURLWithPath: "/work/plans/other.md"), fragment: "section"))
        #expect(resolve("../spec.MD") == .markdown(URL(fileURLWithPath: "/work/spec.MD"), fragment: nil))
        #expect(resolve("my%20notes.md") == .markdown(URL(fileURLWithPath: "/work/plans/my notes.md"), fragment: nil))
        #expect(resolve("/abs/x.markdown#") == .markdown(URL(fileURLWithPath: "/abs/x.markdown"), fragment: nil))
        #expect(resolve("file:///abs/y.md#top") == .markdown(URL(fileURLWithPath: "/abs/y.md"), fragment: "top"))
    }

    @Test func otherLocalFiles() {
        #expect(resolve("diagram.png") == .file(URL(fileURLWithPath: "/work/plans/diagram.png")))
        #expect(resolve("gone.png", exists: false) == .missing(URL(fileURLWithPath: "/work/plans/gone.png")))
        #expect(resolve("src/a.ts") == .file(URL(fileURLWithPath: "/work/plans/src/a.ts")))
    }

    /// A line in a link to a source file opens the editor there (3.5 opened
    /// the file with the system, at its top, and beeped for path:line).
    @Test func sourceLines() {
        let a = "/work/plans/src/a.ts"
        let file = URL(fileURLWithPath: a)
        #expect(resolve("src/a.ts#L42", existing: [a]) == .source(file, line: 42, column: 0))
        #expect(resolve("src/a.ts#L42C3", existing: [a]) == .source(file, line: 42, column: 3))
        #expect(resolve("src/a.ts#L42-L50", existing: [a]) == .source(file, line: 42, column: 0))
        #expect(resolve("src/a.ts#L42C3-L50C9", existing: [a]) == .source(file, line: 42, column: 3))
        #expect(resolve("src/a.ts:42", existing: [a]) == .source(file, line: 42, column: 0))
        #expect(resolve("src/a.ts:42:7", existing: [a]) == .source(file, line: 42, column: 7))
        #expect(resolve("/work/plans/src/a.ts:9", existing: [a]) == .source(file, line: 9, column: 0))
        #expect(resolve("file:///work/plans/src/a.ts#L5", existing: [a]) == .source(file, line: 5, column: 0))
        // No slash: "a.ts:42" parses with the scheme "a.ts".
        #expect(resolve("main.swift:42", existing: ["/work/plans/main.swift"]) == .source(URL(fileURLWithPath: "/work/plans/main.swift"), line: 42, column: 0))
        #expect(resolve("Makefile:12", existing: ["/work/plans/Makefile"]) == .source(URL(fileURLWithPath: "/work/plans/Makefile"), line: 12, column: 0))
        #expect(resolve("tel:5551234", existing: []) == .external(URL(string: "tel:5551234")!))
        // A custom scheme with a dot stays a URL unless such a file is there.
        #expect(resolve("com.example.viewer:42", existing: []) == .external(URL(string: "com.example.viewer:42")!))
        // Not a line fragment: the file, opened by the system.
        #expect(resolve("src/a.ts#intro", existing: [a]) == .file(file))
        #expect(resolve("src/a.ts#L0", existing: [a]) == .file(file))
        // Missing: named, so the reader can be told which.
        #expect(resolve("src/b.ts:3", existing: [a]) == .missing(URL(fileURLWithPath: "/work/plans/src/b.ts")))
        #expect(resolve("src/b.ts#L3", existing: [a]) == .missing(URL(fileURLWithPath: "/work/plans/src/b.ts")))
        // A file really named with a colon and digits is that file.
        #expect(resolve("odd:12", existing: ["/work/plans/odd:12"]) == .file(URL(fileURLWithPath: "/work/plans/odd:12")))
    }

    /// Images, PDFs and folders go to the system even with a line; Markdown stays in Readout.
    @Test func linesThatDoNotGoToTheEditor() {
        #expect(resolve("shot.png#L3", existing: ["/work/plans/shot.png"]) == .file(URL(fileURLWithPath: "/work/plans/shot.png")))
        #expect(resolve("doc.pdf:2", existing: ["/work/plans/doc.pdf"]) == .file(URL(fileURLWithPath: "/work/plans/doc.pdf")))
        #expect(resolve("src:4", existing: [], folders: ["/work/plans/src"]) == .file(URL(fileURLWithPath: "/work/plans/src")))
        #expect(resolve("other.md:12", existing: ["/work/plans/other.md"]) == .markdown(URL(fileURLWithPath: "/work/plans/other.md"), fragment: nil))
        #expect(resolve("other.md#L12", existing: []) == .markdown(URL(fileURLWithPath: "/work/plans/other.md"), fragment: "L12"))
    }
}

/// 4.1: what the app asks about before it opens a link.
@Suite struct LinkSafetyTests {
    func runs(_ path: String, folder: Bool = false, executable: Bool = false) -> Bool {
        LinkTarget.runsWhenOpened(URL(fileURLWithPath: path), isDirectory: folder, isExecutable: executable)
    }

    @Test func bundlesScriptsAndInstallersRunWhenOpened() {
        for app in ["/A/Tool.app", "/A/Run.workflow", "/A/X.prefPane", "/A/S.saver", "/A/K.kext", "/A/E.appex", "/A/H.XPC"] {
            #expect(runs(app, folder: true), "\(app)")
        }
        for file in ["run.command", "x.tool", "a.terminal", "go.sh", "b.zsh", "c.bash", "d.csh", "e.fish", "f.py", "g.rb",
                     "h.pl", "i.scpt", "j.applescript", "k.jsa", "setup.pkg", "s.mpkg", "disk.dmg", "app.jar",
                     "site.webloc", "s.inetloc", "f.fileloc", "link.URL"] {
            #expect(runs("/work/" + file), "\(file)")
        }
    }

    @Test func documentsAndFoldersDoNot() {
        #expect(!runs("/work/src", folder: true))
        #expect(!runs("/work/Notes.d", folder: true))
        for file in ["shot.png", "spec.pdf", "data.csv", "readme", "main.swift", "Makefile"] { #expect(!runs("/work/" + file), "\(file)") }
        // The executable bit: on a document it means nothing, anything else may run.
        #expect(!runs("/work/shot.png", executable: true))
        #expect(!runs("/work/notes.txt", executable: true))
        #expect(runs("/work/build", executable: true))
        #expect(runs("/work/run.swift", executable: true))
    }

    @Test func onlyWebAndMailSchemesAreSafe() {
        for u in ["https://example.com", "HTTP://example.com/a", "mailto:a@b.c"] {
            #expect(LinkTarget.isSafeExternalScheme(URL(string: u)!), "\(u)")
        }
        for u in ["tel:5551234", "ssh://host", "smb://nas/share", "x-apple.systempreferences:com.apple", "vscode://file/x",
                  "file:///etc/passwd", "ftp://example.com/x"] {
            #expect(!LinkTarget.isSafeExternalScheme(URL(string: u)!), "\(u)")
        }
    }
}
