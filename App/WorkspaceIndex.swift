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
    /// While a folder is missing: the nearest folder above it that exists,
    /// watched for entries added or removed (no timer, no wakeups otherwise).
    private var missingWatches: [String: DirectoryWatch] = [:]
    /// The initial scan of the current folders has not landed yet.
    private var scanning = false
    private var afterScan: [() -> Void] = []

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
        // What is known stays until the new scan lands (the global shortcut
        // must not find nothing in between), except files no longer watched.
        recent.removeAll { !Self.isCandidate($0.url, roots: roots) }
        guard !roots.isEmpty else {
            recent = []
            finishScan()
            return
        }
        scanning = true
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
                // The scan replaces what was kept meanwhile (on this queue no
                // stream event of this generation came before it).
                self.recent = []
                self.record(newest)
                self.finishScan()
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
        // A folder that just appeared: a file renamed into it after the scan
        // above but before the stream started reaches neither. Look again now
        // that the stream runs, on its queue: what this finds is known to the
        // events after it, and what they found first is not reported twice.
        guard !appeared.isEmpty else { return }
        queue.async { [weak self] in
            var late: [(url: URL, isNew: Bool)] = []
            for a in appeared {
                for (url, date) in Self.scan([a.root]).newest where date >= a.since.addingTimeInterval(-2) {
                    if known.paths.insert(Self.givenPath(url.path, roots: realRoots)).inserted { late.append((url: url, isNew: true)) }
                }
            }
            guard !late.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.record(late.map { ($0.url, Date()) })
                self.onWrite?(late)
            }
        }
    }

    /// Watches the folders asked for again: one that did not exist when they
    /// were set (`~/.claude/plans` before the first plan) is picked up once it does.
    func refresh() { configure(requested) }

    /// Runs `block` once the scan of the folders asked for has landed (at
    /// once when none is running): the global shortcut pressed right after a
    /// folder appeared opens what is in it instead of finding nothing.
    func whenScanned(_ block: @escaping () -> Void) {
        if scanning { afterScan.append(block) } else { block() }
    }

    private func finishScan() {
        scanning = false
        let blocks = afterScan
        afterScan = []
        blocks.forEach { $0() }
    }

    /// While a folder asked for does not exist, watches the nearest folder
    /// above it that does (`~/.claude` or `~` for `~/.claude/plans` before
    /// the first plan) for entries added, removed or renamed: one created
    /// later is watched without waiting for Readout to become active, and
    /// nothing wakes the app while nothing changes there.
    private func watchForMissingFolders() {
        var wanted: [String: Set<String>] = [:]   // folder watched -> missing folders below it
        for missing in missingSince.keys {
            guard let above = AgentFolders.nearestExistingAncestor(of: missing, exists: { FileManager.default.fileExists(atPath: $0) }) else { continue }
            wanted[above, default: []].insert(missing)
        }
        // A watched folder that was deleted or moved away: watch again by path.
        for (path, watch) in missingWatches where wanted[path] == nil || watch.isGone {
            watch.cancel()
            missingWatches[path] = nil
        }
        for path in wanted.keys where missingWatches[path] == nil {
            missingWatches[path] = DirectoryWatch(path: path) {
                // Something was added (or the watched folder itself moved):
                // watch again from there, or start watching what appeared.
                MainActor.assumeIsolated { WorkspaceIndex.shared.refresh() }
            }
        }
        // Created between finding it missing and the watch starting: no event comes for it.
        if missingSince.keys.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            DispatchQueue.main.async { WorkspaceIndex.shared.refresh() }
        }
    }

    /// What watches for missing folders, for the smoke test.
    var missingFolderWatch: [String: Any] {
        ["watched": missingWatches.keys.sorted(), "missing": missingSince.keys.sorted(),
         "polling": missingWatches.values.contains { $0.isPolling }]
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

/// Reports entries added, removed or renamed in one folder, and the folder
/// itself deleted or moved (kqueue, on the main queue). Where the folder cannot
/// be opened for events, it checks every 30 s instead, with a wide leeway.
@MainActor
final class DirectoryWatch {
    /// Cancelling a dispatch source is safe from any thread (deinit).
    nonisolated(unsafe) private var source: DispatchSourceProtocol?
    private(set) var isPolling = false
    /// The folder was deleted or moved: the watch no longer follows its path.
    private(set) var isGone = false

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        let fd = open(path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: .main)
            s.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    if let self, let fs = self.source as? DispatchSourceFileSystemObject,
                       !fs.data.isDisjoint(with: [.delete, .rename, .revoke]) { self.isGone = true }
                }
                onChange()
            }
            s.setCancelHandler { close(fd) }
            s.resume()
            source = s
        } else {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
            t.setEventHandler(handler: onChange)
            t.resume()
            source = t
            isPolling = true
        }
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }
}
