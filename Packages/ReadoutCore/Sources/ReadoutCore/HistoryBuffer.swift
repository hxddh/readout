import Foundation

/// A file's history held in memory while it is open, written to disk at
/// most once every `writeInterval` (and when the window closes or the app
/// quits): an agent streaming a long document in records a version every
/// second, and a whole history file written for each would be most of the
/// work Readout does while it reads.
public struct HistoryBuffer: Sendable {
    /// The shortest time between two writes of one history.
    public static let writeInterval: TimeInterval = 5

    public private(set) var history: DocumentHistory
    /// Recorded since the last write.
    public private(set) var dirty = false
    /// When it was last written (nil: not since it was read).
    public private(set) var lastWrite: Date?

    public init(_ history: DocumentHistory) { self.history = history }

    /// Records `keys` at `date` in memory; true when the history changed.
    @discardableResult
    public mutating func record(_ keys: [BlockKey], at date: Date, limits: DocumentHistory.Limits = .standard) -> Bool {
        let changed = history.record(keys, at: date, limits: limits)
        dirty = dirty || changed
        return changed
    }

    /// When the history is next to be written: nil when nothing waits to
    /// be, else `now` or `writeInterval` after the last write, whichever is later.
    public func writeDue(now: Date) -> Date? {
        guard dirty else { return nil }
        guard let lastWrite else { return now }
        return max(now, lastWrite.addingTimeInterval(Self.writeInterval))
    }

    /// The history was written at `date`.
    public mutating func wrote(at date: Date) {
        dirty = false
        lastWrite = date
    }
}
