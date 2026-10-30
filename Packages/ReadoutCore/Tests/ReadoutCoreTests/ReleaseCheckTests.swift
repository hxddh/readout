import Foundation
import Testing
@testable import ReadoutCore

@Suite struct ReleaseCheckTests {
    @Test func comparesVersionsNumerically() {
        #expect(ReleaseCheck.isNewer("v3.1.0", than: "3.0.1"))
        #expect(ReleaseCheck.isNewer("1.0.10", than: "1.0.9"))
        #expect(ReleaseCheck.isNewer("v4", than: "3.9.9"))
        #expect(!ReleaseCheck.isNewer("v3.0.1", than: "3.0.1"))
        #expect(!ReleaseCheck.isNewer("3.0.0", than: "3.0.1"))
        #expect(!ReleaseCheck.isNewer("v3.1.0-beta", than: "3.1.0"))
        #expect(!ReleaseCheck.isNewer("v3.1", than: "3.1.0"))
    }

    @Test func preReleasesRankBelowTheRelease() {
        #expect(!ReleaseCheck.isNewer("3.1.0-rc.2", than: "3.1.0"))
        #expect(ReleaseCheck.isNewer("v3.1.0", than: "3.1.0-beta"))
        #expect(ReleaseCheck.isNewer("3.1.0-rc.10", than: "3.1.0-rc.2"))
        #expect(ReleaseCheck.isNewer("3.1.0-rc", than: "3.1.0-beta.9"))
        #expect(ReleaseCheck.isNewer("3.1.0-rc.1", than: "3.1.0-rc"))
        #expect(ReleaseCheck.isNewer("3.1.1-alpha", than: "3.1.0"))
        #expect(!ReleaseCheck.isNewer("3.1.0+build.7", than: "3.1.0"))
    }

    @Test func plainNotesStripsMarkdown() {
        let notes = "## Fixed\n\nSee **bold** and `code`, plus [a link](https://example.com/x)."
        let plain = ReleaseCheck.plainNotes(notes)
        #expect(!plain.contains("#"))
        #expect(!plain.contains("**"))
        #expect(!plain.contains("`"))
        #expect(!plain.contains("]("))
        #expect(plain.contains("Fixed"))
        #expect(plain.contains("bold"))
        #expect(plain.contains("a link"))
    }

    @Test func plainNotesCapsLength() {
        let long = String(repeating: "word ", count: 500)
        let plain = ReleaseCheck.plainNotes(long, limit: 600)
        #expect(plain.count <= 601)
        #expect(plain.hasSuffix("…"))
        #expect(ReleaseCheck.plainNotes("short").hasSuffix("short"))
    }

    /// The release body is docs/releases/X.Y.Z.md: the alert shows the
    /// release name above it, so a first `## X.Y.Z` heading said it twice,
    /// and `<kbd>` tags showed as typed.
    @Test func plainNotesDropsTheVersionHeadingAndHTMLTags() {
        let notes = "## 3.5.0\n\nReadout 3.5 is calmer.\n\n## Improved\n\n- Switch width with **View ▸ Wide Text** (<kbd>⌥⌘\\</kbd>).\n- A <b>bold</b> &amp; <br/> break"
        let plain = ReleaseCheck.plainNotes(notes)
        #expect(plain.hasPrefix("Readout 3.5 is calmer."))
        #expect(!plain.contains("3.5.0"))
        #expect(!plain.contains("<"))
        #expect(plain.contains("(⌥⌘\\)"))
        #expect(plain.contains("A bold & "))
        #expect(plain.contains("Improved"))
        // Only a heading that is nothing but the version, and only the first line.
        #expect(ReleaseCheck.plainNotes("## Fixed in 3.5.0\n\nx").hasPrefix("Fixed in 3.5.0"))
        #expect(ReleaseCheck.plainNotes("# v3.6.0\nx") == "x")
        #expect(ReleaseCheck.plainNotes("Intro\n\n## 3.5.0\n").contains("3.5.0"))
        #expect(ReleaseCheck.plainNotes("a < b, x<y and 2<3") == "a < b, x<y and 2<3")
        #expect(ReleaseCheck.plainNotes("`<details>` folds") == "<details> folds")
    }

    /// Every shipped release note, as the alert shows it.
    @Test func shippedNotesReadCleanly() throws {
        let releases = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/releases")
        let files = try FileManager.default.contentsOfDirectory(atPath: releases.path).filter { $0.hasSuffix(".md") }
        #expect(files.contains("3.5.0.md"))
        for name in files {
            let version = String(name.dropLast(3))
            let plain = ReleaseCheck.plainNotes(try String(contentsOf: releases.appendingPathComponent(name), encoding: .utf8))
            #expect(!plain.hasPrefix(version), "\(name) starts with its version")
            #expect(!plain.contains("<kbd>") && !plain.contains("</kbd>"), "\(name) shows HTML tags")
        }
    }

    @Test func downloadUpdateHandsTheDiskImageToTheBrowser() throws {
        let page = try #require(URL(string: "https://github.com/hxddh/readout/releases/tag/v3.9.0"))
        let dmg = try #require(URL(string: "https://github.com/hxddh/readout/releases/download/v3.9.0/Readout-3.9.0.dmg"))
        let zip = try #require(URL(string: "https://github.com/hxddh/readout/releases/download/v3.9.0/Readout-3.9.0.zip"))
        let releases = try #require(URL(string: "https://github.com/hxddh/readout/releases"))
        #expect(ReleaseCheck.downloadURL(assets: [("Readout-3.9.0.zip", zip), ("Readout-3.9.0.DMG", dmg)], page: page, releases: releases) == dmg)
        // No disk image, or one not on GitHub over https: the release page.
        #expect(ReleaseCheck.downloadURL(assets: [("Readout-3.9.0.zip", zip)], page: page, releases: releases) == page)
        let elsewhere = try #require(URL(string: "http://github.com/x/Readout.dmg"))
        let other = try #require(URL(string: "https://example.com/Readout.dmg"))
        #expect(ReleaseCheck.downloadURL(assets: [("Readout.dmg", elsewhere), ("Readout.dmg", other)], page: page, releases: releases) == page)
        #expect(ReleaseCheck.downloadURL(assets: [], page: page, releases: releases) == page)
        // A release page not on GitHub over https (or none): the releases page.
        #expect(ReleaseCheck.downloadURL(assets: [], page: elsewhere, releases: releases) == releases)
        #expect(ReleaseCheck.downloadURL(assets: [], page: other, releases: releases) == releases)
        #expect(ReleaseCheck.downloadURL(assets: [], page: nil, releases: releases) == releases)
    }
}
