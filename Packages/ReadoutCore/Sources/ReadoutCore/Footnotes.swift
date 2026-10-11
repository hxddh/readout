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
        guard lines.contains(where: mentions) else { return [] }
        var out: [Definition] = []
        var seen = Set<String>()
        var fences = FenceTracker()
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if fences.consume(line) {
                i += 1
                continue
            }
            guard startsDefinition(line) else { i += 1; continue }
            let ns = line as NSString
            guard let m = start.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { i += 1; continue }
            // Labels match without regard to case, as on GitHub.
            let id = ns.substring(with: m.range(at: 1)).lowercased()
            var body = [ns.substring(with: m.range(at: 2))]
            var end = i
            // Continuation: lines indented by 4+ spaces or a tab; blank lines
            // only when an indented line follows; and, right after text, any
            // line that does not start another block (a wrapped sentence).
            var j = i + 1
            while j < lines.count {
                let l = lines[j]
                if !(body.last ?? "").allSatisfy({ $0 == " " || $0 == "\t" }) && continuesParagraph(l) {
                    body.append(l)
                    end = j
                    j += 1
                } else if l.hasPrefix("    ") || l.hasPrefix("\t") {
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

    private static let blockStart = try! NSRegularExpression(
        pattern: #"^ {0,3}(?:#{1,6}(?:[ \t]|$)|>|\||<|```|~~~|\[|[-*+](?:[ \t]|$)|\d{1,9}[.)](?:[ \t]|$)|(?:[-*_][ \t]*){3,}$)"#)

    /// A line that a paragraph can take as its continuation: not blank, not
    /// indented code, and not the start of another block.
    static func continuesParagraph(_ line: String) -> Bool {
        guard !line.allSatisfy({ $0 == " " || $0 == "\t" }), !line.hasPrefix("    "), !line.hasPrefix("\t") else { return false }
        let ns = line as NSString
        return blockStart.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) == nil
    }

    /// The text contains `[^` (bytes, without Unicode-aware search).
    static func mentions<S: StringProtocol>(_ text: S) -> Bool {
        var previous: UInt8 = 0
        for b in text.utf8 {
            if b == 0x5E && previous == 0x5B { return true }
            previous = b
        }
        return false
    }

    /// Up to three spaces, then `[^` (a cheap test before the full pattern).
    private static func startsDefinition(_ line: String) -> Bool {
        var spaces = 0
        var it = line.utf8.makeIterator()
        while let b = it.next() {
            if b == 0x20 && spaces < 3 { spaces += 1; continue }
            return b == 0x5B && it.next() == 0x5E
        }
        return false
    }

    // MARK: Document-wide numbering

    /// A definition taken out of a fragment, its body rendered (references
    /// inside it are placeholders too).
    struct Note: Equatable, Sendable {
        let id: String
        /// Lines the definition occupied, relative to its fragment until `assemble`.
        var lines: ClosedRange<Int>
        let text: String
        let html: String
    }

    static let open: Character = "\u{E002}"
    static let close: Character = "\u{E003}"

    /// Stands for a reference to `id` until the document is assembled.
    static func placeholder(_ id: String) -> String { "\(open)\(HTML.escape(id))\(close)" }

    /// Numbers references in document order (first reference first) and
    /// gives repeated references distinct anchors, as GitHub does.
    struct Numbering {
        private(set) var order: [String] = []
        private var number: [String: Int] = [:]
        private var uses: [String: Int] = [:]

        /// Replaces the placeholders in `html` (no-op without any).
        mutating func fill(_ html: String) -> String {
            guard html.utf8.contains(0xEE), html.contains(Footnotes.open) else { return html }
            var out = ""
            var rest = html[...]
            while let o = rest.firstIndex(of: Footnotes.open), let c = rest[o...].firstIndex(of: Footnotes.close) {
                out += rest[..<o]
                let id = String(rest[rest.index(after: o)..<c])   // already escaped
                let n: Int
                if let known = number[id] { n = known } else { order.append(id); n = order.count; number[id] = n }
                let k = (uses[id] ?? 0) + 1
                uses[id] = k
                let ref = k == 1 ? "user-content-fnref-\(id)" : "user-content-fnref-\(id)-\(k)"
                out += "<sup class=\"fn-ref\"><a href=\"#user-content-fn-\(id)\" id=\"\(ref)\" data-footnote-ref>\(n)</a></sup>"
                rest = rest[rest.index(after: c)...]
            }
            out += rest
            return out
        }

        /// The footnotes section: referenced definitions in number order
        /// (references inside them are numbered as they come). Nil when
        /// nothing is referenced.
        mutating func section(_ notes: [Note]) -> Block? {
            var byID: [String: Note] = [:]
            for n in notes where byID[HTML.escape(n.id)] == nil { byID[HTML.escape(n.id)] = n }
            var items: [String] = []
            var shown: [Note] = []
            var i = 0
            while i < order.count {
                let id = order[i]
                i += 1
                guard let note = byID[id] else { continue }
                var body = fill(note.html)
                // One way back per reference, as on GitHub: ↩, ↩², …
                let back = (1...max(1, uses[id] ?? 1)).map { k in
                    let ref = k == 1 ? "user-content-fnref-\(id)" : "user-content-fnref-\(id)-\(k)"
                    let label = k == 1 ? "Back to reference \(i)" : "Back to reference \(i)-\(k)"
                    return "<a href=\"#\(ref)\" class=\"fn-back\" data-footnote-backref aria-label=\"\(label)\">↩\(k == 1 ? "" : "<sup>\(k)</sup>")</a>"
                }.joined(separator: " ")
                if body.hasSuffix("</p>") { body = String(body.dropLast(4)) + " " + back + "</p>" } else { body += back }
                items.append("<li id=\"user-content-fn-\(id)\">\(body)</li>")
                shown.append(note)
            }
            guard !shown.isEmpty else { return nil }
            let lo = shown.map(\.lines.lowerBound).min()!, hi = shown.map(\.lines.upperBound).max()!
            let text = shown.map { "[^\($0.id)]: \($0.text)" }.joined(separator: "\n")
            return Block(kind: .footnotes, headingPath: [], lines: lo...hi,
                         fingerprint: XXHash64.hash("footnotes\u{1F}" + text), taskState: [],
                         html: "<section class=\"footnotes\" data-footnotes><ol>\(items.joined())</ol></section>", text: text)
        }
    }
}
