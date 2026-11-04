import Foundation

/// How long Readout took for the last opens and live updates, kept in
/// memory for Help ▸ Performance: what a reader can measure on their own
/// Mac, which no test machine is.
public struct PerfLog: Sendable, Equatable {
    /// One open: the window asked for, to its first patch applied by the
    /// page and to its first patch on screen.
    public struct Open: Sendable, Equatable {
        public var file: String
        public var applied: TimeInterval
        public var painted: TimeInterval?
        public init(file: String, applied: TimeInterval, painted: TimeInterval? = nil) {
            self.file = file
            self.applied = applied
            self.painted = painted
        }
    }

    /// How many opens, and updates, are kept: the newest.
    public static let kept = 10

    public private(set) var opens: [Open] = []
    /// Live updates: a change seen on disk to the page's patch applied.
    public private(set) var updates: [TimeInterval] = []

    public init() {}

    public mutating func opened(_ file: String, applied: TimeInterval) {
        opens.append(Open(file: file, applied: applied))
        if opens.count > Self.kept { opens.removeFirst(opens.count - Self.kept) }
    }

    /// The newest open of `file` without a paint time gets `seconds`.
    public mutating func painted(_ file: String, seconds: TimeInterval) {
        guard let i = opens.lastIndex(where: { $0.file == file && $0.painted == nil }) else { return }
        opens[i].painted = seconds
    }

    public mutating func updated(seconds: TimeInterval) {
        updates.append(seconds)
        if updates.count > Self.kept { updates.removeFirst(updates.count - Self.kept) }
    }

    /// Milliseconds, whole.
    public static func ms(_ seconds: TimeInterval) -> String { "\(Int((seconds * 1000).rounded())) ms" }

    /// The median of `values` (nil when there are none).
    public static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
