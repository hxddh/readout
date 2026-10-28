import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Paths the way the file system reports them.
public enum RealPath {
    /// The path with every symlink resolved, a leading `/private` included
    /// (realpath(3)): FSEvents reports `/private/tmp/...` for `/tmp/...`,
    /// `/private/var/folders/...` for `$TMPDIR`, a symlinked folder's target.
    /// `URL.resolvingSymlinksInPath()` strips `/private` again, so it does not
    /// match. A path that does not exist resolves its parent and keeps the name;
    /// a symlink whose target does not exist yet (`ln -sf ../runs/run-42.md
    /// latest.md` before run 42 is written) resolves to where that target will
    /// be: read relative to the link's folder, that folder resolved, the name kept.
    public static func of(_ path: String) -> String { resolve(path, hops: 0) }

    private static func resolve(_ path: String, hops: Int) -> String {
        if let r = realpath(path, nil) {
            defer { free(r) }
            return String(cString: r)
        }
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        if hops < 32, let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            let next = destination.hasPrefix("/") ? destination : (parent as NSString).appendingPathComponent(destination)
            return resolve(next, hops: hops + 1)
        }
        guard !parent.isEmpty, parent != path, let r = realpath(parent, nil) else { return path }
        defer { free(r) }
        return (String(cString: r) as NSString).appendingPathComponent(ns.lastPathComponent)
    }
}

/// What a file watcher compares file-system events with, for one opened path.
///
/// The opened path may be a symlink (`latest.md -> run-41.md`): events for the
/// file it points to are changes, and an event for the link itself (an agent
/// running `ln -sf run-42.md latest.md`) means the link may point elsewhere
/// now, so it is resolved again. Both folders are watched.
public struct WatchTarget: Equatable, Sendable {
    /// The path as it was opened.
    public let path: String
    /// The real path of the link itself: its folder resolved, its name kept.
    public let linkPath: String
    /// The real path of the file the opened path resolves to now.
    public private(set) var target: String

    public init(path: String) {
        self.path = path
        let ns = path as NSString
        linkPath = (RealPath.of(ns.deletingLastPathComponent) as NSString).appendingPathComponent(ns.lastPathComponent)
        target = RealPath.of(path)
    }

    /// The folders to watch: the target's, and the link's when it differs.
    public var directories: [String] {
        let dirs = [(target as NSString).deletingLastPathComponent, (linkPath as NSString).deletingLastPathComponent]
        return dirs[0] == dirs[1] ? [dirs[0]] : dirs
    }

    /// Whether an event path is the file shown. Exact match first: on
    /// case-sensitive volumes "Readme.md" and "README.md" are different files;
    /// case-insensitive volumes may report either spelling.
    public func isTarget(_ eventPath: String) -> Bool { Self.same(eventPath, target) }

    /// Whether an event path is the opened path itself (the link, when it is one).
    public func isLink(_ eventPath: String) -> Bool { Self.same(eventPath, linkPath) }

    /// Resolves the opened path again; true when it points to another file now.
    public mutating func reresolve() -> Bool {
        let now = RealPath.of(path)
        guard now != target else { return false }
        target = now
        return true
    }

    private static func same(_ a: String, _ b: String) -> Bool { a == b || a.lowercased() == b.lowercased() }
}

/// After a shown symlink is pointed at another file, the reader holds its
/// saves until a read of that file has filled the session: a read of the old
/// target still in flight when the link changed does not count.
public struct RetargetGate: Equatable, Sendable {
    /// The real path of the new target, until a read of it lands.
    public private(set) var pending: String?

    public init() {}

    public var isPending: Bool { pending != nil }

    public mutating func retargeted(to target: String) { pending = target }

    /// A read from `source` (`DocumentLoader.lastSourcePath`) has filled the
    /// session. True when it is the pending target's: the retarget is settled.
    /// Either spelling counts: a target recorded before it existed may be
    /// spelled differently from the real path its read reports.
    public mutating func read(from source: String?) -> Bool {
        guard let p = pending, let source, source == p || RealPath.of(source) == RealPath.of(p) else { return false }
        pending = nil
        return true
    }
}

/// Where the reading state of a file is kept: one key per file, however the
/// path is spelled (through a symlink, under /tmp or /private/tmp), as windows are.
public enum BaselineKey {
    public static func key(forPath path: String) -> String {
        String(XXHash64.hash(RealPath.of(path)), radix: 16)
    }
}

/// `readout-open://open?path=<percent-encoded absolute path>&background=1[&anchor=<section>][&root=<folder>]`:
/// how the `readout` script asks for a file in the background (`readout -b`,
/// `readout --hook`). `root`: the project the agent worked in (the hook's
/// `cwd`), where the paths a plan names are found. `open -g` alone only keeps Readout from activating; the
/// open itself still reaches the app as an ordinary request, which brings the
/// window forward and selects its tab. A scheme of its own, distinct from the
/// `readout:` scheme the reader page loads from inside its web view.
public enum OpenLink {
    public static let scheme = "readout-open"

    public struct Request: Equatable, Sendable {
        public let path: String
        public let background: Bool
        /// A section to scroll to (`readout plan.md#risks`).
        public var anchor: String? = nil
        /// The project folder the agent worked in (absolute; whether it exists
        /// is checked where it is used, `ProjectRoot.validated`).
        public var root: String? = nil
    }

    public static func parse(_ url: URL) -> Request? {
        guard url.scheme?.lowercased() == scheme,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.host?.lowercased() == "open",
              let path = c.queryItems?.first(where: { $0.name == "path" })?.value, path.hasPrefix("/") else { return nil }
        let bg = c.queryItems?.first(where: { $0.name == "background" })?.value?.lowercased()
        let anchor = c.queryItems?.first(where: { $0.name == "anchor" })?.value
        let root = c.queryItems?.first(where: { $0.name == "root" })?.value
        return Request(path: path, background: bg == "1" || bg == "true" || bg == "yes", anchor: anchor?.isEmpty == false ? anchor : nil,
                       root: root?.hasPrefix("/") == true ? root : nil)
    }
}
