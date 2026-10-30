import Foundation

/// URLs that open a file at a line in an editor (Settings ▸ Editor).
public enum EditorURL {
    /// `subl://open?url=file://…&line=N`. The file URL is a query value
    /// itself: every character that is not unreserved is percent-encoded,
    /// or "&" and "=" in a path (`a&line=9.md`) would end the value and add
    /// parameters of their own.
    public static func sublime(path: String, line: Int) -> URL? {
        let fileURL = URL(fileURLWithPath: path).absoluteString
        let encoded = fileURL.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? fileURL
        return URL(string: "subl://open?url=\(encoded)" + (line > 0 ? "&line=\(line)" : ""))
    }

    /// RFC 3986 unreserved characters: letters, digits and "-._~".
    static let queryValueAllowed: CharacterSet = {
        var s = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        s.insert(charactersIn: "-._~")
        return s
    }()
}

/// The editors that open a file at a line, as Settings ▸ Editor stores them
/// (`editor`; "Default app" is `system`, which is none of these).
public enum LineEditor: String, CaseIterable, Sendable {
    case vscode, cursor, zed, xcode, sublime

    /// The editor an app is, by its bundle identifier: with "Default app",
    /// a file whose default app is one of these opens at the line too.
    public init?(bundleIdentifier: String) {
        switch bundleIdentifier.lowercased() {
        case "com.microsoft.vscode": self = .vscode
        case "com.todesktop.230313mzl4w4u92": self = .cursor
        case "dev.zed.zed", "dev.zed.zed-preview": self = .zed
        case "com.apple.dt.xcode": self = .xcode
        case "com.sublimetext.4", "com.sublimetext.3": self = .sublime
        default: return nil
        }
    }

    /// The link that opens `path` at `line` and `column` (0: none). Nil for
    /// Xcode, which `xed -l` opens.
    public func url(path: String, line: Int, column: Int) -> URL? {
        // urlPathAllowed leaves "?" and "#" unescaped: a file literally named
        // "foo#bar.md" would cut the link at the fragment.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        let enc = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let pos = line > 0 ? ":\(line)" + (column > 0 ? ":\(column)" : "") : ""
        switch self {
        case .vscode, .cursor, .zed: return URL(string: "\(rawValue)://file\(enc)\(pos)")
        case .sublime: return EditorURL.sublime(path: path, line: line)
        case .xcode: return nil
        }
    }
}
