import Foundation

/// What the reader window shows around the page (title bar, tabs, menus,
/// sidebar), decided without AppKit so it can be tested.
public enum ReaderChrome {
    /// What the window subtitle shows, most important first: the file's
    /// status (deleted, could not be read, decoded as…), then task progress,
    /// then the folder the file is in (tabs of same-named files differ).
    public enum Subtitle: Equatable, Sendable {
        case status(String)
        case tasks(done: Int, total: Int)
        case folder(String)
    }

    public static func subtitle(status: String?, tasks: TaskStats, path: String) -> Subtitle {
        if let status, !status.isEmpty { return .status(status) }
        if tasks.total > 0 { return .tasks(done: tasks.done, total: tasks.total) }
        return .folder(((path as NSString).deletingLastPathComponent as NSString).lastPathComponent)
    }

    /// Titles for File ▸ Open Recent: the file name, with " — <folder>" only
    /// for names that appear more than once (case-insensitively, as the
    /// default volumes compare them).
    public static func recentTitles(_ paths: [String]) -> [String] {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        var counts: [String: Int] = [:]
        for n in names { counts[n.lowercased(), default: 0] += 1 }
        return zip(paths, names).map { path, name in
            guard counts[name.lowercased(), default: 0] > 1 else { return name }
            let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return folder.isEmpty ? name : "\(name) — \(folder)"
        }
    }

    /// The heading level the outline indents from. A document whose only
    /// top-level heading is its first entry (the H1 title) indents its
    /// sections from their own level, so they do not all sit one step in.
    public static func outlineBaseLevel(_ levels: [Int]) -> Int {
        guard let top = levels.min() else { return 1 }
        guard levels.count > 1, levels.first == top, levels.dropFirst().allSatisfy({ $0 > top }) else { return top }
        return levels.dropFirst().min() ?? top
    }

    /// Where Help ▸ Readout Help goes: the keyboard section of the README in
    /// the reader's language.
    public static func helpURL(preferredLanguages: [String]) -> URL {
        if preferredLanguages.first?.lowercased().hasPrefix("zh") == true {
            // "## 快捷键", percent-encoded.
            return URL(string: "https://github.com/hxddh/readout/blob/main/README.zh-CN.md#%E5%BF%AB%E6%8D%B7%E9%94%AE")!
        }
        return URL(string: "https://github.com/hxddh/readout#keyboard")!
    }
}

/// When a file watcher reports a change: at once when the file has been quiet
/// (the first event of a write), otherwise after `trailing` seconds without a
/// further event, but never later than `maxWait` after the first held one, so
/// a file written continuously still updates. Times are seconds on any clock.
public struct WriteDebounce: Sendable, Equatable {
    public enum Action: Equatable, Sendable {
        /// Report the change now.
        case fire
        /// Report it after this delay (cancelling any earlier scheduled report).
        case schedule(after: Double)
    }

    public let trailing: Double
    public let maxWait: Double
    private var lastFire: Double?
    private var firstHeld: Double?

    public init(trailing: Double = 0.08, maxWait: Double = 0.4) {
        self.trailing = trailing
        self.maxWait = maxWait
    }

    /// Whether a scheduled report is outstanding.
    public var isHolding: Bool { firstHeld != nil }

    /// An event arrived at `now`.
    public mutating func event(at now: Double) -> Action {
        if firstHeld == nil, lastFire.map({ now - $0 >= trailing }) ?? true {
            lastFire = now
            return .fire
        }
        if firstHeld == nil { firstHeld = now }
        let waited = now - firstHeld!
        return .schedule(after: max(0, min(trailing, maxWait - waited)))
    }

    /// The scheduled report ran at `now`.
    public mutating func fired(at now: Double) {
        firstHeld = nil
        lastFire = now
    }
}
