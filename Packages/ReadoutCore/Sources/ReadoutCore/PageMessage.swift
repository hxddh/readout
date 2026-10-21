import Foundation

/// A message posted by the reader page (`window.webkit.messageHandlers.readout`),
/// decoded from the untyped dictionary WebKit delivers. Unknown or malformed
/// messages decode to nil and are ignored.
public enum PageMessage: Equatable, Sendable {
    /// The page finished loading and can take calls.
    case ready
    /// A patch was applied.
    case applied
    /// The first frame after a patch has been presented.
    case painted
    /// Changes the reader has now seen.
    case read(slots: [Int], deletions: [Int])
    /// The heading at the top of the viewport (TOC sync).
    case activeHeading(slot: Int)
    /// The block at the top of the viewport and how far it is scrolled.
    case anchor(slot: Int, offset: Double)
    case copy(text: String)
    /// A context menu is opening: on the heading with this anchor (its menu
    /// offers Copy Link to Section), or nil off a heading.
    case contextHeading(anchor: String?)
    case open(href: String)
    case loadRemote(url: String, id: String)
    case openPath(path: String, line: Int, column: Int)
    case error(message: String)
    /// The reader turned code wrapping on or off (remembered for all windows).
    case setCodeWrap(on: Bool)
    /// A key found nothing to go to (D with no comparison in view): the app beeps.
    case nothing
    /// N or Shift-N found no unread change left in the document
    /// (`{type: "nothing", jump: true}`): the app goes
    /// on to the next document with unread changes, and beeps only when there
    /// is none.
    case noUnread
    /// What the last patch added is to be shown as unread now (the toolbar
    /// badge, the outline's and the tab's dots): until then, more unread waits.
    case showUnread
    /// The reader selected text in the document, or the selection went
    /// (`has`: the context menu offers Copy as Quote while there is one), and
    /// whether a block has the keyboard's focus (`focused`: where N went;
    /// Edit ▸ Copy as Quote quotes it when no text is selected).
    case selection(has: Bool, focused: Bool = false)
    /// N went past the last change and wrapped around to the first: the app beeps.
    case wrapped
    /// Keyboard focus moved to an unread change (N, a rail tick): its place
    /// among the unread changes (1-based) and its kind (`railAdded`,
    /// `railEdited`, `railRemoved`, `railTask`), for VoiceOver.
    case landed(index: Int, total: Int, kind: String)

    public init?(_ msg: [String: Any]) {
        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? Int) }
        func ints(_ v: Any?) -> [Int] { (v as? [Any])?.compactMap { int($0) } ?? [] }
        switch msg["type"] as? String {
        case "ready": self = .ready
        case "applied": self = .applied
        case "painted": self = .painted
        case "read":
            self = .read(slots: ints(msg["slots"]), deletions: ints(msg["deletions"]))
        case "activeHeading":
            guard let slot = int(msg["slot"]) else { return nil }
            self = .activeHeading(slot: slot)
        case "anchor":
            guard let a = msg["anchor"] as? [String: Any], let slot = int(a["slot"]) else { return nil }
            self = .anchor(slot: slot, offset: (a["offset"] as? NSNumber)?.doubleValue ?? (a["offset"] as? Double) ?? 0)
        case "copy":
            guard let text = msg["text"] as? String else { return nil }
            self = .copy(text: text)
        case "contextHeading":
            guard let anchor = msg["anchor"] as? String else { return nil }
            self = .contextHeading(anchor: anchor.isEmpty ? nil : anchor)
        case "open":
            guard let href = msg["href"] as? String else { return nil }
            self = .open(href: href)
        case "loadRemote":
            guard let url = msg["url"] as? String, let id = msg["id"] as? String else { return nil }
            self = .loadRemote(url: url, id: id)
        case "openPath":
            guard let path = msg["path"] as? String else { return nil }
            self = .openPath(path: path, line: int(msg["line"]) ?? 0, column: int(msg["column"]) ?? 0)
        case "setCodeWrap":
            guard let on = (msg["on"] as? NSNumber)?.boolValue ?? (msg["on"] as? Bool) else { return nil }
            self = .setCodeWrap(on: on)
        case "nothing":
            // N's (`jump`), not D's: there is no unread change left to go to.
            let jump = (msg["jump"] as? NSNumber)?.boolValue ?? (msg["jump"] as? Bool) ?? false
            self = jump ? .noUnread : .nothing
        case "showUnread": self = .showUnread
        case "selection":
            guard let has = (msg["has"] as? NSNumber)?.boolValue ?? (msg["has"] as? Bool) else { return nil }
            let focused = (msg["focused"] as? NSNumber)?.boolValue ?? (msg["focused"] as? Bool) ?? false
            self = .selection(has: has, focused: focused)
        case "wrapped": self = .wrapped
        case "landed":
            guard let index = int(msg["index"]), let total = int(msg["total"]), index >= 1, index <= total,
                  let kind = msg["kind"] as? String else { return nil }
            self = .landed(index: index, total: total, kind: kind)
        case "error":
            self = .error(message: msg["message"] as? String ?? "")
        default:
            return nil
        }
    }
}

