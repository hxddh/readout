import Foundation
import Testing
@testable import ReadoutCore

@Suite struct ReaderLayoutTests {
    // reader.css: the text grows with the page up to 1.12 times (from 1332 px),
    // the column 50 rem at most (64 at Wide).
    @Test func columnFollowsThePage() {
        #expect(ReaderLayout.rootSize(width: 900, fontSize: 16) == 16)
        #expect(abs(ReaderLayout.rootSize(width: 1200, fontSize: 16) - 17.333) < 0.01)
        #expect(abs(ReaderLayout.rootSize(width: 2400, fontSize: 16) - 17.92) < 0.001)
        #expect(abs(ReaderLayout.rootSize(width: 2400, fontSize: 20) - 22.4) < 0.001)
        #expect(ReaderLayout.column(width: 900, fontSize: 16) == 800)
        #expect(ReaderLayout.column(width: 500, fontSize: 16) == 444)
        #expect(ReaderLayout.column(width: 900, fontSize: 16, measure: ReaderLayout.wideMeasure) == 844)
        #expect(abs(ReaderLayout.column(width: 2400, fontSize: 16, measure: ReaderLayout.wideMeasure) - 1146.88) < 0.001)
    }

    // At Actual Size with a 220 px outline: not at 1120 or 1280 px, from about
    // 1292 px on, at 1300, 1600 and 2400; at Wide, from about 1614 px.
    @Test func wideWindowsShowTheOutline() {
        func fits(_ w: Double, shown: Bool = false, fs: Double = 16, measure: Double = ReaderLayout.standardMeasure) -> Bool {
            ReaderLayout.sidebarFits(windowWidth: w, sidebarWidth: 220, fontSize: fs, shown: shown, measure: measure)
        }
        #expect(!fits(900))
        #expect(!fits(1120))
        #expect(!fits(1280))
        #expect(fits(1300))
        #expect(fits(1600) && fits(2400))
        // Shown, it stays a little longer as the window narrows (no flicker).
        #expect(fits(1260, shown: true))
        #expect(!fits(1260, shown: false))
        #expect(!fits(1240, shown: true))
        // A larger text size needs a wider window.
        #expect(!fits(1600, fs: 20))
        #expect(fits(1700, fs: 20))
        // So does the wide column.
        #expect(!fits(1600, measure: ReaderLayout.wideMeasure))
        #expect(fits(1620, measure: ReaderLayout.wideMeasure))
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
        #expect(css.contains("--measure: 50rem;"))   // #ro-doc's max-width: the window less the gutters below it
        #expect(css.contains("--measure: 64rem;"))   // Text Width ▸ Wide
        #expect(css.contains("max-width: calc(var(--measure) + var(--gutter) * 2);"))
        #expect(css.contains("--gutter: 28px;"))
        #expect(css.contains("font-size: clamp(calc(var(--fs) * 1px), calc(var(--fs) * (1px + (100vw - 900px) / 3600)), calc(var(--fs) * 1.12px));"))
    }
}
