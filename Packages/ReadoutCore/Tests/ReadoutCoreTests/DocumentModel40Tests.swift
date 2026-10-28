import Foundation
import Testing
@testable import ReadoutCore

/// 4.0 P2: the session owns the document and serves blocks' HTML on request
/// (`DocumentSession.serve`); a page that announced `lean` gets patches
/// without HTML (`RenderPatch.page(lean:)`). Nothing changes for a page that
/// did not announce it.
@Suite struct DocumentModel40Tests {
    static func doc(_ blocks: [String]) -> ParsedDocument { MarkdownParser.parse(blocks.joined(separator: "\n\n")) }

    /// What the page receives: the patch's JSON as the app encodes it.
    static func json(_ out: RenderPatch.Outgoing) -> [String: Any] {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return try! JSONSerialization.jsonObject(with: enc.encode(out)) as! [String: Any]
    }
    /// JSON with sorted keys, to compare decoded objects.
    static func canonical(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    static func ops(_ j: [String: Any]) -> [[String: Any]] { j["ops"] as? [[String: Any]] ?? [] }

    /// The reader page as patch.js applies a patch's JSON: blocks in order,
    /// each with its HTML (a full page) or only its layout (a lean page).
    struct Page {
        struct Item: Equatable { var slot: Int; var html: String?; var layout: BlockLayout? }
        var items: [Item] = []
        var version = 0

        mutating func apply(_ out: RenderPatch.Outgoing) {
            let p = DocumentModel40Tests.json(out)
            if p["reset"] as? Bool == true { items = [] }
            version = p["version"] as! Int
            for op in DocumentModel40Tests.ops(p) {
                let slot = op["slot"] as! Int, html = op["html"] as? String
                let layout = (op["layout"] as? [String: Any]).map { l in
                    BlockLayout(chars: l["chars"] as! Int, lines: l["lines"] as? Int ?? 1, rows: l["rows"] as? Int ?? 0)
                }
                switch op["op"] as! String {
                case "remove":
                    items.removeAll { $0.slot == slot }
                case "insert":
                    let after = op["after"] as? Int
                    let at = after.flatMap { a in a == 0 ? 0 : items.firstIndex { $0.slot == a }.map { $0 + 1 } }
                    #expect(at != nil, "insert \(slot) after \(after ?? -1): no such block")
                    items.insert(Item(slot: slot, html: html, layout: layout), at: at ?? items.count)
                default:
                    guard let i = items.firstIndex(where: { $0.slot == slot }) else {
                        Issue.record("replace \(slot): no such block"); continue
                    }
                    // No HTML and no layout: renders the same, the block stays as it is.
                    if html != nil || layout != nil { items[i].html = html; items[i].layout = layout }
                }
            }
        }
    }

    // MARK: Protocol

    @Test func pageAnnouncesWhatItSpeaks() {
        // Today's page: a bare ready.
        #expect(PageProtocol(ready: ["type": "ready"]) == .legacy)
        #expect(!PageProtocol(ready: ["type": "ready"]).lean)
        let lean = PageProtocol(ready: ["type": "ready", "protocol": NSNumber(value: 2), "caps": ["lean", "later"] as [Any]])
        #expect(lean == PageProtocol(version: 2, capabilities: [.lean]))   // unknown ones ignored
        #expect(lean.lean)
        // A capability needs protocol 2.
        #expect(!PageProtocol(ready: ["type": "ready", "caps": ["lean"] as [Any]]).lean)
        #expect(!PageProtocol(ready: ["type": "ready", "protocol": NSNumber(value: 2)]).lean)
        #expect(PageProtocol.current == 2)
        // `ready` itself decodes as before.
        #expect(PageMessage(["type": "ready", "protocol": NSNumber(value: 2), "caps": ["lean"] as [Any]]) == .ready)
    }

    @Test func blocksRequestDecodes() {
        #expect(PageMessage(["type": "blocks", "version": NSNumber(value: 4), "slots": [NSNumber(value: 3), NSNumber(value: 9)] as [Any],
                             "request": NSNumber(value: 17)]) == .blocks(version: 4, slots: [3, 9], request: 17))
        #expect(PageMessage(["type": "blocks", "version": NSNumber(value: 4)]) == .blocks(version: 4, slots: [], request: 0))
        #expect(PageMessage(["type": "blocks", "slots": [NSNumber(value: 3)] as [Any]]) == nil)   // no version
    }

    /// The page's estimate reads `html.length`, `html.split('\n').length` and `/<tr>/g` (patch.js).
    @Test func layoutIsWhatTheEstimateReads() {
        #expect(BlockLayout(html: "<p>a</p>") == BlockLayout(chars: 8, lines: 1, rows: 0))
        #expect(BlockLayout(html: "<pre>a\nb\n</pre>") == BlockLayout(chars: 15, lines: 3, rows: 0))
        #expect(BlockLayout(html: "") == BlockLayout(chars: 0, lines: 1, rows: 0))
        // UTF-16 code units, as JavaScript counts: 😀 is two, é one.
        #expect(BlockLayout(html: "😀é").chars == 3)
        // `<tr>` exactly, as the regex counts (`<tr class>` and `<track>` are not).
        let table = "<table><thead><tr><th>a</th></tr></thead><tbody><tr><td>1</td></tr><tr class=\"x\"><td>2</td></tr><track></tbody></table>"
        #expect(BlockLayout(html: table).rows == 2)
        #expect(BlockLayout(html: "<tr><tr>").rows == 2)
        let parsed = Self.doc(["| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"]).blocks[0]
        #expect(BlockLayout(html: parsed.html).rows == parsed.html.components(separatedBy: "<tr>").count - 1)
        // Most blocks' layout is their length alone in the JSON.
        let json = String(data: try! JSONEncoder().encode(BlockLayout(chars: 8, lines: 1, rows: 0)), encoding: .utf8)
        #expect(json == #"{"chars":8}"#)
        let round = try! JSONDecoder().decode(BlockLayout.self, from: JSONEncoder().encode(BlockLayout(chars: 9, lines: 4, rows: 2)))
        #expect(round == BlockLayout(chars: 9, lines: 4, rows: 2))
    }

    // MARK: Lean ops

    /// Each lean op is its full op without the HTML and with the HTML's
    /// layout; an op without HTML is the same in both. The rest of the
    /// patch is the same, with `lean: true`.
    func expectLeanIsFullMinusHTML(_ patch: RenderPatch, _ note: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        // A page that did not announce `lean` gets exactly what it got before.
        let before = try! enc.encode(patch.page), now = try! enc.encode(patch.page(lean: false))
        #expect(before == now, "\(note)")
        let text = String(decoding: now, as: UTF8.self)
        #expect(!text.contains(#""layout""#) && !text.contains(#""lean""#), "\(note)")

        var full = Self.json(patch.page(lean: false)), lean = Self.json(patch.page(lean: true))
        #expect(lean["lean"] as? Bool == true && full["lean"] == nil, "\(note)")
        let fullOps = Self.ops(full), leanOps = Self.ops(lean)
        #expect(leanOps.count == fullOps.count && fullOps.count == patch.ops.count, "\(note)")
        for (k, (l, f)) in zip(leanOps, fullOps).enumerated() {
            #expect(l["html"] == nil, "\(note): lean op \(k) has HTML")
            var expected = f
            if let html = f["html"] as? String {
                expected["html"] = nil
                expected["layout"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(BlockLayout(html: html)))
            }
            #expect(Self.canonical(l) == Self.canonical(expected), "\(note): op \(k)")
        }
        full["ops"] = nil; full["lean"] = true; lean["ops"] = nil
        #expect(Self.canonical(lean) == Self.canonical(full), "\(note)")
    }

    @Test func leanOpsAreFullOpsMinusHTML() {
        let s = DocumentSession()
        // Every field an op can have is in one of these (`tight`: a list right under its paragraph).
        var patches = [s.load(Self.doc(["# Plan", "**Files:**\n- a.swift", "One.", "```swift\nlet a = 1\nlet b = 2\n```", "| a |\n|---|\n| 1 |", "- [ ] task", "Two."]))]
        // An edit, an insert, a checkbox, a removal.
        patches.append(s.update(Self.doc(["# Plan", "One, revised.", "```swift\nlet a = 1\nlet b = 2\n```", "| a |\n|---|\n| 1 |", "New.", "- [x] task", "Two."]))!)
        // Renders the same (`*` for `-`): a replace without HTML.
        patches.append(s.update(Self.doc(["# Plan", "One, revised.", "```swift\nlet a = 1\nlet b = 2\n```", "| a |\n|---|\n| 1 |", "New.", "* [x] task", "Two."]))!)
        #expect(patches.last!.ops.contains { $0.op == .replace && $0.html == nil })
        patches.append(s.update(Self.doc(["# Plan", "One, revised.", "```swift\nlet a = 1\nlet b = 2\n```", "| a |\n|---|\n| 1 |", "* [x] task", "Two."]))!)
        #expect(patches.last!.ops.contains { $0.op == .remove })
        // A rewrite: a reset.
        patches.append(s.update(Self.doc(["# Other", "Entirely different text.", "Nothing shared.", "Third.", "Fourth.", "Fifth."]))!)
        #expect(patches.last!.reset)
        #expect(patches[0].ops.contains { $0.tight == true && $0.anchor == nil } && patches[0].ops.contains { $0.anchor != nil })
        #expect(patches.contains { $0.ops.contains { $0.change == .state } })
        for (i, p) in patches.enumerated() { expectLeanIsFullMinusHTML(p, "patch \(i)") }
    }

    // MARK: Request and reply

    @Test func replyIsOfTheCurrentVersion() {
        let s = DocumentSession()
        let p1 = s.load(Self.doc(["# A", "The first paragraph describes the plan in detail.", "This one is removed in the next version.", "Three stays as written."]))
        let slots = s.blocks.map(\.slot)
        // The version shown: its HTML, not stale.
        let r1 = s.serve(slots: slots, version: p1.version, request: 7)
        #expect(r1 == BlockReply(request: 7, version: p1.version, stale: false,
                                 blocks: s.blocks.map { .init(slot: $0.slot, html: $0.html) }, missing: []))
        // Each slot once, in the order asked; a slot no block has is missing.
        let r2 = s.serve(slots: [slots[2], slots[0], slots[2], 999], version: p1.version, request: 8)
        #expect(r2.blocks.map(\.slot) == [slots[2], slots[0]] && r2.missing == [999] && !r2.stale)

        // An edit and a removal: version 2.
        let edited = Self.doc(["# A", "The first paragraph describes the plan in more detail, edited.", "Three stays as written."])
        let p2 = s.update(edited)!
        #expect(p2.version == p1.version + 1)
        #expect(s.blocks.map(\.slot) == [slots[0], slots[1], slots[3]])
        // Asked for version 1 after it: version 2's HTML, flagged stale; the removed block is missing.
        let r3 = s.serve(slots: slots, version: p1.version, request: 9)
        #expect(r3.stale && r3.version == p2.version && r3.request == 9)
        #expect(r3.missing == [slots[2]])
        #expect(r3.blocks.first { $0.slot == slots[1] }?.html == s.blocks[1].html)
        #expect(s.blocks[1].html.contains("edited"))
        // Asked for version 2: the same HTML, current.
        let r4 = s.serve(slots: slots, version: p2.version, request: 10)
        #expect(!r4.stale && r4.blocks == r3.blocks && r4.missing == r3.missing)
        // Nothing visible changed: no patch, no new version, the reply as it was.
        #expect(s.update(edited) == nil)
        #expect(s.serve(slots: slots, version: p2.version, request: 11).blocks == r4.blocks)
    }

    /// A rewrite gives every block a new slot, as many as before: the old
    /// slots are gone and the new ones served (the index follows the version).
    @Test func replyAfterRewriteAndReload() {
        let s = DocumentSession()
        let p1 = s.load(Self.doc(["Alpha one.", "Beta two.", "Gamma three.", "Delta four.", "Epsilon five."]))
        let old = s.blocks.map(\.slot)
        #expect(s.serve(slots: old, version: p1.version, request: 1).blocks.count == 5)
        let rewritten = Self.doc(["Completely new.", "Nothing alike.", "Fully rewritten.", "Other words.", "As many blocks."])
        let p2 = s.update(rewritten)!
        #expect(p2.reset && p2.rewrite)
        let new = s.blocks.map(\.slot)
        #expect(Set(new).isDisjoint(with: old))
        let r = s.serve(slots: old + new, version: p2.version, request: 2)
        #expect(r.missing == old && r.blocks.map(\.slot) == new && r.blocks.map(\.html) == s.blocks.map(\.html))
        // Emptied, then filled again (an agent truncating before it writes).
        _ = s.update(Self.doc([]))
        #expect(s.serve(slots: new, version: s.version, request: 3).missing == new)
        _ = s.update(rewritten)
        let back = s.serve(slots: s.blocks.map(\.slot), version: s.version, request: 4)
        #expect(back.missing.isEmpty && back.blocks.map(\.html) == s.blocks.map(\.html))
    }

    // MARK: Streaming

    /// An agent streaming a document in (cut anywhere, mid-line), then
    /// revising and removing: after every patch a full page and a lean page
    /// hold the session's blocks in order, by slot; what the session serves
    /// for the lean page's slots is the full page's HTML, and the lean
    /// page's layouts are that HTML's.
    @Test func slotsHoldAcrossStreamingPatches() {
        let text = SpliceTests.corpusText(bytes: 24_000)
        var versions: [String] = []
        var cut = text.startIndex
        var rng = IncrementalParserTests.SplitMix64(state: 40)
        while cut < text.endIndex {
            cut = text.index(cut, offsetBy: 200 + Int(rng.next() % 1200), limitedBy: text.endIndex) ?? text.endIndex
            versions.append(String(text[..<cut]))
        }
        // Revisions: a sentence in the middle, a paragraph removed, the top rewritten.
        let mid = text.index(text.startIndex, offsetBy: text.count / 2)
        if let r = text.range(of: "\n\n", range: mid..<text.endIndex) {
            let revised = text.replacingCharacters(in: r, with: " A sentence the agent added.\n\n")
            versions.append(revised)
            // Two paragraphs a third of the way in, by their lines.
            let blocks = MarkdownParser.parse(revised).blocks
            if let k = blocks.indices.dropFirst(blocks.count / 3).first(where: { k in
                k + 1 < blocks.count && blocks[k].kind == .paragraph && blocks[k + 1].kind == .paragraph }) {
                var lines = revised.components(separatedBy: "\n")
                lines.removeSubrange((blocks[k].lines.lowerBound - 1)..<blocks[k + 1].lines.upperBound)
                versions.append(lines.joined(separator: "\n"))
            }
        }
        versions.append("# Fresh start\n\n" + versions.last!)

        let p = IncrementalParser(), s = DocumentSession()
        var full = Page(), lean = Page()
        var lastSlots: [Int: UInt64] = [:]   // slot -> fingerprint of the version before
        var kinds = Set<RenderPatch.Op.Kind>(), resets = 0
        for (n, v) in versions.enumerated() {
            let patch = n == 0 ? s.load(p.parse(v)) : s.update(p.parse(v))
            guard let patch else { continue }
            full.apply(patch.page(lean: false))
            kinds.formUnion(patch.ops.map(\.op)); if patch.reset { resets += 1 }
            lean.apply(patch.page(lean: true))
            let slots = s.blocks.map(\.slot)
            #expect(full.items.map(\.slot) == slots, "version \(n): full page")
            #expect(lean.items.map(\.slot) == slots, "version \(n): lean page")
            #expect(full.items.map(\.html) == s.blocks.map { Optional($0.html) }, "version \(n)")
            #expect(lean.items.allSatisfy { $0.html == nil }, "version \(n)")
            // The lean page asks for what it holds: the full page's HTML, of its version.
            let reply = s.serve(slots: lean.items.map(\.slot), version: lean.version, request: n)
            #expect(!reply.stale && reply.version == lean.version && reply.missing.isEmpty, "version \(n)")
            #expect(reply.blocks.map(\.html) == full.items.map { $0.html ?? "" }, "version \(n)")
            for (l, f) in zip(lean.items, full.items) where l.layout != nil {
                #expect(l.layout == BlockLayout(html: f.html ?? ""), "version \(n): slot \(l.slot)")
            }
            // A block kept from the version before with the same content keeps its slot.
            let fingerprints = Dictionary(s.blocks.map { ($0.slot, $0.fingerprint) }, uniquingKeysWith: { a, _ in a })
            let kept = lastSlots.filter { fingerprints[$0.key] == $0.value }.count
            #expect(n == 0 || patch.reset || kept > 0, "version \(n): no slot kept")
            lastSlots = fingerprints
        }
        #expect(s.version > versions.count / 2)
        // Streaming grew blocks in place, revising removed one: every op, beyond the first reset.
        #expect(kinds == [.insert, .replace, .remove], "\(kinds)")
        #expect(resets == 1, "\(resets)")
    }
}
