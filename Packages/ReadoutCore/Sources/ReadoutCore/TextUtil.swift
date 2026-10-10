import Foundation

enum HTML {
    static func escape(_ s: String) -> String {
        // Fast path: most text needs no escaping.
        var needs = false
        for b in s.utf8 where b == 0x26 || b == 0x3C || b == 0x3E || b == 0x22 || b == 0x27 { needs = true; break }
        if !needs { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    private static let deniedTags = ["title", "textarea", "style", "xmp", "iframe", "noembed", "noframes",
                                     "script", "plaintext", "object", "embed", "base", "meta", "link", "form"]

    private static let remoteMediaSrc = try! NSRegularExpression(
        pattern: #"<(img|video|audio|source|track)\b([^>]*?)\s(src|srcset)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#,
        options: .caseInsensitive)

    /// GFM tagfilter plus removal of event handlers and javascript: URLs.
    /// Remote media sources are replaced with a click-to-load placeholder so
    /// raw HTML cannot phone home without the reader's consent — the same
    /// gate Markdown images go through.
    static func sanitize(_ raw: String) -> String {
        var s = raw
        for tag in deniedTags {
            s = s.replacingOccurrences(of: "<\(tag)", with: "&lt;\(tag)", options: [.caseInsensitive])
            s = s.replacingOccurrences(of: "</\(tag)", with: "&lt;/\(tag)", options: [.caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"\son[a-zA-Z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "javascript:", with: "blocked:", options: .caseInsensitive)
        s = gateRemoteMedia(s)
        return s
    }

    private static func gateRemoteMedia(_ s: String) -> String {
        let ns = s as NSString
        let matches = remoteMediaSrc.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let urlValue = ns.substring(with: m.range(at: 4))
            let unquoted = urlValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let lower = unquoted.lowercased()
            let isRemote = lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
            if isRemote {
                out += "<span class=\"remote-img\" data-src=\"\(escape(unquoted))\" data-alt=\"\"></span>"
            } else {
                out += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

/// GitHub-compatible heading slugs, with per-document de-duplication.
public struct Slugger {
    private var seen: [String: Int] = [:]
    private var used: Set<String> = []
    public init() {}

    public static func slug(_ text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar == " " { out += "-"; continue }
            if scalar == "-" || scalar == "_" { out.unicodeScalars.append(scalar); continue }
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar) {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    public mutating func next(_ text: String) -> String {
        let base = Slugger.slug(text)
        // An explicit "Notes-1" heading followed by a repeated "Notes" would
        // otherwise both claim "notes-1": keep probing until the candidate is
        // actually unused.
        var n = seen[base] ?? 0
        var candidate = base
        if n > 0 { candidate = "\(base)-\(n)" }
        while used.contains(candidate) {
            n += 1
            candidate = "\(base)-\(n)"
        }
        seen[base] = n + 1
        used.insert(candidate)
        return candidate
    }
}

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
        let sa = shingles(a), sb = shingles(b)
        if sa.isEmpty && sb.isEmpty { return a == b ? 1 : 0 }
        let inter = sa.intersection(sb).count
        let union = sa.union(sb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }
}
