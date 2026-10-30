import Foundation
import Testing
@testable import ReadoutCore

/// The reading session (`DocumentSession`): unread sections, what the page is
/// sent, block keys, and what was read surviving a relaunch.
@Suite struct DocumentSessionTests {
    func parse(_ s: String) -> ParsedDocument { MarkdownParser.parse(s) }

    typealias RNG = IncrementalParserTests.SplitMix64

    func doc(_ blocks: [String]) -> ParsedDocument { MarkdownParser.parse(blocks.joined(separator: "\n\n")) }

    static func roundTrip(_ b: [BlockKey]) -> [BlockKey] {
        try! JSONDecoder().decode([BlockKey].self, from: JSONEncoder().encode(b))
    }

    /// What a reader sees: each marked block as "index:kind", and the removed
    /// blocks per anchor ("anchorIndex:count", -1 the top).
    struct Snapshot: Equatable, CustomStringConvertible {
        var marks: [String]
        var deleted: [String]
        var description: String { "marks=\(marks) deleted=\(deleted)" }
    }

    static func snapshot(_ s: DocumentSession) -> Snapshot {
        var index: [Int: Int] = [:]
        for (i, b) in s.blocks.enumerated() { index[b.slot] = i }
        let marks = s.marks.compactMap { slot, kind in index[slot].map { "\($0):\(kind.rawValue)" } }.sorted()
        var per: [Int: Int] = [:]
        for d in s.deletions { per[d.after == 0 ? -1 : (index[d.after] ?? -99), default: 0] += d.count }
        return Snapshot(marks: marks, deleted: per.map { "\($0.key):\($0.value)" }.sorted())
    }

    func relaunch(_ s: DocumentSession, _ blocks: [String]) -> (DocumentSession, RenderPatch) {
        let s2 = DocumentSession()
        let p = s2.load(doc(blocks), baseline: Self.roundTrip(s.baseline))
        return (s2, p)
    }

