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

    /// Claude Code's plans folder, `~/.claude/plans`.
    public static func claudePlans(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".claude/plans")
    }

    /// Whether `~/.claude/plans` is among the folders in Settings (spelled
    /// with `~`, a trailing slash or `.` segments): the welcome window says
    /// new plans open on their own only then.
    public static func includesClaudePlans(_ folders: [String], home: String = NSHomeDirectory()) -> Bool {
        let plans = (claudePlans(home: home) as NSString).standardizingPath
        return folders.contains { folder in
            let expanded = folder.hasPrefix("~") ? home + folder.dropFirst() : folder
            return (expanded as NSString).standardizingPath == plans
        }
    }

    /// The deepest folder above `path` that exists (`~/.claude` or `~` for a
    /// missing `~/.claude/plans`): watched until the missing folder appears,
    /// instead of polling for it. Nil when `path` exists or nothing above it does.
    public static func nearestExistingAncestor(of path: String, exists: (String) -> Bool) -> String? {
        guard !exists(path) else { return nil }
        var current = (path as NSString).standardizingPath
        while current != "/" && !current.isEmpty {
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { return nil }
            if exists(current) { return current }
        }
        return nil
    }
}

/// Decides which Markdown documents agents create in the agent folders open on
/// their own, in the background.
///
/// Only new documents count: a file that already existed when Readout started
/// watching, or that it has seen before, is an edit (an agent touching a README,
/// CHANGELOG or AGENTS.md), and an edit never opens a window. New documents are
/// collected until writes settle (`quiet` seconds without a new one, at most
/// `maxWait` after the first, so a file rewritten continuously cannot hold the
/// others back). Then:
/// - more than `burst` new documents at once is a bulk change (a branch switch,
///   a generator, an unpacked archive): only the newest opens, and the others
///   count as seen, so a later write of one of them does not open it either;
///   the global shortcut still reaches the newest;
/// - a document already open is left to its window, which updates itself;
/// - a document opens on its own at most once per launch.
public struct AutoOpen: Sendable {
    public static let quiet: TimeInterval = 0.8
    public static let maxWait: TimeInterval = 3
    public static let burst = 3

    private var pending: [String: Date] = [:]
    private var firstPending: Date?
    private var opened: Set<String> = []

    public init() {}

    /// A write the folder watcher saw while the app was running, already
    /// filtered with `AgentFolders.isCandidate`. `isNew`: the file was not
    /// there before (an edit of an existing document is ignored).
    public mutating func noteWrite(_ path: String, at date: Date, isNew: Bool) {
        guard isNew, AgentFolders.markdownExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { return }
        pending[path] = max(pending[path] ?? date, date)
        if firstPending == nil { firstPending = date }
    }

    public var hasPending: Bool { !pending.isEmpty }

    /// When to settle, given a write just now: `quiet` after it, but no later
    /// than `maxWait` after the first pending write.
    public func settleDate(now: Date) -> Date {
        let quietEnd = now.addingTimeInterval(Self.quiet)
        guard let first = firstPending else { return quietEnd }
        return min(quietEnd, first.addingTimeInterval(Self.maxWait))
    }

    /// The documents to open now, oldest write first. `isOpen` tells whether a
    /// window already shows the path; `exists` whether it is still there.
    public mutating func settle(isOpen: (String) -> Bool, exists: (String) -> Bool) -> [String] {
        // Oldest write first; same-instant writes in path order, so "newest" is well defined.
        let written = pending.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
            .map(\.key).filter(exists)
        pending = [:]
        firstPending = nil
        // A document already shown counts as opened: closing it means the reader is done with it.
        let shown = written.filter(isOpen)
        opened.formUnion(shown)
        let toOpen = written.filter { !opened.contains($0) }
        opened.formUnion(toOpen)
        // A bulk change: the newest alone, the rest are seen and stay closed.
        guard toOpen.count <= Self.burst else { return toOpen.last.map { [$0] } ?? [] }
        return toOpen
    }
}

extension AgentFolders {
    /// The Markdown documents a batch of file-system events in the agent
    /// folders wrote, each with whether it is new to `known` (the files
    /// already there), which this keeps up to date. A path's name is checked
    /// before the disk is asked: build output and dependencies written into a
    /// watched folder never cost a stat. A document that is gone is forgotten,
    /// so writing it again later makes it new again.
    ///
    /// The initial scan is bounded (depth, entries, no package contents), so
    /// a document not in `known` may have been there all along: it is new
    /// only when it was created (`createdAt`, its birth time; nil: unknown)
    /// no earlier than 2 s before `watchingSince`, when watching started.
    /// The defaults count every document not in `known` as new.
    public static func writes(_ paths: [String], roots: [String], known: inout Set<String>,
                              exists: (String) -> Bool, createdAt: (String) -> Date? = { _ in nil },
                              watchingSince: Date = .distantPast) -> [(path: String, isNew: Bool)] {
        var out: [(path: String, isNew: Bool)] = []
        for path in paths {
            guard isCandidate(path, roots: roots) else { continue }
            guard exists(path) else {
                known.remove(path)
                continue
            }
            guard known.insert(path).inserted else {
                out.append((path, false))
                continue
            }
            let created = createdAt(path)
            out.append((path, created.map { $0 >= watchingSince.addingTimeInterval(-2) } ?? true))
        }
        return out
    }
}
