import Foundation

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
