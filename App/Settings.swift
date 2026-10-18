import AppKit
import Combine
import UniformTypeIdentifiers
import ReadoutCore

/// User preferences, stored in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    enum Editor: String, CaseIterable, Identifiable {
        case system, vscode, cursor, zed, xcode, sublime
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return NSLocalizedString("Default app", comment: "Editor choice")
            case .vscode: return "Visual Studio Code"
            case .cursor: return "Cursor"
            case .zed: return "Zed"
            case .xcode: return "Xcode"
            case .sublime: return "Sublime Text"
            }
        }
    }

    enum HotKeyChoice: String, CaseIterable, Identifiable {
        case optCmdR, ctrlOptCmdR, ctrlOptR, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .optCmdR: return "⌥⌘R"
            case .ctrlOptCmdR: return "⌃⌥⌘R"
            case .ctrlOptR: return "⌃⌥R"
            case .none: return NSLocalizedString("Off", comment: "No global shortcut")
            }
        }
    }

    @Published var workspaces: [String] { didSet { d.set(workspaces, forKey: "workspaces") } }
    @Published var editor: Editor { didSet { d.set(editor.rawValue, forKey: "editor") } }
    @Published var hotKey: HotKeyChoice { didSet { d.set(hotKey.rawValue, forKey: "hotKey") } }
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    @Published var wide: Bool { didSet { d.set(wide, forKey: "wide") } }
    /// Wrap long lines in code blocks (toggled from any code block, remembered).
    @Published var codeWrap: Bool { didSet { d.set(codeWrap, forKey: "codeWrap") } }
    @Published var showSidebar: Bool { didSet { d.set(showSidebar, forKey: "showSidebar") } }
    @Published var checkForUpdatesAutomatically: Bool { didSet { d.set(checkForUpdatesAutomatically, forKey: "checkForUpdatesAutomatically") } }
    @Published var lastUpdateCheck: Date? { didSet { d.set(lastUpdateCheck, forKey: "lastUpdateCheck") } }
    /// The chosen global shortcut could not be registered (another app holds it). Not stored.
    @Published var hotKeyInUse = false

    private init() {
        var ws = d.stringArray(forKey: "workspaces")
        if ws == nil {
            // First launch: Claude Code keeps plans under ~/.claude/plans. Added
            // even before Claude Code made it: it is watched once it exists
            // (the folders are checked again whenever Readout becomes active).
            ws = [(NSHomeDirectory() as NSString).appendingPathComponent(".claude/plans")]
        }
        workspaces = ws ?? []
        editor = Editor(rawValue: d.string(forKey: "editor") ?? "") ?? .system
        // Not ⌥⌘R, which Safari and Xcode use. A stored choice is the user's own and is kept.
        hotKey = HotKeyChoice(rawValue: d.string(forKey: "hotKey") ?? "") ?? .ctrlOptCmdR
        let fs = d.double(forKey: "fontSize")
        fontSize = fs == 0 ? 16 : fs
        wide = d.bool(forKey: "wide")
        codeWrap = d.bool(forKey: "codeWrap")
        showSidebar = d.object(forKey: "showSidebar") as? Bool ?? true
        checkForUpdatesAutomatically = d.object(forKey: "checkForUpdatesAutomatically") as? Bool ?? true
        lastUpdateCheck = d.object(forKey: "lastUpdateCheck") as? Date
    }
}

/// Persists, per file, the version the reader last caught up with and the reading position.
///
/// Two files per document: the record with the baseline (which holds whole
/// block texts, so it can be large) is written only when the baseline
/// changes; the reading position, which changes on every settled scroll, is
/// written to a small file of its own. Writes run in order on one queue.
enum BaselineStore {
    struct Record: Codable {
        var baseline: [BlockKey]
        var topBlockIndex: Int?
        var topOffset: Double?
        /// First 120 characters of the top block's normalized text. Block
        /// indices shift as agents edit; the excerpt survives that.
        var topExcerpt: String?
        var savedAt: Date
    }

    /// The reading position alone.
    private struct Position: Codable {
        var topBlockIndex: Int?
        var topOffset: Double?
        var topExcerpt: String?
        var savedAt: Date
    }

