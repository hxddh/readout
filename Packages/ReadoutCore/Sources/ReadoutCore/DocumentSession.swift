import Foundation

public enum MarkKind: String, Codable, Sendable {
    case inserted, modified, state
}

/// Message sent to the web renderer. A `reset` payload replaces the whole document;
/// otherwise `ops` are applied in order.
public struct RenderPatch: Codable, Sendable {
    public struct Op: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case insert, replace, remove }
        /// For replace: content (marked), state (checkbox only), silent (no mark).
        public enum Change: String, Codable, Sendable { case content, state, silent }
        public let op: Kind
        public let slot: Int
        public var after: Int?
        public var html: String?
        public var change: Change?
        public var kind: BlockKind?
        public var cjk: Bool?
        public var anchor: String?
    }

    public struct Mark: Codable, Sendable, Equatable {
        public let slot: Int
        public let kind: MarkKind
        /// For a modified block: what changed since it was read, as HTML
        /// (`WordDiff.html`); "" when the earlier text was not kept.
        public var diff: String? = nil
    }

    public struct Deletion: Codable, Sendable, Equatable {
        public let id: Int
        /// Slot of the block the deletion sits after; 0 = top of the document.
        public var after: Int
        public var count: Int
        /// The removed text; sent once per deletion (nil in later patches, which
        /// the page fills from what it was sent before).
        public var preview: String?
    }

    public var version: Int
    public var reset: Bool
    public var rewrite: Bool
    public var ops: [Op]
    public var marks: [Mark]
    public var deletions: [Deletion]
    public var toc: [TocEntry]
    public var tasks: TaskStats
    public var title: String?
}

/// Per-open-file state: slot identities, unread change marks and the reading baseline.
public final class DocumentSession {
    /// How much removed text one deletion marker carries before it notes the rest.
    static let previewBytes = 200_000
    static let previewMore = "\n\n…"

