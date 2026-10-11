import Foundation

/// GFM footnote definitions (`[^id]: text`, continued by indented lines).
/// swift-markdown has no footnote support, so definitions are taken out of
/// the source before parsing and references are tokenized by `MathProtector`.
enum Footnotes {
    struct Definition: Equatable {
        let id: String
        let text: String
        /// 1-based source lines the definition occupied.
        let lines: ClosedRange<Int>
    }

    private static let start = try! NSRegularExpression(pattern: #"^ {0,3}\[\^([^\]\s]+)\]:[ \t]?(.*)$"#)

    /// Removes definitions from `lines` (replacing them with blank lines, so
    /// line numbers are preserved) and returns them in source order. Fenced
    /// code is skipped. The first definition of an id wins.
    static func extract(_ lines: inout [String]) -> [Definition] {
        guard lines.contains(where: { $0.contains("[^") }) else { return [] }
        var out: [Definition] = []
        var seen = Set<String>()
        var fence: String? = nil
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.drop(while: { $0 == " " })
            if let f = fence {
                if trimmed.hasPrefix(f) { fence = nil }
                i += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                i += 1
                continue
            }
            let ns = line as NSString
            guard let m = start.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { i += 1; continue }
            let id = ns.substring(with: m.range(at: 1))
            var body = [ns.substring(with: m.range(at: 2))]
            var end = i
            // Continuation: lines indented by 4+ spaces or a tab; blank lines
            // only when an indented line follows.
            var j = i + 1
            while j < lines.count {
                let l = lines[j]
                if l.hasPrefix("    ") || l.hasPrefix("\t") {
                    body.append(l.hasPrefix("\t") ? String(l.dropFirst()) : String(l.dropFirst(4)))
                    end = j
                    j += 1
                } else if l.allSatisfy({ $0 == " " || $0 == "\t" }), j + 1 < lines.count,
                          lines[j + 1].hasPrefix("    ") || lines[j + 1].hasPrefix("\t") {
                    body.append("")
                    j += 1
                } else {
                    break
                }
            }
            for k in i...end { lines[k] = "" }
            if seen.insert(id).inserted {
                out.append(Definition(id: id, text: body.joined(separator: "\n"), lines: (i + 1)...(end + 1)))
            }
            i = end + 1
        }
        return out
    }
}
