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
        pattern: #"<(img|video|audio|source|track)\b[^>]*?\s(src|srcset)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)[^>]*>?"#,
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

    // NOTE (security boundary): this regex gate is UX only — it turns common
    // remote media into click-to-load placeholders. The real security
    // boundary is the Content-Security-Policy in web/src/reader.html, which
    // allows no http:/https: sources at all, so every construct this regex
    // misses is still blocked by the browser. See docs/design.md.
    private static func gateRemoteMedia(_ s: String) -> String {
        let ns = s as NSString
        let matches = remoteMediaSrc.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let urlValue = ns.substring(with: m.range(at: 3))
            let unquoted = urlValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let lower = unquoted.lowercased()
            let isRemote = lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
            var end = m.range.location + m.range.length
            if isRemote {
                let tag = ns.substring(with: m.range(at: 1)).lowercased()
                // Swallow an immediately following empty close tag: <video src="…"></video>.
                let close = "</\(tag)>"
                if ns.substring(from: end).lowercased().hasPrefix(close) { end += close.count }
                out += "<span class=\"remote-img\" data-tag=\"\(tag)\" data-src=\"\(escape(unquoted))\" data-alt=\"\"></span>"
            } else {
                out += ns.substring(with: m.range)
            }
            last = end
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
        var base = Slugger.slug(text)
        // Reader chrome ids live under the ro-* namespace (see docs/design.md):
        // a document slug starting with ro- would collide with them, so keep
        // GitHub-compatible slugs otherwise and escape only this case.
        if base.hasPrefix("ro-") { base = "h-" + base }
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

/// Update-check presentation policy. The decision of what the user sees is a
/// pure function so it is unit-tested on Linux; the AppKit alert/menu code in
/// App/UpdateChecker.swift stays a thin caller.
public enum UpdatePolicy {
    /// Only user-invoked checks may show a modal alert. Background checks
    /// surface through the application menu instead and never steal focus —
    /// whether or not they found an update.
    public static func shouldAlert(interactive: Bool, hasUpdate: Bool) -> Bool {
        interactive
    }

    /// Strips Markdown formatting for alert text: links keep their text,
    /// headings lose their #'s, emphasis/code ticks go away. Capped at
    /// `limit` characters so a long changelog cannot blow up the dialog.
    public static func plainNotes(_ markdown: String, limit: Int = 600) -> String {
        var s = markdown
        s = replacing(#"\[([^\]]*)\]\([^)]*\)"#, in: s, with: "$1")
        s = replacing(#"^#{1,6}\s*"#, in: s, with: "", anchorsMatchLines: true)
        s = replacing(#"(\*\*|__)(.*?)\1"#, in: s, with: "$2")
        s = replacing(#"(^|\s)(\*|_|`|>|-) "#, in: s, with: "$1")
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > limit else { return s }
        let end = s.index(s.startIndex, offsetBy: limit)
        return String(s[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func replacing(_ pattern: String, in s: String, with template: String, anchorsMatchLines: Bool = false) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: anchorsMatchLines ? .anchorsMatchLines : []) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

/// Finds the current index of the block the reader was on when the baseline was
/// saved. Block indices shift as agents edit; the saved text excerpt survives that.
public enum ExcerptAnchor {
    public static func index(of excerpt: String, in texts: [String]) -> Int? {
        guard !excerpt.isEmpty else { return nil }
        if let i = texts.firstIndex(where: { $0.hasPrefix(excerpt) }) { return i }
        // Edited mid-block: fall back to containment, first of the whole excerpt,
        // then of its first half. Short excerpts are ambiguous — leave those to
        // the caller's index fallback instead of guessing.
        if excerpt.count >= 24 {
            if let i = texts.firstIndex(where: { $0.contains(excerpt) }) { return i }
            let half = String(excerpt.prefix(max(24, excerpt.count / 2)))
            if half.count >= 24, let i = texts.firstIndex(where: { $0.contains(half) }) { return i }
        }
        return nil
    }
}
