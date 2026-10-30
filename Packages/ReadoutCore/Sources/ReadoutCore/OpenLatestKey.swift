import Foundation

/// File ▸ Open Latest Agent File's key, ⌃⌥⌘R, stored as `hotKey`. Settings
/// turns it on or off; on, it works from any app. Any other stored value (the
/// keys 3.8 offered, ⌥⌘R and ⌃⌥R) reads as the default, on.
public enum OpenLatestKey: String, CaseIterable, Sendable {
    case ctrlOptCmdR, none

    /// The stored value; ⌃⌥⌘R when there is none (not ⌥⌘R, which Safari and Xcode use).
    public init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .ctrlOptCmdR }

    /// Works from any app (registered system-wide).
    public var isGlobal: Bool { self != .none }

    /// Settings' toggle.
    public func turned(on: Bool) -> Self { on ? .ctrlOptCmdR : .none }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let command = Modifiers(rawValue: 4)
    }

    /// The modifiers, with R: global, or with that off inside Readout only.
    public var modifiers: Modifiers { [.control, .option, .command] }

    /// As the menu writes it.
    public var title: String { "⌃⌥⌘R" }
}
