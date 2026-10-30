import Foundation

/// What macOS adds to an Edit menu on its own (AutoFill, Start Dictation,
/// Emoji & Symbols): left out of a read-only reader's menu.
public enum SystemMenuItems {
    public struct Item: Sendable {
        public var action: String?
        public var submenuActions: [String]
        public var isSeparator: Bool
        public init(action: String?, submenuActions: [String] = [], isSeparator: Bool = false) {
            self.action = action
            self.submenuActions = submenuActions
            self.isSeparator = isSeparator
        }
    }

    static func isAddedByMacOS(_ i: Item) -> Bool {
        let insert = { (a: String) in a.hasPrefix("_handleInsertFrom") }
        if let a = i.action, a == "startDictation:" || a == "orderFrontCharacterPalette:" || insert(a) { return true }
        return !i.submenuActions.isEmpty && i.submenuActions.allSatisfy(insert)
    }

    /// The indices to remove, last first: the items macOS added, and the
    /// separators that leaves at the end or doubled.
    public static func removals(_ items: [Item]) -> [Int] {
        var out: [Int] = []
        var lastKeptIsSeparator = true   // nothing before the first item
        for (n, i) in items.enumerated() {
            if isAddedByMacOS(i) || (i.isSeparator && lastKeptIsSeparator) {
                out.append(n)
            } else {
                lastKeptIsSeparator = i.isSeparator
            }
        }
        // A separator left last.
        if let last = items.indices.last(where: { !out.contains($0) }), items[last].isSeparator { out.append(last) }
        return out.sorted(by: >)
    }
}
