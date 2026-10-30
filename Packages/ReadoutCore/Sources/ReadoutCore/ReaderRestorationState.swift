import Foundation

/// What a reader window keeps for the next launch (System Settings ▸ Desktop
/// & Dock ▸ "Close windows when quitting an application" off): the file, the
/// project an agent named for it, and its place among its window's tabs.
public struct ReaderRestorationState: Equatable, Sendable {
    public var path: String
    public var projectRoot: String?
    /// Windows with the same group were tabs of one window.
    public var group: String?
    public var tabIndex: Int
    public var selected: Bool
    /// The document was looked at (its window was in front) before the quit:
    /// it comes back without the tab's dot of a document opened behind and
    /// not looked at yet. A state kept before 3.8 has no such flag: seen.
    public var seen: Bool

    public init(path: String, projectRoot: String? = nil, group: String? = nil, tabIndex: Int = 0, selected: Bool = true, seen: Bool = true) {
        self.path = path
        self.projectRoot = projectRoot
        self.group = group
        self.tabIndex = tabIndex
        self.selected = selected
        self.seen = seen
    }

    public static let pathKey = "readout.path", rootKey = "readout.projectRoot", groupKey = "readout.tabGroup",
                      indexKey = "readout.tabIndex", selectedKey = "readout.tabSelected", seenKey = "readout.seen"

    /// As kept in the window's restorable state.
    public var dictionary: [String: Any] {
        var d: [String: Any] = [Self.pathKey: path, Self.indexKey: tabIndex, Self.selectedKey: selected, Self.seenKey: seen]
        if let projectRoot { d[Self.rootKey] = projectRoot }
        if let group { d[Self.groupKey] = group }
        return d
    }

    /// The state kept, when the window is to come back: its file is still
    /// there (`exists`). A project folder that is gone is left out.
    public static func restorable(_ d: [String: Any], exists: (String) -> Bool, isDirectory: (String) -> Bool) -> ReaderRestorationState? {
        guard let path = d[pathKey] as? String, path.hasPrefix("/"), exists(path) else { return nil }
        let root = (d[rootKey] as? String).flatMap { isDirectory($0) ? $0 : nil }
        return ReaderRestorationState(path: path, projectRoot: root, group: d[groupKey] as? String,
                                      tabIndex: (d[indexKey] as? NSNumber)?.intValue ?? (d[indexKey] as? Int) ?? 0,
                                      selected: (d[selectedKey] as? NSNumber)?.boolValue ?? (d[selectedKey] as? Bool) ?? true,
                                      seen: (d[seenKey] as? NSNumber)?.boolValue ?? (d[seenKey] as? Bool) ?? true)
    }

    /// Restored windows that were tabs of one window, in tab order (windows
    /// without a group are left alone): indices into `states`.
    public static func tabGroups(_ states: [ReaderRestorationState]) -> [[Int]] {
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for (i, s) in states.enumerated() {
            guard let g = s.group else { continue }
            if groups[g] == nil { order.append(g) }
            groups[g, default: []].append(i)
        }
        return order.compactMap { g in
            let members = groups[g]!.sorted { states[$0].tabIndex < states[$1].tabIndex }
            return members.count > 1 ? members : nil
        }
    }
}
