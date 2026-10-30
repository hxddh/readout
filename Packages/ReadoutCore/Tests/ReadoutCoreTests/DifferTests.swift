import Foundation
import Testing
@testable import ReadoutCore

@Suite struct DifferTests {
    func keys(_ s: String) -> [BlockKey] { MarkdownParser.parse(s).blocks.map(BlockKey.init) }

    @Test func identicalDocuments() {
        let k = keys("# A\n\npara\n\n- x\n")
        let d = Differ.diff(old: k, new: k)
        #expect(d.removed.isEmpty)
        #expect(d.equalCount == k.count)
    }

    @Test func insertionAndDeletion() {
        let old = keys("# A\n\none\n\ntwo\n\nthree\n")
        let new = keys("# A\n\none\n\nbrand new text here\n\nthree\n\nfour\n")
        let d = Differ.diff(old: old, new: new)
        // "two" vs "brand new text here": same kind, 1:1 gap -> modified
        #expect(d.changes[2] == .modified(old: 2))
        #expect(d.changes[4] == .inserted)
        #expect(d.removed.isEmpty)
    }

    @Test func pairsSimilarBlocksInLargerGaps() {
        let old = keys("Intro.\n\nThe quick brown fox jumps over the lazy dog today.\n\nRemoved paragraph entirely gone.\n\nEnd.")
        let new = keys("Intro.\n\nA wholly different inserted paragraph.\n\nThe quick brown fox jumps over the lazy dog tomorrow.\n\nEnd.")
        let d = Differ.diff(old: old, new: new)
        #expect(d.changes[1] == .inserted)
        #expect(d.changes[2] == .modified(old: 1))
        #expect(d.removed == [2])
    }

    @Test func cjkSimilarity() {
        let a = BlockKey(fingerprint: 1, kind: .paragraph, text: "我们需要在下周完成对象存储的兼容性测试")
        let b = BlockKey(fingerprint: 2, kind: .paragraph, text: "我们需要在本周完成对象存储的兼容性测试")
        #expect(Differ.similarity(a, b) > 0.5)
    }

    @Test func rewriteDetection() {
        let old = keys("a\n\nb\n\nc\n\nd\n\ne\n\nf\n")
        let new = keys("# Totally\n\n- different\n- content\n\n```\ncode\n```\n")
        #expect(Differ.diff(old: old, new: new).rewrite)
    }

    /// A five-block skeleton filled in to 29 blocks keeps every old block:
    /// an edit (inserted blocks marked), not a rewrite.
    @Test func growingSkeletonIsNotARewrite() {
        let skeleton = "# Plan\n\n## Goals\n\nShip the feature.\n\n## Steps\n\nTBD.\n"
        let steps = (1...12).map { "## Step \($0)\n\nDo \($0)." }.joined(separator: "\n\n")
        let old = keys(skeleton), new = keys(skeleton + "\n" + steps + "\n")
        #expect(old.count == 5 && new.count == 29)
        let d = Differ.diff(old: old, new: new)
        #expect(!d.rewrite)
        #expect(d.equalCount == 5)
        let s = DocumentSession()
        _ = s.load(MarkdownParser.parse(skeleton))
        let p = s.update(MarkdownParser.parse(skeleton + "\n" + steps + "\n"))!
        #expect(!p.reset && !p.rewrite)
        #expect(p.marks.count == 24 && p.marks.allSatisfy { $0.kind == .inserted })
    }

    /// Cutting a document down to a few of its blocks is a deletion, not a rewrite.
    @Test func shrinkingToAFewBlocksIsNotARewrite() {
        let full = (1...29).map { "Paragraph number \($0) of the plan." }.joined(separator: "\n\n")
        let cut = (1...5).map { "Paragraph number \($0) of the plan." }.joined(separator: "\n\n")
        let d = Differ.diff(old: keys(full), new: keys(cut))
        #expect(!d.rewrite)
        #expect(d.removed.count == 24)
    }

    /// A genuine rewrite is still detected, at equal, larger and smaller sizes.
    @Test func trueRewritesAreStillDetected() {
        let old = keys((1...10).map { "Old paragraph \($0) about storage." }.joined(separator: "\n\n"))
        let same = keys("# New\n\n" + (1...9).map { "Fresh text \($0) on agents." }.joined(separator: "\n\n"))
        let bigger = keys((1...40).map { "Fresh text \($0) on agents." }.joined(separator: "\n\n"))
        let smaller = keys("# New\n\nOne fresh line.\n")
        #expect(Differ.diff(old: old, new: same).rewrite)
        #expect(Differ.diff(old: old, new: bigger).rewrite)
        #expect(Differ.diff(old: old, new: smaller).rewrite)
        // One block kept out of ten, the rest replaced: still a rewrite.
        let kept = keys("Old paragraph 1 about storage.\n\n" + (1...9).map { "Fresh text \($0) on agents." }.joined(separator: "\n\n"))
        #expect(Differ.diff(old: old, new: kept).rewrite)
    }

