import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        // What could name a file was looked up, found or not (a file
        // resolver without folders looks up absolute and ~/ paths only).
        var looked = r != nil || FileResolver.mayBePath(code)
        if looked, let f = base as? FileResolver, f.baseDirectory == nil, f.searchRoots.isEmpty,
           !code.hasPrefix("/"), !code.hasPrefix("~") {
            looked = false
        }
        if looked { fileSystemReads += 1 }
        return r
    }
}

/// The project folder an agent worked in when it wrote a document (Claude
/// Code's hook passes its `cwd`). Plans live in ~/.claude/plans and name
/// paths relative to that folder, which the document's own folder and the
/// folders above it never reach.
public enum ProjectRoot {
    /// `path` when it is an existing directory given as an absolute path
    /// (standardized), else nil. The file system root is no project.
    public static func validated(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        guard p != "/" else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
        return p
    }

    /// The folders a document's path references are also looked up in: its
    /// project first, then the agent folders (`~/` expanded), each once.
    public static func searchRoots(project: String?, workspaces: [String]) -> [URL] {
        var seen: Set<String> = []
        var out: [URL] = []
        for p in (project.map { [$0] } ?? []) + workspaces.map({ NSString(string: $0).expandingTildeInPath }) {
            let u = URL(fileURLWithPath: p).standardizedFileURL
            if seen.insert(u.path).inserted { out.append(u) }
        }
        return out
    }
}

/// Default resolver backed by the file system, relative to the document's directory.
public struct FileResolver: ResourceResolver {
    public let baseDirectory: URL?
    public let searchRoots: [URL]
    /// The project the document was written for (Claude Code's `cwd`): a
    /// relative path is looked up there right after the document's folder,
    /// before the folders above it.
    public let projectRoot: URL?
    /// The repository the document's folder is in (the nearest folder at or
    /// above it holding `.git`): relative paths are looked up in the folders
    /// above the document up to it, and nowhere above the document outside one.
    let repositoryRoot: URL?

    public init(baseDirectory: URL?, searchRoots: [URL] = [], projectRoot: URL? = nil) {
        self.baseDirectory = baseDirectory?.standardizedFileURL
        self.searchRoots = searchRoots
        self.projectRoot = projectRoot?.standardizedFileURL
        self.repositoryRoot = self.baseDirectory.flatMap(Self.repositoryRoot(above:))
    }

    /// A document's resolver: its folder, then its project (when known), then
    /// the folders above it in its repository, then the agent folders.
    public init(baseDirectory: URL?, project: String?, workspaces: [String]) {
        self.init(baseDirectory: baseDirectory,
                  searchRoots: ProjectRoot.searchRoots(project: project, workspaces: workspaces),
                  projectRoot: project.map { URL(fileURLWithPath: $0) })
    }

    public var identity: String {
        ([baseDirectory?.path ?? "", projectRoot?.path ?? ""] + searchRoots.map(\.path)).joined(separator: "\u{1F}")
    }

    /// How many folders above the document a relative path is looked up in.
    static let walkUpLevels = 5

    /// The nearest folder at or above `dir` that holds `.git` (a folder, or
    /// the file a worktree has), else nil. The file system root is no repository.
    static func repositoryRoot(above dir: URL) -> URL? {
        let fm = FileManager.default
        var d = dir.standardizedFileURL
        for _ in 0..<64 {
            if d.path == "/" { return nil }
            if fm.fileExists(atPath: d.appendingPathComponent(".git").path) { return d }
            let up = d.deletingLastPathComponent()
            if up.path == d.path { return nil }
            d = up
        }
        return nil
    }

    /// Where a path written in the document (`src/app.ts`, `../README.md`,
    /// `~/notes.md`, `/etc/hosts`; no `:line` suffix or `#fragment`) may be,
    /// most likely first, each once: an absolute or `~/` path as written;
    /// a relative one in the document's folder, then the project, then the
    /// folders above the document inside its repository (up to five, and
    /// always its root: agents write paths relative to the repository root),
    /// then the other search roots.
    /// Code spans resolve through it; so can links (`[x](src/a.ts#L42)`).
    public func candidates(for path: String) -> [URL] {
        if path.hasPrefix("/") { return [URL(fileURLWithPath: path).standardizedFileURL] }
        if path.hasPrefix("~/") { return [URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL] }
        var out: [URL] = []
        var seen: Set<String> = []
        func add(_ dir: URL) {
            let u = dir.appendingPathComponent(path).standardizedFileURL
            if seen.insert(u.path).inserted { out.append(u) }
        }
        if let b = baseDirectory { add(b) }
        if let projectRoot { add(projectRoot) }
        if let b = baseDirectory, let repo = repositoryRoot {
            var dir = b
            for _ in 0..<Self.walkUpLevels where dir.path != repo.path {
                dir = dir.deletingLastPathComponent()
                add(dir)
            }
            // From deeper in it, still its root: agents write paths relative to it.
            add(repo)
        }
        for r in searchRoots { add(r) }
        return out
    }

    /// The first of `candidates(for:)` that is an existing file (not a folder).
    public func existingFile(_ path: String) -> URL? {
        let fm = FileManager.default
        for c in candidates(for: path) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c.path, isDirectory: &isDir), !isDir.boolValue { return c }
        }
        return nil
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

    /// Could name a file (what `pathPattern` can match): no space, a dot or a
    /// slash, at most 300 characters. Byte checks, run for every code span:
    /// a space, dot or slash byte is that character (UTF-8), and the pattern
    /// matches none of the characters a combining mark could join to a space.
    static func mayBePath(_ code: String) -> Bool {
        !FastBytes.contains(code, 0x20) && (FastBytes.contains(code, 0x2E) || FastBytes.contains(code, 0x2F))
            && (code.utf8.count <= 300 || code.count <= 300)
    }

    public func pathReference(_ code: String) -> PathReference? {
        guard Self.mayBePath(code) else { return nil }
        let ns = code as NSString
        guard let m = FileResolver.pathPattern.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let raw = ns.substring(with: m.range(at: 1))
        // Avoid version numbers and bare domains like "1.2.3" or "example.com" without a slash.
        if !raw.contains("/") && raw.first?.isNumber == true { return nil }
        let line = m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) : nil
        let col = m.range(at: 3).location != NSNotFound ? Int(ns.substring(with: m.range(at: 3))) : nil
        guard let file = existingFile(raw) else { return nil }
        return PathReference(path: file.path, line: line, column: col)
    }
}

/// Reads pixel dimensions from PNG, GIF, JPEG and WebP headers without decoding.
public enum ImageSize {
    public static func read(_ url: URL) -> (Int, Int)? {
        // A regular file only: reading a FIFO or a device would block the
        // parse. Opened without waiting for a writer, then checked (the same
        // file: nothing can be swapped in between).
        let fd = open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, UInt32(info.st_mode) & 0o170000 == 0o100000 else { close(fd); return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
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
