import Foundation
import Testing
@testable import ReadoutCore

@Suite struct ReaderChromeTests {
    @Test func theSubtitleShowsStatusFirstThenTasksThenTheFolder() {
        let tasks = TaskStats(done: 2, total: 5)
        #expect(ReaderChrome.subtitle(status: "The file was deleted.", tasks: tasks, path: "/a/runs/plan.md") == .status("The file was deleted."))
        #expect(ReaderChrome.subtitle(status: nil, tasks: tasks, path: "/a/runs/plan.md") == .tasks(done: 2, total: 5))
        #expect(ReaderChrome.subtitle(status: "", tasks: TaskStats(), path: "/a/runs/plan.md") == .folder("runs"))
        // A failed first read has no tasks and must still say why the window is blank.
        #expect(ReaderChrome.subtitle(status: "The file could not be read.", tasks: TaskStats(), path: "/a/plan.md") == .status("The file could not be read."))
    }

    @Test func recentTitlesNameTheFolderOnlyWhenNamesCollide() {
        let titles = ReaderChrome.recentTitles(["/w/app/plan.md", "/w/web/PLAN.md", "/w/notes.md", "/w/x/README.md"])
        #expect(titles == ["plan.md — app", "PLAN.md — web", "notes.md", "README.md"])
        #expect(ReaderChrome.recentTitles([]) == [])
    }

    @Test func anOutlineUnderASingleTitleIndentsFromItsSections() {
        // # Title, ## A, ### A.1, ## B: the sections start at the left edge.
        #expect(ReaderChrome.outlineBaseLevel([1, 2, 3, 2]) == 2)
        // Several top-level headings, or the top one not first: unchanged.
        #expect(ReaderChrome.outlineBaseLevel([1, 2, 1, 2]) == 1)
        #expect(ReaderChrome.outlineBaseLevel([2, 1, 2]) == 1)
        #expect(ReaderChrome.outlineBaseLevel([2, 3, 3]) == 3)
        #expect(ReaderChrome.outlineBaseLevel([1]) == 1)
        #expect(ReaderChrome.outlineBaseLevel([]) == 1)
    }

    @Test func helpOpensTheKeyboardSectionInTheReadersLanguage() {
        #expect(ReaderChrome.helpURL(preferredLanguages: ["zh-Hans-CN", "en"]).absoluteString
                == "https://github.com/hxddh/readout/blob/main/README.zh-CN.md#%E5%BF%AB%E6%8D%B7%E9%94%AE")
        #expect(ReaderChrome.helpURL(preferredLanguages: ["zh-Hant"]).fragment == "快捷键" || ReaderChrome.helpURL(preferredLanguages: ["zh-Hant"]).fragment == "%E5%BF%AB%E6%8D%B7%E9%94%AE")
        #expect(ReaderChrome.helpURL(preferredLanguages: ["en-US"]).absoluteString == "https://github.com/hxddh/readout#keyboard")
        #expect(ReaderChrome.helpURL(preferredLanguages: []).fragment == "keyboard")
    }

    /// The anchors the help link uses exist in the READMEs (GitHub slugs).
    @Test func theHelpAnchorsExist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let en = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let zh = try String(contentsOf: root.appendingPathComponent("README.zh-CN.md"), encoding: .utf8)
        #expect(en.contains("\n## Keyboard\n"))
        #expect(zh.contains("\n## 快捷键\n"))
    }

    @Test func aWriteAfterAQuietSpellIsReportedAtOnce() {
        var d = WriteDebounce(trailing: 0.08, maxWait: 0.4)
        #expect(d.event(at: 10.0) == .fire)
        // More events right after (the rename's second notification, a burst): held.
        #expect(d.event(at: 10.03) == .schedule(after: 0.08))
        #expect(d.isHolding)
        #expect(d.event(at: 10.06) == .schedule(after: 0.08))
        d.fired(at: 10.14)
        #expect(!d.isHolding)
        // Still inside the trailing window of the last report: held, not doubled.
        #expect(d.event(at: 10.15) == .schedule(after: 0.08))
        d.fired(at: 10.23)
        // Quiet again: the next write fires immediately.
        #expect(d.event(at: 11.0) == .fire)
    }

    @Test func aContinuousWriteIsReportedWithinMaxWait() {
        var d = WriteDebounce(trailing: 0.08, maxWait: 0.4)
        var fires: [Double] = []
        var deadline: Double?
        // An event every 20 ms for two seconds; a scheduled report runs at its deadline.
        for i in 0..<100 {
            let t = Double(i) * 0.02
            if let due = deadline, due <= t { d.fired(at: due); fires.append(due); deadline = nil }
            switch d.event(at: t) {
            case .fire: fires.append(t)
            case .schedule(let after): deadline = t + after
            }
        }
        #expect(fires.first == 0)
        #expect(fires.count >= 4)
        for (a, b) in zip(fires, fires.dropFirst()) { #expect(b - a <= 0.4 + 0.02 + 1e-9) }
    }
}