    fileprivate static let queue = DispatchQueue(label: "Readout.BaselineStore", qos: .utility)

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Readout/Baselines", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Keyed by the real path, as windows are: the same file reached through a
    /// symlink or under /private/tmp shares one history.
    private static func key(for url: URL) -> String { BaselineKey.key(forPath: url.path) }

    private static func file(forKey key: String) -> URL { dir.appendingPathComponent("\(key).json") }
    private static func positionFile(forKey key: String) -> URL { dir.appendingPathComponent("\(key).pos.json") }
    private static func file(for url: URL) -> URL { file(forKey: key(for: url)) }
    private static func positionFile(for url: URL) -> URL { positionFile(forKey: key(for: url)) }

    /// `realPath`: the file the caller's content was read from, when known —
    /// a link may already point elsewhere. The spelling in `url` serves only
    /// the pre-3.3 fallback.
    static func load(_ url: URL, realPath: String? = nil) -> Record? {
        let primary = realPath.map { BaselineKey.key(forPath: $0) } ?? key(for: url)
        if let record = load(key: primary) { return record }
        // Before 3.3 the key was the path as spelled. Read that record once:
        // move it under the real-path key, which is the one used from now on,
        // so a symlink retargeted later does not fall back to it again.
        let legacy = BaselineKey.legacyKey(forPath: url.path)
        guard legacy != primary, let record = load(key: legacy) else { return nil }
        // One unit: the record already merged with its position goes to the
        // new key, and the old files go only once that write succeeded.
        let old = [file(forKey: legacy), positionFile(forKey: legacy)], target = file(forKey: primary)
        queue.async {
            guard let data = try? JSONEncoder().encode(record), (try? data.write(to: target, options: .atomic)) != nil else { return }
            for f in old { try? FileManager.default.removeItem(at: f) }
        }
        return record
    }

    /// The record of `url`, read and decoded off the main thread (behind any
    /// save still queued for it) while the caller does other work.
    @MainActor static func prefetch(_ url: URL) -> Prefetch {
        let prefetch = Prefetch(key: key(for: url), url: url)
        queue.async(qos: .userInitiated) {
            let record = load(url)
            DispatchQueue.main.async { MainActor.assumeIsolated { prefetch.finish(record) } }
        }
        return prefetch
    }

    @MainActor
    final class Prefetch {
        fileprivate let key: String
        fileprivate let url: URL
        private var result: Record??
        private var waiting: [(Record?) -> Void] = []

        fileprivate init(key: String, url: URL) {
            self.key = key
            self.url = url
        }

        fileprivate func finish(_ record: Record?) {
            result = .some(record)
            let w = waiting
            waiting = []
            w.forEach { $0(record) }
        }

