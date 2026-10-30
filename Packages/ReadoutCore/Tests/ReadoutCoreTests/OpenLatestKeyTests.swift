import Foundation
import Testing
@testable import ReadoutCore

/// The Open Latest Agent File shortcut (`OpenLatestKey`).
@Suite struct OpenLatestKeyTests {
    @Test func theShortcutIsAToggle() {
        // Nothing stored, or any other value (4.0: the keys 3.8 offered, ⌥⌘R
        // and ⌃⌥R, are no longer kept): ⌃⌥⌘R, on.
        for stored in [nil, "bogus", "optCmdR", "ctrlOptR", "ctrlOptCmdR"] {
            let key = OpenLatestKey(stored: stored)
            #expect(key == .ctrlOptCmdR && key.isGlobal && key.title == "⌃⌥⌘R")
            #expect(key.turned(on: true) == key)
            #expect(key.turned(on: false) == OpenLatestKey.none)
        }
        // Off (stored "none"): not global, but the menu still has ⌃⌥⌘R; on again gives ⌃⌥⌘R.
        let off = OpenLatestKey(stored: "none")
        #expect(!off.isGlobal && off.title == "⌃⌥⌘R" && off.modifiers == [.control, .option, .command])
        #expect(off.turned(on: true) == .ctrlOptCmdR)
        #expect(OpenLatestKey.allCases == [.ctrlOptCmdR, .none])
    }
}
