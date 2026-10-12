import Foundation

enum HTML {
    static func escape(_ s: String) -> String {
        // Fast path: most text needs no escaping.
        var needs = false
        for b in s.utf8 where b == 0x26 || b == 0x3C || b == 0x3E || b == 0x22 || b == 0x27 { needs = true; break }
        if !needs { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    private static let deniedTags = ["title", "textarea", "style", "xmp", "iframe", "noembed", "noframes",
                                     "script", "plaintext", "object", "embed", "base", "meta", "link", "form"]

    private static let deniedTagPattern = try! NSRegularExpression(
        pattern: "<(/?(?:" + deniedTags.joined(separator: "|") + ")(?=[\\s/>]|$))", options: .caseInsensitive)

    private static let remoteMediaSrc = try! NSRegularExpression(
        pattern: #"<(img|video|audio|source|track)\b[^>]*?\s(src|srcset)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)[^>]*>?"#,
        options: .caseInsensitive)

    /// GFM tagfilter plus removal of event handlers and javascript: URLs.
    /// Remote media sources are replaced with a click-to-load placeholder so
    /// raw HTML cannot phone home without the reader's consent — the same
    /// gate Markdown images go through. Local `src` paths are resolved like
    /// Markdown images' (relative to the document), when a resolver is given.
    static func sanitize(_ raw: String, resolver: ResourceResolver? = nil) -> String {
        var s = raw
        // GFM tagfilter: neutralize the opening "<" and keep the tag as written (<XMP stays XMP).
        s = deniedTagPattern.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                                      withTemplate: "&lt;$1")
        s = s.replacingOccurrences(of: #"\son[a-zA-Z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "javascript:", with: "blocked:", options: .caseInsensitive)
        s = gateRemoteMedia(s, resolver: resolver)
        return s
    }

    // NOTE (security boundary): this regex gate is UX only — it turns common
    // remote media into click-to-load placeholders. The real security
    // boundary is the Content-Security-Policy in web/src/reader.html, which
    // allows no http:/https: sources at all, so every construct this regex
    // misses is still blocked by the browser. See docs/design.md.
    private static func gateRemoteMedia(_ s: String, resolver: ResourceResolver?) -> String {
        let ns = s as NSString
        let matches = remoteMediaSrc.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let urlValue = ns.substring(with: m.range(at: 3))
            let unquoted = urlValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let lower = unquoted.lowercased()
            let isRemote = lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
            var end = m.range.location + m.range.length
            if isRemote {
                let tag = ns.substring(with: m.range(at: 1)).lowercased()
                // Swallow an immediately following empty close tag: <video src="…"></video>.
                let close = "</\(tag)>"
                if ns.substring(from: end).lowercased().hasPrefix(close) { end += close.count }
                out += "<span class=\"remote-img\" data-tag=\"\(tag)\" data-src=\"\(escape(unquoted))\" data-alt=\"\"></span>"
            } else if let resolver, ns.substring(with: m.range(at: 2)).lowercased() == "src", isLocalPath(lower) {
                // A path relative to the document, not to the page: resolved as a Markdown image's.
                let r = resolver.image(unquoted)
                let valueRange = m.range(at: 3)
                out += ns.substring(with: NSRange(location: m.range.location, length: valueRange.location - m.range.location))
                out += "\"" + escape(r.url) + "\""
                out += ns.substring(with: NSRange(location: valueRange.location + valueRange.length,
                                                  length: m.range.location + m.range.length - valueRange.location - valueRange.length))
            } else {
                out += ns.substring(with: m.range)
            }
            last = end
        }
        out += ns.substring(from: last)
        return out
    }

    /// A file path (relative, absolute, `~/` or `file:`), not another scheme, a fragment or data.
    private static func isLocalPath(_ lower: String) -> Bool {
        guard !lower.isEmpty, !lower.hasPrefix("#"), !lower.hasPrefix("data:") else { return false }
        if lower.hasPrefix("file:") { return true }
        if let colon = lower.firstIndex(of: ":"),
           lower[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }) {
            return false   // readout:, blob:, ...
        }
        return true
    }
}
