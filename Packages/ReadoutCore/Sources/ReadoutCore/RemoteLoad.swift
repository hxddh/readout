import Foundation

/// Policy for natively proxied remote images. The page itself can never fetch
/// (its CSP allows no http:/https: sources), so when the reader clicks a
/// remote-image placeholder the native side downloads the bytes with an
/// ephemeral, cookie-free session and serves them back over `readout:`.
/// These pure checks run first — on any response, including redirects — and
/// are unit-tested on Linux.
public enum RemoteLoad {
    /// Maximum proxied response body.
    public static let maxBytes = 20 * 1024 * 1024
    /// Per-download timeout, in seconds.
    public static let timeoutSeconds = 15.0

    public enum Rejection: Equatable, Sendable {
        case scheme
        case contentType
        case tooLarge
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
