import Foundation

/// Resolves document-relative resources while rendering.
public protocol ResourceResolver: Sendable {
    /// Returns rendering info for an image source as written in the document.
    func image(_ src: String) -> ResolvedImage
    /// If inline code looks like a path (optionally `path:line[:col]`) to an existing file, return it.
    func pathReference(_ code: String) -> PathReference?
    /// Equal for resolvers that resolve everything the same way: parsed
    /// fragments are reused only while it stays the same.
    var identity: String { get }
}

public struct ResolvedImage: Sendable {
    public var url: String
    public var remote: Bool
    public var width: Int?
    public var height: Int?
    public init(url: String, remote: Bool, width: Int? = nil, height: Int? = nil) {
        self.url = url; self.remote = remote; self.width = width; self.height = height
    }
}

public struct PathReference: Sendable, Equatable {
    public var path: String
    public var line: Int?
    public var column: Int?
}

public enum ReadoutURL {
    public static let scheme = "readout"
    /// `readout://file/<percent-encoded absolute path>`
    public static func file(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        let enc = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "\(scheme)://file\(enc.hasPrefix("/") ? "" : "/")\(enc)"
    }
}

/// Passes calls to a resolver and counts the answers that came from the
/// file system (a local image's size, whether a path exists): HTML built
/// from them can go stale while the source stays the same, so the render
/// cache does not keep it. Used by one parse, on one thread.
final class ResolverProbe: ResourceResolver, @unchecked Sendable {
    let base: ResourceResolver
    private(set) var fileSystemReads = 0
    init(_ base: ResourceResolver) { self.base = base }
    var identity: String { base.identity }

    func image(_ src: String) -> ResolvedImage {
        let r = base.image(src)
        if !r.remote && !src.lowercased().hasPrefix("data:") { fileSystemReads += 1 }
        return r
    }

    func pathReference(_ code: String) -> PathReference? {
        let r = base.pathReference(code)
        // What could name a file was looked up, found or not.
        if r != nil || (code.count <= 300 && !code.contains(" ") && (code.contains(".") || code.contains("/"))) {
            fileSystemReads += 1
        }
        return r
    }
}

/// Default resolver backed by the file system, relative to the document's directory.
public struct FileResolver: ResourceResolver {
    public let baseDirectory: URL?
    public let searchRoots: [URL]

    public init(baseDirectory: URL?, searchRoots: [URL] = []) {
        self.baseDirectory = baseDirectory
        self.searchRoots = searchRoots
    }

    public var identity: String {
        ([baseDirectory?.path ?? ""] + searchRoots.map(\.path)).joined(separator: "\u{1F}")
    }

    public func image(_ src: String) -> ResolvedImage {
        let lower = src.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//") {
            return ResolvedImage(url: src, remote: true)
        }
        if lower.hasPrefix("data:") { return ResolvedImage(url: src, remote: false) }
        var path = src
        if lower.hasPrefix("file://"), let u = URL(string: src) { path = u.path }
        else if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            // `shot.png?raw=true`, `logo.svg#gh-dark-mode-only`: the file is what comes before
            // (a literal ? or # in a file name is written %3F, %23).
            path = String(path[..<cut])
        }
        path = path.removingPercentEncoding ?? path
        let url: URL
        if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else if path.hasPrefix("~/") { url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath) }
        else if let base = baseDirectory { url = base.appendingPathComponent(path).standardizedFileURL }
        else { return ResolvedImage(url: src, remote: false) }
        let size = ImageSize.read(url)
        return ResolvedImage(url: ReadoutURL.file(url.path), remote: false, width: size?.0, height: size?.1)
    }

    private static let pathPattern = try! NSRegularExpression(
        pattern: #"^(~?[\w@.\-/]*[\w\-]\.[A-Za-z0-9]{1,10}|[\w@.\-]+/[\w@.\-/]+)(?::(\d+))?(?::(\d+))?$"#)

    public func pathReference(_ code: String) -> PathReference? {
        guard code.count <= 300, !code.contains(" "), code.contains(".") || code.contains("/") else { return nil }
        let ns = code as NSString
        guard let m = FileResolver.pathPattern.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let raw = ns.substring(with: m.range(at: 1))
        // Avoid version numbers and bare domains like "1.2.3" or "example.com" without a slash.
        if !raw.contains("/") && raw.first?.isNumber == true { return nil }
        let line = m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) : nil
        let col = m.range(at: 3).location != NSNotFound ? Int(ns.substring(with: m.range(at: 3))) : nil
        var candidates: [URL] = []
        if raw.hasPrefix("/") { candidates.append(URL(fileURLWithPath: raw)) }
        else if raw.hasPrefix("~/") { candidates.append(URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath)) }
        else {
            if let b = baseDirectory {
                candidates.append(b.appendingPathComponent(raw))
                // Agents usually write paths relative to the repository root: walk up a few levels.
                var dir = b
                for _ in 0..<5 {
                    dir = dir.deletingLastPathComponent()
                    candidates.append(dir.appendingPathComponent(raw))
                    if dir.path == "/" { break }
                }
            }
            for r in searchRoots { candidates.append(r.appendingPathComponent(raw)) }
        }
        let fm = FileManager.default
        for c in candidates {
            var isDir: ObjCBool = false
            let p = c.standardizedFileURL.path
            if fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue {
                return PathReference(path: p, line: line, column: col)
            }
        }
        return nil
    }
}

/// Reads pixel dimensions from PNG, GIF, JPEG and WebP headers without decoding.
public enum ImageSize {
    public static func read(_ url: URL) -> (Int, Int)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 64 * 1024), d.count > 24 else { return nil }
        return parse([UInt8](d))
    }

    static func parse(_ b: [UInt8]) -> (Int, Int)? {
        func be16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func be32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        func le16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        // PNG
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) && b.count >= 24 {
            return (be32(16), be32(20))
        }
        // GIF
        if b.starts(with: [0x47, 0x49, 0x46]) && b.count >= 10 {
            return (le16(6), le16(8))
        }
        // WebP
        if b.count >= 30, b.starts(with: [0x52, 0x49, 0x46, 0x46]), b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            let chunk = String(bytes: b[12..<16], encoding: .ascii)
            if chunk == "VP8X" { return (1 + (Int(b[24]) | Int(b[25]) << 8 | Int(b[26]) << 16), 1 + (Int(b[27]) | Int(b[28]) << 8 | Int(b[29]) << 16)) }
            if chunk == "VP8 " && b.count >= 30 { return (le16(26) & 0x3FFF, le16(28) & 0x3FFF) }
            if chunk == "VP8L" && b.count >= 25 {
                let v = Int(b[21]) | Int(b[22]) << 8 | Int(b[23]) << 16 | Int(b[24]) << 24
                return ((v & 0x3FFF) + 1, ((v >> 14) & 0x3FFF) + 1)
            }
        }
        // JPEG
        if b.starts(with: [0xFF, 0xD8]) {
            var i = 2
            while i + 9 < b.count {
                guard b[i] == 0xFF else { i += 1; continue }
                let marker = b[i + 1]
                if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
                let len = be16(i + 2)
                if (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                    return (be16(i + 7), be16(i + 5))
                }
                i += 2 + len
            }
        }
        return nil
    }
}
