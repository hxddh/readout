import Foundation

/// Re-parses only what changed between versions of one document.
///
/// The source is cut into fragments at blank lines where the Markdown parser
/// is in a neutral state: not inside fenced code, raw HTML, a `<details>`
/// the parser joins, a list or a block quote. Each fragment
/// is parsed on its own (`MarkdownParser.parseFragment`) and kept by content
/// hash; on the next version, fragments whose text is unchanged are reused
/// wherever they now sit, and only new text is parsed (concurrently when
/// there are many fragments, as on first open). `assemble` then adds
/// the document-wide parts (line offsets, heading paths, anchors, title).
///
/// The result is identical to `MarkdownParser.parse` (property-tested on the
/// real-agent corpus). Footnotes are numbered when the document is assembled;
/// fragments that may reference one are keyed by the set of defined ids.
/// Documents with link reference definitions are parsed in full.
///
/// A version that differs from the previous one in one run of lines (an
/// agent writing on, an edit in one place) is spliced into it (`splice`):
/// only the fragments around the change are cut, parsed and assembled
/// again, and the rest of the previous result is kept as it was, so an
/// append to a large document costs what the append does.
///
/// Not thread-safe: use one instance per document, from one queue.
public final class IncrementalParser: @unchecked Sendable {
    private var resolver: ResourceResolver?
    private var resolverID = "none"
    /// Fragment blocks from the previous version, by fragment key.
    private var previous: [FragmentKey: MarkdownParser.Fragment] = [:]
    /// Fragments reused in the last parse (for tests).
    private(set) var lastReused = 0
    /// Fragments parsed in the last parse (for tests). Nil after a full parse.
    private(set) var lastParsed: Int? = nil
    /// The last parse was a splice (for tests).
    private(set) var lastSpliced = false
    /// Base heading slugs by text, across versions.
    private let memo = Slugger.Memo()
    /// What the previous version left to splice the next one into (nil: a full parse next).
    private var state: SpliceState? = nil
    /// The identity the next result gets (`ParsedDocument.generation`).
    private var nextGeneration = UInt64.random(in: 1...(UInt64.max >> 1))

    struct SpliceState {
        var source: String
        var lines: [String]
        /// UTF-8 offset of each line's first byte in `source`.
        var lineStarts: [Int]
        var frontMatterEnd: Int?
        /// The last line with `]:` or `[^` (link or footnote definitions and references), -1 for none.
        /// Only splicing a document that defines footnotes stops at it.
        var lastSpecial: Int
        var ids: Set<String>
        // Per fragment, in order:
        var starts: [Int]
        var keys: [FragmentKey]
        var trackers: [FenceTracker]
        var checkpoints: [MarkdownParser.Assembler.Checkpoint]
        /// Prefix sums of prose counts (cjk, other): index k sums fragments 0..<k.
        var counts: [(cjk: Int, other: Int)]
        var mixedIsCJK: Bool
        /// The anchors given, at the end of the document, and how (to take back the last ones).
        var slugger: Slugger
        var slugLog: [Slugger.Undo]
        /// The footnotes section the result ends with.
        var section: Block?
        /// How many fragments have each key.
        var keyCount: [FragmentKey: Int]
        var result: ParsedDocument
    }

    /// `doc` with the next identity, and what it kept of `base` (nil: nothing known).
    private func identified(_ doc: ParsedDocument, base: UInt64? = nil, prefix: Int = 0, suffix: Int = 0) -> ParsedDocument {
        var doc = doc
        doc.generation = nextGeneration
        nextGeneration &+= 1
        doc.splice = base.map { ParsedDocument.Splice(base: $0, prefix: prefix, suffix: suffix) }
        return doc
    }

    struct FragmentKey: Hashable {
        let hash: UInt64
        let lineCount: Int
        let atStart: Bool
        /// The defined footnote ids, for fragments that may reference one.
        let footnotes: UInt64
    }

    public init(resolver: ResourceResolver? = nil) {
        self.resolver = resolver
        self.resolverID = resolver.map { "resolver:" + $0.identity } ?? "none"
    }

