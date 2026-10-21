import Foundation

// App shell 3.9: one key for Open Latest Agent File, the default app's editor
// at the line, the Edit menu without what macOS adds, the About panel's link.

/// File ▸ Open Latest Agent File's key, stored as `hotKey`: R with the
/// modifiers of the choice. Settings turns it on or off; on, it works from any
/// app. A key chosen before 3.9 (⌥⌘R, ⌃⌥R) is kept, and shown.
public enum OpenLatestKey: String, CaseIterable, Sendable {
    case optCmdR, ctrlOptCmdR, ctrlOptR, none

    /// The stored value; ⌃⌥⌘R when there is none (not ⌥⌘R, which Safari and Xcode use).
    public init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .ctrlOptCmdR }

    /// Works from any app (registered system-wide).
    public var isGlobal: Bool { self != .none }

    /// Settings' toggle: on keeps the stored key (⌃⌥⌘R when it was off), off is `none`.
    public func turned(on: Bool) -> Self { on ? menuKey : .none }

    /// The key the menu shows: the global one, or with that off ⌃⌥⌘R, which
    /// then works inside Readout only.
    public var menuKey: Self { self == .none ? .ctrlOptCmdR : self }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let command = Modifiers(rawValue: 4)
    }

    /// The modifiers of `menuKey`, with R.
    public var modifiers: Modifiers {
        switch menuKey {
        case .optCmdR: return [.option, .command]
        case .ctrlOptR: return [.control, .option]
        case .ctrlOptCmdR, .none: return [.control, .option, .command]
        }
    }

    /// `menuKey` as the menu writes it: "⌃⌥⌘R".
    public var title: String {
        let m = modifiers
        return (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.command) ? "⌘" : "") + "R"
    }
}

/// The editors that open a file at a line, as Settings ▸ Editor stores them
/// (`editor`; "Default app" is `system`, which is none of these).
public enum LineEditor: String, CaseIterable, Sendable {
    case vscode, cursor, zed, xcode, sublime

    /// The editor an app is, by its bundle identifier: with "Default app",
    /// a file whose default app is one of these opens at the line too.
    public init?(bundleIdentifier: String) {
        switch bundleIdentifier.lowercased() {
        case "com.microsoft.vscode": self = .vscode
        case "com.todesktop.230313mzl4w4u92": self = .cursor
        case "dev.zed.zed", "dev.zed.zed-preview": self = .zed
        case "com.apple.dt.xcode": self = .xcode
        case "com.sublimetext.4", "com.sublimetext.3": self = .sublime
        default: return nil
        }
    }

    /// The link that opens `path` at `line` and `column` (0: none). Nil for
    /// Xcode, which `xed -l` opens.
    public func url(path: String, line: Int, column: Int) -> URL? {
        // urlPathAllowed leaves "?" and "#" unescaped: a file literally named
        // "foo#bar.md" would cut the link at the fragment.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        let enc = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let pos = line > 0 ? ":\(line)" + (column > 0 ? ":\(column)" : "") : ""
        switch self {
        case .vscode, .cursor, .zed: return URL(string: "\(rawValue)://file\(enc)\(pos)")
        case .sublime: return EditorURL.sublime(path: path, line: line)
        case .xcode: return nil
        }
    }
}

/// What macOS adds to an Edit menu on its own (AutoFill, Start Dictation,
/// Emoji & Symbols): left out of a read-only reader's menu.
public enum SystemMenuItems {
    public struct Item: Sendable {
        public var action: String?
        public var submenuActions: [String]
        public var isSeparator: Bool
        public init(action: String?, submenuActions: [String] = [], isSeparator: Bool = false) {
            self.action = action
            self.submenuActions = submenuActions
            self.isSeparator = isSeparator
        }
    }

    static func isAddedByMacOS(_ i: Item) -> Bool {
        let insert = { (a: String) in a.hasPrefix("_handleInsertFrom") }
        if let a = i.action, a == "startDictation:" || a == "orderFrontCharacterPalette:" || insert(a) { return true }
        return !i.submenuActions.isEmpty && i.submenuActions.allSatisfy(insert)
    }

    /// The indices to remove, last first: the items macOS added, and the
    /// separators that leaves at the end or doubled.
    public static func removals(_ items: [Item]) -> [Int] {
        var out: [Int] = []
        var lastKeptIsSeparator = true   // nothing before the first item
        for (n, i) in items.enumerated() {
            if isAddedByMacOS(i) || (i.isSeparator && lastKeptIsSeparator) {
                out.append(n)
            } else {
                lastKeptIsSeparator = i.isSeparator
            }
        }
        // A separator left last.
        if let last = items.indices.last(where: { !out.contains($0) }), items[last].isSeparator { out.append(last) }
        return out.sorted(by: >)
    }
}

extension OpenLink {
    /// `readout-open://open?path=…`: opens `path` in Readout (the About
    /// panel's Acknowledgements link). Every character that is not unreserved
    /// is percent-encoded, so "&" or "=" in a path stay in the value.
    public static func url(path: String) -> URL? {
        let value = path.addingPercentEncoding(withAllowedCharacters: EditorURL.queryValueAllowed) ?? path
        return URL(string: "\(scheme)://open?path=\(value)")
    }
}

extension ReaderChrome {
    /// How many rows Settings' agent folder list is tall: its folders, at
    /// least 2 (room to see where the next one goes), at most 6 (then it scrolls).
    public static func folderListRows(_ count: Int) -> Int { min(max(count, 2), 6) }
}

extension ReleaseCheck {
    /// What Download Update hands to the browser: the release's disk image on
    /// GitHub (`assets`: name and `browser_download_url`), else its page
    /// (`html_url`), else `releases`: only https on github.com.
    public static func downloadURL(assets: [(name: String, url: URL)], page: URL?, releases: URL) -> URL {
        let onGitHub = { (u: URL) in u.scheme == "https" && u.host == "github.com" }
        return assets.first { $0.name.lowercased().hasSuffix(".dmg") && onGitHub($0.url) }?.url ?? page.flatMap { onGitHub($0) ? $0 : nil } ?? releases
    }
}
