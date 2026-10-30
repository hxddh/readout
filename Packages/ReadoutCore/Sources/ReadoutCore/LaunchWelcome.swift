import Foundation

/// The welcome window at launch.
public enum LaunchWelcome {
    /// `keyAELaunchedAsLogInItem` ('lgit'): the Open Application event's
    /// `keyAEPropData` ('prdt') when Readout was opened as a login item
    /// (System Settings ▸ General ▸ Login Items).
    public static let launchedAsLogInItem: UInt32 = fourCC("lgit")
    public static let openApplication: UInt32 = fourCC("oapp")

    /// Whether the launch event (`eventID`, its `keyAEPropData` value) says
    /// Readout was opened as a login item.
    public static func isLoginItemLaunch(eventID: UInt32?, propData: UInt32?) -> Bool {
        eventID == openApplication && propData == launchedAsLogInItem
    }

    /// The welcome window shows at launch when nothing else did (no file
    /// opened, no window restored), unless Readout was opened as a login
    /// item: then it waits quietly for what agents write.
    public static func shows(openedAtLaunch: Bool, windowsOpen: Bool, loginItem: Bool) -> Bool {
        !openedAtLaunch && !windowsOpen && !loginItem
    }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}
