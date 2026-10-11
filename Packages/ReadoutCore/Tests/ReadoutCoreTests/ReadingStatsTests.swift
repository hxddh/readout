import Testing
@testable import ReadoutCore

@Suite struct ReadingStatsTests {
    @Test func countsEnglishWords() {
        #expect(ReadingStats.words(in: "") == 0)
        #expect(ReadingStats.words(in: "hello world") == 2)
        #expect(ReadingStats.words(in: "  one   two\tthree\nfour  ") == 4)
        // "don't" is one word: the apostrophe joins, it does not split.
        // (Corrects the earlier expectation of 3, which encoded the bug.)
        #expect(ReadingStats.words(in: "don't stop") == 2)
        #expect(ReadingStats.words(in: "it’s ’tis") == 2)
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

    @Test func excludesNonProseBlocks() {
        let doc = MarkdownParser.parse("# Title\n\nhello world\n\n```swift\nlet aaaaa = bbbbbbbb\nlet ccccc = dddddddd\n```\n\n$$x + y$$\n\n<div>raw html words here yes</div>\n")
        // Only the heading and paragraph count (1 + 2); code, math and raw
        // HTML are scanning material, not reading material.
        #expect(ReadingStats.words(in: doc.blocks) == 3)
    }

    @Test func minutesAreAtLeastOne() {
        #expect(ReadingStats.minutes(forWords: 0) == 1)
        #expect(ReadingStats.minutes(forWords: 230) == 1)
        #expect(ReadingStats.minutes(forWords: 345) == 2)
        #expect(ReadingStats.minutes(forWords: 2300) == 10)
    }

    @Test func mixedPaceMinutes() {
        // 230 Latin words read in a minute; 450 CJK characters in a minute.
        let latin = String(repeating: "word ", count: 230)
        let cjk = String(repeating: "字", count: 450)
        let doc = MarkdownParser.parse("\(latin)\n\n\(cjk)\n")
        #expect(ReadingStats.minutes(forBlocks: doc.blocks) == 2)
        let tiny = MarkdownParser.parse("hi\n")
        #expect(ReadingStats.minutes(forBlocks: tiny.blocks) == 1)
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
}
