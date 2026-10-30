import Foundation

/// Edit ▸ Copy as Quote (⇧⌘C): the Markdown source of the blocks a selection
/// touches, as a Markdown blockquote, and where it is:
///
///     > The source of the blocks,
///     > line by line.
///     — src/plan.md#L12-L14 (§ Risks)
///
/// Whole blocks: a selection inside a list item or a table cell quotes the
/// item or the table. Ready to paste into an agent's prompt.
public enum QuoteFormatter {
    /// The quote of the blocks of `blocks` (in document order) whose slots are
    /// in `slots`, cited as `path`; nil when none of them is there. Each block
    /// is its source as copying has it (`Block.copySource`: hard breaks and
    /// front matter's fences kept), followed by the link `definitions` they
    /// use (as written; the page finds them, as for ⌘C: `quoteSelection`).
    public static func quote(blocks: [Block], slots: Set<Int>, path: String, definitions: [String] = []) -> String? {
        let picked = blocks.filter { slots.contains($0.slot) }
        guard let first = picked.first else { return nil }
        var body = ""
        var previous: Block?
        for b in picked {
            // Blocks on consecutive lines stay together (a tight list stays
            // tight); a gap between them is one blank line.
            if let p = previous { body += b.lines.lowerBound == p.lines.upperBound + 1 ? "\n" : "\n\n" }
            body += b.copySource
            previous = b
        }
        if !definitions.isEmpty { body += "\n\n" + definitions.joined(separator: "\n") }
        // The footnotes section gathers definitions from anywhere in the file:
        // its lines say nothing about where the rest of the selection is.
        let ranged = picked.filter { $0.kind != .footnotes }
        let lines = (ranged.isEmpty ? picked : ranged).map(\.lines)
        let from = lines.map(\.lowerBound).min() ?? first.lines.lowerBound
        let to = lines.map(\.upperBound).max() ?? first.lines.upperBound
        var cite = "— \(path)#L\(from)" + (to > from ? "-L\(to)" : "")
        if let section = section(of: first) { cite += " (§ \(section))" }
        return blockquote(body) + "\n" + cite
    }

    /// The heading a block is under (a heading: itself); nil before the first heading.
    public static func section(of block: Block) -> String? {
        if block.kind == .heading, let title = block.headingTitle, !title.isEmpty { return title }
        return block.headingPath.last.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `text` as a Markdown blockquote: "> " before every line, ">" alone on a blank one.
    public static func blockquote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }

    /// How the quote names the file: relative to the project an agent named
    /// for it (`readout --hook`) when the file lies inside it, else its path
    /// with the home folder as `~`.
    public static func displayPath(_ path: String, projectRoot: String?, home: String = NSHomeDirectory()) -> String {
        if let projectRoot {
            let root = projectRoot.count > 1 && projectRoot.hasSuffix("/") ? String(projectRoot.dropLast()) : projectRoot
            if root != "/", !root.isEmpty, path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        }
        return ReaderChrome.tabToolTip(path: path, home: home)
    }
}
