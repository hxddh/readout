import Foundation
import Testing
@testable import ReadoutCore

/// 3.8 app shell: what wakes the app while it watches files (P8), and when
/// the spare reader page is made again (P5).
@Suite struct AppShell38Tests {
    @Test func aRepositoryRootDocumentLeavesBuildOutputAndVersionControlOut() {
        let paths = WatchExclusions.paths(for: ["/w/repo"], keep: ["/w/repo/PLAN.md"])
        #expect(paths.count == WatchExclusions.limit)
        #expect(Array(paths.prefix(4)) == ["/w/repo/.git", "/w/repo/node_modules", "/w/repo/.build", "/w/repo/DerivedData"])
        #expect(!paths.contains("/w/repo"))
    }

    @Test func noExclusionHidesTheFileShownOrAWatchedFolder() {
        // The file shown is named like a build folder: that folder is not left out,
        // however FSEvents compares paths ("/w/build" is a prefix of "/w/build.md").
        let named = WatchExclusions.paths(for: ["/w"], keep: ["/w/build.md", "/w/target-notes.md"])
        #expect(!named.contains("/w/build") && !named.contains("/w/target"))
        #expect(named.contains("/w/.git"))
        // A symlink in /w pointing into /w/node_modules/pkg: both folders are
        // watched, so /w/node_modules stays in.
        let linked = WatchExclusions.paths(for: ["/w/node_modules/pkg", "/w"],
                                           keep: ["/w/node_modules/pkg/README.md", "/w/latest.md"])
        #expect(!linked.contains("/w/node_modules"))
        #expect(linked.contains("/w/.git") && linked.contains("/w/node_modules/pkg/.git"))
        #expect(linked.count <= WatchExclusions.limit)
        #expect(Set(linked).count == linked.count)
        // Busiest first across both folders, never more than FSEvents takes.
        #expect(Array(linked.prefix(2)) == ["/w/node_modules/pkg/.git", "/w/.git"])
    }

    @Test func exclusionsIgnoreCaseAsMacVolumesDo() {
        // /repo/latest.md -> Build/plan.md: /repo and /repo/Build are watched.
        // On a case-insensitive volume /repo/build is /repo/Build, which holds
        // the file shown: never excluded.
        let paths = WatchExclusions.paths(for: ["/repo/Build", "/repo"], keep: ["/repo/Build/plan.md", "/repo/latest.md"])
        #expect(!paths.contains { $0.lowercased() == "/repo/build" })
        #expect(paths.contains("/repo/.git"))
        // A file named like a folder in another case is kept too, and so is
        // the folder holding the file, or any folder above it.
        let named = WatchExclusions.paths(for: ["/w"], keep: ["/w/BUILD.md", "/w/Node_Modules/x/plan.md"])
        #expect(!named.contains("/w/build") && !named.contains("/w/node_modules"))
        for p in paths + named {
            for kept in ["/repo/Build/plan.md", "/repo/latest.md", "/w/BUILD.md", "/w/Node_Modules/x/plan.md"] {
                #expect(!kept.lowercased().hasPrefix(p.lowercased()), "\(p) would hide \(kept)")
            }
        }
    }

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

    @Test func theNextSparePageWaitsForTheFirstPaintOrTheFallback() {
        var plan = SparePagePlan()
        // Nothing taken: a paint makes nothing.
        #expect(plan.painted() == false)
        let first = plan.taken()
        #expect(plan.waiting)
        // The page taken paints: the next spare page is made now, once.
        #expect(plan.painted() == true)
        #expect(plan.painted() == false)
        // Its fallback timer fires later: nothing is owed any more.
        #expect(plan.fallbackFired(first) == false)

        // No paint within the fallback: the timer makes it.
        let second = plan.taken()
        #expect(plan.fallbackFired(second) == true)
        #expect(plan.painted() == false)

        // Taken twice before either timer fires: only the later timer counts.
        let a = plan.taken(), b = plan.taken()
        #expect(plan.fallbackFired(a) == false)
        #expect(plan.waiting)
        #expect(plan.fallbackFired(b) == true)
        #expect(SparePagePlan.fallback == 3)
    }
}
