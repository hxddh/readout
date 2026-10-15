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
    /// What the reader has read, to persist between launches: `load` with
    /// it marks exactly what is unread now. The current version's blocks
    /// that are read; of a block with an unread edit, the version last read;
    /// no unread insertions; and the blocks of unread deletions, as last
    /// read, where they were. The current version when nothing is unread.
    public private(set) var baseline: [BlockKey] = []
    /// For each block marked modified: its Markdown source when last read
    /// (nil: not kept), and the comparison.
    private var readText: [Int: String?] = [:]
    /// Blocks whose `readText` is the normalized text (a baseline saved
    /// before sources were kept): compared with the normalized text now.
    private var readNormalized: Set<Int> = []
    /// The key of each block marked modified as last read: its fingerprint
    /// (a change back is no change) and, when an older baseline kept only
    /// the start of its text, that start.
    private var readKey: [Int: BlockKey] = [:]
    /// The removed blocks of each unread deletion, as last read (by deletion id).
    private var deletionKeys: [Int: [BlockKey]] = [:]
    /// Keys of `blocks`, once computed for them (nil: not yet).
    private var blockKeys: [BlockKey]? = nil
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
        resetMarks()
        beforeEmpty = nil
        let keys = blocks.map(BlockKey.init)
        var rewrite = false
        if let persisted, persisted != keys {
            let d = Differ.diff(old: persisted, new: keys)
            rewrite = d.rewrite
            // Checkbox states come from the baseline (nil in one saved before they were kept).
            if !d.rewrite {
                // A baseline saved before sources were kept has only the normalized text.
                applyMarks(d, oldKeys: persisted, oldSlotForIndex: { _ in nil }, oldTasks: { persisted[$0].taskState },
                           oldTexts: persisted.map { $0.wholeSource ?? $0.wholeText },
                           oldNormalized: { persisted[$0].source == nil })
            }
            rebuildBaseline(keys)
        } else {
            baseline = keys
            blockKeys = keys
        }
        // Rewritten since it was last read: no marks, and the notice says why.
        return fullPayload(rewrite: rewrite)
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

    /// What the session held before the document went empty. An agent
    /// truncates a file before writing it again, and a read can land in
    /// between: the version after the empty one is compared with this, so
    /// rewriting the same text marks nothing (and a deletion of everything
    /// does not stay behind).
    private struct State {
        var blocks: [Block], title: String?, marks: [Int: MarkKind], deletions: [RenderPatch.Deletion]
        var baseline: [BlockKey], readText: [Int: String?], readKey: [Int: BlockKey], readTasks: [Int: [Bool]]
        var diffs: [Int: String], readNormalized: Set<Int>, deletionKeys: [Int: [BlockKey]]
    }
    private var beforeEmpty: State?

    /// Applies a new parse. Returns nil when nothing visible changed.
    public func update(_ doc: ParsedDocument) -> RenderPatch? {
        if doc.blocks.isEmpty {
            if beforeEmpty == nil && !blocks.isEmpty {
                beforeEmpty = State(blocks: blocks, title: title, marks: marks, deletions: deletions, baseline: baseline,
                                    readText: readText, readKey: readKey, readTasks: readTasks, diffs: diffs,
                                    readNormalized: readNormalized, deletionKeys: deletionKeys)
            }
        } else if let s = beforeEmpty {
            beforeEmpty = nil
            blocks = s.blocks; title = s.title; marks = s.marks; deletions = s.deletions; baseline = s.baseline
            blockKeys = nil
            readText = s.readText; readKey = s.readKey; readTasks = s.readTasks; diffs = s.diffs
            readNormalized = s.readNormalized; deletionKeys = s.deletionKeys
            // The page shows the empty version: it gets the whole document, marked against the one before.
            if let p = apply(doc), p.reset { return p }
            return fullPayload(rewrite: false)
        }
        let patch = apply(doc)
        dropBeforeEmptyIfRead()
        return patch
    }

    private func apply(_ doc: ParsedDocument) -> RenderPatch? {
        let oldBlocks = blocks
        let oldKeys = blockKeys ?? oldBlocks.map(BlockKey.init)
        var newBlocks = doc.blocks
        let newKeys = newBlocks.map(BlockKey.init)
        let d = Differ.diff(old: oldKeys, new: newKeys)
        title = doc.title

        if d.rewrite {
            for i in newBlocks.indices { newBlocks[i].slot = allocSlot() }
            blocks = newBlocks
            resetMarks()
            baseline = newKeys
            blockKeys = newKeys
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
                   oldTasks: { oldBlocks[$0].taskState },
                   oldTexts: oldBlocks.map(\.source), oldNormalized: { _ in false })
        rebuildBaseline(newKeys)
        if ops.isEmpty { return nil }
        return payload(ops: ops, reset: false, rewrite: false)
    }

    private func applyMarks(_ d: DiffResult, oldKeys: [BlockKey], oldSlotForIndex: (Int) -> Int?,
                            oldBlocks: [Block] = [], oldTasks: (Int) -> [Bool]?, oldTexts: [String?],
                            oldNormalized: (Int) -> Bool) {
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
                        readKey[slot] = oldKeys[o]
                        if oldNormalized(o) { readNormalized.insert(slot) } else { readNormalized.remove(slot) }
                        // Unless a checkbox change since reading already recorded them.
                        if readTasks[slot] == nil, let read = oldTasks(o) { readTasks[slot] = read }
                    }
                    // Changed back to what was read: the same content (fingerprint).
                    let reverted = readKey[slot].map { $0.fingerprint == blocks[n].fingerprint } ?? false
                    if reverted {
                        // Changed back to the text that was read: no comparison to show,
                        // but a checkbox that differs from what was read is still news.
                        let readState = readTasks[slot] ?? oldTasks(o)
                        marks[slot] = readState.map { $0 != blocks[n].taskState } == true ? .state : nil
                        readText[slot] = nil; readKey[slot] = nil; diffs[slot] = nil
                        // A state mark keeps the checkboxes as read, so unticking clears it.
                        readTasks[slot] = marks[slot] == .state ? readState : nil
                    } else if let read = readText[slot] ?? nil {
                        marks[slot] = .modified
                        let now = readNormalized.contains(slot) ? blocks[n].text : blocks[n].source
                        diffs[slot] = WordDiff.html(old: read, new: now, budget: &budget)
                        sentDiffs.remove(slot)
                    } else {
                        marks[slot] = .modified
                        diffs[slot] = ""
                        sentDiffs.remove(slot)
                    }
                }
            case let .equal(o):
                if let read = oldTasks(o), read != blocks[n].taskState, marks[slot] == nil {
                    marks[slot] = .state
                    readTasks[slot] = read   // the checkboxes as read
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
        var newDeletionKeys: [Int: [BlockKey]] = [:]          // the same, the removed blocks as last read
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
            // The block as last read: before an unread edit, with the checkboxes as read.
            var removedKey = oldKeys[o]
            if let s = oldSlotForIndex(o) {
                if marks[s] == .modified, let k = readKey[s] { removedKey = k }
                if marks[s] == .modified || marks[s] == .state, let t = readTasks[s] { removedKey = removedKey.with(taskState: t) }
                marks[s] = nil
            }
            let after = anchorBefore(o)
            newDeletionKeys[after, default: []].append(removedKey)
            // Only the start is known for a long block in an older baseline: marked as cut.
            let preview = Self.bounded(lastRead ?? oldTexts[o] ?? (oldKeys[o].text + " …"))
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
        for (anchor, var del) in newDeletions.sorted(by: { $0.key < $1.key }) {
            del = .init(id: allocDeletionID(), after: del.after, count: del.count, preview: del.preview)
            deletionKeys[del.id] = newDeletionKeys[anchor] ?? []
            reanchored.append(del)
        }
        deletions = reanchored
        let liveDeletions = Set(deletions.map(\.id))
        deletionKeys = deletionKeys.filter { liveDeletions.contains($0.key) }
        marks = marks.filter { newSlots.contains($0.key) }
        readText = readText.filter { marks[$0.key] == .modified }
        readKey = readKey.filter { marks[$0.key] == .modified }
        readNormalized = readNormalized.filter { marks[$0] == .modified }
        readTasks = readTasks.filter { marks[$0.key] == .modified || marks[$0.key] == .state }
        diffs = diffs.filter { marks[$0.key] == .modified }
    }

    private func resetMarks() {
        marks = [:]; deletions = []; readText = [:]; readKey = [:]; readTasks = [:]; diffs = [:]; sentDiffs = []; sentDeletions = []
        readNormalized = []; deletionKeys = [:]
    }

    /// The baseline for what is unread now (see `baseline`). `keys`: the current blocks' keys, when at hand.
    private func rebuildBaseline(_ keys: [BlockKey]? = nil) {
        let keys = keys ?? blockKeys ?? blocks.map(BlockKey.init)
        blockKeys = keys
        guard !marks.isEmpty || !deletions.isEmpty else { baseline = keys; return }
        var removedAfter: [Int: [BlockKey]] = [:]   // by the slot the removed blocks sat after (0: the top)
        for del in deletions { removedAfter[del.after, default: []] += deletionKeys[del.id] ?? [] }
        var out: [BlockKey] = removedAfter[0] ?? []
        out.reserveCapacity(keys.count + deletions.count)
        for (i, b) in blocks.enumerated() {
            switch marks[b.slot] {
            case .inserted?:
                break
            case .modified?:
                let read = readKey[b.slot] ?? keys[i]
                out.append(readTasks[b.slot].map { read.with(taskState: $0) } ?? read)
            case .state?:
                out.append(readTasks[b.slot].map { keys[i].with(taskState: $0) } ?? keys[i])
            case nil:
                out.append(keys[i])
            }
            out += removedAfter[b.slot] ?? []
        }
        baseline = out
    }

    // MARK: Reading

    public func markRead(slots: [Int], deletionIDs: [Int]) {
        for s in slots { marks[s] = nil; readText[s] = nil; readKey[s] = nil; readTasks[s] = nil; diffs[s] = nil }
        let ids = Set(deletionIDs)
        // Reading the removal of everything accepts the empty version: it is
        // no longer a passing truncation to look past.
        if blocks.isEmpty && deletions.contains(where: { ids.contains($0.id) }) { beforeEmpty = nil }
        deletions.removeAll { ids.contains($0.id) }
        for id in ids { deletionKeys[id] = nil }
        readNormalized.subtract(slots)
        rebuildBaseline()
        dropBeforeEmptyIfRead()
    }

    /// Once the reader has caught up with the empty version (the baseline
    /// moved to it), what came before is no longer what was last read.
    private func dropBeforeEmptyIfRead() {
        if beforeEmpty != nil && blocks.isEmpty && marks.isEmpty && deletions.isEmpty { beforeEmpty = nil }
    }

    public func markAllRead() {
        resetMarks()
        baseline = blockKeys ?? blocks.map(BlockKey.init)
        dropBeforeEmptyIfRead()
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