    /// `text` cut to the preview bound on a character boundary, ending with the ellipsis when cut.
    static func bounded(_ text: String) -> String {
        guard text.utf8.count > previewBytes else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: previewBytes - previewMore.utf8.count)
        while String.Index(end, within: text) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end]) + previewMore
    }
    public private(set) var blocks: [Block] = []
    public private(set) var version = 0
    public private(set) var title: String?
    private var nextSlot = 1
    private var nextDeletionID = 1
    public private(set) var marks: [Int: MarkKind] = [:]
    public private(set) var deletions: [RenderPatch.Deletion] = []
    /// The version the reader has fully caught up with. Persist this between launches.
    public private(set) var baseline: [BlockKey] = []
    /// For each block marked modified: its text when last read (nil: not kept), and the comparison.
    private var readText: [Int: String?] = [:]
    /// What is known of the read block when an older baseline kept only the
    /// start of its text: that start and the block's fingerprint.
    private var readKey: [Int: BlockKey] = [:]
    /// Task states of those blocks when last read (known after a live update, not after a relaunch).
    private var readTasks: [Int: [Bool]] = [:]
    private var diffs: [Int: String] = [:]
    /// Comparisons and deletion texts the page already has: a patch carries
    /// each one once, not again with every later patch.
    private var sentDiffs: Set<Int> = []
    private var sentDeletions: Set<Int> = []

    public init() {}

    public var unreadCount: Int { marks.count + deletions.count }

    // MARK: Loading

    /// First render. When a persisted baseline is supplied, changes made since then are marked.
    public func load(_ doc: ParsedDocument, baseline persisted: [BlockKey]? = nil) -> RenderPatch {
        blocks = doc.blocks
        title = doc.title
        for i in blocks.indices { blocks[i].slot = allocSlot() }
        marks = [:]; deletions = []; readText = [:]; readKey = [:]; readTasks = [:]; diffs = [:]; sentDiffs = []; sentDeletions = []
        let keys = blocks.map(BlockKey.init)
        if let persisted, persisted != keys {
            let d = Differ.diff(old: persisted, new: keys)
            if !d.rewrite { applyMarks(d, oldKeys: persisted, oldSlotForIndex: { _ in nil }, oldTexts: persisted.map(\.wholeText)) }
            baseline = persisted
            if marks.isEmpty && deletions.isEmpty { baseline = keys }
        } else {
            baseline = keys
        }
        return fullPayload(rewrite: false)
    }

    public func fullPayload(rewrite: Bool) -> RenderPatch {
        version += 1
        var ops: [RenderPatch.Op] = []
        var prev = 0
        for b in blocks {
            ops.append(.init(op: .insert, slot: b.slot, after: prev, html: b.html, change: nil,
                             kind: b.kind, cjk: b.cjk, anchor: b.anchor))
            prev = b.slot
        }
        return payload(ops: ops, reset: true, rewrite: rewrite)
    }

    // MARK: Updating

    /// Applies a new parse. Returns nil when nothing visible changed.
    public func update(_ doc: ParsedDocument) -> RenderPatch? {
        let oldBlocks = blocks
        let oldKeys = oldBlocks.map(BlockKey.init)
        var newBlocks = doc.blocks
        let newKeys = newBlocks.map(BlockKey.init)
        let d = Differ.diff(old: oldKeys, new: newKeys)
        title = doc.title

        if d.rewrite {
            for i in newBlocks.indices { newBlocks[i].slot = allocSlot() }
            blocks = newBlocks
            marks = [:]; deletions = []; readText = [:]; readKey = [:]; readTasks = [:]; diffs = [:]; sentDiffs = []; sentDeletions = []
            baseline = newKeys
            return fullPayload(rewrite: true)
        }

        // Assign slots.
        for (n, c) in d.changes.enumerated() {
            switch c {
            case let .equal(o), let .modified(o): newBlocks[n].slot = oldBlocks[o].slot
            case .inserted: newBlocks[n].slot = allocSlot()
            }
        }

        // Build ops: removals first, then inserts/replaces in document order.
        var ops: [RenderPatch.Op] = []
        for o in d.removed { ops.append(.init(op: .remove, slot: oldBlocks[o].slot)) }
        var prev = 0
        for (n, c) in d.changes.enumerated() {
            let b = newBlocks[n]
            switch c {
            case let .equal(o):
                let ob = oldBlocks[o]
                if ob.taskState != b.taskState {
                    ops.append(.init(op: .replace, slot: b.slot, html: b.html, change: .state, kind: b.kind, cjk: b.cjk, anchor: b.anchor))
                } else if ob.html != b.html || ob.cjk != b.cjk {
                    ops.append(.init(op: .replace, slot: b.slot, html: b.html, change: .silent, kind: b.kind, cjk: b.cjk, anchor: b.anchor))
                }
            case .modified:
                ops.append(.init(op: .replace, slot: b.slot, html: b.html, change: .content, kind: b.kind, cjk: b.cjk, anchor: b.anchor))
            case .inserted:
                ops.append(.init(op: .insert, slot: b.slot, after: prev, html: b.html, kind: b.kind, cjk: b.cjk, anchor: b.anchor))
            }
            prev = b.slot
        }

        // Order changes are impossible here (no moves), so inserts by `after` reproduce the order.
        let oldSlotForIndex: (Int) -> Int? = { oldBlocks[$0].slot }
        blocks = newBlocks
        applyMarks(d, oldKeys: oldKeys, oldSlotForIndex: oldSlotForIndex, oldBlocks: oldBlocks,
                   oldTexts: oldBlocks.map(\.text))
        if marks.isEmpty && deletions.isEmpty { baseline = newKeys }
        if ops.isEmpty { return nil }
        return payload(ops: ops, reset: false, rewrite: false)
    }

    private func applyMarks(_ d: DiffResult, oldKeys: [BlockKey], oldSlotForIndex: (Int) -> Int?,
                            oldBlocks: [Block] = [], oldTexts: [String?]) {
        let newSlots = Set(blocks.map(\.slot))
        // One comparison budget for the update: many large edited blocks cost
        // what one does, and those past it are shown replaced whole.
        var budget = WordDiff.maxWork
        for (n, c) in d.changes.enumerated() {
            let slot = blocks[n].slot
            switch c {
            case .inserted:
                marks[slot] = .inserted
            case let .modified(o):
                if marks[slot] != .inserted {
                    // Compared with the text as last read: the first change since then keeps it.
                    if marks[slot] != .modified {
                        readText[slot] = oldTexts[o]
                        if oldTexts[o] == nil { readKey[slot] = oldKeys[o] }
                        // Unless a checkbox change since reading already recorded them.
                        if readTasks[slot] == nil, !oldBlocks.isEmpty { readTasks[slot] = oldBlocks[o].taskState }
                    }
                    let reverted = (readText[slot] ?? nil).map { $0 == blocks[n].text }
                        ?? (readKey[slot].map { $0.fingerprint == blocks[n].fingerprint } ?? false)
                    if reverted {
                        // Changed back to the text that was read: no comparison to show,
                        // but a checkbox that differs from what was read is still news.
                        let readState = readTasks[slot] ?? (oldBlocks.isEmpty ? nil : oldBlocks[o].taskState)
                        marks[slot] = readState.map { $0 != blocks[n].taskState } == true ? .state : nil
                        readText[slot] = nil; readKey[slot] = nil; diffs[slot] = nil
                        // A state mark keeps the checkboxes as read, so unticking clears it.
                        readTasks[slot] = marks[slot] == .state ? readState : nil
                    } else if let read = readText[slot] ?? nil {
                        marks[slot] = .modified
                        diffs[slot] = WordDiff.html(old: read, new: blocks[n].text, budget: &budget)
                        sentDiffs.remove(slot)
                    } else {
                        marks[slot] = .modified
                        diffs[slot] = ""
                        sentDiffs.remove(slot)
                    }
                }
            case let .equal(o):
                if !oldBlocks.isEmpty, oldBlocks[o].taskState != blocks[n].taskState, marks[slot] == nil {
                    marks[slot] = .state
                    readTasks[slot] = oldBlocks[o].taskState   // the checkboxes as read
                } else if marks[slot] == .state, let read = readTasks[slot], read == blocks[n].taskState {
                    // Ticked and unticked again before it was read: nothing new.
                    marks[slot] = nil; readTasks[slot] = nil
                }
            }
        }

        // Where each removed old block sat, expressed as the nearest preceding surviving slot.
        var oldToNewSlot: [Int: Int] = [:]  // old index -> surviving slot
        for (n, c) in d.changes.enumerated() {
            switch c {
            case let .equal(o), let .modified(o): oldToNewSlot[o] = blocks[n].slot
            case .inserted: break
            }
        }
        func anchorBefore(_ oldIndex: Int) -> Int {
            var i = oldIndex - 1
            while i >= 0 { if let s = oldToNewSlot[i] { return s }; i -= 1 }
            return 0
        }

        var newDeletions: [Int: RenderPatch.Deletion] = [:]  // keyed by anchor slot
        for o in d.removed {
            if let s = oldSlotForIndex(o), marks[s] == .inserted {
                // Inserted and removed before it was read: nothing to report.
                marks[s] = nil
                continue
            }
            // The whole removed text as last read (what is kept of it, for an older baseline).
            // An unread edit is never shown as what was removed: when only the start of
            // the read text is known (an older baseline), that start is shown, marked as cut.
            let lastRead: String? = oldSlotForIndex(o).flatMap { slot -> String? in
                guard marks[slot] == .modified else { return nil }
                if let text = readText[slot] ?? nil { return text }
                return readKey[slot].map { $0.text + " …" }
            }
            if let s = oldSlotForIndex(o) { marks[s] = nil }
            let after = anchorBefore(o)
            let preview = Self.bounded(lastRead ?? oldTexts[o] ?? oldKeys[o].text)
            if var existing = newDeletions[after] {
                existing.count += 1
                // Grouped removals keep every block up to a bound; past it the
                // preview says that more was removed instead of dropping blocks silently.
                var text = existing.preview ?? ""
                if text.utf8.count + preview.utf8.count + 2 <= Self.previewBytes {
                    text += "\n\n" + preview
                } else if !text.hasSuffix(Self.previewMore) {
                    text += Self.previewMore
                }
                existing.preview = text
                newDeletions[after] = existing
            } else {
                newDeletions[after] = .init(id: 0, after: after, count: 1, preview: preview)
            }
        }

        // Re-anchor existing deletion marks whose anchor block disappeared.
        var reanchored: [RenderPatch.Deletion] = []
        for var del in deletions {
            if del.after != 0 && !newSlots.contains(del.after) {
                if let oldIndex = oldBlocks.firstIndex(where: { $0.slot == del.after }) {
                    del.after = anchorBefore(oldIndex)
                } else {
                    del.after = 0
                }
            }
            reanchored.append(del)
        }
        for (_, var del) in newDeletions.sorted(by: { $0.key < $1.key }) {
            del = .init(id: allocDeletionID(), after: del.after, count: del.count, preview: del.preview)
            reanchored.append(del)
        }
        deletions = reanchored
        marks = marks.filter { newSlots.contains($0.key) }
        readText = readText.filter { marks[$0.key] == .modified }
        readKey = readKey.filter { marks[$0.key] == .modified }
        readTasks = readTasks.filter { marks[$0.key] == .modified || marks[$0.key] == .state }
        diffs = diffs.filter { marks[$0.key] == .modified }
    }

    // MARK: Reading

    public func markRead(slots: [Int], deletionIDs: [Int]) {
        for s in slots { marks[s] = nil; readText[s] = nil; readKey[s] = nil; readTasks[s] = nil; diffs[s] = nil }
        let ids = Set(deletionIDs)
        deletions.removeAll { ids.contains($0.id) }
        if marks.isEmpty && deletions.isEmpty { baseline = blocks.map(BlockKey.init) }
    }

    public func markAllRead() {
        marks = [:]; deletions = []; readText = [:]; readKey = [:]; readTasks = [:]; diffs = [:]; sentDiffs = []; sentDeletions = []
        baseline = blocks.map(BlockKey.init)
    }

    public var currentMarks: [RenderPatch.Mark] {
        marks.map { .init(slot: $0.key, kind: $0.value, diff: $0.value == .modified ? diffs[$0.key] : nil) }
            .sorted { $0.slot < $1.slot }
    }

    /// Marks and deletions for a patch: everything for a full payload, otherwise
    /// only the comparisons and deletion texts the page has not been sent.
    private func outgoing(reset: Bool) -> ([RenderPatch.Mark], [RenderPatch.Deletion]) {
        var outMarks = currentMarks, outDeletions = deletions
        if !reset {
            for i in outMarks.indices where sentDiffs.contains(outMarks[i].slot) { outMarks[i].diff = nil }
            for i in outDeletions.indices where sentDeletions.contains(outDeletions[i].id) { outDeletions[i].preview = nil }
        }
        sentDiffs = Set(outMarks.lazy.filter { $0.kind == .modified }.map(\.slot)).union(reset ? [] : sentDiffs)
            .filter { marks[$0] == .modified }
        sentDeletions = Set(deletions.map(\.id))
        return (outMarks, outDeletions)
    }

    // MARK: Helpers

    private func allocSlot() -> Int { defer { nextSlot += 1 }; return nextSlot }
    private func allocDeletionID() -> Int { defer { nextDeletionID += 1 }; return nextDeletionID }

    private func payload(ops: [RenderPatch.Op], reset: Bool, rewrite: Bool) -> RenderPatch {
        if !reset { version += 1 }
        let doc = ParsedDocument(blocks: blocks, title: title)
        let (outMarks, outDeletions) = outgoing(reset: reset)
        return RenderPatch(version: version, reset: reset, rewrite: rewrite, ops: ops,
                           marks: outMarks, deletions: outDeletions,
                           toc: doc.toc(), tasks: doc.tasks, title: title)
    }
}
