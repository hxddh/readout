import Foundation
import Testing
@testable import ReadoutCore

/// 3.9 app shell: one key for Open Latest Agent File (S3, S4), the default
/// app's editor at the line (S5), the Edit menu without what macOS adds (S8),
/// the About panel's Acknowledgements link (E8), the folder list's height (E14).
@Suite struct AppShell39Tests {
    @Test func theShortcutIsAToggleThatKeepsAStoredKey() {
        // Nothing stored, or a value from no version: ⌃⌥⌘R, on.
        #expect(OpenLatestKey(stored: nil) == .ctrlOptCmdR)
        #expect(OpenLatestKey(stored: "bogus") == .ctrlOptCmdR)
        // A key chosen before 3.9 keeps working and is what is shown.
        for (stored, title) in [("optCmdR", "⌥⌘R"), ("ctrlOptR", "⌃⌥R"), ("ctrlOptCmdR", "⌃⌥⌘R")] {
            let key = OpenLatestKey(stored: stored)
            #expect(key.isGlobal && key.title == title)
            #expect(key.turned(on: true) == key)
            #expect(key.turned(on: false) == OpenLatestKey.none)
        }
        // Off (stored "none", the picker's Off before 3.9): not global, but the
        // menu still has ⌃⌥⌘R; on again gives ⌃⌥⌘R.
        let off = OpenLatestKey(stored: "none")
        #expect(!off.isGlobal && off.title == "⌃⌥⌘R" && off.modifiers == [.control, .option, .command])
        #expect(off.turned(on: true) == .ctrlOptCmdR)
        #expect(OpenLatestKey.ctrlOptR.modifiers == [.control, .option])
        #expect(OpenLatestKey.optCmdR.modifiers == [.option, .command])
    }

    @Test func theDefaultAppIsLineAwareWhenItIsAKnownEditor() {
        #expect(LineEditor(bundleIdentifier: "com.microsoft.VSCode") == .vscode)
        #expect(LineEditor(bundleIdentifier: "com.todesktop.230313mzl4w4u92") == .cursor)
        #expect(LineEditor(bundleIdentifier: "dev.zed.Zed") == .zed)
        #expect(LineEditor(bundleIdentifier: "dev.zed.Zed-Preview") == .zed)
        #expect(LineEditor(bundleIdentifier: "com.apple.dt.Xcode") == .xcode)
        #expect(LineEditor(bundleIdentifier: "com.sublimetext.4") == .sublime)
        #expect(LineEditor(bundleIdentifier: "com.sublimetext.3") == .sublime)
        for other in ["com.apple.TextEdit", "io.github.hxddh.readout", "com.coteditor.CotEditor", ""] {
            #expect(LineEditor(bundleIdentifier: other) == nil)
        }
        // The stored `editor` values are the same names (Settings' picker overrides).
        #expect(LineEditor.allCases.map(\.rawValue) == ["vscode", "cursor", "zed", "xcode", "sublime"])
    }

    @Test func lineAwareLinksCarryTheLineAndEscapeTheFragment() {
        #expect(LineEditor.vscode.url(path: "/tmp/a#b?.md", line: 3, column: 2)?.absoluteString == "vscode://file/tmp/a%23b%3F.md:3:2")
        #expect(LineEditor.cursor.url(path: "/tmp/x y.swift", line: 9, column: 0)?.absoluteString == "cursor://file/tmp/x%20y.swift:9")
        #expect(LineEditor.zed.url(path: "/tmp/z.md", line: 0, column: 5)?.absoluteString == "zed://file/tmp/z.md")
        #expect(LineEditor.sublime.url(path: "/tmp/plain.md", line: 4, column: 0)?.absoluteString == "subl://open?url=file%3A%2F%2F%2Ftmp%2Fplain.md&line=4")
        #expect(LineEditor.xcode.url(path: "/tmp/a.swift", line: 4, column: 1) == nil)
    }

    @Test func theEditMenuLosesWhatMacOSAdds() {
        typealias I = SystemMenuItems.Item
        // As CI's menus.json shows the Edit menu of 3.8 on macOS 26.
        let items: [I] = [
            I(action: "undo:"), I(action: "redo:"), I(action: nil, isSeparator: true),
            I(action: "copy:"), I(action: nil, isSeparator: true),
            I(action: "submenuAction:", submenuActions: ["showFind:", "findNext:"]),
            I(action: "submenuAction:", submenuActions: ["startSpeaking:", "stopSpeaking:"]),
            I(action: nil, isSeparator: true),
            I(action: "submenuAction:", submenuActions: ["_handleInsertFromContactsCommand:", "_handleInsertFromPasswordsCommand:", "_handleInsertFromCreditCardsCommand:"]),
            I(action: "startDictation:"), I(action: "startDictation:"),
            I(action: "orderFrontCharacterPalette:"), I(action: "orderFrontCharacterPalette:"),
        ]
        let removed = SystemMenuItems.removals(items)
        #expect(removed == [12, 11, 10, 9, 8, 7])
        var kept = items
        for n in removed { kept.remove(at: n) }
        #expect(kept.last?.submenuActions == ["startSpeaking:", "stopSpeaking:"])
        // Nothing added: nothing removed. A doubled separator goes.
        #expect(SystemMenuItems.removals(Array(items.prefix(7))).isEmpty)
        #expect(SystemMenuItems.removals([I(action: "a:"), I(action: nil, isSeparator: true), I(action: nil, isSeparator: true), I(action: "b:")]) == [2])
    }

    @Test func theAcknowledgementsLinkOpensTheFileInReadout() throws {
        let path = "/Applications/Read out & co.app/Contents/Resources/Acknowledgements.md"
        let url = try #require(OpenLink.url(path: path))
        #expect(url.scheme == OpenLink.scheme)
        let request = try #require(OpenLink.parse(url))
        #expect(request.path == path && !request.background && request.anchor == nil && request.root == nil)
    }

    @Test func downloadUpdateHandsTheDiskImageToTheBrowser() throws {
        let page = try #require(URL(string: "https://github.com/hxddh/readout/releases/tag/v3.9.0"))
        let dmg = try #require(URL(string: "https://github.com/hxddh/readout/releases/download/v3.9.0/Readout-3.9.0.dmg"))
        let zip = try #require(URL(string: "https://github.com/hxddh/readout/releases/download/v3.9.0/Readout-3.9.0.zip"))
        #expect(ReleaseCheck.downloadURL(assets: [("Readout-3.9.0.zip", zip), ("Readout-3.9.0.DMG", dmg)], page: page) == dmg)
        // No disk image, or one not on GitHub over https: the release page.
        #expect(ReleaseCheck.downloadURL(assets: [("Readout-3.9.0.zip", zip)], page: page) == page)
        let elsewhere = try #require(URL(string: "http://github.com/x/Readout.dmg"))
        let other = try #require(URL(string: "https://example.com/Readout.dmg"))
        #expect(ReleaseCheck.downloadURL(assets: [("Readout.dmg", elsewhere), ("Readout.dmg", other)], page: page) == page)
        #expect(ReleaseCheck.downloadURL(assets: [], page: page) == page)
    }

    @Test func theFolderListIsAsTallAsItsRows() {
        #expect(ReaderChrome.folderListRows(0) == 2)
        #expect(ReaderChrome.folderListRows(1) == 2)
        #expect(ReaderChrome.folderListRows(4) == 4)
        #expect(ReaderChrome.folderListRows(40) == 6)
    }
}
