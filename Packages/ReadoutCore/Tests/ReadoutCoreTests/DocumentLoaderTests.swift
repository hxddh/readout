import Foundation
import Testing
@testable import ReadoutCore

@MainActor
@Suite(.serialized) struct DocumentLoaderTests {
    let dir: URL
    let file: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("readout-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("plan.md")
    }

    func write(_ text: String) throws { try Data(text.utf8).write(to: file, options: .atomic) }
    func write(bytes: [UInt8]) throws { try Data(bytes).write(to: file, options: .atomic) }

    func loader(retryDelay: TimeInterval = 0.05) -> DocumentLoader {
        DocumentLoader(url: file, retryDelay: retryDelay) { [dir] in FileResolver(baseDirectory: dir) }
    }

    func initial(_ l: DocumentLoader) async -> DocumentLoader.ReadResult? {
        await withCheckedContinuation { cont in l.loadInitial { cont.resume(returning: $0) } }
    }

    func change(_ l: DocumentLoader) async -> DocumentLoader.Change {
        await withCheckedContinuation { cont in l.readChange { cont.resume(returning: $0) } }
    }

    func texts(_ r: DocumentLoader.ReadResult?) -> [String] { r?.doc.blocks.map(\.text) ?? [] }

    @Test func loadsAndParses() async throws {
        try write("# Plan\n\nFirst step.\n")
        let r = await initial(loader())
        #expect(texts(r) == ["# Plan", "First step."])
    }

    /// 3.9.1: the fence languages reach the page before the parsed document does.
    @Test func fenceLanguagesArriveBeforeTheParse() async throws {
        try write("# Plan\n\n```python\nx = 1\n```\n\n- ```Go\n  package main\n  ```\n")
        let l = loader()
        var events: [String] = []
        let r: DocumentLoader.ReadResult? = await withCheckedContinuation { cont in
            l.loadInitial(fenceLanguages: { events.append("langs " + $0.joined(separator: ",")) }) { r in
                events.append("parsed")
                cont.resume(returning: r)
            }
        }
        #expect(r != nil)
        #expect(events == ["langs python,go", "parsed"])
    }

    @Test func unreadableFileYieldsNil() async {
        let r = await initial(loader())
        #expect(r == nil)
    }

    @Test func identicalBytesAreUnchanged() async throws {
        try write("# Plan\n")
        let l = loader()
        _ = await initial(l)
        try write("# Plan\n")
        guard case .unchanged = await change(l) else { Issue.record("expected unchanged"); return }
    }

    @Test func eachReadNamesTheFileItCameFrom() async throws {
        let fm = FileManager.default
        let a = dir.appendingPathComponent("run-41.md"), b = dir.appendingPathComponent("run-42.md")
        try Data("# A\n".utf8).write(to: a)
        try Data("# A\n".utf8).write(to: b)   // same bytes: an unchanged read still moves the source
        try fm.createSymbolicLink(atPath: file.path, withDestinationPath: "run-41.md")
        let l = loader()
        let r = await initial(l)
        #expect(r?.sourcePath == RealPath.of(a.path))
        #expect(l.lastSourcePath == RealPath.of(a.path))
        try fm.removeItem(at: file)
        try fm.createSymbolicLink(atPath: file.path, withDestinationPath: "run-42.md")
        guard case .unchanged = await change(l) else { Issue.record("expected unchanged"); return }
        #expect(l.lastSourcePath == RealPath.of(b.path))
        try Data("# B\n\nNew.\n".utf8).write(to: b)
        guard case .content(let c) = await change(l) else { Issue.record("expected content"); return }
        #expect(c.sourcePath == RealPath.of(b.path))
        #expect(l.lastSourcePath == RealPath.of(b.path))
    }

    @Test func newContentIsReported() async throws {
        try write("# Plan\n")
        let l = loader()
        _ = await initial(l)
        try write("# Plan\n\nAdded.\n")
        guard case .content(let r) = await change(l) else { Issue.record("expected content"); return }
        #expect(texts(r) == ["# Plan", "Added."])
    }

