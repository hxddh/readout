import Foundation

/// Word count and reading-time estimates for subtitles and progress.
public enum ReadingStats {
    /// Block kinds that carry prose. Code, math, diagrams, raw HTML and front
    /// matter are excluded: they take scanning, not reading, time.
    public static let proseKinds: Set<BlockKind> = [.paragraph, .heading, .listItem, .quote, .alert, .table]

    /// CJK characters count individually; Latin text counts words. An
    /// apostrophe inside a word (don't, it's, ’) does not split it.
    public static func words(in text: String) -> Int {
        counts(in: text).latin + counts(in: text).cjk
    }

    /// Separate Latin-word and CJK-character counts, for mixed-speed timing.
    public static func counts(in text: String) -> (latin: Int, cjk: Int) {
        var latin = 0, cjk = 0
        var inWord = false
        let scalars = Array(text.unicodeScalars)
        for (i, s) in scalars.enumerated() {
            if CJK.isCJK(s) {
                cjk += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(s) {
                if !inWord { latin += 1; inWord = true }
            } else if s.value == 0x27 || s.value == 0x2019 {  // ' or ’
                // Keep inWord: an apostrophe between alphanumerics (don't)
                // joins; a leading/trailing one (’tis, ’) starts nothing.
                let prevIsWord = i > 0 && CharacterSet.alphanumerics.contains(scalars[i - 1])
                let nextIsWord = i + 1 < scalars.count && CharacterSet.alphanumerics.contains(scalars[i + 1])
                if !(prevIsWord && nextIsWord) { inWord = false }
            } else {
                inWord = false
            }
        }
        return (latin, cjk)
    }

    public static func words(in blocks: [Block]) -> Int {
        blocks.filter { proseKinds.contains($0.kind) }.reduce(0) { $0 + words(in: $1.text) }
    }

    /// Mixed-pace minutes: Latin words at 230 wpm plus CJK characters at
    /// 450 cpm, always at least 1.
    public static func minutes(forWords words: Int, wpm: Int = 230) -> Int {
        max(1, Int((Double(words) / Double(wpm)).rounded()))
    }

    public static func minutes(forBlocks blocks: [Block]) -> Int {
        let prose = blocks.filter { proseKinds.contains($0.kind) }
        var latin = 0, cjk = 0
        for b in prose {
            let c = counts(in: b.text)
            latin += c.latin
            cjk += c.cjk
        }
        return max(1, Int((Double(latin) / 230.0 + Double(cjk) / 450.0).rounded()))
    }
}
