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

    /// Open Latest Agent File's key (`hotKey`; Settings turns it on or off).
    typealias HotKeyChoice = OpenLatestKey

    @Published var workspaces: [String] { didSet { d.set(workspaces, forKey: "workspaces") } }
    @Published var editor: Editor { didSet { d.set(editor.rawValue, forKey: "editor") } }
    @Published var hotKey: HotKeyChoice { didSet { d.set(hotKey.rawValue, forKey: "hotKey") } }
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    /// View ▸ Text Width: "standard" or "wide", the column the page lays the text in.
    @Published var textWidth: String { didSet { d.set(textWidth, forKey: "textWidth") } }
    /// Wrap long lines in code blocks (toggled from any code block, remembered).
    @Published var codeWrap: Bool { didSet { d.set(codeWrap, forKey: "codeWrap") } }
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
        // A stored on or off is kept; any other stored key (3.8's ⌥⌘R or
        // ⌃⌥R) reads as on, ⌃⌥⌘R (HotKeyChoice).
        hotKey = HotKeyChoice(stored: d.string(forKey: "hotKey"))
        let fs = d.double(forKey: "fontSize")
        fontSize = fs == 0 ? 16 : fs
        textWidth = d.string(forKey: "textWidth") == "wide" ? "wide" : "standard"
        codeWrap = d.bool(forKey: "codeWrap")
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
    typealias Record = ReadingRecord

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
    /// a link may already point elsewhere.
    static func load(_ url: URL, realPath: String? = nil) -> Record? {
        let stem = realPath.map { BaselineKey.key(forPath: $0) } ?? key(for: url)
        return Record.decode(record: try? Data(contentsOf: file(forKey: stem)),
                             position: try? Data(contentsOf: positionFile(forKey: stem)))
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

    /// The versions of `url` seen so far, beside its record (`DocumentHistory`).
    private static func historyFile(for url: URL) -> URL { dir.appendingPathComponent("\(key(for: url)).history.json") }

    static func history(for url: URL) -> DocumentHistory {
        queue.sync { DocumentHistory.decode(try? Data(contentsOf: historyFile(for: url))) }
    }

    /// Adds the file's blocks as they are now to its history, behind any
    /// save still queued for it.
    static func recordVersion(_ keys: [BlockKey], at date: Date, for url: URL) {
        let target = historyFile(for: url)
        queue.async {
            var history = DocumentHistory.decode(try? Data(contentsOf: target))
            guard history.record(keys, at: date), let data = try? JSONEncoder().encode(history) else { return }
            try? data.write(to: target, options: .atomic)
        }
    }

    /// When `url` was last read (its reading position or record last
    /// saved), nil when never: the changes inbox's test for a file not open.
    static func lastRead(_ url: URL) -> Date? {
        [positionFile(for: url), file(for: url)]
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    /// Where the record and the position for `url` live (smoke test).
    static func recordFiles(for url: URL) -> (record: URL, position: URL) { (file(for: url), positionFile(for: url)) }

    /// Saves the reading position, and the whole record when `baselineChanged`
    /// or when there is none under the key yet (a symlink now pointing to
    /// another file): `load` needs the record, not just the position.
    static func save(_ record: Record, for url: URL, baselineChanged: Bool) {
        let target = file(for: url), positionTarget = positionFile(for: url)
        let position = Record.Position(record)
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
        let file = URL(fileURLWithPath: path)
        // "Default app": the app the file opens in, at the line when it is an
        // editor that can (LineEditor). A choice in Settings overrides it.
        let app = AppSettings.shared.editor == .system ? defaultEditor(for: file) : nil
        let editor = LineEditor(rawValue: AppSettings.shared.editor.rawValue)
            ?? app.flatMap { Bundle(url: $0)?.bundleIdentifier }.flatMap(LineEditor.init(bundleIdentifier:))
        if editor == .xcode {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
            p.arguments = line > 0 ? ["-l", String(line), path] : [path]
            if (try? p.run()) != nil { return }
        }
        if let url = editor?.url(path: path, line: line, column: column), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let app = app ?? defaultEditor(for: file) {
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSSound.beep()
        }
    }

    /// The app the system picks for the file, unless that is Readout itself
    /// (the default app for Markdown): then the default plain-text editor, or TextEdit.
    private static func defaultEditor(for file: URL) -> URL? {
        let ws = NSWorkspace.shared
        let isReadout = { (app: URL?) -> Bool in
            guard let app else { return false }
            return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
                || app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
        }
        if let app = ws.urlForApplication(toOpen: file), !isReadout(app) { return app }
        if let editor = ws.urlForApplication(toOpen: .plainText), !isReadout(editor) { return editor }
        return ws.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
    }
}
