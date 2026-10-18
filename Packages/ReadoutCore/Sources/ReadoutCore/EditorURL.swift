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