    /// Pairing a large rewritten section between stable blocks stays fast:
    /// each block's shingles are built once, and the gap size is bounded.
    @Test func largeRewrittenSectionPairsQuickly() {
        let keep = (0..<1000).map { "Stable paragraph number \($0) with some words." }
        for size in [100, 200] {
            let a = (0..<size).map { "Old section paragraph \($0): " + String(repeating: "lorem ipsum dolor sit amet \($0) ", count: 15) }
            let b = (0..<size).map { "New section paragraph \($0): " + String(repeating: "consectetur adipiscing elit \($0 * 7) ", count: 15) }
            let old = keys((keep + a + keep).joined(separator: "\n\n")), new = keys((keep + b + keep).joined(separator: "\n\n"))
            var best = Double.infinity
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                let d = Differ.diff(old: old, new: new)
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                #expect(!d.rewrite && d.equalCount == 2000)
            }
            print("perf differ_gap_\(size): \(String(format: "%.1f", best)) ms")
            // Generous for a debug build on a shared runner (it took seconds before).
            #expect(best < 1500, "pairing a \(size)x\(size) gap took \(best) ms")
        }
    }

    /// Property: applying the diff's mapping reconstructs the new key sequence.
    @Test func randomEditsReconstruct() {
        var rng = SplitMix(seed: 42)
        let words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa"]
        func para() -> String { (0..<Int.random(in: 3...8, using: &rng)).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ") }
        for _ in 0..<200 {
            var paras = (0..<Int.random(in: 0...15, using: &rng)).map { _ in para() }
            let old = keys(paras.joined(separator: "\n\n"))
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                switch Int.random(in: 0...2, using: &rng) {
                case 0: paras.insert(para(), at: Int.random(in: 0...paras.count, using: &rng))
                case 1: if !paras.isEmpty { paras.remove(at: Int.random(in: 0..<paras.count, using: &rng)) }
                default: if !paras.isEmpty { paras[Int.random(in: 0..<paras.count, using: &rng)] += " more" }
                }
            }
            let new = keys(paras.joined(separator: "\n\n"))
            let d = Differ.diff(old: old, new: new)
            #expect(d.changes.count == new.count)
            var usedOld = Set<Int>()
            var lastOld = -1
            for (n, c) in d.changes.enumerated() {
                switch c {
                case let .equal(o):
                    #expect(old[o].fingerprint == new[n].fingerprint)
                    #expect(o > lastOld); lastOld = o; usedOld.insert(o)
                case let .modified(o):
                    #expect(o > lastOld); lastOld = o; usedOld.insert(o)
                case .inserted: break
                }
            }
            #expect(usedOld.union(d.removed).count == old.count)
            #expect(usedOld.intersection(d.removed).isEmpty)
        }
    }

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

    /// A large range of repeated blocks only (no fingerprint unique on both
    /// sides to anchor on) still matches what survives, in bounded time.
    @Test func repeatedBlocksWithoutAnchorsStillMatch() {
        let a = key("Repeated block A."), b = key("Repeated block B.")
        let old = Array(repeating: a, count: 2500) + Array(repeating: b, count: 2500)
        let new = Array(repeating: b, count: 2500) + Array(repeating: a, count: 2500)
        var d: DiffResult? = nil
        let t = ms { d = Differ.diff(old: old, new: new) }
        #expect(t < 1500, "\(Int(t)) ms")
        #expect(d?.rewrite == false)
        #expect((d?.equalCount ?? 0) >= 2500)
    }

    /// Rotated runs of repeated blocks keep what survives (A…F runs of 1,000 each, then B…F, A).
    @Test func rotatedRunsOfRepeatedBlocksStillMatch() {
        let letters = ["A", "B", "C", "D", "E", "F"].map { key("Repeated block \($0).") }
        let old = letters.flatMap { Array(repeating: $0, count: 1000) }
        let new = (letters.dropFirst() + [letters[0]]).flatMap { Array(repeating: $0, count: 1000) }
        var d: DiffResult? = nil
        let t = ms { d = Differ.diff(old: old, new: new) }
        #expect(t < 1500, "\(Int(t)) ms")
        #expect(d?.rewrite == false)
        #expect((d?.equalCount ?? 0) >= 5000)
    }

    /// Runs of repeated blocks reordered: the runs that keep their order survive.
    @Test func reorderedRunsKeepTheRunsInOrder() {
        func blocks(_ runs: [Int]) -> [BlockKey] { runs.flatMap { Array(repeating: key("Repeated block \($0)."), count: 300) } }
        let d = Differ.diff(old: blocks([2, 0, 1, 2, 3, 5, 1, 0, 6, 7]), new: blocks([7, 6, 5, 6, 4, 6, 7, 6, 3, 4]))
        #expect(!d.rewrite)
        #expect(d.equalCount >= 900)
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
}

