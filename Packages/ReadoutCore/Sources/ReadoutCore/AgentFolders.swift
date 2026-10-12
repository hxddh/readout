import Foundation

/// The folders agents write to: which files in them count as Markdown an agent
/// wrote, and which of those open on their own.
public enum AgentFolders {
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext"]
    /// Dependencies, build output and version control: never an agent's document.
    public static let skippedDirectories: Set<String> = ["node_modules", ".git", ".hg", ".svn", "build", ".build", "DerivedData",
                                                         "Pods", "vendor", "target", "dist", ".next", ".venv", "venv", "__pycache__", ".cache"]

    /// The one hidden folder agents write documents to (Claude Code's plans).
    public static let agentHiddenDirectory = ".claude"

    /// A Markdown file in one of `roots`, outside skipped and hidden folders
    /// below the root (`.claude` aside), and not hidden itself: the same files
    /// the initial scan finds. The root itself may be hidden (`~/.claude/plans`).
    public static func isCandidate(_ path: String, roots: [String]) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard markdownExtensions.contains(url.pathExtension.lowercased()) else { return false }
        let all = url.standardizedFileURL.pathComponents
        let root = roots.map { URL(fileURLWithPath: $0).standardizedFileURL.pathComponents }
            .filter { $0.count < all.count && Array(all.prefix($0.count)) == $0 }
            .max { $0.count < $1.count }
        guard let root else { return false }
        let below = all.dropFirst(root.count)
        for (i, c) in below.enumerated() {
            if skippedDirectories.contains(c) { return false }
            if c.hasPrefix("."), c != agentHiddenDirectory || i == below.count - 1 { return false }
        }
        return true
    }
}

/// Decides which Markdown files written in the agent folders open on their own,
/// in the background.
///
/// Writes are collected until they settle (`quiet` seconds without a new one,
/// so an agent writing a file in several steps opens it once, finished). Then:
/// - more than `burst` different files at once is a bulk change (a branch switch,
///   a generator, an unpacked archive): nothing opens; the global shortcut
///   still reaches the newest;
/// - a file that is already open is left to its window, which updates itself;
/// - a file opens on its own at most once per launch, so a window the reader
///   closed does not come back with the agent's next edit.
public struct AutoOpen: Sendable {
    public static let quiet: TimeInterval = 0.8
    public static let burst = 3

    private var pending: [String: Date] = [:]
    private var opened: Set<String> = []

    public init() {}

    /// A write the folder watcher saw while the app was running, already
    /// filtered with `AgentFolders.isCandidate`. Non-Markdown paths are ignored.
    public mutating func noteWrite(_ path: String, at date: Date) {
        guard AgentFolders.markdownExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { return }
        pending[path] = max(pending[path] ?? date, date)
    }

    public var hasPending: Bool { !pending.isEmpty }

    /// The files to open now that writes have settled, oldest write first.
    /// `isOpen` tells whether a window already shows the path; `exists` whether
    /// it is still there (an agent's temp file is renamed away).
    public mutating func settle(isOpen: (String) -> Bool, exists: (String) -> Bool) -> [String] {
        let written = pending.sorted { $0.value < $1.value }.map(\.key).filter(exists)
        pending = [:]
        guard written.count <= Self.burst else { return [] }
        // A file already shown counts as opened too: closing its window means
        // the reader is done with it.
        let shown = written.filter(isOpen)
        let toOpen = written.filter { !opened.contains($0) && !shown.contains($0) }
        opened.formUnion(shown)
        opened.formUnion(toOpen)
        return toOpen
    }
}