    /// Parses with a (possibly changed) resolver: nothing resolved against
    /// a different one (other search folders) is reused, neither fragments
    /// nor the rendered HTML in `cache`.
    public func parse(_ rawSource: String, resolver: ResourceResolver?, cache: MarkdownParser.RenderCache? = nil) -> ParsedDocument {
        self.resolver = resolver
        return parse(rawSource, cache: cache)
    }

    /// Parses with the current resolver, whose identity is checked on every
    /// call (a resolver may change its configuration).
    public func parse(_ rawSource: String, cache: MarkdownParser.RenderCache? = nil) -> ParsedDocument {
        let id = resolver.map { "resolver:" + $0.identity } ?? "none"
        if id != resolverID {
            previous = [:]
            state = nil
            cache?.clear()
            resolverID = id
        }
        lastSpliced = false
        if state != nil, let doc = splice(rawSource, cache: cache) {
            lastSpliced = true
            return doc
        }
        let lines = MarkdownParser.sourceLines(rawSource)
        // Footnote definitions leave the flow (as in `parseFragment`); the
        // fragmenter reads the lines the Markdown parser will see.
        var flow = lines
        // Front matter is not Markdown: no definitions come from it (as in parseFragment).
        let frontMatter = MarkdownParser.frontMatterEnd(lines)
        if let end = frontMatter { for i in 0...end { flow[i] = "" } }
        let definitions = flow.contains(where: { Footnotes.mentions($0) }) ? Footnotes.extract(&flow) : []
        if let end = frontMatter { for i in 0...end { flow[i] = lines[i] } }
        guard !Self.needsFullParse(flow) else {
            previous = [:]
            state = nil
            lastReused = 0
            lastParsed = nil
            return identified(MarkdownParser.assemble([(offset: 0, fragment: MarkdownParser.parseFragment(
                lines, atDocumentStart: true, resolver: resolver, cache: cache))]))
        }
        let ids = Set(definitions.map(\.id))
        let idsHash = ids.isEmpty ? 0 : XXHash64.hash(ids.sorted().joined(separator: "\u{1F}"))
        var entries: [(offset: Int, slice: [String], key: FragmentKey)] = []
        var trackers: [FenceTracker] = []
        let ranges = Self.walk(flow, start: 0, i: frontMatter.map { $0 + 1 } ?? 0, fences: FenceTracker(),
                               snapshots: &trackers, record: true, stop: nil).ranges
        for range in ranges {
            let slice = Array(lines[range])
            let text = slice.joined(separator: "\n")
            let key = FragmentKey(hash: XXHash64.hash(text), lineCount: slice.count, atStart: range.lowerBound == 0,
                                  footnotes: idsHash != 0 && Footnotes.mentions(text) ? idsHash : 0)
            entries.append((range.lowerBound, slice, key))
        }
        // Fragments not in the previous version, each parsed once (the same
        // text may occur twice), concurrently: they depend on nothing outside them.
        var next: [FragmentKey: MarkdownParser.Fragment] = [:]
        var jobs: [(slice: [String], key: FragmentKey)] = []
        var queued = Set<FragmentKey>()
        for e in entries where previous[e.key] == nil && queued.insert(e.key).inserted { jobs.append((e.slice, e.key)) }
        let parsedFragments = Self.parseFragments(jobs.map { ($0.slice, $0.key.atStart) }, footnoteIDs: ids,
                                                  resolver: resolver, cache: cache)
        for (job, fragment) in zip(jobs, parsedFragments) { next[job.key] = fragment }
        // Reused fragments keep their blocks' HTML in the render cache.
        var keep: [String] = []
        var parts: [(offset: Int, fragment: MarkdownParser.Fragment)] = []
        parts.reserveCapacity(entries.count)
        for e in entries {
            if let fragment = next[e.key] {
                parts.append((e.offset, fragment))
            } else if let fragment = previous[e.key] {
                next[e.key] = fragment
                keep += fragment.cacheKeys
                parts.append((e.offset, fragment))
            }
        }
        cache?.keep(keep)
        previous = next
        lastReused = entries.count - jobs.count
        lastParsed = jobs.count
        // Assembled with a checkpoint per fragment, so the next version can resume after its unchanged prefix.
        var asm = MarkdownParser.Assembler()
        asm.memo = memo
        asm.slugLog = []
        var counts: [(cjk: Int, other: Int)] = [(0, 0)]
        counts.reserveCapacity(parts.count + 1)
        for p in parts { let c = MarkdownParser.Assembler.counts(p.fragment); counts.append((counts.last!.cjk + c.cjk, counts.last!.other + c.other)) }
        asm.mixedIsCJK = counts.last!.cjk > counts.last!.other
        var checkpoints: [MarkdownParser.Assembler.Checkpoint] = []
        checkpoints.reserveCapacity(parts.count)
        for p in parts { checkpoints.append(asm.checkpoint); asm.add(offset: p.offset, fragment: p.fragment) }
        let bodyCount = asm.out.count
        let doc = identified(asm.finish())
        // Splicing reads the source as bytes: only sources whose lines are its bytes split at LF.
        if !rawSource.utf8.starts(with: [0xEF, 0xBB, 0xBF]), !FastBytes.contains(rawSource, 0x0D) {
            var starts: [Int] = []
            starts.reserveCapacity(lines.count)
            var o = 0
            for l in lines { starts.append(o); o += l.utf8.count + 1 }
            var keyCount: [FragmentKey: Int] = [:]
            for e in entries { keyCount[e.key, default: 0] += 1 }
            var source = rawSource
            source.makeContiguousUTF8()
            state = SpliceState(source: source, lines: lines, lineStarts: starts, frontMatterEnd: frontMatter,
                                lastSpecial: Self.lastSpecial(lines, from: 0) ?? -1, ids: ids,
                                starts: entries.map(\.offset), keys: entries.map(\.key), trackers: trackers,
                                checkpoints: checkpoints, counts: counts, mixedIsCJK: asm.mixedIsCJK,
                                slugger: asm.slugger, slugLog: asm.slugLog ?? [],
                                section: doc.blocks.count > bodyCount ? doc.blocks.last : nil,
                                keyCount: keyCount, result: doc)
        } else {
            state = nil
        }
        return doc
    }

