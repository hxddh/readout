import Foundation

/// Tracks fenced code blocks line by line with CommonMark's rules, so every
/// pre-pass (math protection, footnote extraction, fragmenting) agrees with
/// the Markdown parser about what is code:
/// - an opening fence is 3+ backticks or tildes, indented less than 4
///   spaces (a backtick fence's info string may not contain a backtick);
/// - it is closed by a line of the same character, at least as long,
///   indented less than 4 spaces, with nothing after it but spaces;
/// - a fence opened inside a list item also ends where the item ends: at
///   the first non-blank line indented less than the item's content.
/// HTML comment blocks (`<!--` to `-->`) are tracked the same way: what is
/// inside them is neither code nor Markdown.
struct FenceTracker {
    private(set) var open: (char: Character, count: Int, container: Int?)? = nil
    private var inComment = false
    /// Content column of the list item the current line belongs to, if any.
    private var itemContent: Int? = nil

    var isOpen: Bool { open != nil || inComment }

    private static let marker = try! NSRegularExpression(pattern: #"^( {0,3})([-*+]|\d{1,9}[.)])( {1,4})(?=\S)"#)

    /// Feeds one line; returns true when the line is part of a fence
    /// (opening line, content or closing line).
    mutating func consume<S: StringProtocol>(_ line: S) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        let indent = line.count - trimmed.count
        let blank = trimmed.allSatisfy { $0 == " " || $0 == "\t" }
        if inComment {
            if line.contains("-->") { inComment = false }
            return true
        }
        if let f = open {
            if let c = f.container, !blank, indent < c {
                open = nil      // the list item ended, and the fence with it
            } else {
                if indent < (f.container ?? 0) + 4, trimmed.first == f.char {
                    let run = trimmed.prefix(while: { $0 == f.char }).count
                    if run >= f.count && trimmed.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) { open = nil }
                }
                return true
            }
        }
        if !blank {
            let s = String(line)
            let ns = s as NSString
            if let m = Self.marker.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
                itemContent = m.range.length
            } else if let c = itemContent, indent < c {
                itemContent = nil
            }
        }
        if indent < 4, trimmed.hasPrefix("<!--") {
            if !trimmed.dropFirst(4).contains("-->") { inComment = true }
            return true
        }
        let base = itemContent ?? 0
        let relative = indent - (indent >= base ? base : 0)
        if relative < 4, let c = trimmed.first, c == "`" || c == "~" {
            let run = trimmed.prefix(while: { $0 == c }).count
            if run >= 3 && !(c == "`" && trimmed.dropFirst(run).contains("`")) {
                open = (c, run, indent >= base && itemContent != nil ? base : nil)
                return true
            }
        }
        return false
    }
}
