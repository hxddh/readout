import Foundation

/// What the reader window shows around the page (title bar, tabs, menus,
/// sidebar), decided without AppKit so it can be tested.
public enum ReaderChrome {
    /// What the window subtitle shows, most important first: the file's
    /// status (deleted, could not be read, decoded as…), then task progress,
    /// then, only for a window without a tab bar, the folder the file is in.
    /// With a tab bar the folder is not repeated there: the tab's tooltip
    /// shows the path (`tabToolTip`). Without one (System Settings' "Prefer
    /// tabs: In Full Screen") the tooltip never shows, and two plan.md
    /// windows would look the same in the title bar and the Window menu.
    public enum Subtitle: Equatable, Sendable {
        case status(String)
        case tasks(done: Int, total: Int)
        case folder(String)
    }

    public static func subtitle(status: String?, tasks: TaskStats, path: String, showsTabBar: Bool) -> Subtitle? {
        if let status, !status.isEmpty { return .status(status) }
        if tasks.total > 0 { return .tasks(done: tasks.done, total: tasks.total) }
        guard !showsTabBar else { return nil }
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return folder.isEmpty || folder == "/" ? nil : .folder(folder)
    }

    /// The tab's tooltip: the file's path, with the home folder as `~`, so
    /// tabs of same-named files in different folders can be told apart.
    public static func tabToolTip(path: String, home: String = NSHomeDirectory()) -> String {
        let home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Titles for File ▸ Open Recent: the file name, with " — <folder>" only
    /// for names that appear more than once (case-insensitively, as the
    /// default volumes compare them). When the folders have the same name
    /// too, more of the path is shown ("a/runs", "b/runs") until the titles differ.
    public static func recentTitles(_ paths: [String]) -> [String] {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        var titles = names
        var counts: [String: Int] = [:]
        for n in names { counts[n.lowercased(), default: 0] += 1 }
        // The folders above each file, nearest first.
        let folders = paths.map { path -> [String] in
            Array((path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init).reversed())
        }
        func title(_ i: Int, depth: Int) -> String {
            let shown = folders[i].prefix(depth).reversed().joined(separator: "/")
            return shown.isEmpty ? names[i] : "\(names[i]) — \(shown)"
        }
        // Each group of same-named files: one folder more for those still alike.
        var open = Set(names.indices.filter { counts[names[$0].lowercased(), default: 0] > 1 })
        var depth = 1
        while !open.isEmpty {
            var seen: [String: Int] = [:]
            for i in open { seen[title(i, depth: depth).lowercased(), default: 0] += 1 }
            for i in open {
                titles[i] = title(i, depth: depth)
                // Told apart, or nothing more to show (the same path twice).
                if seen[titles[i].lowercased()] == 1 || depth >= folders[i].count { open.remove(i) }
            }
            depth += 1
        }
        return titles
    }

    /// Context-menu items (WebKit identifiers) the reader removes. Always the
    /// ones that would navigate away from the rendered document or open a
    /// link inside the web view. Copy Link, Download Linked File and Copy
    /// Image URL only for links into the page's own readout: URLs (a relative
    /// link resolved against the page, a local or proxied image; the page's
    /// policy allows no http(s) images, so an image URL is always one): a
    /// link to the web (`linkURL` https, mailto, …) can still be copied.
    /// `linkURL` nil: the link under the pointer is not known, treat it as internal.
    public static func blockedContextMenuItems(linkURL: String?) -> Set<String> {
        var blocked: Set<String> = [
            "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
            "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow",
            "WKMenuItemIdentifierOpenFrameInNewWindow", "WKMenuItemIdentifierOpenImageInNewWindow",
            "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierCopyImageURL",
            "WKMenuItemIdentifierInspectElement",
        ]
        let scheme = linkURL.flatMap { URL(string: $0)?.scheme?.lowercased() }
        if scheme == nil || scheme == ReadoutURL.scheme || scheme == "file" {
            blocked.formUnion(["WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierDownloadLinkedFile"])
        }
        return blocked
    }

    /// The heading level the outline indents from. A document whose only
    /// top-level heading is its first entry (the H1 title) indents its
    /// sections from their own level, so they do not all sit one step in.
    public static func outlineBaseLevel(_ levels: [Int]) -> Int {
        guard let top = levels.min() else { return 1 }
        guard levels.count > 1, levels.first == top, levels.dropFirst().allSatisfy({ $0 > top }) else { return top }
        return levels.dropFirst().min() ?? top
    }

    /// Where Help ▸ Readout Help goes: the keyboard shortcuts bundled with
    /// the app (Help/Keyboard*.md), opened in Readout itself, offline, in
    /// the reader's language.
    public static func helpFileName(preferredLanguages: [String]) -> String {
        preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "Keyboard.zh-Hans.md" : "Keyboard.md"
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
