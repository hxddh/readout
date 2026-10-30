import Foundation

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
    /// `build.md`), whatever way FSEvents compares them. Compared ignoring
    /// case, as most Mac volumes do: `build` is `Build`, the folder of
    /// `/repo/Build/plan.md`. (On a case-sensitive volume that only leaves out less.)
    public static func paths(for directories: [String], keep: [String] = []) -> [String] {
        let protected = (directories + keep).map { ($0 as NSString).standardizingPath.lowercased() }
        var out: [String] = []
        for name in names {
            for dir in directories {
                let candidate = (dir as NSString).appendingPathComponent(name)
                let folded = (candidate as NSString).standardizingPath.lowercased()
                guard !protected.contains(where: { $0.hasPrefix(folded) }),
                      !out.contains(where: { $0.lowercased() == candidate.lowercased() }) else { continue }
                out.append(candidate)
                if out.count == limit { return out }
            }
        }
        return out
    }
}
