import Foundation
import Testing
@testable import ReadoutCore

/// 3.7 fixes to the reading session. Each test failed on 3.6.0.
@Suite struct SessionFixes37Tests {
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

    // MARK: H1: unread removals take no part in the relaunch diff

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

    // MARK: U7: a half-written last block that becomes a list, task or table

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
