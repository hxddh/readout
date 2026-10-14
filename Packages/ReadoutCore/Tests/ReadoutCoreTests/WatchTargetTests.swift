import Foundation
import Testing
@testable import ReadoutCore

/// A scratch folder reached through a symlinked parent, the way macOS reaches
/// /tmp (-> /private/tmp) and $TMPDIR (/var -> /private/var).
private struct Scratch {
    let real: String    // what FSEvents reports
    let linked: String  // what the reader opened

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString)").path
        let fm = FileManager.default
        try fm.createDirectory(atPath: base + "/private/tmp", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: base + "/tmp", withDestinationPath: base + "/private/tmp")
        real = RealPath.of(base) + "/private/tmp"
        linked = base + "/tmp"
    }

    func write(_ name: String, _ text: String = "# x\n") {
        FileManager.default.createFile(atPath: real + "/" + name, contents: Data(text.utf8))
    }
}

@Suite struct WatchTargetTests {
    @Test func aFileUnderASymlinkedFolderMatchesTheRealPathEventsReport() throws {
        let s = try Scratch()
        s.write("plan.md")
        let t = WatchTarget(path: s.linked + "/plan.md")
        #expect(t.target == s.real + "/plan.md")
        #expect(t.directories == [s.real])
        // FSEvents reports the real path: it must be recognised as the file shown.
        #expect(t.isTarget(s.real + "/plan.md"))
        #expect(!t.isTarget(s.real + "/other.md"))
        // The spelling the old code compared with never appears in an event.
        #expect(t.target != URL(fileURLWithPath: s.linked + "/plan.md").standardizedFileURL.path)
    }

    @Test func caseVariantsStillMatch() throws {
        let s = try Scratch()
        s.write("Readme.md")
        let t = WatchTarget(path: s.real + "/Readme.md")
        #expect(t.isTarget(s.real + "/README.md"))
    }

    @Test func aMissingFileResolvesItsFolder() throws {
        let s = try Scratch()
        let t = WatchTarget(path: s.linked + "/later.md")
        #expect(t.target == s.real + "/later.md")
    }

    @Test func aRetargetedSymlinkIsFollowed() throws {
        let s = try Scratch()
        let fm = FileManager.default
        try fm.createDirectory(atPath: s.real + "/runs", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: s.real + "/links", withIntermediateDirectories: true)
        s.write("runs/run-41.md")
        s.write("runs/run-42.md")
        let link = s.linked + "/links/latest.md"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: "../runs/run-41.md")
        var t = WatchTarget(path: link)
        #expect(t.target == s.real + "/runs/run-41.md")
        // Both the target's folder and the link's own folder are watched.
        #expect(Set(t.directories) == [s.real + "/runs", s.real + "/links"])
        #expect(t.isLink(s.real + "/links/latest.md"))
        #expect(!t.isTarget(s.real + "/links/latest.md"))
        let unchanged = t.reresolve()
        #expect(!unchanged)

        // `ln -sf ../runs/run-42.md latest.md`, done atomically.
        try fm.createSymbolicLink(atPath: s.real + "/links/.tmp-link", withDestinationPath: "../runs/run-42.md")
        #expect(rename(s.real + "/links/.tmp-link", s.real + "/links/latest.md") == 0)
        let changed = t.reresolve()
        #expect(changed)
        #expect(t.target == s.real + "/runs/run-42.md")
        #expect(t.isTarget(s.real + "/runs/run-42.md"))
        #expect(!t.isTarget(s.real + "/runs/run-41.md"))
    }

    /// `ln -sf ../runs/run-42.md latest.md` before run-42.md is written: the
    /// window must watch run-42.md's folder, under its real spelling, so it
    /// picks the file up when the agent writes it.
    @Test func aSymlinkToAFileNotWrittenYetResolvesToWhereItWillBe() throws {
        let s = try Scratch()
        let fm = FileManager.default
        try fm.createDirectory(atPath: s.real + "/runs", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: s.real + "/links", withIntermediateDirectories: true)
        s.write("runs/run-41.md")
        let link = s.linked + "/links/latest.md"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: "../runs/run-41.md")
        var t = WatchTarget(path: link)

        try fm.createSymbolicLink(atPath: s.real + "/links/.tmp-link", withDestinationPath: "../runs/run-42.md")
        #expect(rename(s.real + "/links/.tmp-link", s.real + "/links/latest.md") == 0)
        let changed = t.reresolve()
        #expect(changed)
        #expect(t.target == s.real + "/runs/run-42.md")
        #expect(Set(t.directories) == [s.real + "/runs", s.real + "/links"])
        #expect(RealPath.of(link) == s.real + "/runs/run-42.md")

        // The agent writes run-42.md: same path, so no second retarget, and the event matches.
        s.write("runs/run-42.md")
        let again = t.reresolve()
        #expect(!again)
        #expect(t.isTarget(s.real + "/runs/run-42.md"))
        // Keys agree before and after the file exists.
        #expect(BaselineKey.key(forPath: link) == BaselineKey.key(forPath: s.real + "/runs/run-42.md"))
    }

    @Test func aDanglingAbsoluteSymlinkAndALoopStillResolve() throws {
        let s = try Scratch()
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: s.real + "/abs.md", withDestinationPath: s.linked + "/later.md")
        #expect(RealPath.of(s.linked + "/abs.md") == s.real + "/later.md")
        try fm.createSymbolicLink(atPath: s.real + "/a.md", withDestinationPath: "b.md")
        try fm.createSymbolicLink(atPath: s.real + "/b.md", withDestinationPath: "a.md")
        #expect(RealPath.of(s.real + "/a.md").hasPrefix(s.real + "/"))   // terminates
    }

    @Test func aRetargetSettlesOnAReadOfEitherSpelling() throws {
        let s = try Scratch()
        var g = RetargetGate()
        // Recorded through the link's spelling while the file did not exist.
        g.retargeted(to: s.linked + "/later.md")
        s.write("later.md")
        let settled = g.read(from: s.real + "/later.md")
        #expect(settled)
        #expect(!g.isPending)
    }

    @Test func aRetargetSettlesOnlyOnAReadOfTheNewTarget() {
        var g = RetargetGate()
        let r1 = g.read(from: "/r/run-41.md")
        #expect(!r1)       // nothing pending
        g.retargeted(to: "/r/run-42.md")
        #expect(g.isPending)
        let r2 = g.read(from: "/r/run-41.md")
        #expect(!r2)       // the old target's read, still in flight
        #expect(g.isPending)
        let r3 = g.read(from: nil)
        #expect(!r3)
        g.retargeted(to: "/r/run-43.md")             // pointed elsewhere again before any read
        let r4 = g.read(from: "/r/run-42.md")
        #expect(!r4)
        let r5 = g.read(from: "/r/run-43.md")
        #expect(r5)
        #expect(!g.isPending)
    }

    @Test func baselineKeysAgreeAcrossSpellings() throws {
        let s = try Scratch()
        s.write("plan.md")
        #expect(BaselineKey.key(forPath: s.linked + "/plan.md") == BaselineKey.key(forPath: s.real + "/plan.md"))
        #expect(BaselineKey.key(forPath: s.linked + "/./plan.md") == BaselineKey.key(forPath: s.real + "/plan.md"))
        // The pre-3.3 key, from the spelling, differs: it is only a fallback.
        #expect(BaselineKey.legacyKey(forPath: s.linked + "/plan.md") != BaselineKey.legacyKey(forPath: s.real + "/plan.md"))
        #expect(BaselineKey.legacyKey(forPath: s.real + "/plan.md") == BaselineKey.key(forPath: s.real + "/plan.md"))
    }
}

