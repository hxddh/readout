import Foundation
import ReadoutCore

/// Tracks the most recently written Markdown files under the user's workspace folders,
/// so the global shortcut can open "whatever the agent just wrote", and reports
/// each write while the app runs (`onWrite`) so new documents open on their own.
@MainActor
final class WorkspaceIndex {
    static let shared = WorkspaceIndex()

    private(set) var recent: [(url: URL, date: Date)] = []
    private var stream: FSEventsStream?
    private let queue = DispatchQueue(label: "readout.workspaces", qos: .utility)
    private var roots: [String] = []

    nonisolated static let markdownExtensions = AgentFolders.markdownExtensions
    nonisolated static let skippedDirectories = AgentFolders.skippedDirectories
    /// Writes seen while running (not the initial scan), on the main queue,
    /// with whether the file is a new document (not there before).
    var onWrite: (([(url: URL, isNew: Bool)]) -> Void)?

    /// Markdown files known to exist under the roots: the initial scan's, then
    /// every one seen written. Touched only on `queue`.
    private final class Known: @unchecked Sendable { var paths: Set<String> = [] }

    /// The folders last asked for, as given (some may not exist yet).
    private var requested: [String] = []
    /// Bumped on every reconfiguration: results of an earlier one (a scan, a
    /// stream event delivered before its stream stopped) are dropped.
    private var generation = 0

    /// Folders asked for that do not exist yet, with when that was first seen.
    private var missingSince: [String: Date] = [:]
    /// Checks every few seconds, only while a folder is missing, whether it exists now.
    private var missingTimer: Timer?

    func configure(_ paths: [String]) {
        requested = paths
        let expanded = paths.map { ($0 as NSString).expandingTildeInPath }
        let normalized = expanded.filter { FileManager.default.fileExists(atPath: $0) }
        // A folder that appeared since it was found missing: what an agent
        // wrote into it since then is new, not something that was already there.
        let now = Date()
        var appeared: [(root: String, since: Date)] = []
        for root in normalized { if let since = missingSince.removeValue(forKey: root) { appeared.append((root, since)) } }
        for root in expanded where !normalized.contains(root) && missingSince[root] == nil { missingSince[root] = now }
        missingSince = missingSince.filter { expanded.contains($0.key) }
        watchForMissingFolders()
        guard normalized != roots else { return }
        roots = normalized
        generation += 1
        let gen = generation
        // Not stop(): it waits for the queue, which a scan of large folders
        // can hold for seconds. The old stream's late events are dropped by generation.
        stream?.stopAsync()
        stream = nil
        recent = []
        guard !roots.isEmpty else { return }
        let rootsCopy = roots
        let known = Known()
        // FSEvents reports real paths (/private/var/..., a symlinked folder's
        // target); map them back to the folder as the user added it.
        let realRoots = rootsCopy.map { (given: $0, real: Self.realPath($0)) }
        // The scan is queued before the stream starts, so on this serial queue
        // every event is judged against the files that were already there.
        queue.async { [weak self] in
            let (newest, all) = Self.scan(rootsCopy)
            known.paths = Set(all.map { Self.givenPath($0, roots: realRoots) })
            // Written into a folder that did not exist a moment ago: new documents.
            var fresh: [(url: URL, isNew: Bool)] = []
            for a in appeared {
                for (url, date) in Self.scan([a.root]).newest where date >= a.since.addingTimeInterval(-2) {
                    fresh.append((url: url, isNew: true))
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.record(newest)
                if !fresh.isEmpty { self.onWrite?(fresh) }
            }
        }
        stream = FSEventsStream(paths: roots, latency: 0.3, queue: queue) { [weak self] events in
            var hits: [(URL, Date, Bool)] = []
            for e in events where e.isFile {
                let path = Self.givenPath(e.path, roots: realRoots)
                guard FileManager.default.fileExists(atPath: path) else {
                    known.paths.remove(path)   // removed or renamed away: a later write is new again
                    continue
                }
                let url = URL(fileURLWithPath: path)
                guard Self.isCandidate(url, roots: rootsCopy) else { continue }
                let isNew = known.paths.insert(path).inserted
                hits.append((url, Date(), isNew))
            }
            guard !hits.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.record(hits.map { ($0.0, $0.1) })
                self.onWrite?(hits.map { (url: $0.0, isNew: $0.2) })
            }
        }
    }

    /// Watches the folders asked for again: one that did not exist when they
    /// were set (`~/.claude/plans` before the first plan) is picked up once it does.
    func refresh() { configure(requested) }

    /// Polls (a stat per missing folder every 2 s) only while a folder asked
    /// for does not exist, so one created later is watched without waiting
    /// for Readout to become active.
    private func watchForMissingFolders() {
        if missingSince.isEmpty {
            missingTimer?.invalidate()
            missingTimer = nil
        } else if missingTimer == nil {
            missingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let index = WorkspaceIndex.shared
                    if index.missingSince.keys.contains(where: { FileManager.default.fileExists(atPath: $0) }) { index.refresh() }
                }
            }
        }
    }

    /// The path with symlinks and /private resolved, as FSEvents reports it
    /// (a symlink to a file not written yet: where that file will be).
    nonisolated static func realPath(_ path: String) -> String { RealPath.of(path) }

    /// An FSEvents path rewritten under the root as the user added it.
    nonisolated static func givenPath(_ path: String, roots: [(given: String, real: String)]) -> String {
        for r in roots where r.real != r.given {
            if path == r.real { return r.given }
            if path.hasPrefix(r.real + "/") { return r.given + path.dropFirst(r.real.count) }
        }
        return path
    }

    private func record(_ hits: [(URL, Date)]) {
        var map: [String: (URL, Date)] = [:]
        for r in recent { map[r.url.path] = (r.url, r.date) }
        for (u, d) in hits {
            if let existing = map[u.path], existing.1 >= d { continue }
            map[u.path] = (u, d)
        }
        recent = map.values.sorted { $0.1 > $1.1 }.prefix(50).map { (url: $0.0, date: $0.1) }
        recent.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
    }

    var latest: URL? {
        recent.first(where: { FileManager.default.fileExists(atPath: $0.url.path) })?.url
    }

    nonisolated static func isCandidate(_ url: URL, roots: [String]) -> Bool { AgentFolders.isCandidate(url.path, roots: roots) }

    /// Bounded initial scan: the newest Markdown files, and every one found.
    nonisolated static func scan(_ roots: [String]) -> (newest: [(URL, Date)], all: Set<String>) {
        var out: [(URL, Date)] = []
        var all: Set<String> = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .nameKey]
        for root in roots {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                        options: [.skipsPackageDescendants]) else { continue }
            var visited = 0
            while let item = e.nextObject() as? URL {
                visited += 1
                if visited > 50_000 { break }
                let name = item.lastPathComponent
                if let v = try? item.resourceValues(forKeys: [.isDirectoryKey]), v.isDirectory == true {
                    if skippedDirectories.contains(name) || (name.hasPrefix(".") && name != ".claude") || e.level > 8 {
                        e.skipDescendants()
                    }
                    continue
                }
                guard markdownExtensions.contains(item.pathExtension.lowercased()) else { continue }
                all.insert(item.path)
                if let d = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    out.append((item, d))
                }
            }
        }
        return (out.sorted { $0.1 > $1.1 }.prefix(50).map { $0 }, all)
    }
}
