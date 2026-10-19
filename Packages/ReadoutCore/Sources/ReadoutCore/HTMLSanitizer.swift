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

    /// A media tag with a `src` or `srcset` attribute. A `>` inside a quoted
    /// value does not end it, and neither does a `<` (`alt="x<y"`), but a
    /// value that has passed a `>` cannot run on into a following tag (a `<`
    /// that starts one), and unquoted text never does. A tag whose quotes do
    /// not pair up — `alt='it's'` — so that the quote-aware scan cannot reach
    /// its `>`, falls back to ending at its first `>`: it cannot swallow the
    /// text and tags after it. A tag whose quotes pair up never falls back, so
    /// `src=` inside a quoted value stays text. Every attempt stops at the
    /// next `>` followed by a tag, so the scan is linear.
    private static let remoteMediaSrc: NSRegularExpression = {
        let lt = #"<(?![a-z/!?])"#                      // a `<` that does not start a tag
        let quoted = { (q: String) in #"\#(q)[^\#(q)>]*(?:>(?:[^\#(q)<]|\#(lt))*)?\#(q)"# }
        let item = #"(?:[^<>"']|\#(lt)|\#(quoted("\""))|\#(quoted("'")))"#
        let plain = #"(?:[^<>]|\#(lt))"#
        let source = #"\s(?:src|srcset)\s*="#
        let quoteAware = #"\#(item)*?\#(source)\#(item)*>"#
        let unbalanced = #"(?!\#(item)*>)\#(plain)*?\#(source)\#(plain)*>?"#
        return try! NSRegularExpression(
            pattern: #"<(img|video|audio|source|track)\b(?:\#(quoteAware)|\#(unbalanced))"#, options: .caseInsensitive)
    }()
    /// Each `src` and `srcset` attribute of a media tag.
    private static let sourceAttribute = try! NSRegularExpression(
        pattern: #"\s(src|srcset)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, options: .caseInsensitive)

    /// A Markdown link's destination, with a scheme that runs code or carries
    /// a document (`javascript:`, `vbscript:`, `data:`, however spaced or
    /// cased) turned into `blocked:`, as raw HTML's `javascript:` is.
    static func safeLink(_ destination: String) -> String {
        guard let colon = destination.firstIndex(of: ":") else { return destination }
        let scheme = String(String.UnicodeScalarView(destination[..<colon].unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F })).lowercased()
        guard ["javascript", "vbscript", "data"].contains(scheme) else { return destination }
        return "blocked:" + destination[destination.index(after: colon)...]
    }

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
            let tagText = ns.substring(with: m.range)
            let tns = tagText as NSString
            // Every src and srcset: the value's range in the tag, which it is, the value unquoted.
            let attributes = sourceAttribute.matches(in: tagText, range: NSRange(location: 0, length: tns.length)).map {
                (range: $0.range(at: 2), srcset: tns.substring(with: $0.range(at: 1)).lowercased() == "srcset",
                 value: tns.substring(with: $0.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            }
            // A remote source anywhere in the tag (src first: it is what the placeholder loads).
            let urls = attributes.filter { !$0.srcset }.map(\.value)
                + attributes.filter(\.srcset).flatMap { srcsetCandidates($0.value).map(\.url) }
            var end = m.range.location + m.range.length
            if let remote = urls.first(where: isRemote) {
                let tag = ns.substring(with: m.range(at: 1)).lowercased()
                // Swallow an immediately following empty close tag: <video src="…"></video>.
                let close = "</\(tag)>"
                if ns.substring(from: end).lowercased().hasPrefix(close) { end += close.count }
                out += "<span class=\"remote-img\" data-tag=\"\(tag)\" data-src=\"\(escape(remote))\" data-alt=\"\"></span>"
            } else if let resolver {
                // Paths relative to the document, not to the page: each src and
                // srcset candidate is resolved as a Markdown image's.
                var at = 0
                for a in attributes {
                    let value: String
                    if a.srcset {
                        value = srcsetCandidates(a.value).map { c in
                            (isLocalPath(c.url.lowercased()) ? resolver.image(c.url).url : c.url) + c.descriptor
                        }.joined(separator: ", ")
                    } else {
                        guard isLocalPath(a.value.lowercased()) else { continue }
                        value = resolver.image(a.value).url
                    }
                    out += tns.substring(with: NSRange(location: at, length: a.range.location - at))
                    out += "\"" + escape(value) + "\""
                    at = a.range.location + a.range.length
                }
                out += tns.substring(from: at)
            } else {
                out += tagText
            }
            last = end
        }
        out += ns.substring(from: last)
        return out
    }

    private static func isRemote(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
    }

    /// A `srcset`'s candidates: each URL and its descriptor as written (with
    /// a leading space: `" 2x"`; empty without one), split as the HTML standard does.
    static func srcsetCandidates(_ value: String) -> [(url: String, descriptor: String)] {
        var out: [(url: String, descriptor: String)] = []
        var rest = Substring(value)
        while true {
            rest = rest.drop(while: { $0.isWhitespace || $0 == "," })
            guard !rest.isEmpty else { break }
            var url = rest.prefix(while: { !$0.isWhitespace })
            rest = rest.dropFirst(url.count)
            var descriptor = ""
            if url.hasSuffix(",") {
                // Commas ending the URL end the candidate.
                while url.hasSuffix(",") { url = url.dropLast() }
            } else {
                let d = rest.prefix(while: { $0 != "," })
                rest = rest.dropFirst(d.count)
                let trimmed = d.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { descriptor = " " + trimmed }
            }
            if !url.isEmpty { out.append((String(url), descriptor)) }
        }
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
