import Foundation
#if canImport(Glibc)
import Glibc
#endif
import Testing
@testable import ReadoutCore

/// The project a plan was written in (`ProjectRoot`): a root given by the hook,
/// searched first, and paths in the plan resolved through it.
@Suite struct ProjectRootTests {
    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: RealPath.of(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("readout-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aProjectRootMustBeAnExistingAbsoluteFolder() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("app/src"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("app/README.md").path, contents: Data())
        #expect(ProjectRoot.validated(dir.path + "/app") == dir.path + "/app")
        #expect(ProjectRoot.validated(dir.path + "/app/src/../") == dir.path + "/app")
        #expect(ProjectRoot.validated(dir.path + "/app/README.md") == nil)   // a file
        #expect(ProjectRoot.validated(dir.path + "/gone") == nil)
        #expect(ProjectRoot.validated("app") == nil)
        #expect(ProjectRoot.validated("/") == nil)
        #expect(ProjectRoot.validated(nil) == nil)
    }

    @Test func theProjectRootComesFirstAndOnce() {
        let roots = ProjectRoot.searchRoots(project: "/work/app", workspaces: ["~/.claude/plans", "/work/app/", "/other"])
        let home = NSString(string: "~").expandingTildeInPath
        #expect(roots.map(\.path) == ["/work/app", home + "/.claude/plans", "/other"])
        #expect(ProjectRoot.searchRoots(project: nil, workspaces: []).isEmpty)
    }

    /// A plan in ~/.claude/plans names `src/app/feature.swift` relative to the
    /// project it was written for: with the project as a root it resolves.
    @Test func aPlanOutsideItsProjectResolvesThroughTheRoot() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let plans = dir.appendingPathComponent("home/.claude/plans"), project = dir.appendingPathComponent("work/app")
        try fm.createDirectory(at: plans, withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent("src/app"), withIntermediateDirectories: true)
        fm.createFile(atPath: project.appendingPathComponent("src/app/feature.swift").path, contents: Data("x".utf8))
        let text = "Change `src/app/feature.swift:12` first."
        let before = MarkdownParser.parse(text, resolver: FileResolver(baseDirectory: plans,
                                                                         searchRoots: ProjectRoot.searchRoots(project: nil, workspaces: [plans.path])))
        #expect(!before.blocks[0].html.contains("path-link"))
        let resolver = FileResolver(baseDirectory: plans,
                                    searchRoots: ProjectRoot.searchRoots(project: ProjectRoot.validated(project.path), workspaces: [plans.path]))
        let after = MarkdownParser.parse(text, resolver: resolver)
        #expect(after.blocks[0].html.contains(#"class="path-link" data-path="\#(project.path)/src/app/feature.swift" data-line="12""#))
    }

    @MainActor @Test func aRootGivenLaterRendersTheSameBytesAgain() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let project = dir.appendingPathComponent("app"), plans = dir.appendingPathComponent("plans")
        try fm.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: plans, withIntermediateDirectories: true)
        fm.createFile(atPath: project.appendingPathComponent("src/x.swift").path, contents: Data())
        let file = plans.appendingPathComponent("plan.md")
        try Data("See `src/x.swift`.\n".utf8).write(to: file)
        final class Box { var root: String? }
        let box = Box()
        let loader = DocumentLoader(url: file) {
            FileResolver(baseDirectory: plans, searchRoots: ProjectRoot.searchRoots(project: box.root, workspaces: []))
        }
        let first = await withCheckedContinuation { c in loader.loadInitial { c.resume(returning: $0) } }
        #expect(first?.doc.blocks.first?.html.contains("path-link") == false)
        box.root = project.path
        loader.forgetContent()
        let change = await withCheckedContinuation { c in loader.readChange { c.resume(returning: $0) } }
        guard case .content(let r) = change else { Issue.record("same bytes were not read again"); return }
        #expect(r.doc.blocks.first?.html.contains("path-link") == true)
    }
}

