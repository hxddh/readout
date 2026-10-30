import Foundation
import Testing
@testable import ReadoutCore

/// `ProcessRunner`: its time and size limits, and children that hold its output.
@Suite struct ProcessRunnerTests {
    @Test func processRunnerKeepsToItsTimeAndSizeLimits() {
        #expect(ProcessRunner.run("/bin/sh", ["-c", "printf hello"], timeout: 5, limit: 100) == Data("hello".utf8))
        // Fails: nil.
        #expect(ProcessRunner.run("/bin/sh", ["-c", "exit 3"], timeout: 5, limit: 100) == nil)
        // Too slow: stopped at the limit, not waited for.
        let start = Date()
        #expect(ProcessRunner.run("/bin/sh", ["-c", "sleep 5"], timeout: 0.3, limit: 100) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
        // Too much: stopped.
        #expect(ProcessRunner.run("/bin/sh", ["-c", "head -c 200000 /dev/zero"], timeout: 5, limit: 1000) == nil)
        // Not there: nil.
        #expect(ProcessRunner.run("/nonexistent/git", [], timeout: 1, limit: 10) == nil)
        #expect(GitTools.available(xcodeSelect: "/nonexistent/xcode-select") == false)
    }

    @Test func aProgramPastItsTimeLimitStopsAtTheLimit() {
        let t0 = Date()
        // A shell waiting on its command (as the audit's hanging git).
        #expect(ProcessRunner.run("/bin/sh", ["-c", "sleep 5; echo hi"], timeout: 0.5, limit: 100) == nil)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed < 0.85, "\(elapsed)")   // 3.7: 1.0 (the limit, then half a second more)
    }

    /// A program that exits at once, leaving a child that holds its output
    /// open: its output, when it exits, and no reader left waiting.
    @Test func aChildHoldingTheOutputDoesNotHoldTheResult() async throws {
        let t0 = Date()
        let out = ProcessRunner.run("/bin/sh", ["-c", "echo '# Old'; (sleep 4) & exit 0"], timeout: 1, limit: 100)
        let elapsed = Date().timeIntervalSince(t0)
        #if canImport(Darwin)
        #expect(out == Data("# Old\n".utf8))   // 3.7: nil, after the limit and half a second more
        #expect(elapsed < 0.7, "\(elapsed)")
        #else
        // swift-corelibs-foundation reports the exit only once the child has
        // exited too (it watches a socket the child inherits): at the limit.
        #expect(out == nil)
        #expect(elapsed < 1.3, "\(elapsed)")   // 3.7: 1.5
        #endif
        // 3.7's reader waited for the child, 4 s. (Other tests may run one meanwhile: none for long.)
        var waited = 0
        while ProcessRunner.liveReaders > 0 && waited < 200 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        #expect(ProcessRunner.liveReaders == 0)
        // Output past the limit still stops it at once.
        let t1 = Date()
        #expect(ProcessRunner.run("/bin/sh", ["-c", "head -c 200000 /dev/zero; sleep 5"], timeout: 3, limit: 1000) == nil)
        #expect(Date().timeIntervalSince(t1) < 1)
    }
}
