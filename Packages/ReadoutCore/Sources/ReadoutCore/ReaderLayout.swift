import Foundation

/// The reader page's column, as reader.css lays it out, and whether a window
/// has room for the outline beside it.
///
/// The page's text grows a little with its width (html's font-size: the
/// reader's size up to 900 px, 1.12 times it from 1332 px, smoothly between)
/// and its column follows the page: the width less a margin each side (5% of
/// it, the gutter at least), up to `cap` rem of the text (View ▸ Text Width:
/// Standard 80, Wide no limit). A window shows the outline (the sidebar) by
/// itself once the page beside it still has a column of 50 rem, and hides it
/// once it no longer would. The reader's own Show/Hide Sidebar holds in that
/// window (`SidebarFit.choice`).
public enum ReaderLayout {
    /// reader.css: --gutter.
    public static let gutter = 28.0

    /// reader.css: --cap (rem) at View ▸ Text Width ▸ Standard and Wide.
    public static let standardCap = 80.0
    public static let wideCap = Double.infinity

    /// The narrowest and widest column (rem) the reader can drag the
    /// column's edge to.
    public static let customCapRange = 30.0...200.0

    /// View ▸ Text Width as the app keeps it: "standard", "wide", or the
    /// column's width in rem (whole), dragged at its edge. Anything else is
    /// Standard.
    public static func textWidth(_ stored: String?) -> String {
        guard let stored else { return "standard" }
        if stored == "wide" { return stored }
        if let rem = Double(stored), rem.isFinite { return textWidth(rem: rem) }
        return "standard"
    }

    /// The column dragged to `rem` wide, as the app keeps it.
    public static func textWidth(rem: Double) -> String {
        String(Int(min(max(rem, customCapRange.lowerBound), customCapRange.upperBound).rounded()))
    }

    /// The narrowest column (rem) the page keeps beside the outline.
    public static let columnBesideOutline = 50.0

    /// The page's root font size (px) at a page `width` (px), the reader's
    /// text size being `fontSize` (Actual Size: 16).
    public static func rootSize(width: Double, fontSize: Double) -> Double {
        fontSize * min(1.12, max(1, 1 + (width - 900) / 3600))
    }

    /// reader.css: --side, the margin each side of the column in a page `width` px wide.
    public static func side(width: Double) -> Double {
        max(gutter, 0.05 * width)
    }

    /// The text column's width (px) in a page `width` px wide, the column
    /// being at most `cap` rem.
    public static func column(width: Double, fontSize: Double, cap: Double = standardCap) -> Double {
        min(cap * rootSize(width: width, fontSize: fontSize), width - 2 * side(width: width))
    }

    /// Whether a window `windowWidth` px wide (its content) has room for the
    /// outline, `sidebarWidth` px, and a column of `columnBesideOutline` rem
    /// beside it. `shown`: the outline is shown now; it then stays until the
    /// column is narrower than that, and comes only once it is 16 px wider,
    /// so a window resized across the point does not flicker between the two.
    public static func sidebarFits(windowWidth: Double, sidebarWidth: Double, fontSize: Double, shown: Bool) -> Bool {
        let page = windowWidth - sidebarWidth
        guard page > 0 else { return false }
        let wanted = columnBesideOutline * rootSize(width: page, fontSize: fontSize)
        return column(width: page, fontSize: fontSize, cap: .infinity) >= wanted + (shown ? 0 : 16)
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
