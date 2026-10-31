import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        /// The host name did not resolve, so it could not be checked.
        case unresolved
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
    /// Single-label names (`intranet`, `router`) are refused too. Names are
    /// checked again after resolution (`checkResolved`), which catches public
    /// names pointing at private addresses (`127.0.0.1.nip.io`).
    public static func checkHost(_ rawHost: String) -> Rejection? {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return .privateAddress }

        if host.contains(":") {
            let bare = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host  // drop zone id
            guard let bytes = parseIPv6(bare) else { return .privateAddress }
            return isPublicIPv6(bytes) ? nil : .privateAddress
        }

        // Control characters, spaces and percent-escapes never belong in a
        // host name; a NUL could truncate it further down the stack.
        if host.unicodeScalars.contains(where: { $0.value <= 0x20 || $0 == "%" || $0 == "\u{7f}" }) {
            return .privateAddress
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".lan")
            || host.hasSuffix(".internal") || host.hasSuffix(".home.arpa") {
            return .privateAddress
        }

        // A host whose last label is a number is an IPv4 literal (the WHATWG
        // URL "ends in a number" rule, which browsers and resolvers follow).
        // Only canonical dotted-quad decimal is evaluated; every other numeric
        // spelling is refused outright. `1a.de` or `1feed.cafe` are names.
        if endsInNumber(host) {
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            let octets = parts.compactMap { p -> Int? in
                guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber),
                      p.count == 1 || p.first != "0", let v = Int(p), v <= 255 else { return nil }
                return v
            }
            guard parts.count == 4, octets.count == 4 else { return .privateAddress }
            return isPublicIPv4(octets) ? nil : .privateAddress
        }
        // Single-label names only resolve on local networks (search domains, mDNS, hosts files).
        if !host.contains(".") { return .privateAddress }
        return nil
    }

    /// True when `host` is an address literal (no name resolution needed).
    public static func isAddressLiteral(_ rawHost: String) -> Bool {
        var host = rawHost
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") { return true }
        return endsInNumber(host.lowercased())
    }

    /// WHATWG URL: the last label (ignoring one trailing dot) is decimal
    /// digits or `0x` followed by hex digits.
    static func endsInNumber(_ host: String) -> Bool {
        var labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.last?.isEmpty == true, labels.count > 1 { labels.removeLast() }
        guard let last = labels.last, !last.isEmpty else { return false }
        if last.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        let l = last.lowercased()
        return l.hasPrefix("0x") && l.dropFirst(2).allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Checks the addresses a name resolved to: every one must be public, and
    /// a name that resolves to nothing is refused (it could not be checked).
    public static func checkResolved(_ addresses: [String]) -> Rejection? {
        guard !addresses.isEmpty else { return .unresolved }
        return addresses.contains(where: { checkHost($0) != nil }) ? .privateAddress : nil
    }

    /// Numeric addresses for `host` from the system resolver (empty on failure).
    public static func systemResolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let ai = node {
            var buf = [CChar](repeating: 0, count: 1025)  // NI_MAXHOST
            if let addr = ai.pointee.ai_addr,
               getnameinfo(addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            node = ai.pointee.ai_next
        }
        return out
    }

    static func isPublicIPv4(_ o: [Int]) -> Bool {
        switch (o[0], o[1], o[2]) {
        case (192, 0, 0): return false              // IETF protocol assignments
        case (192, 0, 2), (198, 51, 100), (203, 0, 113): return false   // documentation
        default: break
        }
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
        if Array(b[0..<8]) == [1, 0, 0, 0, 0, 0, 0, 0] { return false }      // 100::/64 discard
        if Array(b[0..<6]) == [0, 0x64, 0xff, 0x9b, 0, 1] { return false }   // 64:ff9b:1::/48 local NAT64
        if Array(b[0..<4]) == [0x20, 0x01, 0, 0] { return false }             // 2001::/32 Teredo
        if Array(b[0..<4]) == [0x20, 0x01, 0x0d, 0xb8] { return false }       // 2001:db8::/32 documentation
        if b[0] == 0x20 && b[1] == 0x02 { return isPublicIPv4(b[2..<6].map(Int.init)) }  // 2002::/16 6to4
        if b[0..<8].allSatisfy({ $0 == 0 }) && b[8] == 0xff && b[9] == 0xff && b[10] == 0 && b[11] == 0 {
            return isPublicIPv4(b[12..<16].map(Int.init))                   // ::ffff:0:a.b.c.d translated
        }
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
