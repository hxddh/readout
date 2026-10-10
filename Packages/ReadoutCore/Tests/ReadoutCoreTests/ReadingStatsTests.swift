import Testing
@testable import ReadoutCore

@Suite struct ReadingStatsTests {
    @Test func countsEnglishWords() {
        #expect(ReadingStats.words(in: "") == 0)
        #expect(ReadingStats.words(in: "hello world") == 2)
        #expect(ReadingStats.words(in: "  one   two\tthree\nfour  ") == 4)
        // Apostrophes split words ("don't" -> "don", "t"); matches the
        // whitespace-words estimate used for reading time.
        #expect(ReadingStats.words(in: "don't stop") == 3)
    }

    @Test func countsCJKCharactersIndividually() {
        #expect(ReadingStats.words(in: "你好世界") == 4)
        #expect(ReadingStats.words(in: "hello你好") == 3)
        #expect(ReadingStats.words(in: "テストです") == 5)
    }

    @Test func countsBlocks() {
        let doc = MarkdownParser.parse("# Title\n\nhello world\n\n你好\n")
        #expect(ReadingStats.words(in: doc.blocks) == 5)
    }

    @Test func minutesAreAtLeastOne() {
        #expect(ReadingStats.minutes(forWords: 0) == 1)
        #expect(ReadingStats.minutes(forWords: 400) == 1)
        #expect(ReadingStats.minutes(forWords: 600) == 2)
        #expect(ReadingStats.minutes(forWords: 4000) == 10)
    }
}

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
        // Too little overlap: the half-excerpt (first half of the excerpt) no
        // longer appears, so no anchor rather than a wrong one.
        #expect(ExcerptAnchor.index(of: "opening words of this block that used to be longer", in: texts) == nil)
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
}
