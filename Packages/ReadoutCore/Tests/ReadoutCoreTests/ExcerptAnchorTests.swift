import Testing
@testable import ReadoutCore

@Suite struct ExcerptAnchorTests {
    @Test func emptyExcerptMatchesNothing() {
        #expect(ExcerptAnchor.index(of: "", in: ["abc"]) == nil)
    }

    @Test func prefixMatchSurvivesAppends() {
        let texts = ["intro paragraph here", "old second block that later grew a tail"]
        #expect(ExcerptAnchor.index(of: "old second block", in: texts) == 1)
    }

    @Test func containmentFallbackForMidBlockEdits() {
        let texts = ["the agent rewrote the opening words of this block"]
        // Whole-excerpt containment: the middle of the excerpt survived, so it anchors.
        #expect(ExcerptAnchor.index(of: "agent rewrote the opening words of this block!!", in: texts) == 0)
        #expect(ExcerptAnchor.index(of: "rewrote the opening words of this bloc", in: texts) == 0)
        // Rewritten tail: the surviving 25-character head still anchors —
        // a head that long matching elsewhere by coincidence is unlikely.
        #expect(ExcerptAnchor.index(of: "opening words of this block that used to be longer", in: texts) == 0)
        // No overlap at all: no anchor rather than a wrong one.
        #expect(ExcerptAnchor.index(of: "zzzz entire replacement text with no overlap at all here", in: texts) == nil)
    }

    @Test func halfExcerptFallbackForRewrittenTails() {
        let texts = ["prefix-1234567890-abcdefghij TAIL WAS REWRITTEN"]
        let excerpt = "prefix-1234567890-abcdefghij totally different tail here"
        #expect(excerpt.count >= 24)
        #expect(!texts[0].contains(excerpt))
        #expect(ExcerptAnchor.index(of: excerpt, in: texts) == 0)
    }

    @Test func shortExcerptsDoNotGuess() {
        #expect(ExcerptAnchor.index(of: "abc", in: ["xxabcyy"]) == nil)
    }

    @Test func picksFirstOfDuplicates() {
        #expect(ExcerptAnchor.index(of: "same intro text here", in: ["same intro text here", "same intro text here!"]) == 0)
    }

    @Test func nearBreaksTiesTowardSavedPosition() {
        // Agent plans repeat near-identical list items; without `near` the
        // resume position jumps to the first copy.
        let texts = ["- [ ] write the conditional-write case", "filler block here",
                     "- [ ] write the conditional-write case (done)"]
        #expect(ExcerptAnchor.index(of: "- [ ] write the conditional-write case", in: texts) == 0)
        #expect(ExcerptAnchor.index(of: "- [ ] write the conditional-write case", in: texts, near: 2) == 2)
        #expect(ExcerptAnchor.index(of: "- [ ] write the conditional-write case", in: texts, near: 1) == 0)
    }

    @Test func resumeFallsBackToTheIndexUnlessRewritten() {
        let texts = ["first block of the new text", "second block", "third block"]
        // The excerpt is found: rewritten or not, that block.
        #expect(ExcerptAnchor.resumeIndex(excerpt: "second block", index: 0, in: texts, rewritten: false) == 1)
        #expect(ExcerptAnchor.resumeIndex(excerpt: "second block", index: 0, in: texts, rewritten: true) == 1)
        // Not found: the saved index, except in a rewritten document (the top).
        #expect(ExcerptAnchor.resumeIndex(excerpt: "gone", index: 2, in: texts, rewritten: false) == 2)
        #expect(ExcerptAnchor.resumeIndex(excerpt: "gone", index: 2, in: texts, rewritten: true) == nil)
        #expect(ExcerptAnchor.resumeIndex(excerpt: "gone", index: 5, in: texts, rewritten: false) == nil)
        // 4.0: a position with an index and no excerpt (saved before 3.0) is none.
        #expect(ExcerptAnchor.resumeIndex(excerpt: nil, index: 2, in: texts, rewritten: false) == nil)
        #expect(ExcerptAnchor.resumeIndex(excerpt: nil, index: 2, in: texts, rewritten: true) == nil)
    }
}
