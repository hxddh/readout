import Foundation
import Testing
@testable import ReadoutCore

/// Agent folder events (`AgentFolders`): which writes are documents, and which are new.
@Suite struct AgentFoldersTests {
    @Test func agentFolderEventsAskTheDiskOnlyAboutMarkdownDocuments() {
        var asked: [String] = []
        var known: Set<String> = ["/w/plans/old.md", "/w/plans/gone.md"]
        let events = ["/w/plans/node_modules/x/index.js", "/w/plans/.git/index", "/w/plans/build.log",
                      "/w/plans/new.md", "/w/plans/old.md", "/w/plans/gone.md", "/w/plans/node_modules/x/README.md",
                      "/w/plans/.hidden.md", "/elsewhere/a.md"]
        let writes = AgentFolders.writes(events, roots: ["/w/plans"], known: &known) { path in
            asked.append(path)
            return path != "/w/plans/gone.md"
        }
        // Build output, dependencies, hidden files and other folders never cost a stat.
        #expect(asked == ["/w/plans/new.md", "/w/plans/old.md", "/w/plans/gone.md"])
        #expect(writes.map(\.path) == ["/w/plans/new.md", "/w/plans/old.md"])
        #expect(writes.map(\.isNew) == [true, false])
        // Gone: forgotten, so writing it again is a new document.
        #expect(known == ["/w/plans/old.md", "/w/plans/new.md"])
    }

    /// 4.1: a document the bounded initial scan did not reach (too deep, past
    /// its entry limit, in a package) was taken for a new one on its first
    /// edit. Not in `known`, it is new only if created since watching started.
    @Test func aDocumentTheScanMissedIsNewOnlyIfCreatedSinceWatchingStarted() {
        let since = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let born: [String: Date] = ["/w/plans/deep/old.md": since.addingTimeInterval(-86_400),
                                    "/w/plans/fresh.md": since.addingTimeInterval(30),
                                    "/w/plans/racing.md": since.addingTimeInterval(-1)]
        var known: Set<String> = ["/w/plans/known.md"]
        let events = ["/w/plans/deep/old.md", "/w/plans/fresh.md", "/w/plans/racing.md", "/w/plans/unknown.md", "/w/plans/known.md"]
        let writes = AgentFolders.writes(events, roots: ["/w/plans"], known: &known, exists: { _ in true },
                                         createdAt: { born[$0] }, watchingSince: since)
        #expect(writes.map(\.path) == events)
        // Created long before: an edit. Since (or within 2 s before): new. No birth time: new, as before.
        #expect(writes.map(\.isNew) == [false, true, true, true, false])
        // Seen now: its next write is an edit either way.
        #expect(known.isSuperset(of: events))
        let again = AgentFolders.writes(["/w/plans/fresh.md"], roots: ["/w/plans"], known: &known, exists: { _ in true },
                                        createdAt: { born[$0] }, watchingSince: since)
        #expect(again.map(\.isNew) == [false])
    }
}