/// Where a link clicked in a document leads.
public enum LinkTarget: Equatable, Sendable {
    /// A non-file URL (https:, mailto:, …): opened by the system.
    case external(URL)
    /// `#section` in the same document.
    case sameDocument(fragment: String)
    /// Another Markdown file, optionally at a section: opened in Readout.
    case markdown(URL, fragment: String?)
    /// A file at a line (`src/a.ts#L42`, `#L42C3`, `#L42-L50`, `src/a.ts:42:3`):
    /// opened in the editor chosen in Settings, at that line. `column` 0: none.
    case source(URL, line: Int, column: Int)
    /// Any other local file (an image, a PDF, a folder, a file without a
    /// line): opened by the system.
    case file(URL)
    /// A local path that does not exist.
    case missing(URL)

    /// Files the system opens even with a line in the link: a line means nothing to them.
    static let systemOpened: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic",
                                            "avif", "ico", "pdf", "mov", "mp4", "m4v", "mp3", "m4a", "wav", "zip"]

    /// - Parameters:
    ///   - documentURL: the file the link appears in (relative paths resolve against its folder).
    ///   - markdownExtensions: lowercased extensions Readout opens itself.
    ///   - fileExists: existence check for non-Markdown targets.
    ///   - isDirectory: whether an existing target is a folder (opened by the system, line or not).
    ///   - candidates: where else a relative path may be (`FileResolver.candidates(for:)`:
    ///     the project an agent named, the folders above in the repository, the
    ///     agent folders), as code-span paths are looked up: a link to a file
    ///     not beside the document is looked for there before it is missing.
    public static func resolve(_ href: String, from documentURL: URL, markdownExtensions: Set<String>,
                               fileExists: (URL) -> Bool, isDirectory: (URL) -> Bool = { _ in false },
                               candidates: ((String) -> [URL])? = nil) -> LinkTarget? {
        let target = resolveHere(href, from: documentURL, markdownExtensions: markdownExtensions, fileExists: fileExists, isDirectory: isDirectory)
        guard let candidates, let target else { return target }
        let here = { (p: String) in documentURL.deletingLastPathComponent().appendingPathComponent(p).standardizedFileURL.path }
        let missing: URL
        switch target {
        case .missing(let u): missing = u
        case .markdown(let u, _) where !fileExists(u): missing = u
        case .external:
            // "feature.swift:42" reads as a URL scheme when no such file is beside the document.
            let written = String(href.prefix { $0 != "#" })
            guard !written.contains("//"), let (stripped, _) = SourceLine.pathSuffix(written),
                  stripped.contains(".") || stripped.contains("/") else { return target }
            missing = URL(fileURLWithPath: here(stripped.removingPercentEncoding ?? stripped))
        default: return target
        }
        // The path as written (without the fragment or a :line suffix), relative.
        var path = href
        var rest = ""
        if let hash = path.firstIndex(of: "#") { rest = String(path[hash...]); path = String(path[..<hash]) }
        path = path.removingPercentEncoding ?? path
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.lowercased().hasPrefix("file:") else { return target }
        var suffix = ""
        if let (stripped, _) = SourceLine.pathSuffix(path), here(stripped) == missing.path, here(path) != missing.path {
            suffix = String(path.dropFirst(stripped.count))
            path = stripped
        }
        for c in candidates(path) where c.standardizedFileURL.path != missing.path && fileExists(c) {
            let found = c.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?"))) ?? c.path
            return resolveHere(found + suffix + rest, from: documentURL, markdownExtensions: markdownExtensions, fileExists: fileExists, isDirectory: isDirectory)
        }
        return target
    }

    private static func resolveHere(_ href: String, from documentURL: URL, markdownExtensions: Set<String>,
                                    fileExists: (URL) -> Bool, isDirectory: (URL) -> Bool) -> LinkTarget? {
        func url(_ p: String) -> URL {
            p.hasPrefix("/") ? URL(fileURLWithPath: p)
                : documentURL.deletingLastPathComponent().appendingPathComponent(p).standardizedFileURL
        }
        // "main.swift:42" and "Makefile:12" parse as URLs with the schemes
        // "main.swift" and "makefile": a file name with a line when that file
        // is there. Otherwise a URL: "tel:5551234", "com.example.viewer:42".
        if let u = URL(string: href), let scheme = u.scheme?.lowercased(), scheme != "file" {
            let isPath = SourceLine.pathSuffix(href).map { s in
                fileExists(url(s.path.removingPercentEncoding ?? s.path)) || fileExists(url(href.removingPercentEncoding ?? href))
            } ?? false
            if !isPath { return .external(u) }
        }
        // Split off the fragment first: other.md#section should open the file
        // AND scroll to the section.
        var fragment: String? = nil
        var path = href
        if let hash = path.firstIndex(of: "#") {
            fragment = String(path[path.index(after: hash)...])
            path = String(path[..<hash])
        }
        if path.lowercased().hasPrefix("file://"), let u = URL(string: path) {
            fragment = fragment ?? u.fragment
            path = u.path
        }
        path = path.removingPercentEncoding ?? path
        if fragment?.isEmpty == true { fragment = nil }
        guard !path.isEmpty else {
            // Same-document anchor: scroll in place.
            return fragment.map { .sameDocument(fragment: $0) }
        }
        var target = url(path)
        var line: (line: Int, column: Int)? = fragment.flatMap(SourceLine.fragment)
        // path:42[:3], unless a file is really named that way.
        if let (stripped, l) = SourceLine.pathSuffix(path), !fileExists(target) {
            target = url(stripped)
            line = l
            if markdownExtensions.contains(target.pathExtension.lowercased()) { return .markdown(target, fragment: nil) }
        }
        if markdownExtensions.contains(target.pathExtension.lowercased()) { return .markdown(target, fragment: fragment) }
        guard fileExists(target) else { return .missing(target) }
        if let line, !isDirectory(target), !systemOpened.contains(target.pathExtension.lowercased()) {
            return .source(target, line: line.line, column: line.column)
        }
        return .file(target)
    }
}

/// Line references in links to source files.
public enum SourceLine {
    /// GitHub's line fragments: `L42`, `L42C3`, `L42-L50`, `L42C3-L50C1`, `L42-50`.
    public static func fragment(_ fragment: String) -> (line: Int, column: Int)? {
        guard let m = match(#"^L(\d+)(?:C(\d+))?(?:-L?\d+(?:C\d+)?)?$"#, fragment), let line = m[1].flatMap({ Int($0) }), line > 0 else { return nil }
        return (line, m[2].flatMap { Int($0) } ?? 0)
    }

    /// `path:42` or `path:42:3`: the path without the suffix, and the line.
    public static func pathSuffix(_ path: String) -> (path: String, line: (line: Int, column: Int))? {
        guard let m = match(#"^(.+?):(\d+)(?::(\d+))?$"#, path), let p = m[1], let line = m[2].flatMap({ Int($0) }), line > 0,
              !p.hasSuffix("/"), !p.isEmpty else { return nil }
        return (p, (line, m[3].flatMap { Int($0) } ?? 0))
    }

    private static func match(_ pattern: String, _ s: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }
}
