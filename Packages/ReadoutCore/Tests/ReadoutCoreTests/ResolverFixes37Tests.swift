import Foundation
import Testing
@testable import ReadoutCore

/// 3.7 fixes to path resolution. Each test failed on 3.6.0.
@Suite struct ResolverFixes37Tests {
    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("readout-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    // MARK: U3: the project before the folders above, which stop at the repository

    /// A plan in ~/.claude/plans names `CLAUDE.md` and `src/app.ts:42` of its
    /// project: the walk up from the plan's folder found ~/.claude/CLAUDE.md
    /// and ~/src/app.ts first.
    @Test func aPlanResolvesInItsProjectBeforeTheFoldersAboveIt() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home"), plans = home.appendingPathComponent(".claude/plans")
        let project = dir.appendingPathComponent("work/app")
        try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
        try touch(home.appendingPathComponent(".claude/CLAUDE.md"))
        try touch(home.appendingPathComponent("src/app.ts"))
        try touch(project.appendingPathComponent("CLAUDE.md"))
        try touch(project.appendingPathComponent("src/app.ts"))
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let roots = ProjectRoot.searchRoots(project: project.path, workspaces: [plans.path])
        let html = MarkdownParser.parse("Read `CLAUDE.md`, then `src/app.ts:42`.",
                                        resolver: FileResolver(baseDirectory: plans, searchRoots: roots)).blocks[0].html
        #expect(html.contains("data-path=\"\(project.path)/CLAUDE.md\""), "\(html)")
        #expect(html.contains("data-path=\"\(project.path)/src/app.ts\" data-line=\"42\""), "\(html)")
        // Also when the plans folder is in a repository (dotfiles): the project comes first.
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let r = FileResolver(baseDirectory: plans, project: project.path, workspaces: [plans.path])
        #expect(r.pathReference("CLAUDE.md")?.path == project.appendingPathComponent("CLAUDE.md").path)
        #expect(r.pathReference("src/app.ts:42") == PathReference(path: project.appendingPathComponent("src/app.ts").path, line: 42, column: nil))
        // Without a project the repository's folders are looked at.
        #expect(FileResolver(baseDirectory: plans).pathReference("CLAUDE.md")?.path == home.appendingPathComponent(".claude/CLAUDE.md").path)
    }

    /// Outside a repository nothing above the document's folder is looked at.
    @Test func noWalkUpOutsideARepository() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plans = dir.appendingPathComponent("home/.claude/plans")
        try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
        try touch(dir.appendingPathComponent("home/.claude/CLAUDE.md"))
        try touch(plans.appendingPathComponent("notes.md"))
        let r = FileResolver(baseDirectory: plans)
        #expect(r.pathReference("CLAUDE.md") == nil)
        #expect(r.pathReference("notes.md")?.path == plans.appendingPathComponent("notes.md").path)
        #expect(r.candidates(for: "CLAUDE.md").map(\.path) == [plans.appendingPathComponent("CLAUDE.md").path])
    }

    /// Inside a repository the walk up reaches its root (a worktree's `.git`
    /// is a file) and stops there.
    @Test func walkUpStopsAtTheRepositoryRoot() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outer = dir.appendingPathComponent("outer"), repo = outer.appendingPathComponent("repo")
        let docs = repo.appendingPathComponent("docs/design")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try touch(repo.appendingPathComponent(".git"))   // a worktree
        try touch(repo.appendingPathComponent("src/a.swift"))
        try touch(outer.appendingPathComponent("README.md"))
        let r = FileResolver(baseDirectory: docs)
        #expect(r.pathReference("src/a.swift:7")?.path == repo.appendingPathComponent("src/a.swift").path)
        #expect(r.pathReference("README.md") == nil)
        #expect(r.candidates(for: "README.md").map(\.path) == [
            docs.appendingPathComponent("README.md").path,
            repo.appendingPathComponent("docs/README.md").path,
            repo.appendingPathComponent("README.md").path,
        ])
    }

    /// The order every caller shares: the document's folder, the project,
    /// the folders above in the repository, the other roots; each once.
    @Test func candidatesOrder() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = dir.appendingPathComponent("repo"), docs = repo.appendingPathComponent("docs")
        let project = dir.appendingPathComponent("project"), plans = dir.appendingPathComponent("plans")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let r = FileResolver(baseDirectory: docs, project: project.path, workspaces: [plans.path, project.path])
        #expect(r.candidates(for: "src/a.ts").map(\.path) == [
            docs.path + "/src/a.ts", project.path + "/src/a.ts", repo.path + "/src/a.ts", plans.path + "/src/a.ts",
        ])
        #expect(r.candidates(for: "../x.md").map(\.path) == [repo.path + "/x.md", dir.path + "/x.md"])
        #expect(r.candidates(for: "/etc/hosts").map(\.path) == ["/etc/hosts"])
        let home = NSString(string: "~").expandingTildeInPath
        #expect(r.candidates(for: "~/notes.md").map(\.path) == [home + "/notes.md"])
        #expect(FileResolver(baseDirectory: nil).candidates(for: "a.md").isEmpty)
    }

    /// `existingFile` skips folders and missing files.
    @Test func existingFileIsAFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let docs = dir.appendingPathComponent("docs"), project = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("src"), withIntermediateDirectories: true)
        try touch(project.appendingPathComponent("src"))   // a file named src in the project
        let r = FileResolver(baseDirectory: docs, project: project.path, workspaces: [])
        #expect(r.existingFile("src") == project.appendingPathComponent("src").standardizedFileURL)
        #expect(r.existingFile("missing.md") == nil)
    }
}
