import Foundation

/// The pure parts of the GitHub Releases update check (App/UpdateChecker.swift).
public enum ReleaseCheck {
    /// Compares dotted version tags numerically ("v1.0.10" is newer than "1.0.9").
    /// A leading "v" and any pre-release suffix ("-beta") are ignored.
    public static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0.split(separator: "-").first ?? $0) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
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
