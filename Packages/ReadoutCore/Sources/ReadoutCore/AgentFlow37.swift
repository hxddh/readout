import Foundation

// Agent workflow 3.7: quoting a passage back to the agent, catching up
// across documents, and the first open of a file in a git repository.

/// Edit ▸ Copy as Quote (⇧⌘C): the Markdown source of the blocks a selection
/// touches, as a Markdown blockquote, and where it is:
///
///     > The source of the blocks,
///     > line by line.
///     — src/plan.md#L12-L14 (§ Risks)
///
/// Whole blocks: a selection inside a list item or a table cell quotes the
/// item or the table. Ready to paste into an agent's prompt.
public enum QuoteFormatter {
    /// The quote of the blocks of `blocks` (in document order) whose slots are
    /// in `slots`, cited as `path`; nil when none of them is there. Each block
    /// is its source as copying has it (`Block.copySource`: hard breaks and
    /// front matter's fences kept), followed by the definitions of `links`
    /// its reference links use.
    public static func quote(blocks: [Block], slots: Set<Int>, path: String, links: [LinkDefinition] = []) -> String? {
        let picked = blocks.filter { slots.contains($0.slot) }
        guard let first = picked.first else { return nil }
        var body = ""
        var previous: Block?
        for b in picked {
            // Blocks on consecutive lines stay together (a tight list stays
            // tight); a gap between them is one blank line.
            if let p = previous { body += b.lines.lowerBound == p.lines.upperBound + 1 ? "\n" : "\n\n" }
            body += b.copySource
            previous = b
        }
        let used = LinkDefinition.used(by: body, in: links)
        if !used.isEmpty { body += "\n\n" + used.map(\.md).joined(separator: "\n") }
        // The footnotes section gathers definitions from anywhere in the file:
        // its lines say nothing about where the rest of the selection is.
        let ranged = picked.filter { $0.kind != .footnotes }
        let lines = (ranged.isEmpty ? picked : ranged).map(\.lines)
        let from = lines.map(\.lowerBound).min() ?? first.lines.lowerBound
        let to = lines.map(\.upperBound).max() ?? first.lines.upperBound
        var cite = "— \(path)#L\(from)" + (to > from ? "-L\(to)" : "")
        if let section = section(of: first) { cite += " (§ \(section))" }
        return blockquote(body) + "\n" + cite
    }

    /// The heading a block is under (a heading: itself); nil before the first heading.
    public static func section(of block: Block) -> String? {
        if block.kind == .heading, let title = block.headingTitle, !title.isEmpty { return title }
        return block.headingPath.last.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `text` as a Markdown blockquote: "> " before every line, ">" alone on a blank one.
    public static func blockquote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }

    /// How the quote names the file: relative to the project an agent named
    /// for it (`readout --hook`) when the file lies inside it, else its path
    /// with the home folder as `~`.
    public static func displayPath(_ path: String, projectRoot: String?, home: String = NSHomeDirectory()) -> String {
        if let projectRoot {
            let root = projectRoot.count > 1 && projectRoot.hasSuffix("/") ? String(projectRoot.dropLast()) : projectRoot
            if root != "/", !root.isEmpty, path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        }
        return ReaderChrome.tabToolTip(path: path, home: home)
    }
}

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

// MARK: - First open marked against the last commit

/// Runs git. Behind a protocol so the logic is tested without git.
public protocol GitRunning: Sendable {
    /// git's standard output for `arguments`, run in `directory`, when it
    /// exits with 0 within the time and size limits; else nil.
    func run(_ arguments: [String], in directory: String) -> Data?
}

/// A file opened for the first time (no reading state saved) that lies in a
/// git repository and differs from its last commit is marked against that
/// commit: what the agent changed since is unread.
public enum GitBaseline {
    /// Larger versions are not compared (nor read past this).
    public static let sizeLimit = 5 * 1024 * 1024
    /// git gets this long; the first open waits for it no longer.
    public static let timeout: TimeInterval = 1.5

    /// The nearest folder at or above the file's folder holding `.git` (a
    /// folder, or the file a worktree or submodule has), else nil. The file
    /// system root is no repository.
    public static func repository(containing path: String, exists: (String) -> Bool) -> String? {
        var dir = (path as NSString).deletingLastPathComponent
        for _ in 0..<64 {
            if dir.isEmpty || dir == "/" { return nil }
            if exists(dir + "/.git") { return dir }
            let up = (dir as NSString).deletingLastPathComponent
            if up == dir { return nil }
            dir = up
        }
        return nil
    }