        /// The record for the file the content was read from, on the main
        /// thread: the prefetched one, or, when a symlink pointed elsewhere by
        /// the time it was read, that file's, also read off the main thread.
        func record(forSourcePath source: String, _ completion: @escaping (Record?) -> Void) {
            guard BaselineKey.key(forPath: source) == key else {
                let url = self.url
                BaselineStore.queue.async(qos: .userInitiated) {
                    let record = BaselineStore.load(url, realPath: source)
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion(record) } }
                }
                return
            }
            if let result { completion(result) } else { waiting.append(completion) }
        }
    }

    /// Waits for every queued save: called when the app quits, which would
    /// otherwise exit before the last reading position is written.
    static func flush() { queue.sync {} }

    private static func load(key: String) -> Record? {
        guard let data = try? Data(contentsOf: file(forKey: key)),
              var record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        if let data = try? Data(contentsOf: positionFile(forKey: key)),
           let position = try? JSONDecoder().decode(Position.self, from: data), position.savedAt >= record.savedAt {
            record.topBlockIndex = position.topBlockIndex
            record.topOffset = position.topOffset
            record.topExcerpt = position.topExcerpt
            record.savedAt = position.savedAt
        }
        return record
    }

    /// The project folder an agent named for the file (`readout --hook`
    /// passes its working folder), beside the file's record, while it exists.
    private static func rootFile(for url: URL) -> URL { dir.appendingPathComponent("\(key(for: url)).root") }

    static func projectRoot(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: rootFile(for: url)) else { return nil }
        return ProjectRoot.validated(String(decoding: data, as: UTF8.self))
    }

    static func saveProjectRoot(_ root: String, for url: URL) {
        let target = rootFile(for: url)
        queue.async { try? Data(root.utf8).write(to: target, options: .atomic) }
    }

    /// Where the records for `url` live under the current and the pre-3.3 key (smoke test).
    static func recordFiles(for url: URL) -> (current: URL, legacy: URL, legacyPosition: URL) {
        let legacy = BaselineKey.legacyKey(forPath: url.path)
        return (file(for: url), file(forKey: legacy), positionFile(forKey: legacy))
    }

    /// Saves the reading position, and the whole record when `baselineChanged`
    /// or when there is none under the key yet (a symlink now pointing to
    /// another file): `load` needs the record, not just the position.
    static func save(_ record: Record, for url: URL, baselineChanged: Bool) {
        let target = file(for: url), positionTarget = positionFile(for: url)
        let position = Position(topBlockIndex: record.topBlockIndex, topOffset: record.topOffset,
                                topExcerpt: record.topExcerpt, savedAt: record.savedAt)
        queue.async {
            if baselineChanged || !FileManager.default.fileExists(atPath: target.path), let data = try? JSONEncoder().encode(record) {
                try? data.write(to: target, options: .atomic)
            }
            if let data = try? JSONEncoder().encode(position) { try? data.write(to: positionTarget, options: .atomic) }
        }
    }

    /// Drops records not opened for 90 days (a record whose position was saved
    /// recently is kept, even when its baseline has not changed since).
    static func prune() {
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let cutoff = Date().addingTimeInterval(-90 * 86400)
            func stem(_ u: URL) -> Substring { u.lastPathComponent.split(separator: ".").first ?? "" }
            func modified(_ u: URL) -> Date? { try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            let fresh = Set(items.filter { (modified($0) ?? .distantPast) >= cutoff }.map(stem))
            for i in items where !fresh.contains(stem(i)) {
                if let m = modified(i), m < cutoff { try? fm.removeItem(at: i) }
            }
        }
    }
}

/// Opens `path:line:column` references in the user's editor.
@MainActor
enum EditorOpener {
    static func open(path: String, line: Int, column: Int) {
        let editor = AppSettings.shared.editor
        // urlPathAllowed leaves "?" and "#" unescaped: a file literally named
        // "foo#bar.md" would truncate the editor URL at the fragment.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        let enc = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let pos = line > 0 ? ":\(line)" + (column > 0 ? ":\(column)" : "") : ""
        var url: URL?
        switch editor {
        case .vscode: url = URL(string: "vscode://file\(enc)\(pos)")
        case .cursor: url = URL(string: "cursor://file\(enc)\(pos)")
        case .zed: url = URL(string: "zed://file\(enc)\(pos)")
        case .sublime: url = EditorURL.sublime(path: path, line: line)
        case .xcode:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
            p.arguments = line > 0 ? ["-l", String(line), path] : [path]
            if (try? p.run()) != nil { return }
        case .system: break
        }
        if let url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            openInDefaultEditor(URL(fileURLWithPath: path))
        }
    }

    /// Opens the file in the app the system picks for it, unless that is
    /// Readout itself (the default app for Markdown): then in the default
    /// plain-text editor, or TextEdit.
    private static func openInDefaultEditor(_ file: URL) {
        let ws = NSWorkspace.shared
        let isReadout = { (app: URL?) -> Bool in
            guard let app else { return false }
            return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
                || app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
        }
        let app = ws.urlForApplication(toOpen: file)
        guard isReadout(app) else {
            ws.open(file)
            return
        }
        var editor = ws.urlForApplication(toOpen: .plainText)
        if editor == nil || isReadout(editor) {
            editor = ws.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        }
        guard let editor else { return NSSound.beep() }
        ws.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}
