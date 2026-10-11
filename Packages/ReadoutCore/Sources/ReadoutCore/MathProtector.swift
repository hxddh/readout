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

    /// A footnote reference: its definition id, number (order of first
    /// reference) and which occurrence of that footnote this is (1-based).
    struct Footnote { let id: String; let number: Int; let occurrence: Int }

    /// Ids with a definition; only these turn `[^id]` into a reference.
    var footnoteIDs: Set<String> = []
    /// Referenced footnote ids in number order.
    private(set) var footnoteOrder: [String] = []
    private var footnoteUses: [String: Int] = [:]

    static let open: Character = "\u{E000}"
    static let close: Character = "\u{E001}"

    private(set) var spans: [Span] = []

    mutating func protect(_ source: String) -> String {
        var out: [Substring] = []
        var fences = FenceTracker()
        var result = ""
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if fences.consume(line) {
                out.append(line)
                continue
            }
            // Indented code blocks (4 spaces) are left alone.
            if line.hasPrefix("    ") || line.hasPrefix("\t") { out.append(line); continue }
            out.append(Substring(protectLine(String(line))))
        }
        result = out.joined(separator: "\n")
        return result
    }

    private mutating func token(_ tex: String, display: Bool) -> String {
        spans.append(Span(tex: tex, display: display))
        return "\(MathProtector.open)\(spans.count - 1)\(MathProtector.close)"
    }

    private mutating func footnoteToken(_ id: String) -> String {
        if !footnoteOrder.contains(id) { footnoteOrder.append(id) }
        let n = footnoteOrder.firstIndex(of: id)! + 1
        let k = (footnoteUses[id] ?? 0) + 1
        footnoteUses[id] = k
        spans.append(Span(tex: "", display: false, footnote: Footnote(id: id, number: n, occurrence: k)))
        return "\(MathProtector.open)\(spans.count - 1)\(MathProtector.close)"
    }

    private mutating func protectLine(_ line: String) -> String {
        let mayHaveFootnote = !footnoteIDs.isEmpty && line.contains("[^")
        // Fast path: nothing that could start math or a footnote reference.
        if !mayHaveFootnote && !line.utf8.contains(UInt8(ascii: "$")) && !line.utf8.contains(UInt8(ascii: "\\")) { return line }
        let chars = Array(line)
        // A line that is only `$$...$$` is display math handled at block level.
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("$$") && !mayHaveFootnote { return line }
        let displayLine = t.hasPrefix("$$")
        var out = ""
        var i = 0
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
            // Footnote reference: [^id] whose definition exists.
            if mayHaveFootnote && c == "[" && i + 1 < chars.count && chars[i + 1] == "^",
               let end = chars[(i + 2)...].firstIndex(of: "]"), end > i + 2 {
                let id = String(chars[(i + 2)..<end])
                if footnoteIDs.contains(id) && !id.contains(where: \.isWhitespace) {
                    out += footnoteToken(id)
                    i = end + 1
                    continue
                }
            }
            if displayLine { out.append(c); i += 1; continue }
            // Escaped dollar.
            if c == "\\" && i + 1 < chars.count {
                if chars[i + 1] == "(" , let end = find(chars, from: i + 2, seq: ["\\", ")"]) {
                    let tex = String(chars[(i + 2)..<end])
                    out += token(tex, display: false)
                    i = end + 2
                    continue
                }
                if chars[i + 1] == "[" , let end = find(chars, from: i + 2, seq: ["\\", "]"]) {
                    let tex = String(chars[(i + 2)..<end])
                    out += token(tex, display: true)
                    i = end + 2
                    continue
                }
                out.append(c); out.append(chars[i + 1]); i += 2
                continue
            }
            if c == "$" {
                if i + 1 < chars.count && chars[i + 1] == "$" {
                    // Inline display math $$...$$
                    if let end = find(chars, from: i + 2, seq: ["$", "$"]), end > i + 2 {
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

    private func find(_ chars: [Character], from: Int, seq: [Character]) -> Int? {
        var i = from
        while i + seq.count <= chars.count {
            if Array(chars[i..<(i + seq.count)]) == seq { return i }
            i += 1
        }
        return nil
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
                    let id = HTML.escape(fn.id)
                    let ref = fn.occurrence == 1 ? "user-content-fnref-\(id)" : "user-content-fnref-\(id)-\(fn.occurrence)"
                    out += "<sup class=\"fn-ref\"><a href=\"#user-content-fn-\(id)\" id=\"\(ref)\" data-footnote-ref>\(fn.number)</a></sup>"
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
