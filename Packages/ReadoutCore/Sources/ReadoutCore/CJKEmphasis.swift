import Foundation

/// CJK-friendly emphasis (https://github.com/tats-u/markdown-cjk-friendly).
///
/// CommonMark decides whether `*` and `_` open or close emphasis from the
/// characters around them, and treats CJK punctuation as punctuation:
/// `**注意：**这里` and `这是**加粗（括号）**的` keep their asterisks. The
/// CJK-friendly amendment changes that decision next to CJK characters,
/// CJK punctuation and variation selectors only.
///
/// cmark-gfm cannot be told the amended rule, so `MathProtector` adjusts
/// what it sees: for each delimiter run next to such a character whose
/// amended result differs from cmark's, it inserts an invisible marker
/// between the run and its neighbour, chosen so cmark computes the amended
/// result: `neutral` reads as a letter, `punctuation` as punctuation. The
/// renderer removes the markers from everything it outputs (`strip`).
/// Elsewhere both rules agree, and nothing is inserted: text without CJK
/// renders exactly as before.
enum CJKEmphasis {
    /// A letter to cmark (private use, not punctuation, not white space).
    static let neutral: Unicode.Scalar = "\u{E005}"
    /// Punctuation to cmark (U+1BC9F DUPLOYAN PUNCTUATION CHINOOK FULL STOP,
    /// the last code point of its punctuation table; not CJK).
    static let punctuation: Unicode.Scalar = "\u{1BC9F}"

    /// The line could hold a run that needs a marker: `*` or `_`, and a code
    /// point from U+1000 up (the lead bytes of all CJK and variation selectors).
    static func mayApply(_ line: String) -> Bool {
        var star = false, wide = false
        for b in line.utf8 {
            if b == 0x2A || b == 0x5F { star = true } else if b >= 0xE1 { wide = true }
            if star && wide { return true }
        }
        return false
    }

    enum Insert: Equatable { case none, neutral, punctuation }

    /// cmark-gfm's `scan_delims`: whether a run of `delimiter` between
    /// `before` and `after` (10 at a line's start or end) can open and close.
    static func cmark(_ delimiter: UInt8, before b: UInt32, after a: UInt32) -> (open: Bool, close: Bool) {
        let bs = CJKText.isSpace(b), asp = CJKText.isSpace(a)
        let bp = CJKText.isPunctuation(b), ap = CJKText.isPunctuation(a)
        let left = !asp && (!ap || bs || bp)
        let right = !bs && (!bp || asp || ap)
        if delimiter == 0x5F { return (left && (!right || bp), right && (!left || ap)) }
        return (left, right)
    }

    /// The amended rule (as markdown-it-cjk-friendly implements it):
    /// `before` the code point before the run (10: line start), `beforeThat`
    /// the one before it (looked at after a variation selector), `after` the
    /// one after the run (10: line end).
    static func amended(_ delimiter: UInt8, beforeThat p0: UInt32, before p1: UInt32, after a: UInt32) -> (open: Bool, close: Bool) {
        // After a text variation selector, the character it varies decides.
        var main = p1
        var twoBack: UInt32? = nil
        if CJKText.isTextVariationSelector(p1) {
            twoBack = p0
            if !CJKText.isSpace(p0) { main = p0 }
        }
        if CJKText.isSpace(main) || CJKText.isSpace(a) { return (!CJKText.isSpace(a), !CJKText.isSpace(main)) }
        let lp = CJKText.isPunctuation(main), np = CJKText.isPunctuation(a)
        var left = lp, right = np
        if delimiter == 0x2A {
            let previousCJK: Bool
            if let t = twoBack {
                // ‘︁ ’︁ “︁ ”︁: quotation marks in their fullwidth form.
                previousCJK = CJKText.isCJK(t) || (p1 == 0xFE01 && [0x2018, 0x2019, 0x201C, 0x201D].contains(t))
            } else {
                previousCJK = CJKText.isCJK(p1) || CJKText.isIdeographicVariationSelector(p1)
            }
            let eitherCJK = CJKText.isCJK(a) || previousCJK
            left = left || eitherCJK || !np
            right = right || eitherCJK || !lp
        }
        return (left, right)
    }

    /// What to insert before and after a run so cmark computes the amended
    /// result, or nil when cmark's result is already that (or no insertion
    /// gives it). `before` is nil at the start of the line's content, `after`
    /// nil at its end; `mayInsertBefore` / `mayInsertAfter` say whether the
    /// neighbour there is one a marker may follow / precede.
    static func inserts(_ delimiter: UInt8, beforeThat: UInt32?, before: UInt32?, after: UInt32?,
                        mayInsertBefore: Bool, mayInsertAfter: Bool) -> (Insert, Insert)? {
        let b = before ?? 10, a = after ?? 10
        // White space on either side: both rules agree (a variation selector
        // after white space aside, which the amendment leaves unspecified).
        if CJKText.isSpace(b) || CJKText.isSpace(a) { return nil }
        // Only CJK characters and variation selectors make the rules differ.
        let involved = CJKText.isCJK(a) || CJKText.isCJK(b) || CJKText.isTextVariationSelector(b)
            || CJKText.isIdeographicVariationSelector(b)
        guard involved else { return nil }
        let target = amended(delimiter, beforeThat: beforeThat ?? 10, before: b, after: a)
        let now = cmark(delimiter, before: b, after: a)
        if now == target { return nil }
        func code(_ i: Insert, _ v: UInt32) -> UInt32 {
            switch i {
            case .none: return v
            case .neutral: return neutral.value
            case .punctuation: return punctuation.value
            }
        }
        let options: [Insert] = [.none, .neutral, .punctuation]
        var best: (Insert, Insert, Int)? = nil
        for i in options where i == .none || mayInsertBefore {
            for j in options where j == .none || mayInsertAfter {
                let cost = (i == .none ? 0 : 1) + (j == .none ? 0 : 1)
                if cost == 0 { continue }
                let r = cmark(delimiter, before: code(i, b), after: code(j, a))
                if r == target, best.map({ cost < $0.2 }) ?? true { best = (i, j, cost) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Whether the lines hold a marker character themselves. Such a line gets
    /// no marker, and a block holding one keeps what is in it: markers could
    /// not be told apart from it. Decided per line and per block, so the full
    /// and the incremental parse agree. Byte scan first.
    static func containsMarker<C: Collection>(_ lines: C) -> Bool where C.Element: StringProtocol {
        lines.contains { line in
            line.utf8.contains { $0 == 0xEE || $0 == 0xF0 }
                && line.unicodeScalars.contains { $0 == neutral || $0 == punctuation }
        }
    }

    /// How many marker characters the lines hold.
    static func markerCount<C: Collection>(_ lines: C) -> Int where C.Element: StringProtocol {
        lines.reduce(0) { n, line in
            guard line.utf8.contains(where: { $0 == 0xEE || $0 == 0xF0 }) else { return n }
            return n + line.unicodeScalars.filter { $0 == neutral || $0 == punctuation }.count
        }
    }

    /// Text without the markers.
    static func strip(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0 == neutral || $0 == punctuation }) else { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars where u != neutral && u != punctuation { out.append(u) }
        return String(out)
    }
}