@Suite struct SessionTests {
    func parse(_ s: String) -> ParsedDocument { MarkdownParser.parse(s) }

    @Test func slotsStableAcrossEdits() {
        let s = DocumentSession()
        let p0 = s.load(parse("# T\n\none\n\ntwo\n"))
        #expect(p0.reset)
        let slots0 = s.blocks.map(\.slot)
        let p1 = s.update(parse("# T\n\nzero\n\none\n\ntwo changed\n"))!
        #expect(!p1.reset)
        #expect(s.blocks[0].slot == slots0[0])
        #expect(s.blocks[2].slot == slots0[1])
        #expect(s.blocks[3].slot == slots0[2])
        #expect(p1.ops.contains { $0.op == .insert && $0.after == slots0[0] })
        #expect(p1.ops.contains { $0.op == .replace && $0.slot == slots0[2] && $0.change == .content })
        #expect(Set(p1.marks.map(\.kind)) == [.inserted, .modified])
    }

    @Test func noOpUpdateReturnsNil() {
        let s = DocumentSession()
        _ = s.load(parse("a\n\nb\n"))
        #expect(s.update(parse("a\n\nb\n")) == nil)
    }

    @Test func marksAccumulateUntilRead() {
        let s = DocumentSession()
        _ = s.load(parse("# T\n\none\n"))
        _ = s.update(parse("# T\n\none\n\ntwo\n"))
        _ = s.update(parse("# T\n\none\n\ntwo\n\nthree\n"))
        #expect(s.unreadCount == 2)
        let firstNew = s.blocks[2].slot
        s.markRead(slots: [firstNew], deletionIDs: [])
        #expect(s.unreadCount == 1)
        s.markAllRead()
        #expect(s.unreadCount == 0)
        #expect(s.baseline == s.blocks.map(BlockKey.init))
    }

    @Test func checkboxToggleIsStateChange() {
        let s = DocumentSession()
        _ = s.load(parse("- [ ] a\n- [ ] b\n"))
        let p = s.update(parse("- [x] a\n- [ ] b\n"))!
        #expect(p.ops.count == 1)
        #expect(p.ops[0].change == .state)
        #expect(p.marks == [.init(slot: s.blocks[0].slot, kind: .state)])
        #expect(p.tasks == TaskStats(done: 1, total: 2))
    }

    @Test func deletionsAreAnchored() {
        let s = DocumentSession()
        _ = s.load(parse("# T\n\nkeep one\n\n```\ndrop me\n```\n\nkeep two\n"))
        let p = s.update(parse("# T\n\nkeep one\n\nkeep two\n"))!
        #expect(p.deletions.count == 1)
        #expect(p.deletions[0].after == s.blocks[1].slot)
        #expect(p.deletions[0].preview?.contains("drop me") == true)
    }

    @Test func insertedThenRemovedLeavesNoTrace() {
        let s = DocumentSession()
        _ = s.load(parse("# T\n\none\n"))
        _ = s.update(parse("# T\n\none\n\n```\ntemp\n```\n"))
        _ = s.update(parse("# T\n\none\n"))
        #expect(s.unreadCount == 0)
    }

    @Test func persistedBaselineMarksChangesSinceLastRead() {
        let first = DocumentSession()
        _ = first.load(parse("# T\n\none\n\ntwo\n"))
        let baseline = first.baseline
        let second = DocumentSession()
        let p = second.load(parse("# T\n\none\n\ntwo\n\nthree\n"), baseline: baseline)
        #expect(p.marks.count == 1)
        #expect(p.marks[0].kind == .inserted)
    }

    @Test func rewriteResets() {
        let s = DocumentSession()
        _ = s.load(parse("a\n\nb\n\nc\n\nd\n\ne\n"))
        let p = s.update(parse("# New\n\n- x\n- y\n"))!
        #expect(p.reset && p.rewrite)
        #expect(p.marks.isEmpty)
    }