    static let words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu",
                        "plan", "step", "agent", "file", "change", "test", "build", "deploy", "review", "fix"]

    static func sentence(_ rng: inout RNG, _ n: Int? = nil) -> String {
        (0..<(n ?? Int.random(in: 3...9, using: &rng))).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
    }

    static func block(_ rng: inout RNG, dupPool: [String]) -> String {
        if !dupPool.isEmpty && Int.random(in: 0..<6, using: &rng) == 0 { return dupPool.randomElement(using: &rng)! }
        switch Int.random(in: 0..<9, using: &rng) {
        case 0: return "## " + sentence(&rng, 3)
        case 1: return "- [" + (Bool.random(using: &rng) ? "x" : " ") + "] " + sentence(&rng) + "\n- [ ] " + sentence(&rng)
        case 2: return "```swift\nlet x = \(Int.random(in: 0..<5, using: &rng))\n```"
        case 3: return "- " + sentence(&rng) + "\n- " + sentence(&rng)
        case 4: return "> " + sentence(&rng)
        case 5: return "---"
        default: return sentence(&rng, Int.random(in: 4...14, using: &rng))
        }
    }

    static func object(_ value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try #require(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
    }

    @Test func unreadSectionsFollowMarksDeletionsAndReads() {
        let s = DocumentSession()
        let v1 = "Intro.\n\n# Title\n\n## Alpha\n\nAlpha text.\n\n### Deep\n\nDeep text.\n\n## Beta\n\nBeta text.\n\nBeta more.\n\n##### Small\n\nSmall text.\n"
        _ = s.load(MarkdownParser.parse(v1))
        #expect(s.unreadSections.isEmpty)
        let heading = { (title: String) in s.blocks.first { $0.headingTitle == title }!.slot }
        // Edited under Deep (not Alpha above it), removed under Beta, edited
        // under an H5 (not in the outline: its Beta section), edited before any heading.
        let v2 = "Intro, edited.\n\n# Title\n\n## Alpha\n\nAlpha text.\n\n### Deep\n\nDeep text, edited.\n\n## Beta\n\nBeta text.\n\n##### Small\n\nSmall text, edited.\n"
        _ = s.update(MarkdownParser.parse(v2))
        #expect(s.unreadSections == [heading("Deep"), heading("Beta")])
        // Reading the Deep edit leaves Beta.
        let deep = s.blocks.first { $0.text.contains("Deep text") }!.slot
        s.markRead(slots: [deep], deletionIDs: [])
        #expect(s.unreadSections == [heading("Beta")])
        // The deletion alone still marks Beta.
        let small = s.blocks.first { $0.text.contains("Small text") }!.slot
        s.markRead(slots: [small], deletionIDs: [])
        #expect(s.unreadSections == [heading("Beta")])
        s.markRead(slots: [], deletionIDs: s.deletions.map(\.id))
        #expect(s.unreadSections.isEmpty)
        #expect(s.unreadCount >= 1)   // the intro edit: before the outline
        // An inserted heading is its own section.
        _ = s.update(MarkdownParser.parse(v2 + "\n## Gamma\n"))
        #expect(s.unreadSections == [heading("Gamma")])
        s.markAllRead()
        #expect(s.unreadSections.isEmpty)
    }

    @Test func opsCarryTheSourceAndWhetherABlankLineCameBefore() throws {
        let s = DocumentSession()
        let patch = s.load(MarkdownParser.parse("**Files:**\n- a  \n- b\n\nAfter.\n"))
        let ops = patch.ops
        #expect(ops.map(\.src) == ["**Files:**", "- a  ", "- b", "After."])
        // The list starts on the line after the paragraph; "After." after a blank line.
        #expect(ops.map(\.tight) == [nil, true, true, nil])
    }

    /// A change that renders the same (another list marker, a blank line
    /// added) still reaches the page's copy, without a mark.
    @Test func aSourceOnlyChangeIsASilentReplace() throws {
        let s = DocumentSession()
        _ = s.load(MarkdownParser.parse("Intro.\n\n- a\n- b\n"))
        let p1 = try #require(s.update(MarkdownParser.parse("Intro.\n\n* a\n* b\n")))
        #expect(p1.ops.map(\.op) == [.replace, .replace])
        #expect(p1.ops.allSatisfy { $0.change == .silent })
        #expect(p1.ops.map(\.src) == ["* a", "* b"])
        // Without HTML: the page keeps the blocks as they are and updates their source.
        #expect(p1.ops.allSatisfy { $0.html == nil })
        #expect(s.marks.isEmpty)
        // The blank line before the list goes: its first item is now tight.
        let p2 = try #require(s.update(MarkdownParser.parse("Intro.\n* a\n* b\n")))
        #expect(p2.ops.count == 1 && p2.ops[0].change == .silent && p2.ops[0].tight == true)
        // Nothing changed at all: no patch.
        #expect(s.update(MarkdownParser.parse("Intro.\n* a\n* b\n")) == nil)
    }

    /// The page gets the patch without the outline, task counts and title
    /// (web/src/reader/patch.js reads none of them); everything else is the same JSON.
    @Test func pagePayloadIsThePatchWithoutAppFields() throws {
        let session = DocumentSession()
        let first = session.load(MarkdownParser.parse("# Title\n\n- [ ] a\n\n## B\n\ntext"))
        let second = try #require(session.update(MarkdownParser.parse("# Title\n\n- [x] a\n\n## B\n\ntext\n\nmore")))
        for patch in [first, second] {
            let page = try Self.object(patch.page)
            var full = try Self.object(patch)
            #expect(full["toc"] != nil && full["tasks"] != nil && full["title"] != nil)
            full["toc"] = nil; full["tasks"] = nil; full["title"] = nil
            #expect(NSDictionary(dictionary: page) == NSDictionary(dictionary: full))
            #expect(Set(page.keys) == ["version", "reset", "rewrite", "ops", "marks", "deletions"])
        }
    }

    /// An agent appending one paragraph to a 1 MB document: the page's patch
    /// is that paragraph, not the document's whole outline (142 KB before).
    @Test func appendPatchToThePageIsSmall() throws {
        let doc = PerformanceBudgetTests.document(bytes: 1_000_000)
        let session = DocumentSession()
        let parser = IncrementalParser()
        _ = session.load(parser.parse(doc))
        let patch = try #require(session.update(parser.parse(doc + "\n\nThe agent appended this new paragraph describing the next step of the plan.\n")))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let bytes = try encoder.encode(patch.page).count
        #expect(patch.ops.count == 1)
        #expect(bytes < 1_000, "page payload \(bytes) bytes")
        #expect(try encoder.encode(patch).count > 100_000)   // the app's model still gets the outline
    }

    /// Keys reused from the previous version are the keys built afresh, over
    /// random edit sequences (blocks edited, inserted, removed, duplicated, moved).
    @Test func reusedKeysAreFreshKeys() {
        var rng = RNG(state: 12)
        for _ in 0..<150 {
            var lines = (0..<Int.random(in: 0..<40, using: &rng)).map { _ in DifferentialFuzzTests.palette.randomElement(using: &rng)! }
            var old = MarkdownParser.parse(lines.joined(separator: "\n")).blocks
            for _ in 0..<12 {
                for _ in 0..<Int.random(in: 1..<4, using: &rng) { DifferentialFuzzTests.mutate(&lines, rng: &rng) }
                if Int.random(in: 0..<4, using: &rng) == 0, lines.count > 6 {
                    // A run of lines moved elsewhere.
                    let run = Array(lines[1..<4]); lines.removeSubrange(1..<4); lines += run
                }
                let new = MarkdownParser.parse(lines.joined(separator: "\n")).blocks
                let fresh = new.map(BlockKey.init)
                #expect(DocumentSession.keys(new, reusing: old, old.map(BlockKey.init)) == fresh)
                old = new
            }
        }
    }

    /// A session updated many times has the baseline a fresh load computes.
    @Test func sessionBaselineMatchesFreshKeys() {
        var rng = RNG(state: 55)
        var lines = (0..<30).map { _ in DifferentialFuzzTests.palette.randomElement(using: &rng)! }
        let session = DocumentSession()
        let parser = IncrementalParser()
        _ = session.load(parser.parse(lines.joined(separator: "\n")))
        for _ in 0..<60 {
            DifferentialFuzzTests.mutate(&lines, rng: &rng)
            let doc = parser.parse(lines.joined(separator: "\n"))
            _ = session.update(doc)
            session.markAllRead()
            #expect(session.baseline == session.blocks.map(BlockKey.init))
        }
    }

    @Test func partialReadSurvivesRelaunch() throws {
        let v1 = (1...10).map { "Paragraph \($0) of the plan, first draft." }.joined(separator: "\n\n")
        let v2 = (1...10).map { $0 <= 2 ? "Paragraph \($0) of the plan, revised wording here." : "Paragraph \($0) of the plan, first draft." }.joined(separator: "\n\n")
        let s = DocumentSession()
        _ = s.load(parse(v1))
        _ = s.update(parse(v2))
        #expect(s.marks.count == 2)
        // The reader reads the first change, then quits: what is persisted is s.baseline.
        let first = s.marks.keys.sorted()[0]
        s.markRead(slots: [first], deletionIDs: [])
        #expect(s.marks.count == 1)
        let s2 = DocumentSession()
        let p = s2.load(parse(v2), baseline: s.baseline)
        #expect(s2.marks.count == 1, "relaunch shows \(s2.marks.count) unread changes; the reader had read all but 1")
        // The same unread change, at the same block, and the same unread removal.
        let unread = try #require(s.marks.first)
        #expect(p.marks.map(\.kind) == [unread.value])
        #expect(s2.blocks.firstIndex { $0.slot == p.marks.first?.slot } == s.blocks.firstIndex { $0.slot == unread.key })
        #expect(p.deletions.map(\.preview) == s.deletions.map(\.preview))
        #expect(s2.unreadCount == s.unreadCount)
    }

    /// Insertions, deletions, edits and ticked boxes partly read: a relaunch
    /// shows exactly the ones still unread, with the same comparisons and removed text.
    @Test func everyKindOfUnreadChangeSurvivesRelaunch() throws {
        let v1 = "# Plan\n\nKeep this paragraph as it is.\n\nThe cache uses Redis for sessions.\n\nRemoved paragraph one.\n\nRemoved paragraph two.\n\n- [ ] write the test\n- [ ] ship it\n\nEnd of the plan.\n"
        let v2 = "# Plan\n\nKeep this paragraph as it is.\n\nA brand new paragraph.\n\nThe cache uses Postgres for sessions.\n\n- [x] write the test\n- [ ] ship it\n\nAnother new one.\n\nEnd of the plan.\n"
        let s = DocumentSession()
        _ = s.load(parse(v1))
        let p = try #require(s.update(parse(v2)))
        #expect(p.marks.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.inserted, .inserted, .modified, .state])
        #expect(p.deletions.count == 1)
        // Every subset read: the relaunch shows the rest.
        let all = s.marks.keys.sorted()
        for mask in 0..<(1 << (all.count + 1)) {
            let r = DocumentSession()
            _ = r.load(parse(v1))
            let q = try #require(r.update(parse(v2)))
            let slots = all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let readDeletion = mask & (1 << all.count) != 0
            r.markRead(slots: slots, deletionIDs: readDeletion ? q.deletions.map(\.id) : [])
            let unread = all.filter { !slots.contains($0) }
            let expected = unread.map { slot in (r.blocks.firstIndex { $0.slot == slot }!, q.marks.first { $0.slot == slot }!) }
            let reopened = DocumentSession()
            let o = reopened.load(parse(v2), baseline: r.baseline)
            let got = o.marks.map { m in (reopened.blocks.firstIndex { $0.slot == m.slot }!, m) }.sorted { $0.0 < $1.0 }
            #expect(got.map(\.0) == expected.map(\.0).sorted(), "mask \(mask)")
            for ((i, m), (j, e)) in zip(got, expected.sorted { $0.0 < $1.0 }) {
                #expect(i == j && m.kind == e.kind && m.diff == e.diff, "mask \(mask) block \(i)")
            }
            #expect(o.deletions.map(\.preview) == (readDeletion ? [] : q.deletions.map(\.preview)), "mask \(mask)")
            #expect(!o.rewrite)
            // And again: the baseline of the reopened session is the same.
            #expect(reopened.baseline == r.baseline, "mask \(mask)")
        }
    }

    /// An edited block removed before it was read: the relaunch shows the
    /// removal of the text that was read, not of the unread edit.
    @Test func editedThenRemovedSurvivesRelaunchAsRead() throws {
        let s = DocumentSession()
        _ = s.load(parse("# T\n\nThe plan uses Postgres 16.\n\nOther text.\n\nMore text here.\n\nAnd more.\n"))
        _ = s.update(parse("# T\n\nThe plan uses Postgres 18.\n\nOther text.\n\nMore text here.\n\nAnd more.\n"))
        _ = s.update(parse("# T\n\nOther text.\n\nMore text here.\n\nAnd more.\n"))
        let reopened = DocumentSession()
        let o = reopened.load(parse("# T\n\nOther text.\n\nMore text here.\n\nAnd more.\n"), baseline: s.baseline)
        #expect(o.deletions.map(\.preview) == ["The plan uses Postgres 16."])
        #expect(o.marks.isEmpty)
    }

    /// Removals from several updates that end up in one place keep the order
    /// they were read in: B deleted, then A, of A B C is A B before C.
    @Test func removalsFromSeveralUpdatesKeepTheirOrder() throws {
        let s = DocumentSession()
        _ = s.load(parse("Alpha paragraph.\n\nBravo paragraph.\n\nCharlie paragraph.\n"))
        _ = s.update(parse("Alpha paragraph.\n\nCharlie paragraph.\n"))
        _ = s.update(parse("Charlie paragraph.\n"))
        #expect(s.baseline.map(\.text) == ["Alpha paragraph.", "Bravo paragraph.", "Charlie paragraph."])
        let reopened = DocumentSession()
        let o = reopened.load(parse("Charlie paragraph.\n"), baseline: s.baseline)
        #expect(o.deletions.map(\.preview) == ["Alpha paragraph.\n\nBravo paragraph."])
        // Removed in the middle of an earlier removal's place: still in reading order.
        let t = DocumentSession()
        _ = t.load(parse("One.\n\nTwo.\n\nThree.\n\nFour.\n\nFive.\n"))
        _ = t.update(parse("One.\n\nTwo.\n\nFour.\n\nFive.\n"))
        _ = t.update(parse("One.\n\nFive.\n"))
        #expect(t.baseline.map(\.text) == ["One.", "Two.", "Three.", "Four.", "Five."])
    }

    /// A task ticked (not yet read) and then removed: the removal shows the
    /// task as it was read, unticked, live and after a relaunch.
    @Test func removedTaskShowsTheCheckboxAsRead() throws {
        let s = DocumentSession()
        _ = s.load(parse("# T\n\n- [ ] write the test\n\nOther text.\n\nMore text.\n"))
        _ = s.update(parse("# T\n\n- [x] write the test\n\nOther text.\n\nMore text.\n"))
        #expect(s.marks.values.map(\.self) == [.state])
        let p = try #require(s.update(parse("# T\n\nOther text.\n\nMore text.\n")))
        #expect(p.deletions.map(\.preview) == ["- [ ] write the test"])
        let reopened = DocumentSession()
        let o = reopened.load(parse("# T\n\nOther text.\n\nMore text.\n"), baseline: s.baseline)
        #expect(o.deletions.map(\.preview) == ["- [ ] write the test"])
        // Ticked, unread, then edited: compared with the task as read.
        let t = DocumentSession()
        _ = t.load(parse("# T\n\n- [ ] write the test\n\nOther text.\n"))
        _ = t.update(parse("# T\n\n- [x] write the test\n\nOther text.\n"))
        let q = try #require(t.update(parse("# T\n\n- [x] write the tests\n\nOther text.\n")))
        #expect(q.marks.first?.kind == .modified)
        #expect(q.marks.first?.diff == "- [<del> </del><ins>x</ins>] write the <del>test</del><ins>tests</ins>")
    }

    /// A block removed, then an unrelated one inserted in its place, both
    /// unread: a relaunch shows the insertion and the removal, not an edit.
    @Test func removalThenInsertionAtTheSamePlaceSurvivesRelaunch() throws {
        let s = DocumentSession()
        _ = s.load(parse("Keep one.\n\nRemoved paragraph about caching.\n\nKeep two.\n\nKeep three.\n"))
        _ = s.update(parse("Keep one.\n\nKeep two.\n\nKeep three.\n"))
        _ = s.update(parse("Keep one.\n\nEntirely new words here.\n\nKeep two.\n\nKeep three.\n"))
        #expect(s.marks.values.map(\.self) == [.inserted] && s.deletions.count == 1)
        let reopened = DocumentSession()
        let o = reopened.load(parse("Keep one.\n\nEntirely new words here.\n\nKeep two.\n\nKeep three.\n"), baseline: s.baseline)
        #expect(o.marks.map(\.kind) == [.inserted])
        #expect(o.deletions.map(\.preview) == ["Removed paragraph about caching."])
        #expect(reopened.unreadCount == s.unreadCount)
    }

    @Test func removedTextAndComparisonsShowTheSource() throws {
        let s = DocumentSession()
        _ = s.load(parse("# Steps\n\n- [ ] **Step 1** write it\n- [ ] **Step 2** test it\n\n3. Third numbered item\n4. Fourth numbered item\n\nEnd.\n"))
        let p = try #require(s.update(parse("# Steps\n\n- [ ] **Step 1** write it all\n\n3. Third numbered item\n\nEnd.\n")))
        let previews = p.deletions.compactMap(\.preview)
        #expect(previews.contains("- [ ] **Step 2** test it"), "\(previews)")
        #expect(previews.contains("4. Fourth numbered item"), "\(previews)")
        #expect(p.marks.first { $0.kind == .modified }?.diff == "- [ ] **Step 1** write it<ins> all</ins>")
        // After a relaunch too.
        let reopened = DocumentSession()
        let o = reopened.load(parse("# Steps\n\n- [ ] **Step 1** write it all\n\n3. Third numbered item\n\nEnd.\n"), baseline: s.baseline)
        #expect(o.deletions.compactMap(\.preview).sorted() == previews.sorted())
        #expect(o.marks.first { $0.kind == .modified }?.diff == "- [ ] **Step 1** write it<ins> all</ins>")
    }

    @Test func growingParagraphThatSplitsIsAnEdit() throws {
        let head = "# Plan\n\nIntro paragraph that stays the same.\n\n"
        let s = DocumentSession()
        _ = s.load(parse(head + "The agent is writing this paragr"))
        let p = try #require(s.update(parse(head + "The agent is writing this paragraph now, and it grew much longer than the part written before, with many more words.\n\n- first item of the list\n- second item\n\nAnother paragraph after the list.\n")))
        #expect(p.deletions.isEmpty, "\(p.deletions)")
        #expect(p.marks.map(\.kind) == [.modified, .inserted, .inserted, .inserted])
        // A half-written list item that grows into several items.
        let t = DocumentSession()
        _ = t.load(parse(head + "- Step one: configure the bu"))
        let q = try #require(t.update(parse(head + "- Step one: configure the bucket policy, the lifecycle rules and the replication target for every region we serve.\n- Step two: test it.\n- Step three: ship it.\n")))
        #expect(q.deletions.isEmpty, "\(q.deletions)")
        #expect(q.marks.map(\.kind) == [.modified, .inserted, .inserted])
        // A table row written before its delimiter row is a paragraph until then.
        let w = DocumentSession()
        _ = w.load(parse(head + "| File | Original Methods | Adapta"))
        let x = try #require(w.update(parse(head + "| File | Original Methods | Adaptation |\n| --- | --- | --- |\n| a.ts | 12 | none |\n\nAfter the table.\n")))
        #expect(x.deletions.isEmpty, "\(x.deletions)")
        #expect(x.marks.map(\.kind) == [.modified, .inserted])
        // Unrelated blocks still read as removed and inserted.
        let u = DocumentSession()
        _ = u.load(parse(head + "Completely different words here.\n\nTail text."))
        let r = try #require(u.update(parse(head + "Nothing in common at all, really nothing.\n\nSecond new block with more.\n\nTail text.")))
        #expect(r.deletions.count == 1)
    }

    /// Trimmed in steps, then the remaining block edited: the baseline keeps
    /// four removed blocks, which counted towards "rewritten" after a relaunch
    /// (no marks, no notice of what changed, no place restored).
    @Test func trimmedThenEditedIsNoRewriteAfterRelaunch() {
        let five = ["Alpha para one here", "Bravo para two here", "Charlie para three here", "Delta para four here", "Echo para five here"]
        let s = DocumentSession()
        _ = s.load(doc(five))
        _ = s.update(doc(Array(five.prefix(3))))
        _ = s.update(doc(Array(five.prefix(1))))
        _ = s.update(doc(["Alpha para one here, revised"]))
        let (s2, p) = relaunch(s, ["Alpha para one here, revised"])
        #expect(!p.rewrite)
        #expect(Self.snapshot(s) == Self.snapshot(s2))
        #expect(Self.snapshot(s2).marks == ["0:modified"])
    }

    /// An unread removal next to a block then replaced one for one: live it
    /// is an edit; after a relaunch the removed key widened the gap to 2×1 and
    /// the edit became an insertion plus a removal.
    @Test func editNextToUnreadRemovalStaysAnEdit() {
        let s = DocumentSession()
        _ = s.load(doc(["Alpha para one here", "Bravo para two here", "Charlie three"]))
        _ = s.update(doc(["Alpha para one here", "Charlie three"]))
        _ = s.update(doc(["Completely different words now", "Charlie three"]))
        let (s2, _) = relaunch(s, ["Completely different words now", "Charlie three"])
        #expect(Self.snapshot(s) == Self.snapshot(s2))
    }

    /// A removed block whose text comes back still stays removed after a
    /// relaunch, and what came back is new (as before the fix).
    @Test func removedBlockTextAddedBackIsInsertedAfterRelaunch() {
        let s = DocumentSession()
        _ = s.load(doc(["A para one", "B para two", "C para three"]))
        _ = s.update(doc(["A para one", "C para three"]))
        let (s2, p) = relaunch(s, ["A para one", "B para two", "C para three"])
        #expect(!p.rewrite)
        #expect(Self.snapshot(s2) == Snapshot(marks: ["1:inserted"], deleted: ["0:1"]))
    }

    /// Random realistic edits (insertions, removals, appended words, word
    /// swaps, checkbox toggles; no block rewritten whole) with partial reads in
    /// between, and a relaunch after every step: the relaunch never calls the
    /// document rewritten when the live session did not. On 3.6.0 a sixth of
    /// the seeds produced one.
    @Test func relaunchNeverInventsARewrite() {
        var checked = 0
        var falseRewrites: [String] = []
        for seed in 0..<150 {
            var rng = RNG(state: UInt64(seed) &* 104729 &+ 3)
            var dup: [String] = []
            var blocks: [String] = (0..<Int.random(in: 3...14, using: &rng)).map { _ in
                let b = Self.block(&rng, dupPool: dup); dup.append(b); return b
            }
            func text() -> String { blocks.joined(separator: "\n\n") }
            var s = DocumentSession()
            _ = s.load(MarkdownParser.parse(text()))
            var liveRewrite = false
            for step in 1...30 {
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    let at = blocks.isEmpty ? 0 : Int.random(in: 0..<blocks.count, using: &rng)
                    switch Int.random(in: 0..<7, using: &rng) {
                    case 0, 1: let b = Self.block(&rng, dupPool: dup); dup.append(b); blocks.insert(b, at: min(at, blocks.count))
                    case 2: if blocks.count > 1 { blocks.remove(at: at) }
                    case 3: if !blocks.isEmpty { blocks[at] += " " + Self.words.randomElement(using: &rng)! }
                    case 4:
                        if blocks[at].contains("[x]") { blocks[at] = blocks[at].replacingOccurrences(of: "[x]", with: "[ ]") }
                        else if let r = blocks[at].range(of: "[ ]") { blocks[at].replaceSubrange(r, with: "[x]") }
                    case 5:
                        if blocks.count > 2 {
                            let n = Int.random(in: 1...min(3, blocks.count - 1), using: &rng)
                            blocks.removeSubrange(at..<min(blocks.count, at + n))
                        }
                    default:
                        blocks[at] = blocks[at].replacingOccurrences(of: Self.words.randomElement(using: &rng)!,
                                                                     with: Self.words.randomElement(using: &rng)!)
                    }
                }
                if let p = s.update(MarkdownParser.parse(text())), p.rewrite { liveRewrite = true }
                if Int.random(in: 0..<3, using: &rng) > 0 {
                    let slots = s.marks.keys.filter { _ in Bool.random(using: &rng) }
                    let dels = s.deletions.map(\.id).filter { _ in Bool.random(using: &rng) }
                    s.markRead(slots: Array(slots), deletionIDs: dels)
                }
                if s.unreadCount == 0 { liveRewrite = false }
                let s2 = DocumentSession()
                let p = s2.load(MarkdownParser.parse(text()), baseline: Self.roundTrip(s.baseline))
                checked += 1
                if p.rewrite && !liveRewrite && falseRewrites.count < 5 {
                    falseRewrites.append("seed \(seed) step \(step): live \(Self.snapshot(s))")
                }
                if Int.random(in: 0..<4, using: &rng) == 0 { s = s2; liveRewrite = p.rewrite }
            }
        }
        #expect(checked == 150 * 30)
        #expect(falseRewrites.isEmpty, "\(falseRewrites.joined(separator: "\n"))")
    }

    /// Streaming stops at "1.", "- [ ]", "|": the half-written block changes
    /// kind when the agent goes on, and was reported as a removed block.
    @Test func halfWrittenLastBlockIsNotReportedRemoved() {
        let cases: [(String, String)] = [
            ("Intro text.\n\n1.", "Intro text.\n\n1. Run the whole suite before you change the parser, then again after\n\nExpected: PASS."),
            ("Intro text.\n\n- [ ]", "Intro text.\n\n- [ ] Write the failing test for the parser first\n\nThen run the suite and check that it fails."),
            ("Intro text.\n\n| Name | Value |\n|", "Intro text.\n\n| Name | Value |\n| --- | --- |\n| retries | 3 |\n| timeout | 30 s |\n\nBoth are read at start-up."),
            ("Intro text.\n\n*", "Intro text.\n\n**Note:** the release notes list every change, and the migration guide explains each one."),
            ("## Steps\n\n1. Clone the repository\n2.", "## Steps\n\n1. Clone the repository\n2. **Thread safety** (issue #2): use `call_soon_threadsafe` from the worker\n3. **Mov"),
        ]
        for (before, after) in cases {
            let s = DocumentSession()
            _ = s.load(MarkdownParser.parse(before))
            let p = s.update(MarkdownParser.parse(after))
            #expect(p?.deletions.isEmpty == true, "\(before.debugDescription) → \(after.debugDescription): \(String(describing: p?.deletions))")
            #expect(s.deletions.isEmpty)
            #expect(!s.marks.isEmpty, "the completed block is new")
        }
    }

    /// A short last block really removed (not taken into what follows) is still reported.
    @Test func shortLastBlockReallyRemovedIsReported() {
        let s = DocumentSession()
        _ = s.load(MarkdownParser.parse("Intro text.\n\nDone."))
        let p = s.update(MarkdownParser.parse("Intro text.\n\n- a new list"))
        #expect(p?.deletions.map(\.count) == [1])
        // Its text is not at the start of what follows.
        let s2 = DocumentSession()
        _ = s2.load(MarkdownParser.parse("Intro text.\n\n- [ ]"))
        let p2 = s2.update(MarkdownParser.parse("Intro text.\n\nThe checklist was dropped: every step is done by the script now, and nothing else is left to tick."))
        #expect(p2?.deletions.map(\.count) == [1])
        // A short last block replaced by an unrelated one that merely contains its text.
        let s4 = DocumentSession()
        _ = s4.load(MarkdownParser.parse("Intro text.\n\na"))
        let p4 = s4.update(MarkdownParser.parse("Intro text.\n\n# beta"))
        #expect(p4?.deletions.map(\.count) == [1])
        // Not the last block: a removal.
        let s3 = DocumentSession()
        _ = s3.load(MarkdownParser.parse("Intro text.\n\n-\n\nMore text here."))
        let p3 = s3.update(MarkdownParser.parse("Intro text.\n\nMore text here."))
        #expect(p3?.deletions.map(\.count) == [1])
    }

    /// The real-agent corpus streamed in 40-200 character chunks, the reader
    /// following (everything read after each patch): removed-block marks are
    /// what the agent did, not artefacts of half-written blocks. 3.6.0
    /// reported such removals in most documents.
    @Test func streamingTheCorpusReportsAlmostNoRemovals() throws {
        var seed: UInt64 = 7
        func rnd() -> Double { seed = (seed * 16807) % 2147483647; return Double(seed) / 2147483647 }
        var removed = 0, docsWithRemovals: [String] = []
        for url in CorpusTests.documents() {
            let src = Array(FileContent.decode(try Data(contentsOf: url)).text.unicodeScalars)
            let parser = IncrementalParser()
            let s = DocumentSession()
            var pos = 0, first = true, here = 0
            while pos < src.count {
                pos = min(src.count, pos + 40 + Int(rnd() * 160))
                var text = String.UnicodeScalarView(); text.append(contentsOf: src[0..<pos])
                let d = parser.parse(String(text))
                if first { _ = s.load(d); first = false }
                else if let p = s.update(d), !p.reset { here += p.deletions.reduce(0) { $0 + $1.count } }
                s.markAllRead()
            }
            removed += here
            if here > 0 { docsWithRemovals.append("\(url.lastPathComponent): \(here)") }
        }
        print("U7 corpus stream: \(removed) removed blocks in \(docsWithRemovals)")
        #expect(removed <= 2, "\(docsWithRemovals)")
    }
}
