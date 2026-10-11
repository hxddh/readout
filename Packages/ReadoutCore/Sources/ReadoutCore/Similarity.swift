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

    /// Fraction of letter-like scalars that are CJK.
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
}

/// Token-bigram Jaccard similarity. Latin text is tokenized into words, CJK into characters.
public enum Similarity {
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        func flush() { if !word.isEmpty { out.append(word); word = "" } }
        for s in text.lowercased().unicodeScalars {
            if CJK.isCJK(s) {
                flush(); out.append(String(s))
            } else if CharacterSet.alphanumerics.contains(s) {
                word.unicodeScalars.append(s)
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
