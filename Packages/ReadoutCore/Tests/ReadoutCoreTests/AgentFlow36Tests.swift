import Foundation
import Testing
@testable import ReadoutCore

/// 3.6 agent workflow: the project a plan was written in (U2), where the
/// unread changes are (U6), remote images loaded once per address (U11).
@Suite struct AgentFlow36Tests {
    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: RealPath.of(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("readout-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: U2: the hook's cwd is the plan's project

    @Test func theOpenLinkCarriesTheProjectRoot() {
        let u = URL(string: "readout-open://open?background=1&path=%2Fh%2F.claude%2Fplans%2Fp.md&root=%2Fwork%2Fmy%20app")!
        #expect(OpenLink.parse(u) == .init(path: "/h/.claude/plans/p.md", background: true, root: "/work/my app"))
        // Without one, as before 3.6.
        #expect(OpenLink.parse(URL(string: "readout-open://open?background=1&path=%2Fa.md")!)?.root == nil)
        // A relative or empty root is no root.
        #expect(OpenLink.parse(URL(string: "readout-open://open?path=%2Fa.md&root=work")!)?.root == nil)
        #expect(OpenLink.parse(URL(string: "readout-open://open?path=%2Fa.md&root=")!)?.root == nil)
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

    // MARK: U6: unread changes per outline entry

    @Test func unreadSectionsFollowMarksDeletionsAndReads() {
        let s = DocumentSession()
        let v1 = "Intro.\n\n# Title\n\n## Alpha\n\nAlpha text.\n\n### Deep\n\nDeep text.\n\n## Beta\n\nBeta text.\n\nBeta more.\n\n##### Small\n\nSmall text.\n"
        _ = s.load(MarkdownParser.parse(v1))
        #expect(s.unreadSections.isEmpty)
        let heading = { (title: String) in s.blocks.first { $0.headingTitle == title }!.slot }
        // Edited under Deep (not Alpha above it), removed under Beta, edited
        // under an H5 (not in the outline: its Beta section), edited before any heading.
        let v2 = "Intro, edited.\n\n# Title\n\n## Alpha\n\nAlpha text.\n\n### Deep\n\nDeep text, edited.\n\n## Beta\n\nBeta text.\n\n##### Small\n\nSmall text, edited.\n"
        _ = s.update(MarkdownParser.parse(v2))
        #expect(s.unreadSections == [heading("Deep"), heading("Beta")])
        // Reading the Deep edit leaves Beta.
        let deep = s.blocks.first { $0.text.contains("Deep text") }!.slot
        s.markRead(slots: [deep], deletionIDs: [])
        #expect(s.unreadSections == [heading("Beta")])
        // The deletion alone still marks Beta.
        let small = s.blocks.first { $0.text.contains("Small text") }!.slot
        s.markRead(slots: [small], deletionIDs: [])
        #expect(s.unreadSections == [heading("Beta")])
        s.markRead(slots: [], deletionIDs: s.deletions.map(\.id))
        #expect(s.unreadSections.isEmpty)
        #expect(s.unreadCount >= 1)   // the intro edit: before the outline
        // An inserted heading is its own section.
        _ = s.update(MarkdownParser.parse(v2 + "\n## Gamma\n"))
        #expect(s.unreadSections == [heading("Gamma")])
        s.markAllRead()
        #expect(s.unreadSections.isEmpty)
    }

    // MARK: U11: a remote image loaded once is shown again

    @Test func theCacheRemembersWhichAddressEachImageCameFrom() {
        func image(_ bytes: Int) -> RemoteFetcher.Image { .init(data: Data(count: bytes), contentType: "image/png") }
        var cache = RemoteImageCache(capacity: 100)
        let a = cache.insert(image(40), url: "https://img.example/a.png")!
        #expect(cache.token(forURL: "https://img.example/a.png") == a)
        #expect(cache.token(forURL: "https://img.example/b.png") == nil)
        // Loaded again: the new bytes.
        let a2 = cache.insert(image(40), url: "https://img.example/a.png")!
        #expect(cache.token(forURL: "https://img.example/a.png") == a2)
        #expect(cache.known == ["https://img.example/a.png": a2])
        // Evicted: forgotten, so the reader is asked again.
        _ = cache.insert(image(40), url: "https://img.example/b.png")
        _ = cache.insert(image(40), url: "https://img.example/c.png")
        #expect(cache.token(forURL: "https://img.example/a.png") == nil)
        #expect(Set(cache.known.keys) == ["https://img.example/b.png", "https://img.example/c.png"])
    }
}