    @Test func burstsShareOneFreshResult() async throws {
        try write("# Plan\n")
        let l = loader()
        _ = await initial(l)
        #expect(l.parseCount == 1)
        try write("# Plan\n\nv2\n")
        var changes: [DocumentLoader.Change] = []
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var left = 3
            let done = { (c: DocumentLoader.Change) in
                changes.append(c)
                left -= 1
                if left == 0 { cont.resume() }
            }
            l.readChange(done)
            // Lands while the first parse is (likely) running: the burst must
            // end on this content, never on the stale v2.
            try? write("# Plan\n\nv3\n")
            l.readChange(done)
            l.readChange(done)
        }
        // Every caller is answered; the content is reported exactly once; and
        // the burst cost one parse plus one fresh re-read, not one per write.
        let contents = changes.compactMap { if case .content(let r) = $0 { return r } else { return nil } }
        #expect(changes.count == 3)
        #expect(contents.count == 1)
        #expect(texts(contents.first) == ["# Plan", "v3"])
        #expect(l.parseCount == 3)
    }

    @Test func halfWrittenFileIsRetriedUntilComplete() async throws {
        try write("# Plan\n")
        // A generous retry window, so the completing write always lands inside it.
        let l = loader(retryDelay: 1.0)
        _ = await initial(l)
        // A truncated UTF-8 sequence at the end: an agent mid-write.
        try write(bytes: Array("# Plan\n\n中".utf8.dropLast()))
        let pending = Task { @MainActor in await change(l) }
        try await Task.sleep(nanoseconds: 150_000_000)
        try write("# Plan\n\n中文\n")
        guard case .content(let r) = await pending.value else { Issue.record("expected content"); return }
        #expect(texts(r) == ["# Plan", "中文"])
    }

    @Test func halfWriteRetriesAreBounded() async throws {
        try write("# Plan\n")
        let l = loader(retryDelay: 0.05)
        _ = await initial(l)
        try write(bytes: Array("# Plan\n\n中".utf8.dropLast()))
        let start = Date()
        guard case .content(let r) = await change(l) else { Issue.record("expected content"); return }
        // Two retries, then the valid prefix is shown rather than waiting forever.
        #expect(Date().timeIntervalSince(start) >= 0.1)
        #expect(texts(r) == ["# Plan"])
    }
}

/// 3.9.1: the languages a document's fences name, read without parsing it.
@Suite struct FenceLanguagesTests {
    @Test func namesEachFenceLanguageOnceInOrder() {
        let text = """
        # Plan
        ```Python title="x"
        print(1)
        ```
        > ```bash
        > ls
        > ```
        1. ```yaml{.line-numbers}
           a: 1
           ```
        ~~~ diff
        -a
        ~~~
        ```python
        ```
        ``inline`` and ```
        """
        #expect(FenceLanguages.scan(text) == ["python", "bash", "yaml", "diff"])
    }

    /// Container markers in any mix, before the fence: all skipped.
    @Test func fencesInAnyContainerAreNamed() {
        let text = "-\t```go\n1) ```ruby\n> > - ```lua\n> quote\nlazy line\n```zig\n\t```perl\n  * + 12. ```php\n"
        #expect(FenceLanguages.scan(text) == ["go", "ruby", "lua", "zig", "perl", "php"])
    }

    @Test func onlyTheFirstBytesOfAHugeFileAreLookedAt() {
        let text = String(repeating: "x\n", count: 100) + "```late\n```"
        #expect(FenceLanguages.scan(text, maxBytes: 100).isEmpty)
        #expect(FenceLanguages.scan(text) == ["late"])
    }

    @Test func codeSpansAreNotFences() {
        #expect(FenceLanguages.scan("``js`` and `a`\nno fences here\n").isEmpty)
        // Indented four spaces it is code, not a fence; a quick look names it anyway (harmless).
        #expect(FenceLanguages.scan("``js``\n    ```rust\n").count == 1)
        #expect(FenceLanguages.scan("").isEmpty)
    }

    @Test func stopsAtTheLimit() {
        let text = (0..<40).map { "```l\($0)\n```" }.joined(separator: "\n")
        #expect(FenceLanguages.scan(text).count == 16)
        #expect(FenceLanguages.scan(text, limit: 3) == ["l0", "l1", "l2"])
    }
}
