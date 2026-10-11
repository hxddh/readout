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
}
