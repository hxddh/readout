import Foundation

/// N with nothing unread left in the document: on to the next document with
/// unread changes.
public enum CrossDocument {
    /// The documents to look in after `current`, in order: the other tabs of
    /// its window after it (then those before it), then the tabs of the other
    /// windows. `groups`: each window's tabs in tab order, windows front to back.
    public static func order<ID: Equatable>(after current: ID, groups: [[ID]]) -> [ID] {
        var out: [ID] = []
        if let group = groups.first(where: { $0.contains(current) }), let i = group.firstIndex(of: current) {
            out += group[(i + 1)...]
            out += group[..<i]
        }
        for group in groups where !group.contains(current) {
            for id in group where !out.contains(id) && id != current { out.append(id) }
        }
        return out
    }

    /// A document waiting for the reader, the rule of its tab's dot: it has
    /// unread changes, or was opened behind and has not been looked at yet
    /// (a file opened for the first time has no baseline, so nothing unread).
    public static func needsAttention(unread: Int, lookedAt: Bool) -> Bool { unread > 0 || !lookedAt }

    /// Open Latest Agent File (⌃⌥⌘R): the newest of the open agent
    /// documents waiting for the reader (`needsAttention`), nil when none is.
    /// So a plan an agent just wrote, opened behind, beats an older one with
    /// unread edits; one looked at with nothing unread is not considered.
    public static func newestNeedingAttention(_ documents: [(path: String, modified: Date, unread: Int, lookedAt: Bool)]) -> String? {
        documents.filter { needsAttention(unread: $0.unread, lookedAt: $0.lookedAt) }.max { $0.modified < $1.modified }?.path
    }
}

/// What the window shows of a document's unread state: the toolbar badge's
/// count, the outline's dots, the tab's dot (and so the Dock badge). While an
/// agent writes where the reader reads, each paragraph arrives unread and is
/// read within its dwell: shown at once, the badge and dots would blink with
/// every one. So more unread waits until the page says what it added is to be
/// shown (`PageMessage.showUnread`, or a fallback); less shows at once.
public struct UnreadDisplay: Equatable, Sendable {
    public var count: Int
    public var sections: Set<Int>
    public var dot: Bool

    public init(count: Int = 0, sections: Set<Int> = [], dot: Bool = false) {
        self.count = count
        self.sections = sections
        self.dot = dot
    }

    /// What to show now, going from `shown` to `actual` with increases held
    /// back: every decrease, none of the increases. `held`: something waits.
    public static func next(shown: UnreadDisplay, actual: UnreadDisplay) -> (show: UnreadDisplay, held: Bool) {
        let show = UnreadDisplay(count: min(shown.count, actual.count),
                                 sections: shown.sections.intersection(actual.sections),
                                 dot: shown.dot && actual.dot)
        return (show, show != actual)
    }
}

extension CrossDocument {
    /// N with nothing unread left in `current`: the first document after it
    /// (`order(after:groups:)`) that waits for the reader (`waiting`: the tab
    /// dot's rule, `needsAttention`), nil when none does.
    public static func next<ID: Equatable>(after current: ID, groups: [[ID]], waiting: (ID) -> Bool) -> ID? {
        order(after: current, groups: groups).first(where: waiting)
    }

    /// Where N lands in the document it went on to.
    public enum Arrival: Equatable, Sendable {
        /// At its first unread change.
        case firstChange
        /// Opened behind and not looked at yet: nothing is marked (a first
        /// open has no baseline), it is read from where it shows.
        case whereItShows
    }

    public static func arrival(unread: Int) -> Arrival { unread > 0 ? .firstChange : .whereItShows }

    /// The Dock badge for `waiting` open documents (unread changes, or opened
    /// behind and not looked at yet, as their tabs' dots say); nil for none.
    public static func badgeLabel(waiting: Int) -> String? { waiting > 0 ? String(waiting) : nil }
}
