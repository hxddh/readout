import Foundation

/// The changes inbox: every document waiting for the reader, open or not,
/// newest first. An open document waits by the rule of its tab's dot
/// (`CrossDocument.needsAttention`); a file in an agent folder that is not
/// open waits when it changed after its reading state was last saved, was
/// closed with unread changes left, or was never read.
public enum ChangesInbox {
    public struct Entry: Equatable, Sendable {
        public let path: String
        /// Its unread changes, when open; nil for a file not open (what
        /// changed shows when it opens).
        public let unread: Int?
        public let modified: Date
    }

    /// `open`: the open documents; `recent`: the files agents wrote in the
    /// watched folders; `lastRead`: when a file not open had its reading
    /// state last saved and the unread changes it had then, nil when never
    /// read. A file open and recent counts once, as open.
    public static func entries(open: [(path: String, unread: Int, lookedAt: Bool, modified: Date)],
                               recent: [(path: String, modified: Date)],
                               lastRead: (String) -> (at: Date, unread: Int)?) -> [Entry] {
        var out = open.filter { CrossDocument.needsAttention(unread: $0.unread, lookedAt: $0.lookedAt) }
            .map { Entry(path: $0.path, unread: $0.unread, modified: $0.modified) }
        let opened = Set(open.map(\.path))
        for r in recent where !opened.contains(r.path) {
            if let read = lastRead(r.path), read.at >= r.modified, read.unread == 0 { continue }
            out.append(Entry(path: r.path, unread: nil, modified: r.modified))
        }
        return out.sorted { $0.modified > $1.modified }
    }
}
