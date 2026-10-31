import Foundation
import ReadoutCore

/// The first open of a file in a git repository: the committed version, as a
/// reading baseline, so what changed since the last commit is marked.
/// git runs off the main thread, at most `GitBaseline.timeout`, and only when
/// the developer tools are installed (`/usr/bin/git` would otherwise ask to
/// install them); files outside a repository never run it.
@MainActor
enum CommitBaseline {
    /// Concurrent: one window's slow git does not hold up another's.
    private static let queue = DispatchQueue(label: "Readout.CommitBaseline", qos: .userInitiated, attributes: .concurrent)
    /// Found once per launch (under `toolsLock`). Not found is asked again next
    /// time: a first `xcode-select` or git after boot can outlast the limit.
    nonisolated(unsafe) private static var toolsAvailable = false
    nonisolated private static let toolsLock = NSLock()

    static func find(path: String, current: String, completion: @escaping @MainActor @Sendable ([BlockKey]?) -> Void) {
        withGit(path: path, otherwise: nil, {
            GitBaseline.headText(for: path, current: current, git: ProcessGit()).map { MarkdownParser.parse($0).blocks.map(BlockKey.init) }
        }, completion: completion)
    }

    /// View ▸ Compare with Last Commit: the version the window `displayed`
    /// against the committed version of the file at `path` (its real path),
    /// with the guards of `find`. Only git's HEAD blob is read.
    static func compare(path: String, displayed: [BlockKey], completion: @escaping @MainActor @Sendable (CommitComparison) -> Void) {
        withGit(path: path, otherwise: .unavailable, {
            GitBaseline.compare(path: path, displayed: displayed, git: ProcessGit())
        }, completion: completion)
    }

    /// `work`'s result on `queue` for a file in a git repository with git
    /// there to ask, else `otherwise`; `completion` gets it on the main actor.
    private static func withGit<T: Sendable>(path: String, otherwise: T, _ work: @escaping @Sendable () -> T,
                                             completion: @escaping @MainActor @Sendable (T) -> Void) {
        // The app's own files (help) are no one's commit.
        guard !path.hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/") else { return completion(otherwise) }
        queue.async {
            var result = otherwise
            if GitBaseline.repository(containing: path, exists: { FileManager.default.fileExists(atPath: $0) }) != nil {
                // Held while asking: windows opening together ask once.
                let available = toolsLock.withLock { () -> Bool in
                    if !toolsAvailable { toolsAvailable = GitTools.available() }
                    return toolsAvailable
                }
                if available { result = work() }
            }
            let found = result
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(found) } }
        }
    }
}
