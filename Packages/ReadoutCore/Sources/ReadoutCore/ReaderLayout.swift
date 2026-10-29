import Foundation

/// The reader page's column, as reader.css lays it out, and whether a window
/// has room for the outline beside it.
///
/// The page's text grows with its width (html's font-size: the reader's size
/// up to 900 px, 1.25 times it from 1800 px, smoothly between) and its column
/// is 35 em of that text, or the width less its gutters. A wide window shows
/// the outline (the sidebar) by itself once the page beside it still has
/// comfortable margins around the column, and hides it once it no longer
/// would. The reader's own Show/Hide Sidebar holds in that window
/// (`SidebarFit.choice`).
public enum ReaderLayout {
    /// reader.css: --gutter.
    public static let gutter = 28.0

    /// The page's root font size (px) at a page `width` (px), the reader's
    /// text size being `fontSize` (Actual Size: 16).
    public static func rootSize(width: Double, fontSize: Double) -> Double {
        fontSize * min(1.25, max(1, 1 + (width - 900) / 3600))
    }

    /// The text column's width (px) in a page `width` px wide.
    public static func column(width: Double, fontSize: Double) -> Double {
        min(35 * rootSize(width: width, fontSize: fontSize), width - 2 * gutter)
    }

    /// The margin each side of the column the page keeps beside the outline:
    /// 6 rem of its text (96 px at Actual Size), so the outline never crowds
    /// the column in.
    public static func comfortableMargin(width: Double, fontSize: Double) -> Double {
        6 * rootSize(width: width, fontSize: fontSize)
    }

    /// Whether a window `windowWidth` px wide (its content) has room for the
    /// outline, `sidebarWidth` px, and the page beside it. `shown`: the outline
    /// is shown now; it then stays until the margins are under the comfortable
    /// one, and comes only once they are 16 px over it, so a window resized
    /// across the point does not flicker between the two.
    public static func sidebarFits(windowWidth: Double, sidebarWidth: Double, fontSize: Double, shown: Bool) -> Bool {
        let page = windowWidth - sidebarWidth
        guard page > 0 else { return false }
        let spare = (page - column(width: page, fontSize: fontSize)) / 2
        return spare >= comfortableMargin(width: page, fontSize: fontSize) + (shown ? 0 : 16)
    }
}

/// The outline's state in one window: shown by the window's width
/// (`ReaderLayout.sidebarFits`) unless the reader chose otherwise there.
///
/// A Show/Hide Sidebar against what the width calls for holds in that window
/// (hidden in a wide window, it stays hidden however wide the window gets);
/// one that agrees with it gives the window back to its width. The choice is
/// the window's own and is not kept: a new window starts from its width.
public struct SidebarFit: Equatable, Sendable {
    /// The reader's choice in this window; nil: the width decides.
    public private(set) var choice: Bool?

    public init() {}

    /// Whether the outline shows, the width calling for `fits`.
    public func shown(fits: Bool) -> Bool { choice ?? fits }

    /// The reader showed (`show` true) or hid the outline, the width calling for `fits`.
    public mutating func toggled(to show: Bool, fits: Bool) {
        choice = show == fits ? nil : show
    }
}