@Suite struct OpenLinkTests {
    @Test func parsesABackgroundRequest() {
        let u = URL(string: "readout-open://open?background=1&path=%2Ftmp%2Fa%20b%2B%26c%3D%25.md")!
        #expect(OpenLink.parse(u) == .init(path: "/tmp/a b+&c=%.md", background: true))
    }

    @Test func rejectsOtherURLs() {
        #expect(OpenLink.parse(URL(string: "readout://open?path=%2Fa.md")!) == nil)       // the web view's scheme
        #expect(OpenLink.parse(URL(string: "readout-open://file?path=%2Fa.md")!) == nil)
        #expect(OpenLink.parse(URL(string: "readout-open://open?path=a.md")!) == nil)     // relative
        #expect(OpenLink.parse(URL(string: "readout-open://open")!) == nil)
        #expect(OpenLink.parse(URL(string: "readout-open://open?path=%2Fa.md")!) == .init(path: "/a.md", background: false))
    }

    /// The `readout` script (cli/readout) with `open` replaced by `echo`.
    private func runScript(_ args: [String], cwd: String, stdin: String? = nil) throws -> String {
        try runScriptWithStatus(args, cwd: cwd, stdin: stdin).output
    }

    private func runScriptWithStatus(_ args: [String], cwd: String, stdin: String? = nil) throws -> (output: String, status: Int32) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [root.appendingPathComponent("cli/readout").path] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["READOUT_OPEN_COMMAND"] = "echo"
        p.environment = env
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardInput = input
        try p.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), p.terminationStatus)
    }

    @Test func aSkippedFileMakesTheScriptFailAfterOpeningTheRest() throws {
        let s = try Scratch()
        s.write("plan.md")
        let r = try runScriptWithStatus(["-b", "plan.md", "missing.md"], cwd: s.real)
        #expect(r.output.split(separator: " ").count == 4)   // plan.md still opened
        #expect(r.status != 0)
        #expect(try runScriptWithStatus(["-b", "plan.md"], cwd: s.real).status == 0)
    }

    @Test func theScriptOpensInTheBackgroundThroughTheScheme() throws {
        let s = try Scratch()
        let name = "a b+&c=%é.md"
        s.write(name)
        let out = try runScript(["-b", name, "/nonexistent/x.md"], cwd: s.real)
        let words = out.split(separator: " ").map(String.init)
        #expect(Array(words.prefix(3)) == ["-g", "-b", "io.github.hxddh.readout"])
        let urls = words.dropFirst(3).compactMap { URL(string: $0) }
        #expect(urls.count == 1)   // a missing file is not sent
        #expect(urls.first.flatMap(OpenLink.parse) == .init(path: s.real + "/" + name, background: true))
    }

    @Test func theScriptStillOpensInTheForegroundAsBefore() throws {
        let s = try Scratch()
        s.write("plan.md")
        #expect(try runScript(["plan.md"], cwd: s.real) == "-b io.github.hxddh.readout -- plan.md")
    }

    #if os(macOS)
    // The hook reads its JSON with macOS's plutil (the Linux toolchain ships a different one).
    @Test func theHookOpensInTheBackgroundThroughTheScheme() throws {
        let s = try Scratch()
        s.write("plan.md")
        let out = try runScript(["--hook"], cwd: "/", stdin: #"{"tool_input":{"file_path":"\#(s.real)/plan.md"}}"#)
        let words = out.split(separator: " ").map(String.init)
        #expect(words.count == 4)
        #expect(words.last.flatMap { URL(string: $0) }.flatMap(OpenLink.parse) == .init(path: s.real + "/plan.md", background: true))
    }
    #endif
}
