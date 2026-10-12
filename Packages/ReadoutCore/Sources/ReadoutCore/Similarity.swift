import Foundation

enum CJK {
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2A6DF:
            return true
        default:
            return false
        }
    }

    /// Fraction of letter-like scalars that are CJK (code, where the flag only
    /// sets line breaking: its line height is its own).
    static func ratio(_ text: String) -> Double {
        var cjk = 0, letters = 0
        for s in text.unicodeScalars {
            let v = s.value
            if v < 0x80 {
                if (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) { letters += 1 }
            } else if isCJK(s) { cjk += 1; letters += 1 }
            else if s.properties.isAlphabetic { letters += 1 }
        }
        return letters == 0 ? 0 : Double(cjk) / Double(letters)
    }

    /// Fraction of prose's units that are CJK: each CJK character is a unit
    /// and so is each word of other letters, so a mixed sentence counts
    /// `Swift` as much as `编写`; inline code spans (identifiers, paths,
    /// commands) do not count. Mixed Chinese and English list items then
    /// read the same way instead of flipping with the length of the English words.
    static func proseRatio(_ text: String) -> Double {
        var skip: [Range<Int>] = []
        if text.utf8.contains(0x60) { skip = codeSpans(Array(text.unicodeScalars)) }
        var cjk = 0, units = 0
        var inWord = false
        var next = 0   // index into skip
        var i = -1
        for s in text.unicodeScalars {
            i += 1
            if next < skip.count, i >= skip[next].lowerBound {
                if i < skip[next].upperBound { inWord = false; continue }
                next += 1
                if next < skip.count, i >= skip[next].lowerBound { inWord = false; continue }
            }
            let v = s.value
            let letter: Bool
            if v < 0x80 {
                letter = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            } else if isCJK(s) {
                cjk += 1; units += 1
                letter = false
            } else {
                letter = s.properties.isAlphabetic
            }
            if letter && !inWord { units += 1 }
            inWord = letter
        }
        return units == 0 ? 0 : Double(cjk) / Double(units)
    }

    /// Ranges of backtick code spans: a run of backticks up to the next run of the same length.
    private static func codeSpans(_ scalars: [Unicode.Scalar]) -> [Range<Int>] {
        var runs: [(start: Int, end: Int)] = []
        var i = 0
        while i < scalars.count {
            if scalars[i] == "`" {
                var j = i
                while j < scalars.count && scalars[j] == "`" { j += 1 }
                runs.append((i, j))
                i = j
            } else {
                i += 1
            }
        }
        // For each run, the next run of the same length (found from the end, in one pass).
        var nextSame = [Int?](repeating: nil, count: runs.count)
        var lastOfLength: [Int: Int] = [:]
        for k in stride(from: runs.count - 1, through: 0, by: -1) {
            let len = runs[k].end - runs[k].start
            nextSame[k] = lastOfLength[len]
            lastOfLength[len] = k
        }
        var out: [Range<Int>] = []
        var k = 0
        while k < runs.count {
            if let m = nextSame[k] { out.append(runs[k].start..<runs[m].end); k = m + 1 } else { k += 1 }
        }
        return out
    }
}

/// Token-bigram Jaccard similarity. Latin text is tokenized into words, CJK into characters.
public enum Similarity {
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        // The current word as UTF-8. Words with non-ASCII letters are
        // lowercased when complete; ASCII (most of what agents write) is
        // lowercased and classified inline, without the much slower
        // CharacterSet lookup.
        var word: [UInt8] = []
        var nonASCII = false
        func flush() {
            guard !word.isEmpty else { return }
            let w = String(decoding: word, as: UTF8.self)
            out.append(nonASCII ? w.lowercased() : w)
            word.removeAll(keepingCapacity: true)
            nonASCII = false
        }
        for s in text.unicodeScalars {
            let v = s.value
            if v < 0x80 {
                if (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) { word.append(UInt8(v)) }
                else if v >= 0x41 && v <= 0x5A { word.append(UInt8(v + 0x20)) }
                else { flush() }
            } else if CJK.isCJK(s) {
                flush(); out.append(String(s))
            } else if CharacterSet.alphanumerics.contains(s) {
                word.append(contentsOf: String(s).utf8)
                nonASCII = true
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    static func shingles(_ text: String) -> Set<String> {
        let t = tokens(text)
        // Unigrams plus bigrams: robust for short blocks, order-sensitive for long ones.
        var set = Set(t)
        if t.count >= 2 { for i in 0..<(t.count - 1) { set.insert(t[i] + "\u{1}" + t[i + 1]) } }
        return set
    }

    public static func jaccard(_ a: String, _ b: String) -> Double {
        jaccardSets(shingles(a), shingles(b), bothEmpty: a == b)
    }

    /// Jaccard over precomputed shingle sets. `bothEmpty` is the tiebreaker when
    /// both sets are empty (the raw texts tokenized to nothing): pass whether the
    /// original texts were identical.
    static func jaccardSets(_ sa: Set<String>, _ sb: Set<String>, bothEmpty: Bool = true) -> Double {
        if sa.isEmpty && sb.isEmpty { return bothEmpty ? 1 : 0 }
        let inter = sa.intersection(sb).count
        let union = sa.union(sb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }
}
