import Foundation
import Testing
@testable import ReadoutCore

@Suite struct ReaderLayoutTests {
    // reader.css: the text grows with the page, 35 em at most.
    @Test func columnFollowsThePage() {
        #expect(ReaderLayout.rootSize(width: 900, fontSize: 16) == 16)
        #expect(abs(ReaderLayout.rootSize(width: 1600, fontSize: 16) - 19.111) < 0.01)
        #expect(ReaderLayout.rootSize(width: 2400, fontSize: 16) == 20)
        #expect(ReaderLayout.rootSize(width: 2400, fontSize: 20) == 25)
        #expect(ReaderLayout.column(width: 900, fontSize: 16) == 560)
        #expect(ReaderLayout.column(width: 500, fontSize: 16) == 444)
    }

    // At Actual Size with a 220 px outline: not at 900 or 1000 px, from about
    // 1004 px on, at 1280, 1600 and 2400.
    @Test func wideWindowsShowTheOutline() {
        func fits(_ w: Double, shown: Bool = false, fs: Double = 16) -> Bool {
            ReaderLayout.sidebarFits(windowWidth: w, sidebarWidth: 220, fontSize: fs, shown: shown)
        }
        #expect(!fits(900))
        #expect(!fits(1000))
        #expect(fits(1010))
        #expect(fits(1280) && fits(1600) && fits(2400))
        // Shown, it stays a little longer as the window narrows (no flicker).
        #expect(fits(990, shown: true))
        #expect(!fits(990, shown: false))
        #expect(!fits(960, shown: true))
        // A larger text size needs a wider window.
        #expect(!fits(1100, fs: 20))
        #expect(fits(1400, fs: 20))
        #expect(!ReaderLayout.sidebarFits(windowWidth: 200, sidebarWidth: 220, fontSize: 16, shown: true))
    }

    // The reader's choice against the width holds; one with it gives the window back to its width.
    @Test func aManualToggleHoldsInItsWindow() {
        var s = SidebarFit()
        #expect(s.shown(fits: true) && !s.shown(fits: false))
        s.toggled(to: false, fits: true)          // hidden in a wide window
        #expect(!s.shown(fits: true))              // stays hidden as it widens
        #expect(!s.shown(fits: false))
        s.toggled(to: true, fits: true)           // shown again: the width decides
        #expect(s.choice == nil)
        s.toggled(to: true, fits: false)          // shown in a narrow window
        #expect(s.shown(fits: false))
        s.toggled(to: false, fits: false)
        #expect(s.choice == nil && !s.shown(fits: false))
    }

    // The arithmetic is reader.css's: the same numbers there.
    @Test func matchesTheStylesheet() throws {
        let css = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("web/src/reader.css"), encoding: .utf8)
        #expect(css.contains("--measure: min(35rem, 100vw - 2 * var(--gutter));"))
        #expect(css.contains("--gutter: 28px;"))
        #expect(css.contains("font-size: clamp(calc(var(--fs) * 1px), calc(var(--fs) * (1px + (100vw - 900px) / 3600)), calc(var(--fs) * 1.25px));"))
    }
}
