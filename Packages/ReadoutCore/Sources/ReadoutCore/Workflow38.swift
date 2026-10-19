import Foundation

// Agent workflow 3.8: a new document counts as waiting, View ▸ Compare with
// Last Commit, and a quiet launch at login.

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

/// The notice above a document marked against its last commit (the first
/// open of a file in a repository, View ▸ Compare with Last Commit).
public enum CommitNotice: Equatable, Sendable {
    /// What changed since the commit is marked.
    case marked
    /// Most of it changed since: nothing is marked (a rewrite), and the
    /// notice says against what, not only "This file was rewritten".
    case rewritten

    /// The notice for a document just marked against its committed version.
    /// nil: nothing to say (nothing marked, and no rewrite).
    public static func after(rewrite: Bool, unread: Int) -> CommitNotice? {
        if rewrite { return .rewritten }
        return unread > 0 ? .marked : nil
    }
}

/// View ▸ Compare with Last Commit: the open document against `git show HEAD:`.
public enum CommitComparison: Equatable, Sendable {
    /// The committed text, to mark the document against.
    case baseline(String)
    /// The document is as it was committed.
    case unchanged
    /// Outside a repository, not committed (untracked, new), not text, too
    /// large, a Git LFS pointer, or git missing, failing or too slow.
    case unavailable
}

extension GitBaseline {
    /// The committed version of the file at `path` (its real path) compared
    /// with its `current` text.
    public static func compare(path: String, current: String, git: GitRunning,
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> CommitComparison {
        guard repository(containing: path, exists: exists) != nil else { return .unavailable }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        // As headText: relative to the folder git runs in (a submodule's or worktree's own HEAD).
        guard let data = git.run(["--no-pager", "show", "HEAD:./" + name], in: dir) else { return .unavailable }
        if let text = baselineText(head: data, current: current) { return .baseline(text) }
        // baselineText says nil for the same text and for what is not compared: tell them apart.
        let comparable = !data.isEmpty && data.count <= sizeLimit && !data.contains(0)
            && !data.starts(with: Array("version https://git-lfs.github.com/spec/".utf8))
        return comparable ? .unchanged : .unavailable
    }
}

/// The welcome window at launch.
public enum LaunchWelcome {
    /// `keyAELaunchedAsLogInItem` ('lgit'): the Open Application event's
    /// `keyAEPropData` ('prdt') when Readout was opened as a login item
    /// (System Settings ▸ General ▸ Login Items).
    public static let launchedAsLogInItem: UInt32 = fourCC("lgit")
    public static let openApplication: UInt32 = fourCC("oapp")

    /// Whether the launch event (`eventID`, its `keyAEPropData` value) says
    /// Readout was opened as a login item.
    public static func isLoginItemLaunch(eventID: UInt32?, propData: UInt32?) -> Bool {
        eventID == openApplication && propData == launchedAsLogInItem
    }

    /// The welcome window shows at launch when nothing else did (no file
    /// opened, no window restored), unless Readout was opened as a login
    /// item: then it waits quietly for what agents write.
    public static func shows(openedAtLaunch: Bool, windowsOpen: Bool, loginItem: Bool) -> Bool {
        !openedAtLaunch && !windowsOpen && !loginItem
    }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}
