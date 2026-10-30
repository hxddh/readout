import Foundation
import Testing
@testable import ReadoutCore

/// What a watched folder leaves out (`WatchExclusions`): build output and version
/// control, never the file shown or a watched folder.
@Suite struct WatchExclusionsTests {
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
}
