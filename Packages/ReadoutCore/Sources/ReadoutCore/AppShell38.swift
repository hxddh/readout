import Foundation

// App shell 3.8: what wakes the app while it watches files, and when the
// spare reader page is made again.

/// Folders a file watcher's FSEvents stream leaves out (FSEventStreamSetExclusionPaths).
///
/// A window watches the folder of the file it shows, recursively: a `PLAN.md`
/// at a repository's root woke the app ~33 times a second per window during a
/// build, for writes into `.git`, `node_modules`, `.build` or `DerivedData`
/// that can never be the file shown. Excluded folders are filtered before
/// the app is woken.
public enum WatchExclusions {
    /// FSEvents takes at most eight exclusion paths per stream.
    public static let limit = 8

    /// Busiest first: what a build, a package install or a commit writes into.
    public static let names = [".git", "node_modules", ".build", "DerivedData", "build", "target", "dist", ".next",
                               "Pods", ".venv", "__pycache__", ".cache", "vendor", ".hg", ".svn", "venv"]

    /// The folders of `names` directly in each watched folder, busiest first
    /// across them, at most `limit`. Never one that is, or holds, a watched
    /// folder or a path in `keep` (the file shown, the link to it), and never
    /// one whose path a kept path merely starts with (`build` beside
    /// `build.md`), whatever way FSEvents compares them.
    public static func paths(for directories: [String], keep: [String] = []) -> [String] {
        let protected = directories + keep
        var out: [String] = []
        for name in names {
            for dir in directories {
                let candidate = (dir as NSString).appendingPathComponent(name)
                guard !protected.contains(where: { $0.hasPrefix(candidate) }), !out.contains(candidate) else { continue }
                out.append(candidate)
                if out.count == limit { return out }
            }
        }
        return out
    }
}

extension AgentFolders {
    /// The Markdown documents a batch of file-system events in the agent
    /// folders wrote, each with whether it is new to `known` (the files
    /// already there), which this keeps up to date. A path's name is checked
    /// before the disk is asked: build output and dependencies written into a
    /// watched folder never cost a stat. A document that is gone is forgotten,
    /// so writing it again later makes it new again.
    public static func writes(_ paths: [String], roots: [String], known: inout Set<String>,
                              exists: (String) -> Bool) -> [(path: String, isNew: Bool)] {
        var out: [(path: String, isNew: Bool)] = []
        for path in paths {
            guard isCandidate(path, roots: roots) else { continue }
            guard exists(path) else {
                known.remove(path)
                continue
            }
            out.append((path, known.insert(path).inserted))
        }
        return out
    }
}

/// When the reader page pool makes its next spare page, after one is taken.
///
/// Made right away, the next spare page competed with the page just taken
/// while that one was still loading its first document (at launch: WebKit's
/// first process start). It is made once a page has painted its first
/// document, or after `fallback` seconds when none does.
public struct SparePagePlan: Equatable, Sendable {
    public static let fallback: TimeInterval = 3

    /// A spare page is owed: one was taken and the next is not made yet.
    public private(set) var waiting = false
    private var generation = 0

    public init() {}

    /// A spare page was taken. Returns the token the fallback timer started
    /// now presents to `fallbackFired`.
    public mutating func taken() -> Int {
        waiting = true
        generation += 1
        return generation
    }

    /// A page painted its first document: true when the next spare page is to be made now.
    public mutating func painted() -> Bool {
        defer { waiting = false }
        return waiting
    }

    /// The fallback timer of `token` fired: true when the spare page is still
    /// owed and no later take started a timer of its own.
    public mutating func fallbackFired(_ token: Int) -> Bool {
        guard waiting, token == generation else { return false }
        waiting = false
        return true
    }
}
