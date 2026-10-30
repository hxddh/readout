import Foundation

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
        head(of: path, git: git, exists: exists).flatMap { baselineText(head: $0, current: current) }
    }

    /// The bytes of the committed version of the file at `path`, or nil:
    /// outside a repository, not committed, or git failing or too slow.
    static func head(of path: String, git: GitRunning, exists: (String) -> Bool) -> Data? {
        guard repository(containing: path, exists: exists) != nil else { return nil }
        // Relative to the folder git runs in: a submodule's or worktree's own HEAD.
        return git.run(["--no-pager", "show", "HEAD:./" + (path as NSString).lastPathComponent], in: (path as NSString).deletingLastPathComponent)
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
    /// The committed version's blocks, to mark the document against.
    case baseline([BlockKey])
    /// The document is as it was committed.
    case unchanged
    /// Outside a repository, not committed (untracked, new), not text, too
    /// large, a Git LFS pointer, or git missing, failing or too slow.
    case unavailable

    /// What to do with a comparison that comes back from git (it runs off
    /// the main thread, reading the file and its commit).
    public enum Arrival: Equatable, Sendable {
        /// The window still shows the version it was asked for.
        case apply
        /// A read landed meanwhile (an agent's write, a retargeted symlink's
        /// file): compare again with the version shown now, once.
        case rerun
        /// Changed again during the rerun, or a retarget's read is pending: dropped.
        case drop
    }

    /// `askedAt` and `current`: the window's content generation (it goes up
    /// with every read that lands) when the comparison was asked for, and now.
    public static func applies(askedAt: Int, current: Int, retargeting: Bool, rerun: Bool) -> Arrival {
        if retargeting { return .drop }
        if askedAt == current { return .apply }
        return rerun ? .drop : .rerun
    }
}

extension GitBaseline {
    /// The committed version of the file at `path` (its real path) compared
    /// with the version the window `displayed` (its blocks' keys, as the
    /// session holds them), never with the file on disk: a write that reached
    /// the disk but not the window yet would be compared instead. Only git's
    /// HEAD blob is read.
    public static func compare(path: String, displayed: [BlockKey], git: GitRunning,
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> CommitComparison {
        guard let text = head(of: path, git: git, exists: exists).flatMap(committedText(head:)) else { return .unavailable }
        let committed = MarkdownParser.parse(text).blocks.map(BlockKey.init)
        return committed == displayed ? .unchanged : .baseline(committed)
    }
}