    /// The last line at or after `from` holding `]:` or `[^`.
    static func lastSpecial(_ lines: [String], from: Int, to: Int? = nil) -> Int? {
        var k = (to ?? lines.count) - 1
        while k >= from {
            if FastBytes.contains(lines[k], 0x5D, 0x3A) || FastBytes.contains(lines[k], 0x5B, 0x5E) { return k }
            k -= 1
        }
        return nil
    }

    // MARK: Splicing

    /// The new version as the previous one with the changed run of lines
    /// replaced: the source is compared as bytes (common prefix and suffix),
    /// fragmenting resumes at the fragment before the change with the fence
    /// state it had there and stops once it is back on a boundary of the
    /// previous version in the unchanged suffix with the same state, and
    /// assembly resumes from the checkpoint at the first changed fragment.
    /// The blocks before it are kept as they are, and those after it too
    /// (moved by the lines added or removed) when no heading changed.
    ///
    /// Nil when the change is one splicing does not cover: in the first
    /// fragment or the front matter, a link or footnote definition made in
    /// it, footnote definitions or references at or after it in a document
    /// that defines footnotes, a CJK emphasis marker character in it
    /// (`CJKEmphasis`: such a block keeps what is in it, decided per block),
    /// or the document's CJK reading flipping (it touches every block). The
    /// caller then parses as before, from nothing kept here.
    private func splice(_ rawSource: String, cache: MarkdownParser.RenderCache?) -> ParsedDocument? {
        // Taken out, so the arrays below are changed in place (nil until it is put back).
        guard var st = state else { return nil }
        state = nil
        if rawSource.utf8.starts(with: [0xEF, 0xBB, 0xBF]) || FastBytes.contains(rawSource, 0x0D) { return nil }
        var new = rawSource
        new.makeContiguousUTF8()
        let oldLen = st.source.utf8.count, newLen = new.utf8.count
        // Common prefix and suffix, in bytes.
        let (p, q): (Int, Int) = st.source.utf8.withContiguousStorageIfAvailable { a in
            new.utf8.withContiguousStorageIfAvailable { b in Self.commonEnds(a, b) }
        }.flatMap { $0 } ?? (-1, -1)
        guard p >= 0 else { return nil }
        if p == oldLen && p == newLen {
            cache?.resume()
            lastReused = st.keys.count; lastParsed = 0
            let doc = identified(st.result, base: st.result.generation, prefix: st.result.blocks.count)
            st.result.generation = doc.generation
            state = st
            return doc
        }
        let oldCount = st.lines.count
        // The first changed line: the one holding byte p.
        let changed = Self.lastIndex(st.lineStarts, atMost: p)
        // Old lines wholly in the common suffix (the LF before them too), after the changed line.
        var oldSuffixFrom = oldCount
        if q > 0 {
            let first = Self.firstIndex(st.lineStarts, atLeast: oldLen - q + 1)
            oldSuffixFrom = max(first, changed + 1)
        }
        let suffixCount = oldCount - oldSuffixFrom
        let byteShift = newLen - oldLen
        let windowStart = st.lineStarts[changed]
        let windowEnd = suffixCount > 0 ? st.lineStarts[oldSuffixFrom] + byteShift - 1 : newLen
        guard windowEnd >= windowStart, windowStart <= newLen else { return nil }
        // Resume at the fragment holding the changed line, or the one before
        // when the change is on its first line (the boundary looked at it).
        let k = Self.lastIndex(st.starts, atMost: changed)
        let r = st.starts[k] < changed ? k : k - 1
        guard r >= 1 else { return nil }
        let S = st.starts[r]
        guard st.frontMatterEnd.map({ $0 < S }) ?? true else { return nil }
        // With footnotes defined, their numbers follow the order of the
        // references: a change before one may renumber it. Without any, `[^`
        // and `]:` after the change are text (a document defining links is
        // parsed in full, never spliced): only a definition the change itself
        // makes (looked for below) matters.
        let footnotesDefined = !st.ids.isEmpty
        if footnotesDefined { guard st.lastSpecial < S else { return nil } }
        // The old lines replaced, before they go.
        let removedMarker = CJKEmphasis.containsMarker(st.lines[changed..<oldSuffixFrom])
        // The new lines: the old ones before the change, the window split, the old suffix.
        let windowLines: [String] = new.utf8.withContiguousStorageIfAvailable { b in
            FastBytes.lines(String(decoding: UnsafeBufferPointer(rebasing: b[windowStart..<windowEnd]), as: UTF8.self))
        } ?? []
        st.lines.replaceSubrange(changed..<oldSuffixFrom, with: windowLines)
        let lineCount = st.lines.count
        let delta = lineCount - oldCount
        let suffixStart = lineCount - suffixCount
        guard MarkdownParser.frontMatterEnd(st.lines) == st.frontMatterEnd else { return nil }
        if footnotesDefined { guard Self.lastSpecial(st.lines, from: S, to: suffixStart) == nil else { return nil } }
        // Fragment from S until back on an old boundary in the suffix with the same fence state.
        var trackers: [FenceTracker] = []
        var resync: Int? = nil
        let walked = Self.walk(st.lines, start: S, i: S, fences: st.trackers[r], snapshots: &trackers, record: true) { j, fences in
            guard j >= suffixStart else { return false }
            let o = j - delta
            let idx = Self.lastIndex(st.starts, atMost: o)
            guard st.starts[idx] == o, idx > r, st.trackers[idx] == fences else { return false }
            resync = idx
            return true
        }
        let windowRanges = walked.ranges
        let fragmentCount = st.starts.count
        let oldEnd = resync ?? fragmentCount   // old fragments r..<oldEnd are replaced
        let windowEndLine = resync.map { st.starts[$0] + delta } ?? lineCount
        // No definition from the change to where fragmenting is back in step,
        // with the fences as they are now (a fence opened or closed by the
        // change can turn a `[x]:` line that was code into one).
        if !footnotesDefined && Self.defines(st.lines[S..<windowEndLine], fences: st.trackers[r]) { return nil }
        // A marker character where the emphasis policy decides per block: as before.
        if removedMarker || CJKEmphasis.containsMarker(st.lines[S..<windowEndLine]) { return nil }
        // Keys and parses of the window's fragments.
        var windowKeys: [FragmentKey] = []
        var jobs: [(slice: [String], key: FragmentKey)] = []
        var queued = Set<FragmentKey>()
        for range in windowRanges {
            let slice = Array(st.lines[range])
            let key = FragmentKey(hash: XXHash64.hash(slice.joined(separator: "\n")), lineCount: slice.count, atStart: false, footnotes: 0)
            windowKeys.append(key)
            if previous[key] == nil && queued.insert(key).inserted { jobs.append((slice, key)) }
        }
        cache?.resume()
        let parsed = Self.parseFragments(jobs.map { ($0.slice, false) }, footnoteIDs: st.ids, resolver: resolver, cache: cache)
        var fresh: [FragmentKey: MarkdownParser.Fragment] = [:]
        for (job, f) in zip(jobs, parsed) { fresh[job.key] = f }
        let windowFragments = windowKeys.map { fresh[$0] ?? previous[$0]! }
        // The document's CJK reading must not flip (it touches every block).
        var c = 0, o = 0
        for f in windowFragments { let n = MarkdownParser.Assembler.counts(f); c += n.cjk; o += n.other }
        let total = st.counts[fragmentCount]
        let cjk = total.cjk - (st.counts[oldEnd].cjk - st.counts[r].cjk) + c
        let other = total.other - (st.counts[oldEnd].other - st.counts[r].other) + o
        guard (cjk > other) == st.mixedIsCJK else {
            // Keep what was parsed: the full parse reuses it.
            for (k, f) in fresh { previous[k] = f }
            return nil
        }

        // Assemble: the old blocks before the change, the window from the checkpoint, the rest.
        let cp = st.checkpoints[r]
        let oldBodyEnd = st.result.blocks.count - (st.section == nil ? 0 : 1)
        // Nothing the rest's assembly reads changed (headings above it, anchors given): its blocks are kept.
        let headingFree = resync.map { rs in
            !windowFragments.contains { $0.blocks.contains { $0.kind == .heading } }
                && !st.result.blocks[cp.blocks..<st.checkpoints[rs].blocks].contains { $0.kind == .heading }
        } ?? false
        var asm = MarkdownParser.Assembler()
        asm.memo = memo
        asm.mixedIsCJK = st.mixedIsCJK
        swap(&asm.out, &st.result.blocks)
        // (Copied out before they are cut off; the rest is changed in place.)
        var kept: [Block] = []
        if headingFree, let rs = resync { kept = Array(asm.out[st.checkpoints[rs].blocks..<oldBodyEnd]) }
        asm.out.removeSubrange(cp.blocks...)
        asm.headingStack = cp.headingStack
        asm.currentPath = cp.currentPath
        asm.title = cp.title
        swap(&asm.slugger, &st.slugger)
        asm.slugLog = []
        swap(&asm.slugLog!, &st.slugLog)
        // Heading-free: no anchor is given from the checkpoint on, and those after stay given.
        if !headingFree { asm.rewindSlugs(to: cp.slugs) }
        var windowCheckpoints: [MarkdownParser.Assembler.Checkpoint] = []
        var windowCounts: [(cjk: Int, other: Int)] = []
        var sums = st.counts[r]
        for (range, f) in zip(windowRanges, windowFragments) {
            windowCheckpoints.append(asm.checkpoint)
            asm.add(offset: range.lowerBound, fragment: f)
            let n = MarkdownParser.Assembler.counts(f)
            sums = (sums.cjk + n.cjk, sums.other + n.other)
            windowCounts.append(sums)
        }
        // Heading-free, the log still holds the anchors after the window: before
        // each window fragment, as many were given as at the checkpoint.
        if headingFree { for i in windowCheckpoints.indices { windowCheckpoints[i].slugs = cp.slugs } }
        let prefixBlocks = cp.blocks
        var suffixBlocks = st.section == nil ? 0 : 1
        var restCheckpoints: [MarkdownParser.Assembler.Checkpoint] = []
        if let rs = resync {
            if headingFree {
                let blockShift = asm.out.count - st.checkpoints[rs].blocks
                if delta == 0 {
                    asm.out += kept
                } else {
                    asm.out.reserveCapacity(asm.out.count + kept.count + 1)
                    for b in kept {
                        var nb = Block(kind: b.kind, headingPath: b.headingPath, lines: (b.lines.lowerBound + delta)...(b.lines.upperBound + delta),
                                       fingerprint: b.fingerprint, taskState: b.taskState, html: b.html, text: b.text, source: b.source,
                                       headingLevel: b.headingLevel, headingTitle: b.headingTitle, anchor: b.anchor)
                        nb.cjk = b.cjk
                        nb.cjkMixed = b.cjkMixed
                        asm.out.append(nb)
                    }
                }
                suffixBlocks += kept.count
                restCheckpoints = st.checkpoints[rs...].map { var x = $0; x.blocks += blockShift; return x }
            } else {
                for idx in rs..<fragmentCount {
                    restCheckpoints.append(asm.checkpoint)
                    asm.add(offset: st.starts[idx] + delta, fragment: previous[st.keys[idx]]!)
                }
            }
            for idx in rs..<fragmentCount {
                sums = (sums.cjk + st.counts[idx + 1].cjk - st.counts[idx].cjk, sums.other + st.counts[idx + 1].other - st.counts[idx].other)
                windowCounts.append(sums)
            }
        }
        kept = []
        if let section = st.section { asm.out.append(section) }
        // Heading-free, the kept blocks never went through `add`, so `asm.title`
        // stops at the window. No heading changed, so the first H1 (before, in
        // or after the window) is the previous result's: its title still holds.
        let title = headingFree ? st.result.title : asm.title
        let doc = identified(ParsedDocument(blocks: asm.out, title: title), base: st.result.generation,
                             prefix: prefixBlocks, suffix: suffixBlocks)
        asm.out = []

        // Fragments and cached HTML that the replaced run alone held go.
        let replacedKeys = Array(st.keys[r..<oldEnd])
        for k in windowKeys { st.keyCount[k, default: 0] += 1 }
        for (k, f) in fresh { previous[k] = f }
        let live = Set(windowFragments.flatMap(\.cacheKeys))
        for k in replacedKeys {
            let n = (st.keyCount[k] ?? 1) - 1
            if n <= 0 {
                st.keyCount[k] = nil
                if let f = previous.removeValue(forKey: k) { cache?.drop(f.cacheKeys.filter { !live.contains($0) }) }
            } else { st.keyCount[k] = n }
        }
        lastReused = st.keys.count - (oldEnd - r) + windowKeys.count - jobs.count
        lastParsed = jobs.count

        // The state for the next version, changed in place.
        st.source = new
        st.lineStarts.replaceSubrange(changed..<oldSuffixFrom, with: Self.starts(windowLines, from: windowStart))
        if byteShift != 0 { for i in (changed + windowLines.count)..<st.lineStarts.count { st.lineStarts[i] += byteShift } }
        let w = windowRanges.count
        st.starts.replaceSubrange(r..<oldEnd, with: windowRanges.map(\.lowerBound))
        if delta != 0 { for i in (r + w)..<st.starts.count { st.starts[i] += delta } }
        st.keys.replaceSubrange(r..<oldEnd, with: windowKeys)
        st.trackers.replaceSubrange(r..<oldEnd, with: trackers.prefix(w))
        st.checkpoints.replaceSubrange(r..., with: windowCheckpoints + restCheckpoints)
        st.counts.replaceSubrange((r + 1)..., with: windowCounts)
        swap(&st.slugger, &asm.slugger)
        swap(&st.slugLog, &asm.slugLog!)
        st.result = doc
        state = st
        return doc
    }

