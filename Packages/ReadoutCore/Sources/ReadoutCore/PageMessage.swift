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
    case copyLink(anchor: String)
    case open(href: String)
    case loadRemote(url: String, id: String)
    case openPath(path: String, line: Int, column: Int)
    case error(message: String)
    /// The reader turned code wrapping on or off (remembered for all windows).
    case setCodeWrap(on: Bool)
    /// A key found nothing to go to (N with no change left): the app beeps.
    case nothing
    /// N went past the last change and wrapped around to the first: the app beeps.
    case wrapped

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
        case "copyLink":
            guard let anchor = msg["anchor"] as? String, !anchor.isEmpty else { return nil }
            self = .copyLink(anchor: anchor)
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
        case "nothing": self = .nothing
        case "wrapped": self = .wrapped
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
    public static func resolve(_ href: String, from documentURL: URL, markdownExtensions: Set<String>,
                               fileExists: (URL) -> Bool, isDirectory: (URL) -> Bool = { _ in false }) -> LinkTarget? {
        func url(_ p: String) -> URL {
            p.hasPrefix("/") ? URL(fileURLWithPath: p)
                : documentURL.deletingLastPathComponent().appendingPathComponent(p).standardizedFileURL
        }
        // "main.swift:42" and "Makefile:12" parse as URLs with the schemes
        // "main.swift" and "makefile": a file name with a line. A scheme has
        // no dot; "tel:5551234" stays a URL unless a file "tel" is there.
        if let u = URL(string: href), let scheme = u.scheme?.lowercased(), scheme != "file" {
            let suffix = SourceLine.pathSuffix(href)
            let isPath = suffix.map { s in
                scheme.contains(".") || fileExists(url(s.path.removingPercentEncoding ?? s.path))
                    || fileExists(url(href.removingPercentEncoding ?? href))
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
