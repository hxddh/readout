import Foundation
import Testing
@testable import ReadoutCore

/// The official examples of the GFM spec's extension sections (tables, task
/// lists, strikethrough, autolinks, disallowed raw HTML), so block splitting
/// and Readout's own rendering never break standard behavior.
///
/// Readout's HTML differs from the reference renderer in presentation only
/// (wrapper elements, classes, a styled task box, one list per block), so both
/// sides are reduced to a canonical form before comparing: tags and the
/// attributes that carry meaning (href, start, alignment, spans), text, and
/// checkbox state.
@Suite struct GFMSpecTests {
    struct Example: Decodable { let example: Int; let section: String; let markdown: String; let html: String }
    struct Fixture: Decodable { let examples: [Example] }

    static let examples: [Example] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/gfm-extension-examples.json")
        guard let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(Fixture.self, from: data) else { return [] }
        return f.examples
    }()

    /// Deliberate differences from the reference renderer, with the reason.
    static let deviations: [Int: String] = [:]

    static func render(_ markdown: String) -> String {
        MarkdownParser.parse(markdown).blocks.map(\.html).joined()
    }

    static func canonical(_ html: String) -> String {
        var s = html
        func sub(_ pattern: String, _ template: String) {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        // Checkboxes: the reference renders <input>, Readout a styled span.
        sub(#"<input[^>]*checked[^>]*>"#, "[x]")
        sub(#"<input[^>]*type="checkbox"[^>]*>"#, "[ ]")
        sub(#"<span class="task-box checked"[^>]*></span>"#, "[x]")
        sub(#"<span class="task-box"[^>]*></span>"#, "[ ]")
        sub(#"\[( |x)\] ?"#, "[$1] ")
        // Alignment: align="x" and style="text-align:x" are the same.
        sub(#"style="text-align:(\w+)""#, #"align="$1""#)
        // Presentation-only wrappers, and the break opportunities in long autolinks' text.
        sub(#"</?(div|span)\b[^>]*>"#, "")
        sub("<wbr>", "")
        // Keep only meaningful attributes, in a fixed order.
        s = keepAttributes(s)
        // One list per list-item block: merge adjacent lists of the same kind.
        sub(#"</ul>\s*<ul>"#, "")
        sub(#"</ol>\s*<ol(?: start="\d+")?>"#, "")
        // An empty table body is omitted by the reference renderer.
        sub(#"<tbody>\s*</tbody>"#, "")
        // Entities and whitespace.
        s = s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
        sub(#">\s+<"#, "><")
        sub(#"\s+"#, " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func keepAttributes(_ html: String) -> String {
        let tag = try! NSRegularExpression(pattern: #"<([a-zA-Z][a-zA-Z0-9]*)(\s[^>]*)?>"#)
        let attr = try! NSRegularExpression(pattern: #"\b(href|start|align|colspan|rowspan)="([^"]*)""#)
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in tag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            var kept: [String] = []
            if m.range(at: 2).location != NSNotFound {
                let attrs = ns.substring(with: m.range(at: 2))
                let ans = attrs as NSString
                for a in attr.matches(in: attrs, range: NSRange(location: 0, length: ans.length)) {
                    kept.append("\(ans.substring(with: a.range(at: 1)))=\"\(ans.substring(with: a.range(at: 2)))\"")
                }
            }
            out += "<\(name)\(kept.sorted().map { " " + $0 }.joined())>"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    @Test func fixtureIsPresent() {
        #expect(Self.examples.count == 24)
    }

    @Test(arguments: examples) func example(_ e: Example) {
        let got = Self.canonical(Self.render(e.markdown))
        let want = Self.canonical(e.html)
        if let reason = Self.deviations[e.example] {
            #expect(got != want, "example \(e.example) now matches; drop its deviation (\(reason))")
            return
        }
        #expect(got == want, "GFM example \(e.example) (\(e.section))\nmarkdown: \(e.markdown.debugDescription)\nwant: \(want)\n got: \(got)")
    }
}

extension GFMSpecTests.Example: CustomTestStringConvertible {
    var testDescription: String { "\(section) #\(example)" }
}