    /// The text to mark the file's `current` text against, from the bytes of
    /// its committed version: nil when that is the same text, too large, not
    /// text, or a Git LFS pointer (the content is elsewhere). A file committed
    /// empty is a baseline too (all of what it has now is new): a git that
    /// failed or a file not committed gives no bytes at all (nil), not empty ones.
    public static func baselineText(head: Data, current: String) -> String? {
        guard let text = committedText(head: head),
              MarkdownParser.sourceLines(text) != MarkdownParser.sourceLines(current) else { return nil }
        return text
    }

    /// The committed version's text, decoded as the app decodes the file
    /// (FileContent: UTF-8, UTF-16 with or without a byte order mark, …), so
    /// a UTF-16 file's NUL bytes are not taken for a binary's; nil when it is
    /// too large, a Git LFS pointer, or binary (NULs in the decoded text).
    public static func committedText(head: Data) -> String? {
        guard head.count <= sizeLimit else { return nil }
        if head.starts(with: Array("version https://git-lfs.github.com/spec/".utf8)) { return nil }
        let text = FileContent.decode(head).text
        return text.contains("\0") ? nil : text
    }

    /// The committed text to mark the file at `path` (its real path) against,
    /// or nil: outside a repository, not committed (untracked, a new file),
    /// unchanged since, or git missing, failing or too slow.
    public static func headText(for path: String, current: String, git: GitRunning,
                                exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard repository(containing: path, exists: exists) != nil else { return nil }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        // Relative to the folder git runs in: a submodule's or worktree's own HEAD.
        guard let data = git.run(["--no-pager", "show", "HEAD:./" + name], in: dir) else { return nil }
        return baselineText(head: data, current: current)
    }
}

/// git as a subprocess, with a hard time limit and a cap on what it may write.
public struct ProcessGit: GitRunning {
    public let executable: String
    public let timeout: TimeInterval
    public let limit: Int

    public init(executable: String = "/usr/bin/git", timeout: TimeInterval = GitBaseline.timeout, limit: Int = GitBaseline.sizeLimit) {
        self.executable = executable
        self.timeout = timeout
        self.limit = limit
    }

    public func run(_ arguments: [String], in directory: String) -> Data? {
        ProcessRunner.run(executable, arguments, in: directory, timeout: timeout, limit: limit,
                          environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat", "LC_ALL": "C"])
    }
}

/// Runs a program, blocking the calling thread (never the main thread) for
/// at most `timeout`: its standard output when it exits with 0 in time and
/// writes no more than `limit` bytes; else nil (it is terminated).
public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String], in directory: String? = nil,
                           timeout: TimeInterval, limit: Int, environment: [String: String] = [:]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        // Read as it is written (a full pipe would stall it), up to the limit.
        final class Box: @unchecked Sendable { var data = Data(); var over = false }
        let box = Box()
        let read = DispatchSemaphore(value: 0)
        let handle = out.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                box.data.append(chunk)
                if box.data.count > limit { box.over = true; break }
            }
            read.signal()
        }
        let deadline = DispatchTime.now() + timeout
        if read.wait(timeout: deadline) == .timedOut || box.over {
            process.terminate()
            _ = exited.wait(timeout: .now() + 0.5)
            return nil
        }
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            return nil
        }
        return process.terminationStatus == 0 && process.terminationReason == .exit ? box.data : nil
    }
}

/// Whether git can run without macOS offering to install the command line
/// developer tools: `/usr/bin/git` is a shim that asks for them when no
/// developer folder is set. `xcode-select -p` says whether one is (it never asks).
public enum GitTools {
    public static func available(xcodeSelect: String = "/usr/bin/xcode-select", git: String = "/usr/bin/git",
                                 isDirectory: (String) -> Bool = { p in
                                     var dir: ObjCBool = false
                                     return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && dir.boolValue
                                 }) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: git), FileManager.default.isExecutableFile(atPath: xcodeSelect),
              let out = ProcessRunner.run(xcodeSelect, ["-p"], timeout: 1.5, limit: 4096) else { return false }
        let path = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && isDirectory(path)
    }
}

// MARK: - Window restoration

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
