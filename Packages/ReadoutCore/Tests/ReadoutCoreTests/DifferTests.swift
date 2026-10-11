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
