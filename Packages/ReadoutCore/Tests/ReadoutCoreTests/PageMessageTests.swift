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
        #expect(PageMessage(["type": "setCodeWrap", "on": NSNumber(value: true)]) == .setCodeWrap(on: true))
        #expect(PageMessage(["type": "setCodeWrap"]) == nil)
    }

    @Test func rejectsMalformedMessages() {
        #expect(PageMessage([:]) == nil)
        #expect(PageMessage(["type": "nope"]) == nil)
        #expect(PageMessage(["type": "activeHeading"]) == nil)
        #expect(PageMessage(["type": "anchor", "anchor": NSNull()]) == nil)   // captureAnchor() can be null
        #expect(PageMessage(["type": "copyLink", "anchor": ""]) == nil)
        #expect(PageMessage(["type": "loadRemote", "url": "https://x/a.png"]) == nil)
    }
}

@Suite struct LinkTargetTests {
    let doc = URL(fileURLWithPath: "/work/plans/plan.md")
    let md: Set<String> = ["md", "markdown"]

    func resolve(_ href: String, exists: Bool = true) -> LinkTarget? {
        LinkTarget.resolve(href, from: doc, markdownExtensions: md, fileExists: { _ in exists })
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
        #expect(resolve("gone.png", exists: false) == .missing)
    }
}
