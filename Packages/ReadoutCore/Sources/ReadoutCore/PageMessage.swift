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
    /// Any other local file: opened by the system.
    case file(URL)
    /// A local path that does not exist.
    case missing

    /// - Parameters:
    ///   - documentURL: the file the link appears in (relative paths resolve against its folder).
    ///   - markdownExtensions: lowercased extensions Readout opens itself.
    ///   - fileExists: existence check for non-Markdown targets.
    public static func resolve(_ href: String, from documentURL: URL, markdownExtensions: Set<String>,
                               fileExists: (URL) -> Bool) -> LinkTarget? {
        if let u = URL(string: href), let scheme = u.scheme?.lowercased(), scheme != "file" {
            return .external(u)
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
        let target = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : documentURL.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
        if markdownExtensions.contains(target.pathExtension.lowercased()) { return .markdown(target, fragment: fragment) }
        return fileExists(target) ? .file(target) : .missing
    }
}
