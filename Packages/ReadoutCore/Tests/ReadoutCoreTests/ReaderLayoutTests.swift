import Foundation
import Testing
@testable import ReadoutCore

@Suite struct ReaderLayoutTests {
    // reader.css: the text grows with the page up to 1.12 times (from 1332 px);
    // the column is the page less 5% each side (28 px at least), 80 rem at most
    // (no limit at Wide).
    @Test func columnFollowsThePage() {
        #expect(ReaderLayout.rootSize(width: 900, fontSize: 16) == 16)
        #expect(abs(ReaderLayout.rootSize(width: 1200, fontSize: 16) - 17.333) < 0.01)
        #expect(abs(ReaderLayout.rootSize(width: 2400, fontSize: 16) - 17.92) < 0.001)
        #expect(abs(ReaderLayout.rootSize(width: 2400, fontSize: 20) - 22.4) < 0.001)
        #expect(abs(ReaderLayout.column(width: 900, fontSize: 16) - 810) < 0.001)
        #expect(ReaderLayout.column(width: 500, fontSize: 16) == 444)
        #expect(abs(ReaderLayout.column(width: 1200, fontSize: 16) - 1080) < 0.001)
        #expect(abs(ReaderLayout.column(width: 2400, fontSize: 16) - 1433.6) < 0.001)
        #expect(abs(ReaderLayout.column(width: 2400, fontSize: 16, cap: ReaderLayout.wideCap) - 2160) < 0.001)
    }

    // At Actual Size with a 220 px outline: once the page beside it keeps a
    // 50 rem column, from about 1128 px (and, shown, down to about 1109).
    @Test func wideWindowsShowTheOutline() {
        func fits(_ w: Double, shown: Bool = false, fs: Double = 16) -> Bool {
            ReaderLayout.sidebarFits(windowWidth: w, sidebarWidth: 220, fontSize: fs, shown: shown)
        }
        #expect(!fits(900))
        #expect(!fits(1120))
        #expect(fits(1140))
        #expect(fits(1600) && fits(2400))
        // Shown, it stays a little longer as the window narrows (no flicker).
        #expect(fits(1115, shown: true))
        #expect(!fits(1115, shown: false))
        #expect(!fits(1100, shown: true))
        // A larger text size needs a wider window.
        #expect(!fits(1440, fs: 20))
        #expect(fits(1480, fs: 20))
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
        #expect(css.contains("--side: max(var(--gutter), 5vw);"))
        #expect(css.contains("--cap: 80rem;"))
        #expect(css.contains("--measure: min(var(--cap), 100vw - 2 * var(--side));"))
        #expect(css.contains("max-width: calc(var(--measure) + var(--gutter) * 2);"))
        #expect(css.contains("--gutter: 28px;"))
        #expect(css.contains("font-size: clamp(calc(var(--fs) * 1px), calc(var(--fs) * (1px + (100vw - 900px) / 3600)), calc(var(--fs) * 1.12px));"))
    }

    /// View ▸ Text Width as the app keeps it: Standard, Wide, or a dragged
    /// width in whole rem, within the range the edge allows.
    @Test func aDraggedWidthIsKeptInWholeRemWithinItsRange() {
        #expect(ReaderLayout.textWidth(nil) == "standard")
        #expect(ReaderLayout.textWidth("wide") == "wide")
        #expect(ReaderLayout.textWidth("standard") == "standard")
        #expect(ReaderLayout.textWidth("62") == "62")
        #expect(ReaderLayout.textWidth("12") == "30")
        #expect(ReaderLayout.textWidth("999") == "200")
        #expect(ReaderLayout.textWidth("narrow") == "standard")
        #expect(ReaderLayout.textWidth(rem: 61.6) == "62")
    }
}
