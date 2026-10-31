import Foundation

/// What is kept per file between launches (the app's BaselineStore): the
/// version the reader last caught up with and the reading position.
public struct ReadingRecord: Codable, Sendable, Equatable {
    public var baseline: [BlockKey]
    public var topBlockIndex: Int?
    public var topOffset: Double?
    /// First 120 characters of the top block's normalized text. Block
    /// indices shift as agents edit; the excerpt survives that.
    public var topExcerpt: String?
    public var savedAt: Date

    public init(baseline: [BlockKey], topBlockIndex: Int?, topOffset: Double?, topExcerpt: String?, savedAt: Date) {
        self.baseline = baseline
        self.topBlockIndex = topBlockIndex
        self.topOffset = topOffset
        self.topExcerpt = topExcerpt
        self.savedAt = savedAt
    }

    /// The reading position alone, written on every settled scroll to a small
    /// file of its own (the record, which can be large, only when the baseline changes).
    public struct Position: Codable, Sendable, Equatable {
        public var topBlockIndex: Int?
        public var topOffset: Double?
        public var topExcerpt: String?
        public var savedAt: Date
        /// The unread changes left when it was saved (the changes inbox lists
        /// a file not open that still has some). Nil in a position saved
        /// without it.
        public var unread: Int?

        public init(_ record: ReadingRecord, unread: Int? = nil) {
            topBlockIndex = record.topBlockIndex
            topOffset = record.topOffset
            topExcerpt = record.topExcerpt
            savedAt = record.savedAt
            self.unread = unread
        }
    }

    /// The record from its file's bytes, with the position from its own file
    /// when that was saved since. Nil when there is no record, or it is not
    /// in the format 4.0 writes (a baseline saved before 3.6 kept no block
    /// sources): then the file opens as if it were new, and the next save
    /// replaces both files. Never part of an old record.
    public static func decode(record: Data?, position: Data?) -> ReadingRecord? {
        guard let record, var r = try? JSONDecoder().decode(ReadingRecord.self, from: record) else { return nil }
        if let position, let p = try? JSONDecoder().decode(Position.self, from: position), p.savedAt >= r.savedAt {
            r.topBlockIndex = p.topBlockIndex
            r.topOffset = p.topOffset
            r.topExcerpt = p.topExcerpt
            r.savedAt = p.savedAt
        }
        return r
    }
}