    static func starts(_ lines: [String], from: Int) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(lines.count)
        var o = from
        for l in lines { out.append(o); o += l.utf8.count + 1 }
        return out
    }

    /// The last index whose value is at most `x` (values ascending, the first at most x).
    static func lastIndex(_ a: [Int], atMost x: Int) -> Int {
        var lo = 0, hi = a.count - 1
        while lo < hi { let mid = (lo + hi + 1) >> 1; if a[mid] <= x { lo = mid } else { hi = mid - 1 } }
        return lo
    }

    /// The first index whose value is at least `x` (a.count if none).
    static func firstIndex(_ a: [Int], atLeast x: Int) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let mid = (lo + hi) >> 1; if a[mid] < x { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    /// Lengths of the common prefix and (not overlapping it) common suffix of two byte buffers.
    static func commonEnds(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> (Int, Int) {
        let n = min(a.count, b.count)
        guard n > 0, let pa = a.baseAddress, let pb = b.baseAddress else { return (0, 0) }
        var p = 0
        let chunk = 4096
        while p + chunk <= n && memcmp(pa + p, pb + p, chunk) == 0 { p += chunk }
        while p < n && pa[p] == pb[p] { p += 1 }
        let room = n - p
        var q = 0
        while q + chunk <= room && memcmp(pa + a.count - q - chunk, pb + b.count - q - chunk, chunk) == 0 { q += chunk }
        while q < room && pa[a.count - 1 - q] == pb[b.count - 1 - q] { q += 1 }
        return (p, q)
    }

    /// Parses fragments, concurrently from 8 on; the results are in the jobs' order.
    static func parseFragments(_ jobs: [(slice: [String], atStart: Bool)], footnoteIDs: Set<String>,
                               resolver: ResourceResolver?, cache: MarkdownParser.RenderCache?) -> [MarkdownParser.Fragment] {
        @Sendable func parse(_ k: Int) -> MarkdownParser.Fragment {
            MarkdownParser.parseFragment(jobs[k].slice, atDocumentStart: jobs[k].atStart, footnoteIDs: footnoteIDs,
                                         resolver: resolver, cache: cache)
        }
        guard jobs.count >= 8 else { return jobs.indices.map(parse) }
        let results = UnsafeMutableBufferPointer<MarkdownParser.Fragment?>.allocate(capacity: jobs.count)
        results.initialize(repeating: nil)
        defer { results.deinitialize(); results.deallocate() }
        // Each iteration writes only its own element.
        nonisolated(unsafe) let slots = results
        DispatchQueue.concurrentPerform(iterations: jobs.count) { k in slots[k] = parse(k) }
        return results.map { $0! }
    }

    // MARK: Fragmenting

    /// Link reference definitions reach across the whole document, also
    /// from inside a list item or block quote.
    private static let documentWide = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*(?:>|(?:[-*+]|\d{1,9}[.)])(?=[ \t]|$)))*[ \t]*\[(?:\\.|[^\]\\])+\]:"#)

    /// True when `lines` (footnote definitions taken out) define link
    /// references outside code and raw HTML.
    static func needsFullParse(_ lines: [String]) -> Bool {
        var fences = FenceTracker()
        for line in lines.dropFirst(MarkdownParser.frontMatterEnd(lines).map { $0 + 1 } ?? 0) {
            if fences.consume(line) { continue }
            if FastBytes.contains(line, 0x5D, 0x3A) {   // "]:"
                let ns = line as NSString
                if documentWide.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil { return true }
            }
        }
        return false
    }

    /// Whether `lines`, read from `fences` on, define a link reference or a
    /// footnote outside code and raw HTML.
    static func defines(_ lines: ArraySlice<String>, fences start: FenceTracker) -> Bool {
        var fences = start
        for line in lines {
            if fences.consume(line) { continue }
            if FastBytes.contains(line, 0x5D, 0x3A) {   // "]:"
                let ns = line as NSString
                if documentWide.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil { return true }
            }
        }
        return false
    }

    /// A hash of the link reference definitions in `lines` (each definition
    /// line and the line after it, where a title may continue), nil without any.
    static func linkDefinitionsHash(_ lines: [String]) -> UInt64? {
        func mentionsDefinition(_ line: String) -> Bool { FastBytes.contains(line, 0x5D, 0x3A) }   // "]:"
        guard lines.contains(where: mentionsDefinition) else { return nil }
        var fences = FenceTracker()
        var text = ""
        var found = false
        for (i, line) in lines.enumerated() {
            if fences.consume(line) { continue }
            guard mentionsDefinition(line) else { continue }
            let ns = line as NSString
            guard documentWide.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil else { continue }
            found = true
            text += line + "\n" + (i + 1 < lines.count ? lines[i + 1] : "") + "\n"
        }
        return found ? XXHash64.hash(text) : nil
    }

    private static let listMarker = try! NSRegularExpression(pattern: #"^\d{1,9}[.)](?:[ \t]|$)"#)

    /// True when a line can begin a fresh top-level block that nothing before
    /// a blank line can continue: it starts at column 0 and is not a list
    /// item, quote, table row, HTML, fence, link definition, thematic break
    /// or setext underline.
    static func startsFresh(_ line: String) -> Bool {
        guard let c = line.unicodeScalars.first else { return false }
        switch c {
        case " ", "\t", "-", "*", "+", ">", "|", "<", "`", "~", "[", "=", "_", "$", "\\", ":": return false
        default: break
        }
        if ("0"..."9").contains(c) {
            let ns = line as NSString
            if listMarker.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil { return false }
        }
        return true
    }

    /// Line ranges of the fragments, covering every line exactly once.
    static func fragments(_ lines: [String]) -> [Range<Int>] {
        var unused: [FenceTracker] = []
        return walk(lines, start: 0, i: MarkdownParser.frontMatterEnd(lines).map { $0 + 1 } ?? 0, fences: FenceTracker(),
                    snapshots: &unused, record: false, stop: nil).ranges
    }

    /// Fragments from the one starting at `start` (the loop at line `i`
    /// with `fences` as they were there). With `record`, the fence state at
    /// each fragment's start (`snapshots`, one per range). `stop` is asked
    /// at each new fragment start and ends the walk there when true.
    static func walk(_ lines: [String], start s0: Int, i i0: Int, fences f0: FenceTracker,
                     snapshots: inout [FenceTracker], record: Bool,
                     stop: ((Int, FenceTracker) -> Bool)?) -> (ranges: [Range<Int>], stopped: Int?) {
        var out: [Range<Int>] = []
        var start = s0
        var fences = f0
        if record { snapshots.append(fences) }
        // Front matter is never cut (and never read as Markdown).
        var i = i0
        while i < lines.count {
            let line = lines[i]
            if fences.consume(line) {
                i += 1
                continue
            }
            // Multi-line display math: its lines are paragraph text to the
            // Markdown parser (`MathProtector.protect`), whatever they hold.
            if !fences.indentedCode, FastBytes.contains(line, 0x24, 0x24), let block = MathProtector.displayBlock(lines, at: i) {
                for _ in (i + 1)...block.end { fences.continueParagraph() }
                i = block.end + 1
                continue
            }
            // A neutral boundary: this line is blank, the next non-blank line
            // starts fresh, and nothing is open (code, raw HTML, <details>).
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) && !fences.isOpen {
                var j = i + 1
                while j < lines.count && lines[j].allSatisfy({ $0 == " " || $0 == "\t" }) { j += 1 }
                if j < lines.count && startsFresh(lines[j]) && j > start {
                    out.append(start..<j)
                    start = j
                    i = j
                    if let stop, stop(j, fences) { return (out, j) }
                    if record { snapshots.append(fences) }
                    continue
                }
            }
            i += 1
        }
        if start < lines.count || out.isEmpty { out.append(start..<max(lines.count, start)) }
        return (out, nil)
    }
}
