import Foundation
import Testing
@testable import ReadoutCore

/// 3.6 fixes to the block diff and the reading session. Each test failed on 3.5.0.
@Suite struct SessionFixes36Tests {
    func parse(_ s: String) -> ParsedDocument { MarkdownParser.parse(s) }
    func key(_ s: String, _ kind: BlockKind = .paragraph) -> BlockKey { BlockKey(fingerprint: XXHash64.hash(s), kind: kind, text: s) }
    func ms(_ f: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        f()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// What `Differ.equalPairs` returned before it was bounded: the standard
    /// library's Myers diff over the whole sequences.
    static func referencePairs(_ a: [UInt64], _ b: [UInt64]) -> [(Int, Int)] {
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var pairs: [(Int, Int)] = []
        var oi = 0, ni = 0
        while oi < a.count && ni < b.count {
            if removed.contains(oi) { oi += 1; continue }
            if inserted.contains(ni) { ni += 1; continue }
            pairs.append((oi, ni)); oi += 1; ni += 1
        }
        return pairs
    }

    // MARK: B2: the diff of a large rewrite is bounded

    /// A complete rewrite of a 10,000-block document took 3-6 s and 1.6 GB.
    @Test func rewriteOfLargeDocumentIsCheap() {
        let n = 10_000
        let old = (0..<n).map { key("old block number \($0) alpha beta") }
        let new = (0..<n).map { key("new block number \($0) gamma delta") }
        var d: DiffResult? = nil
        let t = ms { d = Differ.diff(old: old, new: new) }
        #expect(d?.rewrite == true)
        print("perf differ_rewrite_10k: \(String(format: "%.1f", t)) ms")
        // Generous for a debug build on a shared runner (it took seconds in a release build).
        #expect(t < 1000, "a \(n)-block rewrite took \(Int(t)) ms")
    }

    /// Every other block changed: Myers' work is (N + M) × D with D ~ N.
    @Test func everyOtherBlockChangedIsCheapAndExact() {
        let n = 10_000
        let old = (0..<n).map { key("old block number \($0) alpha beta") }
        let mixed = (0..<n).map { $0 % 2 == 0 ? old[$0] : key("changed block \($0) with other words entirely") }
        var d: DiffResult? = nil
        let t = ms { d = Differ.diff(old: old, new: mixed) }
        print("perf differ_alternate_10k: \(String(format: "%.1f", t)) ms")
        #expect(t < 1500, "every other block of \(n) changed took \(Int(t)) ms")
        guard let d else { return }
        #expect(!d.rewrite)
        #expect(d.equalCount == n / 2)
        // The changed blocks pair one for one (each a 1×1 gap of the same kind).
        #expect(d.removed.isEmpty)
        #expect(d.changes.enumerated().allSatisfy { i, c in i % 2 == 0 ? c == .equal(old: i) : c == .modified(old: i) })
    }

    /// Blocks moved around (many repeated) cost Myers a large D too: the result stays a valid alignment.
    @Test func shuffledLargeDocumentIsBoundedAndValid() {
        var rng = IncrementalParserTests.SplitMix64(state: 7)
        let n = 6000
        let old = (0..<n).map { key("block \($0 % 1500) text") }
        var new = old
        new.shuffle(using: &rng)
        var d: DiffResult? = nil
        let t = ms { d = Differ.diff(old: old, new: new) }
        print("perf differ_shuffle_6k: \(String(format: "%.1f", t)) ms")
        #expect(t < 3000, "a shuffled \(n)-block document took \(Int(t)) ms")
        guard let d else { return }
        var last = -1
        for (j, c) in d.changes.enumerated() {
            if case let .equal(o) = c { #expect(old[o].fingerprint == new[j].fingerprint && o > last); last = o }
            if case let .modified(o) = c { #expect(o > last); last = o }
        }
    }

    /// Ordinary edits (also of long documents) get exactly the alignment they got before.
    @Test func ordinaryEditsAlignAsBefore() {
        var rng = IncrementalParserTests.SplitMix64(state: 36)
        for round in 0..<300 {
            let n = round % 10 == 0 ? Int.random(in: 1000...4000, using: &rng) : Int.random(in: 0...60, using: &rng)
            // Few distinct values: many repeated fingerprints, where alignments can tie.
            let alphabet = UInt64(Int.random(in: 2...40, using: &rng))
            let a = (0..<n).map { _ in UInt64.random(in: 0..<alphabet, using: &rng) }
            var b = a
            for _ in 0..<Int.random(in: 0...(n > 100 ? 12 : 6), using: &rng) {
                let at = b.isEmpty ? 0 : Int.random(in: 0..<b.count, using: &rng)
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: b.insert(UInt64.random(in: 0..<(alphabet + 5), using: &rng), at: at)
                case 1: if !b.isEmpty { b.remove(at: at) }
                default: if !b.isEmpty { b[at] = UInt64.random(in: 0..<(alphabet + 5), using: &rng) }
                }
            }
            let got = Differ.equalPairs(a, b)
            let want = Self.referencePairs(a, b)
            #expect(got.map { $0.map { [$0.0, $0.1] } } == want.map { [$0.0, $0.1] } || (got == nil && Differ.isRewrite(equal: want.count, old: a.count, new: b.count)),
                    "round \(round): n \(n) alphabet \(alphabet) got \(got.map { $0.count } ?? -1) want \(want.count)")
            if got == nil { #expect(Differ.isRewrite(equal: want.count, old: a.count, new: b.count), "round \(round)") }
        }
    }

    // MARK: B4: what was read survives a relaunch

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

    /// Baselines saved by 3.5 (no `source`) still load and mark as before.
    @Test func olderBaselinesStillLoad() throws {
        let v1 = "# T\n\n1. First step of the plan.\n2. Second step of the plan.\n\nClosing words.\n"
        let first = DocumentSession()
        _ = first.load(parse(v1))
        var objects = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first.baseline)) as? [[String: Any]])
        for i in objects.indices { objects[i]["source"] = nil }
        let old = try JSONDecoder().decode([BlockKey].self, from: JSONSerialization.data(withJSONObject: objects))
        #expect(old.allSatisfy { $0.source == nil })
        let s = DocumentSession()
        let p = s.load(parse("# T\n\n1. First step of the plan, revised.\n2. Second step of the plan.\n"), baseline: old)
        // Compared as normalized text, as 3.5 did: no list marker noise.
        #expect(p.marks.first { $0.kind == .modified }?.diff == "- First step of the plan<ins>, revised</ins>.")
        #expect(p.deletions.map(\.preview) == ["Closing words."])
        #expect(s.load(parse(v1), baseline: old).marks.isEmpty)
    }

    // MARK: U7: comparisons and removed text show the source

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

    // MARK: U10: a block being streamed in is edited, not removed

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
}
