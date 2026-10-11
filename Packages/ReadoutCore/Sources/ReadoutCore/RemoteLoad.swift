import Foundation

/// Policy for natively proxied remote images. The page itself can never fetch
/// (its CSP allows no http:/https: sources), so when the reader clicks a
/// remote-image placeholder the native side downloads the bytes with an
/// ephemeral, cookie-free session (`RemoteFetcher`) and serves them back over
/// `readout:`. These checks run before the request, on every redirect, and on
/// the response headers before any body is accepted.
public enum RemoteLoad {
    /// Maximum proxied response body.
    public static let maxBytes = 20 * 1024 * 1024
    /// Per-download timeout, in seconds.
    public static let timeoutSeconds = 15.0

    public enum Rejection: Equatable, Sendable {
        case scheme
        case privateAddress
        case contentType
        case tooLarge
    }

    /// Only http/https URLs with a public host may be fetched.
    public static func check(_ urlString: String) -> Rejection? {
        if let r = checkScheme(urlString) { return r }
        guard let host = URL(string: urlString)?.host else { return .scheme }
        return checkHost(host)
    }

    /// Only http/https URLs may be fetched. Anything else (file:, ftp:,
    /// javascript:, data:, …) is rejected before any request goes out.
    public static func checkScheme(_ urlString: String) -> Rejection? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return .scheme }
        return nil
    }

    /// A click in a document must not become a request to the reader's own
    /// machine or local network (routers, dev servers, metadata endpoints).
    /// Literal loopback, link-local, private and unique-local addresses are
    /// refused, as are local host names and numeric host spellings that
    /// resolvers may read as IPv4 (`2130706433`, `0x7f.1`, `0177.0.0.1`).
    /// Names are not resolved here: a public name that resolves to a private
    /// address (DNS rebinding) is out of scope for a click-to-load image.
    public static func checkHost(_ rawHost: String) -> Rejection? {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return .privateAddress }

        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".internal") || host.hasSuffix(".home.arpa") {
            return .privateAddress
        }

        if host.contains(":") {
            let bare = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host  // drop zone id
            guard let bytes = parseIPv6(bare) else { return .privateAddress }
            return isPublicIPv6(bytes) ? nil : .privateAddress
        }

        // A host that starts with a digit and uses only digits, dots and hex
        // spelling is an address literal. Only canonical dotted-quad decimal is
        // evaluated; every other numeric spelling is refused outright.
        if host.first?.isNumber == true, host.allSatisfy({ "0123456789abcdefx.".contains($0) }) {
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            let octets = parts.compactMap { p -> Int? in
                guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber),
                      p.count == 1 || p.first != "0", let v = Int(p), v <= 255 else { return nil }
                return v
            }
            guard parts.count == 4, octets.count == 4 else { return .privateAddress }
            return isPublicIPv4(octets) ? nil : .privateAddress
        }
        return nil
    }

    static func isPublicIPv4(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _): return false
        case (100, 64...127): return false          // carrier-grade NAT
        case (169, 254): return false               // link-local (incl. cloud metadata)
        case (172, 16...31): return false
        case (192, 168): return false
        case (198, 18...19): return false           // benchmarking
        case (224...255, _): return false           // multicast, reserved, broadcast
        default: return true
        }
    }

    static func isPublicIPv6(_ b: [UInt8]) -> Bool {
        let first10Zero = b[0..<10].allSatisfy { $0 == 0 }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] <= 1 { return false }  // :: and ::1
        if b[0] & 0xfe == 0xfc { return false }                              // fc00::/7 unique local
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false }              // fe80::/10 link-local
        if b[0] == 0xfe && b[1] & 0xc0 == 0xc0 { return false }              // fec0::/10 site-local
        if b[0] == 0xff { return false }                                     // multicast
        let v4 = b[12..<16].map(Int.init)
        if first10Zero && b[10] == 0xff && b[11] == 0xff { return isPublicIPv4(v4) }   // ::ffff:a.b.c.d
        if first10Zero && b[10] == 0 && b[11] == 0 { return isPublicIPv4(v4) }         // ::a.b.c.d (compat)
        if Array(b[0..<12]) == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] { return isPublicIPv4(v4) } // 64:ff9b::/96
        return true
    }

    /// Parses an IPv6 literal (RFC 4291 text forms, including `::` and an
    /// embedded dotted quad) into 16 bytes, or nil when it is not one.
    static func parseIPv6(_ s: String) -> [UInt8]? {
        var text = Substring(s)
        var tail: [UInt8] = []
        if let lastColon = text.lastIndex(of: ":"), text[text.index(after: lastColon)...].contains(".") {
            let quad = text[text.index(after: lastColon)...].split(separator: ".", omittingEmptySubsequences: false)
            guard quad.count == 4 else { return nil }
            for q in quad {
                guard !q.isEmpty, q.count <= 3, q.allSatisfy({ $0.isASCII && $0.isNumber }), let v = UInt8(q) else { return nil }
                tail.append(v)
            }
            text = text[...lastColon]
            if text.hasSuffix("::") { /* keep */ } else { text = text.dropLast() }
        }
        func groups(_ part: Substring) -> [UInt16]? {
            if part.isEmpty { return [] }
            var out: [UInt16] = []
            for g in part.split(separator: ":", omittingEmptySubsequences: false) {
                guard (1...4).contains(g.count), let v = UInt16(g, radix: 16) else { return nil }
                out.append(v)
            }
            return out
        }
        let want = tail.isEmpty ? 8 : 6
        var words: [UInt16]
        if let r = text.range(of: "::") {
            guard text[r.upperBound...].range(of: "::") == nil,
                  let head = groups(text[..<r.lowerBound]), let rest = groups(text[r.upperBound...]),
                  head.count + rest.count < want else { return nil }
            words = head + Array(repeating: 0, count: want - head.count - rest.count) + rest
        } else {
            guard let all = groups(text), all.count == want else { return nil }
            words = all
        }
        var bytes = words.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
        bytes += tail
        return bytes.count == 16 ? bytes : nil
    }

    /// Only image bodies may be proxied. `contentType` is the response's
    /// `Content-Type` header value (or nil when absent).
    public static func checkContentType(_ contentType: String?) -> Rejection? {
        guard let ct = contentType?.lowercased(),
              ct.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("image/") }) == true
        else { return .contentType }
        return nil
    }

    /// Enforces `maxBytes` on a `Content-Length` (or accumulated) byte count.
    public static func checkLength(_ bytes: Int) -> Rejection? {
        bytes >= 0 && bytes <= maxBytes ? nil : .tooLarge
    }
}
