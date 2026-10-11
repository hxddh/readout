import Testing
@testable import ReadoutCore

@Suite struct UpdatePolicyTests {
    @Test func alertDecisionCoversAllFourCombinations() {
        // User-invoked checks always report back (update dialog, "up to
        // date" dialog, or failure dialog).
        #expect(UpdatePolicy.shouldAlert(interactive: true, hasUpdate: true))
        #expect(UpdatePolicy.shouldAlert(interactive: true, hasUpdate: false))
        // Background checks never pop up: an update goes to the app menu,
        // anything else stays silent.
        #expect(!UpdatePolicy.shouldAlert(interactive: false, hasUpdate: true))
        #expect(!UpdatePolicy.shouldAlert(interactive: false, hasUpdate: false))
    }

    @Test func plainNotesStripsMarkdown() {
        let notes = "## Fixed\n\nSee **bold** and `code`, plus [a link](https://example.com/x)."
        let plain = UpdatePolicy.plainNotes(notes)
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
        let plain = UpdatePolicy.plainNotes(long, limit: 600)
        #expect(plain.count <= 601)
        #expect(plain.hasSuffix("…"))
        #expect(UpdatePolicy.plainNotes("short").hasSuffix("short"))
    }
}

@Suite struct WelcomeHeightTests {
    @Test func growsWithRecentsAndCapsAtFive() {
        #expect(WelcomeHeight.height(forRecentCount: 0) == 400)
        #expect(WelcomeHeight.height(forRecentCount: 1) == 454)
        #expect(WelcomeHeight.height(forRecentCount: 3) == 502)
        #expect(WelcomeHeight.height(forRecentCount: 5) == 550)
        #expect(WelcomeHeight.height(forRecentCount: 9) == 550)
    }
}
