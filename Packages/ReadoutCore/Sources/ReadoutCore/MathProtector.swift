import Foundation

/// Replaces inline math spans with opaque tokens before Markdown parsing so that
/// `_`, `*` and `\` inside TeX are not interpreted as Markdown. Line structure is preserved.
/// Footnote references (`[^id]` with a definition) are tokenized the same way,
/// so emphasis or link parsing never sees them.
struct MathProtector {
    struct Span {
        let tex: String
        let display: Bool
        var footnote: Footnote? = nil
    }

    /// A footnote reference to a defined id. Its number and anchor depend on
    /// the whole document, so it renders as a placeholder that
    /// `MarkdownParser.assemble` fills in (`Footnotes.reference`).
    struct Footnote { let id: String }

    /// Ids with a definition; only these turn `[^id]` into a reference.
    var footnoteIDs: Set<String> = []

    static let open: Character = "\u{E000}"
    static let close: Character = "\u{E001}"
    /// Stands for a source line taken into a multi-line display math token:
    /// the line stays (line numbers and the paragraph hold), and the
    /// renderer drops it with the line break before it (`HTMLRenderer.inline`).
    static let filler: Character = "\u{E004}"

    private(set) var spans: [Span] = []

    mutating func protect(_ source: String) -> String {
        var out: [String] = []
        var fences = FenceTracker()
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if fences.consume(line) {
                out.append(String(line))
                i += 1
                continue
            }
            // Indented code is left alone: 4+ columns past the content of
            // the list item the line is in, and not continuing a paragraph.
            if fences.indentedCode { out.append(String(line)); i += 1; continue }
            if let block = displayBlock(lines, at: i) {
                out.append(block.opener + token(block.tex, display: true))
                for (k, prefix) in block.prefixes.enumerated() {
                    _ = fences.consume(lines[i + 1 + k])
                    let isLast = k == block.prefixes.count - 1
                    out.append(prefix + String(MathProtector.filler) + (isLast ? protectLine(block.rest) : ""))
                }
                i = block.end + 1
                continue
            }
            out.append(protectLine(String(line)))
            i += 1
        }
        return out.joined(separator: "\n")
    }

    /// Container syntax before a line's content: block quote markers, list markers, indentation.
    private static let containerPrefix = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*(?:>|[-*+](?=[ \t])|\d{1,9}[.)](?=[ \t])))*[ \t]*"#)

    /// `$$` opening a line's content (after its container prefix) and closed
    /// on a later line of the same paragraph: display math over several
    /// lines, which may hold what would otherwise be Markdown (`+ b`).
    /// Returns the opener's prefix, the TeX, the index of the closing line,
    /// each following line's container prefix and the text after the closing `$$`.
    private func displayBlock(_ lines: [Substring], at i: Int)
        -> (opener: String, tex: String, end: Int, prefixes: [String], rest: String)? {
        guard lines[i].utf8.contains(0x24) /* $ */ else { return nil }
        let line = String(lines[i])
        guard line.contains("$$") else { return nil }
        let ns = line as NSString
        let p = MathProtector.containerPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))?.range.length ?? 0
        let prefix = ns.substring(to: p), content = ns.substring(from: p)
        guard content.hasPrefix("$$") else { return nil }
        let first = content.dropFirst(2)
        guard !first.contains("$$") else { return nil }   // closed on this line: inline display math
        // Following lines belong to the same containers: as many quote
        // markers, then the indentation of the opener's content.
        let quotes = prefix.filter { $0 == ">" }.count
        let afterQuote = prefix.lastIndex(of: ">").map { prefix[prefix.index(after: $0)...] } ?? prefix[...]
        var indent = afterQuote.count
        if quotes > 0, afterQuote.first == " " { indent -= 1 }
        var tex: [String] = [String(first)]
        var prefixes: [String] = []
        var j = i + 1
        while j < lines.count, j - i <= 500 {
            var rest = lines[j][...]
            var taken = ""
            for _ in 0..<quotes {
                let spaces = rest.prefix(while: { $0 == " " })
                guard spaces.count <= 3, rest.dropFirst(spaces.count).first == ">" else { break }
                taken += rest.prefix(spaces.count + 1)
                rest = rest.dropFirst(spaces.count + 1)
                if rest.first == " " { taken += " "; rest = rest.dropFirst() }
            }
            let lead = rest.prefix(while: { $0 == " " }).prefix(indent)
            taken += lead
            rest = rest.dropFirst(lead.count)
            // A blank line ends the paragraph; a fence or HTML would open a
            // block the other passes (footnotes, fragments) see.
            let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.isEmpty || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix("<") { return nil }
            prefixes.append(taken)
            if let close = rest.range(of: "$$") {
                tex.append(String(rest[..<close.lowerBound]))
                let joined = tex.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !joined.isEmpty else { return nil }
                return (prefix, joined, j, prefixes, String(rest[close.upperBound...]))
            }
            tex.append(String(rest))
            j += 1
        }
        return nil
    }

    private mutating func token(_ tex: String, display: Bool) -> String {
        spans.append(Span(tex: tex, display: display))
        return "\(MathProtector.open)\(spans.count - 1)\(MathProtector.close)"
    }

    private mutating func footnoteToken(_ id: String) -> String {
        spans.append(Span(tex: "", display: false, footnote: Footnote(id: id)))
        return "\(MathProtector.open)\(spans.count - 1)\(MathProtector.close)"
    }

    /// The display math a paragraph's protected source consists of, if it is
    /// exactly one display token (filler lines and white space aside).
    func soleDisplayMath(_ source: String) -> String? {
        let t = source.filter { $0 != MathProtector.filler }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.first == MathProtector.open, t.last == MathProtector.close,
              let n = Int(t.dropFirst().dropLast()), n < spans.count, spans[n].display, spans[n].footnote == nil else { return nil }
        return spans[n].tex
    }

    /// Whether `\(…\)` or `\[…\]` content reads as TeX rather than escaped
    /// punctuation in prose (`\[WIP\]`, `\[x\]`, `\(sic\)`, `\[\\\]`): it has a
    /// letter or digit and TeX syntax or an operator; inline, a single
    /// character or a space also count.
    static func looksLikeTeX(_ s: ArraySlice<Character>, display: Bool) -> Bool {
        guard s.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        if s.contains(where: { "\\^_{}=+*/<>|".contains($0) }) { return true }
        if display { return false }
        return s.count == 1 || s.contains(" ")
    }

    /// The next `\` + `closer` at or after a position, scanning each part of
    /// the line once however many openers ask (positions only grow).
    private struct CloserSearch {
        let closer: Character
        var found = -1
        var exhausted = false
        mutating func next(_ chars: [Character], from: Int) -> Int? {
            if exhausted { return nil }
            if found >= from { return found }
            var k = max(from, found + 1)
            while k + 1 < chars.count {
                if chars[k] == "\\" {
                    if chars[k + 1] == closer { found = k; return k }
                    k += 2   // an escaped character: in `\\]` the `\]` is not a closer
                } else {
                    k += 1
                }
            }
            exhausted = true
            return nil
        }
    }

    /// The end (exclusive) of a link destination and title starting at
    /// `start` (just after `](`); nil when its parenthesis does not close on this line.
    private static func destinationEnd(_ chars: [Character], from start: Int) -> Int? {
        var k = start
        var depth = 0
        var angle = false
        while k < chars.count {
            let c = chars[k]
            if c == "\\" { k += 2; continue }
            if angle { if c == ">" { angle = false } }
            else if c == "<" && k == start { angle = true }
            else if c == "(" { depth += 1 }
            else if c == ")" { if depth == 0 { return k + 1 }; depth -= 1 }
            k += 1
        }
        return nil
    }

    /// The end (exclusive) of a `<scheme:…>` or `<user@host>` autolink at `start`.
    private static func autolinkEnd(_ chars: [Character], from start: Int) -> Int? {
        var k = start + 1
        var sawColonOrAt = false
        guard k < chars.count, chars[k].isLetter || chars[k].isNumber else { return nil }
        while k < chars.count {
            let c = chars[k]
            if c == ">" { return sawColonOrAt ? k + 1 : nil }
            if c == "<" || c.isWhitespace { return nil }
            if c == ":" || c == "@" { sawColonOrAt = true }
            k += 1
        }
        return nil
    }

    /// The end (exclusive) of a bare `http(s)://` or `www.` address at `i`,
    /// up to the next white space or `<`.
    private static func bareURLEnd(_ chars: [Character], at i: Int) -> Int? {
        if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { return nil }
        func starts(_ s: String) -> Bool {
            var k = i
            for c in s {
                guard k < chars.count, chars[k] == c || chars[k] == Character(c.uppercased()) else { return false }
                k += 1
            }
            return true
        }
        guard starts("http://") || starts("https://") || starts("www.") else { return nil }
        var k = i
        while k < chars.count, !chars[k].isWhitespace, chars[k] != "<" {
            // A footnote reference right after an address is not part of it.
            if chars[k] == "[", k + 1 < chars.count, chars[k + 1] == "^" { break }
            k += 1
        }
        return k
    }

    private mutating func protectLine(_ line: String) -> String {
        let mayHaveFootnote = !footnoteIDs.isEmpty && Footnotes.mentions(line)
        // Fast path: nothing that could start math or a footnote reference.
        if !mayHaveFootnote && !line.utf8.contains(UInt8(ascii: "$")) && !line.utf8.contains(UInt8(ascii: "\\")) { return line }
        let chars = Array(line)
        var out = ""
        var i = 0
        var parenClose = CloserSearch(closer: ")"), bracketClose = CloserSearch(closer: "]")
        // The next `$$` at or after a position (-1: none searched yet), as for `\)`.
        var displayClose = -1, displayExhausted = false
        while i < chars.count {
            let c = chars[i]
            // Inline code span: copy verbatim.
            if c == "`" {
                var run = 0
                while i + run < chars.count && chars[i + run] == "`" { run += 1 }
                let fence = String(repeating: "`", count: run)
                var j = i + run
                var closed = -1
                while j < chars.count {
                    if chars[j] == "`" {
                        var r = 0
                        while j + r < chars.count && chars[j + r] == "`" { r += 1 }
                        if r == run { closed = j; break }
                        j += r
                    } else { j += 1 }
                }
                if closed >= 0 {
                    out += String(chars[i..<(closed + run)])
                    i = closed + run
                } else {
                    out += fence
                    i += run
                }
                continue
            }
            // Link and image destinations, autolinks and bare addresses:
            // a `$` or `\(` there is part of the address, not math.
            if c == "]", i + 1 < chars.count, chars[i + 1] == "(", let end = Self.destinationEnd(chars, from: i + 2) {
                out += String(chars[i..<end]); i = end; continue
            }
            if c == "<", let end = Self.autolinkEnd(chars, from: i) {
                out += String(chars[i..<end]); i = end; continue
            }
            if c == "h" || c == "H" || c == "w" || c == "W", let end = Self.bareURLEnd(chars, at: i) {
                out += String(chars[i..<end]); i = end; continue
            }
            // Footnote reference: [^id] whose definition exists.
            if mayHaveFootnote && c == "[" && i + 1 < chars.count && chars[i + 1] == "^",
               let end = chars[(i + 2)...].firstIndex(of: "]"), end > i + 2 {
                let id = String(chars[(i + 2)..<end])
                if footnoteIDs.contains(id.lowercased()) && !id.contains(where: \.isWhitespace) {
                    out += footnoteToken(id.lowercased())
                    i = end + 1
                    continue
                }
            }
            if c == "\\" && i + 1 < chars.count {
                // \(…\) and \[…\]: math when closed and TeX-like, otherwise CommonMark escapes.
                if chars[i + 1] == "(", let end = parenClose.next(chars, from: i + 2),
                   Self.looksLikeTeX(chars[(i + 2)..<end], display: false) {
                    out += token(String(chars[(i + 2)..<end]), display: false)
                    i = end + 2
                    continue
                }
                if chars[i + 1] == "[", let end = bracketClose.next(chars, from: i + 2),
                   Self.looksLikeTeX(chars[(i + 2)..<end], display: true) {
                    out += token(String(chars[(i + 2)..<end]), display: true)
                    i = end + 2
                    continue
                }
                // An escaped character (an escaped dollar among them).
                out.append(c); out.append(chars[i + 1]); i += 2
                continue
            }
            if c == "$" {
                if i + 1 < chars.count && chars[i + 1] == "$" {
                    // Inline display math $$...$$
                    if !displayExhausted && displayClose < i + 2 {
                        displayClose = -1
                        var k = i + 2
                        while k + 1 < chars.count {
                            if chars[k] == "$" && chars[k + 1] == "$" { displayClose = k; break }
                            k += 1
                        }
                        if displayClose < 0 { displayExhausted = true }
                    }
                    if !displayExhausted, displayClose > i + 2 {
                        let end = displayClose
                        out += token(String(chars[(i + 2)..<end]), display: true)
                        i = end + 2
                        continue
                    }
                    out += "$$"; i += 2; continue
                }
                // GitHub-style strict inline math.
                if i + 1 < chars.count, !chars[i + 1].isWhitespace {
                    var j = i + 1
                    var found = -1
                    while j < chars.count {
                        if chars[j] == "\\" { j += 2; continue }
                        if chars[j] == "$" {
                            let prevSpace = chars[j - 1].isWhitespace
                            let nextDigit = j + 1 < chars.count && chars[j + 1].isNumber
                            let nextDollar = j + 1 < chars.count && chars[j + 1] == "$"
                            if !prevSpace && !nextDigit && !nextDollar { found = j }
                            break
                        }
                        j += 1
                    }
                    if found > i + 1 {
                        out += token(String(chars[(i + 1)..<found]), display: false)
                        i = found + 1
                        continue
                    }
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Replaces tokens in already-escaped HTML text with math placeholders.
    func restore(inHTML text: String) -> String {
        guard !spans.isEmpty, text.utf8.contains(0xEE) else { return text }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == MathProtector.open, let closeIdx = text[i...].firstIndex(of: MathProtector.close),
               let n = Int(text[text.index(after: i)..<closeIdx]), n < spans.count {
                let span = spans[n]
                if let fn = span.footnote {
                    out += Footnotes.placeholder(fn.id)
                } else {
                    let cls = span.display ? "math math-display" : "math math-inline"
                    out += "<span class=\"\(cls)\" data-tex=\"\(HTML.escape(span.tex))\">\(HTML.escape(span.tex))</span>"
                }
                i = text.index(after: closeIdx)
                continue
            }
            out.append(c)
            i = text.index(after: i)
        }
        return out
    }

    /// Replaces tokens with the original TeX source (for plain text / titles).
    func restore(plain text: String) -> String {
        guard !spans.isEmpty, text.utf8.contains(0xEE) else { return text }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == MathProtector.open, let closeIdx = text[i...].firstIndex(of: MathProtector.close),
               let n = Int(text[text.index(after: i)..<closeIdx]), n < spans.count {
                out += spans[n].footnote == nil ? spans[n].tex : ""
                i = text.index(after: closeIdx)
                continue
            }
            out.append(c)
            i = text.index(after: i)
        }
        return out
    }
}