    /// An agent truncates the file and writes it again; a read in between
    /// sees it empty. The same text written back marks nothing.
    @Test func brieflyEmptyFileIsNotTheBaseForTheRefill() {
        let text = "# Report\n\nPara one.\n\nPara two.\n\nPara three.\n"
        let s = DocumentSession()
        _ = s.load(parse(text))
        let slots = s.blocks.map(\.slot)
        _ = s.update(parse(" \n"))
        let p = s.update(parse(text))!
        #expect(p.reset && !p.rewrite)
        #expect(p.marks.isEmpty && p.deletions.isEmpty)
        #expect(s.unreadCount == 0)
        #expect(s.blocks.map(\.slot) == slots)
        #expect(p.ops.map(\.slot) == slots)
        // A refill that differs is marked against the version before the empty one.
        _ = s.update(parse(""))
        let q = s.update(parse(text + "\nPara four.\n"))!
        #expect(q.reset)
        #expect(q.marks.map(\.kind) == [.inserted])
        #expect(q.deletions.isEmpty)
    }

    /// An empty version the reader has read (the deletion marked read, or all
    /// read) is what was last read: the next content is new, not a refill.
    @Test func readEmptyVersionIsTheBaseForWhatFollows() {
        let text = "# Report\n\nPara one.\n\nPara two.\n"
        for readAll in [false, true] {
            let s = DocumentSession()
            _ = s.load(parse(text))
            let empty = s.update(parse(""))!
            #expect(empty.deletions.count == 1)
            if readAll { s.markAllRead() } else { s.markRead(slots: [], deletionIDs: empty.deletions.map(\.id)) }
            let p = s.update(parse(text))!
            #expect(p.marks.count == 3 && p.marks.allSatisfy { $0.kind == .inserted }, "readAll: \(readAll)")
            #expect(p.deletions.isEmpty)
        }
        // Unread inserts removed by the empty version leave nothing to read: the baseline
        // moves to the empty version, and what comes next is new as well.
        let s = DocumentSession()
        _ = s.load(parse("# A\n"))
        _ = s.update(parse("# A\n\nnew one\n"))
        s.markRead(slots: [s.blocks[0].slot], deletionIDs: [])
        _ = s.update(parse("# A\n\nnew one\n\nnew two\n"))
        _ = s.update(parse(""))
        s.markAllRead()
        let q = s.update(parse("# A\n"))!
        #expect(q.marks.map(\.kind) == [.inserted])
    }

    @Test func rewriteSinceLastReadShowsTheNoticeOnLoad() {
        let first = DocumentSession()
        _ = first.load(parse("# Plan\n\nStep one is to do the first thing.\n\nStep two is the second thing.\n\nStep three.\n\nStep four.\n"))
        let second = DocumentSession()
        let p = second.load(parse("# Totally different\n\nAlpha beta.\n\nGamma delta.\n\nEpsilon zeta.\n\nEta theta.\n"),
                            baseline: first.baseline)
        #expect(p.rewrite)
        #expect(p.marks.isEmpty && second.unreadCount == 0)
    }

    @Test func checkboxTickedWhileClosedIsMarkedOnLoad() throws {
        let first = DocumentSession()
        _ = first.load(parse("# T\n\n- [ ] a\n- [ ] b\n"))
        let second = DocumentSession()
        let p = second.load(parse("# T\n\n- [x] a\n- [ ] b\n"), baseline: first.baseline)
        #expect(p.marks == [.init(slot: second.blocks[1].slot, kind: .state)])
        // Unticked again live: nothing new any more.
        let q = second.update(parse("# T\n\n- [ ] a\n- [ ] b\n"))!
        #expect(q.marks.isEmpty)
        // A baseline saved before task states were kept decodes without them: no mark, as before.
        var objects = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first.baseline)) as? [[String: Any]])
        #expect(objects.contains { $0["taskState"] != nil })
        for i in objects.indices { objects[i]["taskState"] = nil }
        let old = try JSONDecoder().decode([BlockKey].self, from: JSONSerialization.data(withJSONObject: objects))
        #expect(old.allSatisfy { $0.taskState == nil })
        let third = DocumentSession()
        #expect(third.load(parse("# T\n\n- [x] a\n- [ ] b\n"), baseline: old).marks.isEmpty)
    }

    @Test func renumberingIsSilent() {
        let s = DocumentSession()
        _ = s.load(parse("1. a\n2. b\n"))
        let p = s.update(parse("1. new\n2. a\n3. b\n"))!
        #expect(p.ops.filter { $0.change == .silent }.count == 2)
        #expect(p.marks.count == 1)
    }
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
