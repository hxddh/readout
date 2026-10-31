import Foundation

/// The versions of one file Readout has seen, oldest first: what the
/// timeline steps through and what two versions are compared from.
///
/// A version is its blocks' keys. A block unchanged between versions is kept
/// once (`pool`), so a version costs what changed in it plus an index per
/// block. Writes an agent streams in come seconds apart: a version less than
/// `settle` after the one before it replaces that one, so the timeline holds
/// the states the file rested in, not every keystroke of a write.
public struct DocumentHistory: Codable, Sendable, Equatable {
    public struct Version: Codable, Sendable, Equatable {
        /// When the file was seen in this state (the last time, for a version a later write replaced).
        public var at: Date
        /// Its blocks, as indices into `pool`.
        public var blocks: [Int]
    }

    /// How old a version may get, how many are kept, and how much block text
    /// all of them may hold together: past any of them the oldest go first.
    /// The newest version is always kept.
    public struct Limits: Sendable, Equatable {
        public var maxAge: TimeInterval
        public var maxVersions: Int
        public var maxTextBytes: Int
        /// Versions closer together than this are one (the later replaces the earlier).
        public var settle: TimeInterval

        public init(maxAge: TimeInterval, maxVersions: Int, maxTextBytes: Int, settle: TimeInterval) {
            self.maxAge = maxAge
            self.maxVersions = maxVersions
            self.maxTextBytes = maxTextBytes
            self.settle = settle
        }

        /// 30 days, 200 versions, 8 MB of block text, 10 s.
        public static let standard = Limits(maxAge: 30 * 86400, maxVersions: 200, maxTextBytes: 8 << 20, settle: 10)
    }

    public private(set) var pool: [BlockKey] = []
    public private(set) var versions: [Version] = []

    public init() {}

    public var isEmpty: Bool { versions.isEmpty }

    /// The blocks of version `i`.
    public func keys(of i: Int) -> [BlockKey] { versions[i].blocks.map { pool[$0] } }

    /// Version `i` as Markdown again: its blocks' sources, a blank line
    /// between them (what opening it shows; link definitions, kept with no
    /// block, are not in it).
    public func markdown(of i: Int) -> String {
        // (Front matter keeps only its body as source: its fences put back.)
        keys(of: i).map { $0.kind == .frontMatter ? "---\n" + $0.wholeSource + "\n---" : $0.wholeSource }
            .joined(separator: "\n\n") + "\n"
    }

    /// The newest version's blocks, or nil when there is none.
    public var latest: [BlockKey]? { versions.isEmpty ? nil : keys(of: versions.count - 1) }

    /// How many blocks `to` has that `from` lacks, and the other way round
    /// (a changed block counts once each way): what a timeline entry says
    /// about a version against the current one.
    public static func difference(from: [BlockKey], to: [BlockKey]) -> (added: Int, removed: Int) {
        var left: [UInt64: Int] = [:]
        for k in from { left[k.fingerprint, default: 0] += 1 }
        var added = 0
        for k in to {
            if let n = left[k.fingerprint], n > 0 { left[k.fingerprint] = n - 1 } else { added += 1 }
        }
        return (added, left.values.reduce(0, +))
    }

    /// The versions to compare `current` with, newest first: every one but
    /// those that are `current` already.
    public func earlier(than current: [BlockKey]) -> [Int] {
        versions.indices.reversed().filter { keys(of: $0) != current }
    }

    /// Records the file as `keys` at `date`, then applies `limits`. False
    /// (nothing changes) when it is the newest version already.
    @discardableResult
    public mutating func record(_ keys: [BlockKey], at date: Date, limits: Limits = .standard) -> Bool {
        let keys = keys.map(Self.stored)
        if let last = latest, last == keys { return false }
        var index = Self.index(pool)
        let blocks = keys.map { key -> Int in
            if let i = index[key.fingerprint]?.first(where: { pool[$0] == key }) { return i }
            pool.append(key)
            index[key.fingerprint, default: []].append(pool.count - 1)
            return pool.count - 1
        }
        let version = Version(at: date, blocks: blocks)
        if versions.count > 1, let last = versions.last, date.timeIntervalSince(last.at) < limits.settle {
            // Still being written: the state it settles in is the version.
            // (Not the first version seen: that is what was there before the write.)
            versions[versions.count - 1] = version
        } else {
            versions.append(version)
        }
        trim(now: date, limits: limits)
        return true
    }

    /// Drops the versions `limits` no longer allows, oldest first, and the blocks no version uses.
    public mutating func trim(now: Date, limits: Limits) {
        guard !versions.isEmpty else { return }
        var drop = 0
        while versions.count - drop > 1, now.timeIntervalSince(versions[drop].at) > limits.maxAge { drop += 1 }
        drop = max(drop, versions.count - max(limits.maxVersions, 1))
        if drop > 0 { versions.removeFirst(drop) }
        compact()
        while versions.count > 1, textBytes > limits.maxTextBytes {
            versions.removeFirst()
            compact()
        }
    }

    /// The block text all versions hold together.
    public var textBytes: Int { pool.reduce(0) { $0 + $1.wholeText.utf8.count + $1.source.utf8.count } }

    /// The pool without the blocks no version uses, the versions renumbered.
    private mutating func compact() {
        var used = [Int](repeating: -1, count: pool.count)
        var kept: [BlockKey] = []
        for v in versions { for i in v.blocks where used[i] < 0 { used[i] = kept.count; kept.append(pool[i]) } }
        guard kept.count < pool.count else { return }
        for v in versions.indices { versions[v].blocks = versions[v].blocks.map { used[$0] } }
        pool = kept
    }

    private static func index(_ pool: [BlockKey]) -> [UInt64: [Int]] {
        var index: [UInt64: [Int]] = [:]
        for (i, k) in pool.enumerated() { index[k.fingerprint, default: []].append(i) }
        return index
    }

    /// A key as a version holds it: a block of the file, never one of an unread deletion.
    private static func stored(_ key: BlockKey) -> BlockKey { key.removed == nil ? key : key.with(removed: false) }

    /// The history from its file's bytes; empty when there are none or they do not decode.
    public static func decode(_ data: Data?) -> DocumentHistory {
        guard let data, let h = try? JSONDecoder().decode(DocumentHistory.self, from: data),
              h.versions.allSatisfy({ $0.blocks.allSatisfy(h.pool.indices.contains) }) else { return DocumentHistory() }
        return h
    }
}
