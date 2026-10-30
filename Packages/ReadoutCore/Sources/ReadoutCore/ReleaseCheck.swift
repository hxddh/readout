import Foundation

/// The pure parts of the GitHub Releases update check (App/UpdateChecker.swift).
public enum ReleaseCheck {
    /// Compares version tags the semantic-versioning way: dotted numbers
    /// first ("v1.0.10" is newer than "1.0.9", "3.1" equals "3.1.0"); with
    /// equal numbers a release is newer than its pre-releases ("3.1.0" over
    /// "3.1.0-rc.2"), and pre-releases compare identifier by identifier
    /// ("rc.10" over "rc.2", "rc" over "beta"). Build metadata is ignored.
    public static func isNewer(_ tag: String, than current: String) -> Bool {
        compare(tag, current) > 0
    }

    static func compare(_ a: String, _ b: String) -> Int {
        func split(_ s: String) -> (core: [Int], pre: [Substring]) {
            var t = s.trimmingCharacters(in: .whitespaces)[...]
            if t.first == "v" || t.first == "V" { t = t.dropFirst() }
            if let plus = t.firstIndex(of: "+") { t = t[..<plus] }
            let dash = t.firstIndex(of: "-")
            let core = (dash.map { t[..<$0] } ?? t).split(separator: ".").map { Int($0) ?? 0 }
            let pre = dash.map { t[t.index(after: $0)...].split(separator: ".") } ?? []
            return (core, pre)
        }
        let x = split(a), y = split(b)
        for i in 0..<max(x.core.count, y.core.count) {
            let p = i < x.core.count ? x.core[i] : 0, q = i < y.core.count ? y.core[i] : 0
            if p != q { return p > q ? 1 : -1 }
        }
        // A release outranks any pre-release of the same version.
        if x.pre.isEmpty != y.pre.isEmpty { return x.pre.isEmpty ? 1 : -1 }
        for i in 0..<max(x.pre.count, y.pre.count) {
            guard i < x.pre.count else { return -1 }   // fewer identifiers: lower
            guard i < y.pre.count else { return 1 }
            let p = x.pre[i], q = y.pre[i]
            switch (Int(p), Int(q)) {
            case let (m?, n?): if m != n { return m > n ? 1 : -1 }
            case (.some, nil): return -1                // numbers rank below words
            case (nil, .some): return 1
            case (nil, nil): if p != q { return p > q ? 1 : -1 }
            }
        }
        return 0
    }

    /// Strips Markdown formatting for alert text: links keep their text,
    /// headings lose their #'s, emphasis/code ticks go away, HTML tags
    /// (`<kbd>⌥⌘\</kbd>`) keep only their text. A first heading that is only
    /// the version (`## 3.5.0`) is dropped: the alert already names the
    /// release above the notes. Capped at `limit` characters so a long
    /// changelog cannot blow up the dialog.
    public static func plainNotes(_ markdown: String, limit: Int = 600) -> String {
        var s = markdown
        s = replacing(#"\A\s*#{1,6}[ \t]*(Readout[ \t]+)?[vV]?\d+(\.\d+)*(-[0-9A-Za-z.-]+)?[ \t]*#*[ \t]*(\n|\z)"#, in: s, with: "")
        // Outside code spans only: "`<details>` renders as…" keeps its tag.
        s = s.split(separator: "`", omittingEmptySubsequences: false).enumerated().map { i, part in
            guard i % 2 == 0 else { return String(part) }
            let t = replacing(#"<!--[\s\S]*?-->"#, in: String(part), with: "")
            return replacing(#"</?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?>"#, in: t, with: "")
        }.joined(separator: "`")
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
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

extension ReleaseCheck {
    /// What Download Update hands to the browser: the release's disk image on
    /// GitHub (`assets`: name and `browser_download_url`), else its page
    /// (`html_url`), else `releases`: only https on github.com.
    public static func downloadURL(assets: [(name: String, url: URL)], page: URL?, releases: URL) -> URL {
        let onGitHub = { (u: URL) in u.scheme == "https" && u.host == "github.com" }
        return assets.first { $0.name.lowercased().hasSuffix(".dmg") && onGitHub($0.url) }?.url ?? page.flatMap { onGitHub($0) ? $0 : nil } ?? releases
    }
}
