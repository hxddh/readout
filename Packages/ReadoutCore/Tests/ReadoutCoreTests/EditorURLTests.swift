import Foundation
import Testing
@testable import ReadoutCore

/// Opening a file in an editor at a line (`EditorURL`, `LineEditor`).
@Suite struct EditorURLTests {
    @Test func theSublimeURLKeepsTheWholePathInsideItsUrlValue() throws {
        let url = try #require(EditorURL.sublime(path: "/tmp/a&line=9 b=c#d?.md", line: 4))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        // One url= and one line=: "&" and "=" in the path do not start parameters of their own.
        #expect(items.map(\.name) == ["url", "line"])
        #expect(items[0].value == URL(fileURLWithPath: "/tmp/a&line=9 b=c#d?.md").absoluteString)
        #expect(items[1].value == "4")
        #expect(EditorURL.sublime(path: "/tmp/plain.md", line: 0)?.absoluteString == "subl://open?url=file%3A%2F%2F%2Ftmp%2Fplain.md")
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
}
