import Foundation
import Testing
@testable import ReadoutCore

/// When the welcome window shows at launch (`LaunchWelcome`).
@Suite struct LaunchWelcomeTests {
    @Test func aLoginItemLaunchShowsNoWelcomeWindow() {
        // The Apple Event codes, as AE/AERegistry.h has them.
        #expect(LaunchWelcome.launchedAsLogInItem == 0x6C67_6974)   // 'lgit'
        #expect(LaunchWelcome.openApplication == 0x6F61_7070)       // 'oapp'
        #expect(LaunchWelcome.isLoginItemLaunch(eventID: 0x6F61_7070, propData: 0x6C67_6974))
        #expect(!LaunchWelcome.isLoginItemLaunch(eventID: 0x6F61_7070, propData: nil))
        #expect(!LaunchWelcome.isLoginItemLaunch(eventID: 0x6F64_6F63, propData: 0x6C67_6974))   // 'odoc'
        #expect(!LaunchWelcome.isLoginItemLaunch(eventID: nil, propData: nil))
        #expect(LaunchWelcome.shows(openedAtLaunch: false, windowsOpen: false, loginItem: false))
        #expect(!LaunchWelcome.shows(openedAtLaunch: false, windowsOpen: false, loginItem: true))
        #expect(!LaunchWelcome.shows(openedAtLaunch: true, windowsOpen: false, loginItem: false))
        #expect(!LaunchWelcome.shows(openedAtLaunch: false, windowsOpen: true, loginItem: false))
    }
}
