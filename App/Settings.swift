import AppKit
import Combine
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
    @Published var showSidebar: Bool { didSet { d.set(showSidebar, forKey: "showSidebar") } }
    @Published var checkForUpdatesAutomatically: Bool { didSet { d.set(checkForUpdatesAutomatically, forKey: "checkForUpdatesAutomatically") } }
    @Published var lastUpdateCheck: Date? { didSet { d.set(lastUpdateCheck, forKey: "lastUpdateCheck") } }

    private init() {
        var ws = d.stringArray(forKey: "workspaces")
        if ws == nil {
            // First launch: Claude Code keeps plans under ~/.claude/plans.
            let plans = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/plans")
            ws = FileManager.default.fileExists(atPath: plans) ? [plans] : []
        }
        workspaces = ws ?? []
        editor = Editor(rawValue: d.string(forKey: "editor") ?? "") ?? .system
        hotKey = HotKeyChoice(rawValue: d.string(forKey: "hotKey") ?? "") ?? .optCmdR
        let fs = d.double(forKey: "fontSize")
        fontSize = fs == 0 ? 16 : fs
        wide = d.bool(forKey: "wide")
        showSidebar = d.object(forKey: "showSidebar") as? Bool ?? true
        checkForUpdatesAutomatically = d.object(forKey: "checkForUpdatesAutomatically") as? Bool ?? true
        lastUpdateCheck = d.object(forKey: "lastUpdateCheck") as? Date
    }
}

/// Persists, per file, the version the reader last caught up with and the reading position.
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

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Readout/Baselines", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func file(for url: URL) -> URL {
        let key = String(XXHash64.hash(url.standardizedFileURL.path), radix: 16)
        return dir.appendingPathComponent("\(key).json")
    }

    static func load(_ url: URL) -> Record? {
        guard let data = try? Data(contentsOf: file(for: url)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func save(_ record: Record, for url: URL) {
        let target = file(for: url)
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(record) { try? data.write(to: target, options: .atomic) }
        }
    }

    /// Drops records older than 90 days.
    static func prune() {
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let cutoff = Date().addingTimeInterval(-90 * 86400)
            for i in items {
                if let m = try? i.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < cutoff {
                    try? fm.removeItem(at: i)
                }
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
        case .sublime:
            let fileURL = URL(fileURLWithPath: path).absoluteString
            url = URL(string: "subl://open?url=\(fileURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileURL)" + (line > 0 ? "&line=\(line)" : ""))
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
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}