/// Path resolution (`FileResolver`): the project before the folders above, the walk
/// up to the repository root, candidates, links to source files, image sizes.
@Suite struct ResolverTests {
    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("readout-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

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

    @Test func repositoryRootIsAlwaysACandidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("b4-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let deep = root + "/repo/docs/a/b/c/d/e/f"
        try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/repo/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/repo/src", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/repo/src/app.ts", atomically: true, encoding: .utf8)
        #expect(FileResolver(baseDirectory: URL(fileURLWithPath: root + "/repo/docs/a")).pathReference("src/app.ts") != nil)
        #expect(FileResolver(baseDirectory: URL(fileURLWithPath: deep)).pathReference("src/app.ts") != nil)   // 3.7: nil
        // The five folders above, then the root (each once), and nothing above it.
        let c = FileResolver(baseDirectory: URL(fileURLWithPath: deep)).candidates(for: "x.md").map(\.path)
        #expect(c.count == 7 && c.last == root + "/repo/x.md", "\(c)")
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

    /// The byte checks before the path pattern say no exactly where the
    /// Character checks they replace did, or the pattern cannot match.
    @Test func pathPrecheckMatchesCharacterChecks() {
        let resolver = FileResolver(baseDirectory: URL(fileURLWithPath: "/tmp"))
        let codes = ["a.swift", "src/a.swift:12", "a b.swift", "README", "1.2.3", "x/y", " \u{301}a.md", "a\u{301}.md",
                     String(repeating: "a", count: 299) + ".md", String(repeating: "é", count: 297) + ".md",
                     String(repeating: "e\u{301}", count: 297) + ".md", "~/notes.txt", "全角.md", "a.md "]
        for code in codes {
            let characterChecks = code.count <= 300 && !code.contains(" ") && (code.contains(".") || code.contains("/"))
            if characterChecks != FileResolver.mayBePath(code) {
                // Only where no path can be found anyway.
                #expect(resolver.pathReference(code) == nil, "\(code.debugDescription)")
            }
        }
        #expect(FileResolver.mayBePath("src/a.swift:12"))
        #expect(!FileResolver.mayBePath("a b.swift"))
        #expect(FileResolver.mayBePath(String(repeating: "e\u{301}", count: 297) + ".md"))   // 300 characters, 894 bytes
        #expect(!FileResolver.mayBePath(String(repeating: "e\u{301}", count: 298) + ".md"))
    }

    @Test func linksToSourceFilesResolveInTheProject() {
        let plan = URL(fileURLWithPath: "/Users/me/.claude/plans/p.md")
        let resolver = FileResolver(baseDirectory: plan.deletingLastPathComponent(), searchRoots: [URL(fileURLWithPath: "/w/app")],
                                    projectRoot: URL(fileURLWithPath: "/w/app"))
        let existing: Set<String> = ["/w/app/src/a.ts", "/w/app/docs/design.md"]
        func resolve(_ href: String) -> LinkTarget? {
            LinkTarget.resolve(href, from: plan, markdownExtensions: ["md"], fileExists: { existing.contains($0.path) },
                               candidates: resolver.candidates(for:))
        }
        #expect(resolve("src/a.ts#L42") == .source(URL(fileURLWithPath: "/w/app/src/a.ts"), line: 42, column: 0))
        #expect(resolve("src/a.ts:7") == .source(URL(fileURLWithPath: "/w/app/src/a.ts"), line: 7, column: 0))
        #expect(resolve("a.ts:7") == .external(URL(string: "a.ts:7")!))   // only the file name: not in the project root
        #expect(resolve("src/a.ts") == .file(URL(fileURLWithPath: "/w/app/src/a.ts")))
        #expect(resolve("docs/design.md#goals") == .markdown(URL(fileURLWithPath: "/w/app/docs/design.md"), fragment: "goals"))
        // Nowhere: missing, beside the document as before.
        #expect(resolve("src/gone.ts#L3") == .missing(URL(fileURLWithPath: "/Users/me/.claude/plans/src/gone.ts")))
        // Without candidates, as before.
        #expect(LinkTarget.resolve("src/a.ts#L42", from: plan, markdownExtensions: ["md"], fileExists: { existing.contains($0.path) })
                == .missing(URL(fileURLWithPath: "/Users/me/.claude/plans/src/a.ts")))
    }

    @Test func aFileNameWithALineIsFoundInTheProjectToo() {
        let plan = URL(fileURLWithPath: "/plans/p.md")
        let existing: Set<String> = ["/w/app/main.swift"]
        let target = LinkTarget.resolve("main.swift:42", from: plan, markdownExtensions: ["md"], fileExists: { existing.contains($0.path) },
                                        candidates: { [URL(fileURLWithPath: "/plans/" + $0), URL(fileURLWithPath: "/w/app/" + $0)] })
        #expect(target == .source(URL(fileURLWithPath: "/w/app/main.swift"), line: 42, column: 0))
        // A URL scheme stays a URL.
        #expect(LinkTarget.resolve("tel:5551234", from: plan, markdownExtensions: ["md"], fileExists: { _ in false },
                                   candidates: { _ in [] }) == .external(URL(string: "tel:5551234")!))
    }

    /// A FIFO named as an image: opening it to read its size waited for a
    /// writer, and the parse with it.
    @Test func aFIFONamedAsAnImageDoesNotBlockTheParse() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pipe = dir.appendingPathComponent("pipe.png")
        try #require(mkfifo(pipe.path, 0o600) == 0)
        let resolver = FileResolver(baseDirectory: dir)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = MarkdownParser.parse("![](pipe.png)\n", resolver: resolver)
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 5) == .success
        if !finished {
            // A writer that comes and goes lets the blocked open return, so the test ends.
            let fd = open(pipe.path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
            done.wait()
        }
        #expect(finished)
        #expect(ImageSize.read(dir) == nil)   // a folder is not read either
    }
}
