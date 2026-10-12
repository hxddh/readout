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
    /// Writes seen while running (not the initial scan), on the main queue.
    var onWrite: (([URL]) -> Void)?

    func configure(_ paths: [String]) {
        let normalized = paths.map { ($0 as NSString).expandingTildeInPath }.filter { FileManager.default.fileExists(atPath: $0) }
        guard normalized != roots else { return }
        roots = normalized
        stream?.stop()
        stream = nil
        recent = []
        guard !roots.isEmpty else { return }
        stream = FSEventsStream(paths: roots, latency: 0.3, queue: queue) { [weak self] events in
            let hits: [(URL, Date)] = events.compactMap { e in
                guard e.isFile, !e.isRemoved || FileManager.default.fileExists(atPath: e.path) else { return nil }
                let url = URL(fileURLWithPath: e.path)
                guard Self.isCandidate(url) else { return nil }
                return (url, Date())
            }
            guard !hits.isEmpty else { return }
            DispatchQueue.main.async {
                self?.record(hits)
                self?.onWrite?(hits.map(\.0))
            }
        }
        let rootsCopy = roots
        queue.async { [weak self] in
            let found = Self.scan(rootsCopy)
            DispatchQueue.main.async { self?.record(found) }
        }
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

    nonisolated static func isCandidate(_ url: URL) -> Bool { AgentFolders.isCandidate(url.path) }

    /// Bounded initial scan for the newest Markdown files.
    nonisolated static func scan(_ roots: [String]) -> [(URL, Date)] {
        var out: [(URL, Date)] = []
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
                if let d = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    out.append((item, d))
                }
            }
        }
        return out.sorted { $0.1 > $1.1 }.prefix(50).map { $0 }
    }
}
