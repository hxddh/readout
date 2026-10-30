import Foundation
import Testing
@testable import ReadoutCore

/// The Edit menu without what macOS adds (`SystemMenuItems`).
@Suite struct SystemMenuItemsTests {
    @Test func theEditMenuLosesWhatMacOSAdds() {
        typealias I = SystemMenuItems.Item
        // As CI's menus.json shows the Edit menu of 3.8 on macOS 26.
        let items: [I] = [
            I(action: "undo:"), I(action: "redo:"), I(action: nil, isSeparator: true),
            I(action: "copy:"), I(action: nil, isSeparator: true),
            I(action: "submenuAction:", submenuActions: ["showFind:", "findNext:"]),
            I(action: "submenuAction:", submenuActions: ["startSpeaking:", "stopSpeaking:"]),
            I(action: nil, isSeparator: true),
            I(action: "submenuAction:", submenuActions: ["_handleInsertFromContactsCommand:", "_handleInsertFromPasswordsCommand:", "_handleInsertFromCreditCardsCommand:"]),
            I(action: "startDictation:"), I(action: "startDictation:"),
            I(action: "orderFrontCharacterPalette:"), I(action: "orderFrontCharacterPalette:"),
        ]
        let removed = SystemMenuItems.removals(items)
        #expect(removed == [12, 11, 10, 9, 8, 7])
        var kept = items
        for n in removed { kept.remove(at: n) }
        #expect(kept.last?.submenuActions == ["startSpeaking:", "stopSpeaking:"])
        // Nothing added: nothing removed. A doubled separator goes.
        #expect(SystemMenuItems.removals(Array(items.prefix(7))).isEmpty)
        #expect(SystemMenuItems.removals([I(action: "a:"), I(action: nil, isSeparator: true), I(action: nil, isSeparator: true), I(action: "b:")]) == [2])
    }
}
