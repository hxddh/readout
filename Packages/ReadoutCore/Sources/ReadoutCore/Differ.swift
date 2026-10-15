import Foundation

/// The minimal per-block information the differ needs. Also what is persisted as a reading baseline.
public struct BlockKey: Codable, Sendable, Equatable {
    public let fingerprint: UInt64
    public let kind: BlockKind
    /// Normalized text, truncated, for similarity matching.
    public let text: String
    /// The whole text when `text` is cut short, so a changed block can be
    /// compared word by word with what was read. Baselines saved before this
    /// field existed lack it (decoded as nil).
    public let full: String?
    /// Checkbox states of the block's task items (not part of the
    /// fingerprint), so a box ticked while the app was closed is noticed.
    /// Nil for blocks without tasks and in baselines saved before this field existed.
    public let taskState: [Bool]?
    /// The block's Markdown source (`Block.source`) when it differs from
    /// the whole normalized text, "" when it does not; nil in baselines
    /// saved before this field existed, which kept only normalized text.
    public let source: String?
    /// In a baseline: a block of an unread deletion (`DocumentSession.baseline`),
    /// kept removed when the document is opened against it. Nil otherwise.
    public let removed: Bool?

    public init(fingerprint: UInt64, kind: BlockKind, text: String, taskState: [Bool]? = nil, source: String? = "") {
        self.fingerprint = fingerprint
        self.kind = kind
        self.taskState = taskState
        self.source = source == text ? "" : source
        self.removed = nil
        // Similarity matching only needs a prefix: token-bigram Jaccard
        // converges well before 500 characters, and the common case (exact
        // fingerprint match) needs no text at all.
        if text.utf8.count >= 500 && text.count >= 500 {   // fewer bytes: fewer characters
            self.text = String(text.prefix(500))
            self.full = text
        } else {
            self.text = text
            self.full = nil
        }
    }

    /// The block's whole text, or nil when only a prefix was kept (an older baseline).
    public var wholeText: String? { full ?? (text.utf8.count < 500 || text.count < 500 ? text : nil) }

    /// The block's whole Markdown source, or nil when it is not known (an older baseline).
    public var wholeSource: String? {
        guard let source else { return nil }
        return source.isEmpty ? wholeText : source
    }

    public init(_ block: Block) {
        self.init(fingerprint: block.fingerprint, kind: block.kind, text: block.text,
                  taskState: block.taskState.isEmpty ? nil : block.taskState, source: block.source)
    }

    private init(fingerprint: UInt64, kind: BlockKind, text: String, full: String?, taskState: [Bool]?, source: String?, removed: Bool?) {
        self.fingerprint = fingerprint
        self.kind = kind
        self.text = text
        self.full = full
        self.taskState = taskState
        self.source = source
        self.removed = removed
    }

    /// The same key with other checkbox states (as they were read).
    func with(taskState: [Bool]?) -> BlockKey {
        BlockKey(fingerprint: fingerprint, kind: kind, text: text, full: full, taskState: taskState, source: source, removed: removed)
    }

    /// The same key marked as (or no longer) a block of an unread deletion.
    func with(removed: Bool) -> BlockKey {
        BlockKey(fingerprint: fingerprint, kind: kind, text: text, full: full, taskState: taskState, source: source, removed: removed ? true : nil)
    }
}

public struct DiffResult: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case equal(old: Int)
        case modified(old: Int)
        case inserted
    }

    /// One entry per new block.
    public var changes: [Change]
    /// Old indices with no counterpart in the new sequence.
    public var removed: [Int]
    /// True when so little survived that the document should be treated as rewritten.
    public var rewrite: Bool

    public var equalCount: Int { changes.filter { if case .equal = $0 { return true }; return false }.count }
}

public enum Differ {
    public static let similarityThreshold = 0.5
    /// Gaps larger than this (old × new) are not paired, everything becomes insert/delete.
    /// Bounds the worst case (a 100-block section rewritten in place, every
    /// block of distinct words) to a few milliseconds of a release build.
    public static let maxPairingCells = 10_000

    /// Rewritten: almost nothing of the smaller version survives unchanged.
    /// Measured against the smaller one, so a skeleton that grows into a
    /// full document (every old block kept) or a document cut down to a
    /// few of its blocks is an edit, not a rewrite.
    static func isRewrite(equal: Int, old: Int, new: Int) -> Bool {
        old >= 5 && new >= 1 && Double(equal) / Double(min(old, new)) < 0.2
    }

    public static func diff(old: [BlockKey], new: [BlockKey]) -> DiffResult {
        // Step 1: exact matches via Myers diff on fingerprints (bounded, see `equalPairs`).
        let oldFP = old.map(\.fingerprint), newFP = new.map(\.fingerprint)
        guard let equalPairs = Self.equalPairs(oldFP, newFP) else {
            // So little can match that it is a rewrite whatever the alignment: not worth computing.
            return DiffResult(changes: [DiffResult.Change](repeating: .inserted, count: new.count),
                              removed: Array(old.indices), rewrite: true)
        }

        var changes = [DiffResult.Change](repeating: .inserted, count: new.count)
        var matchedOld = Set<Int>()
        for (o, n) in equalPairs { changes[n] = .equal(old: o); matchedOld.insert(o) }

        // Step 2: pair deletions and insertions inside each gap into modifications.
        var prevO = -1, prevN = -1
        for (o, n) in equalPairs + [(old.count, new.count)] {
            let gapOld = Array((prevO + 1)..<o), gapNew = Array((prevN + 1)..<n)
            if !gapOld.isEmpty && !gapNew.isEmpty {
                for (go, gn) in pairGap(old: gapOld.map { old[$0] }, new: gapNew.map { new[$0] }) {
                    changes[gapNew[gn]] = .modified(old: gapOld[go])
                    matchedOld.insert(gapOld[go])
                }
            }
            prevO = o; prevN = n
        }

        let removed = (0..<old.count).filter { !matchedOld.contains($0) }
        let rewrite = isRewrite(equal: equalPairs.count, old: old.count, new: new.count)
        return DiffResult(changes: changes, removed: removed, rewrite: rewrite)
    }

    /// Cells of the edit graph Myers' algorithm may visit in one diff: its
    /// time and memory grow with (N + M) × D, which a rewrite of a
    /// 10,000-block document made seconds and gigabytes. A few milliseconds.
    static let maxMyersWork = 4_000_000

    /// Pairs of equal fingerprints in order (old index, new index), or nil
    /// when so few can match that the diff is a rewrite.
    ///
    /// A count of the fingerprints both sides hold gives an upper bound for
    /// what can match: below the rewrite threshold, nil at once. When Myers'
    /// work is small (the usual edit: few blocks differ), the result is
    /// exactly the alignment of the standard library's Myers diff over the
    /// whole sequences, as before it was bounded. Otherwise the shared start
    /// and end are matched and the middle is diffed with Myers where its
    /// edit distance turns out small, else anchored on fingerprints that
    /// occur once on each side (patience diff), the gaps between them diffed the same way.
    static func equalPairs(_ a: [UInt64], _ b: [UInt64]) -> [(Int, Int)]? {
        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix && suffix < b.count - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let aMid = a[prefix..<(a.count - suffix)], bMid = b[prefix..<(b.count - suffix)]
        if isRewrite(equal: prefix + suffix + min(aMid.count, bMid.count), old: a.count, new: b.count) {
            var counts: [UInt64: Int] = [:]
            counts.reserveCapacity(aMid.count)
            for x in aMid { counts[x, default: 0] += 1 }
            var shared = 0
            for x in bMid { if let c = counts[x], c > 0 { counts[x] = c - 1; shared += 1 } }
            if isRewrite(equal: prefix + suffix + shared, old: a.count, new: b.count) { return nil }
        }
        // Myers over the whole sequences costs (N + M) × D: affordable for the usual edit (D small).
        let budget = maxMyersWork / max(1, a.count + b.count)
        if aMid.count + bMid.count <= budget || editDistance(aMid, bMid, limit: budget) != nil {
            return myersPairs(a[...], b[...])
        }

        var pairs: [(Int, Int)] = (0..<prefix).map { ($0, $0) }
        var work: [(a: Range<Int>, b: Range<Int>)] = [(aMid.indices, bMid.indices)]
        while var (ra, rb) = work.popLast() {
            // The shared start and end of this range.
            while !ra.isEmpty && !rb.isEmpty && a[ra.lowerBound] == b[rb.lowerBound] {
                pairs.append((ra.lowerBound, rb.lowerBound)); ra = ra.dropFirst(); rb = rb.dropFirst()
            }
            while !ra.isEmpty && !rb.isEmpty && a[ra.upperBound - 1] == b[rb.upperBound - 1] {
                pairs.append((ra.upperBound - 1, rb.upperBound - 1)); ra = ra.dropLast(); rb = rb.dropLast()
            }
            if ra.isEmpty || rb.isEmpty { continue }
            let size = ra.count + rb.count
            if size * size <= maxMyersWork || editDistance(a[ra], b[rb], limit: maxMyersWork / size) != nil {
                pairs += myersPairs(a[ra], b[rb])
                continue
            }
            let anchors = uniqueAnchors(a[ra], b[rb])
            var lo = (ra.lowerBound, rb.lowerBound)
            for (x, y) in anchors {
                pairs.append((x, y))
                work.append((lo.0..<x, lo.1..<y))
                lo = (x + 1, y + 1)
            }
            if anchors.isEmpty {
                // Only repeated fingerprints: the k-th occurrence of each paired
                // with its k-th, or a greedy pass, whichever keeps more.
                let byOccurrence = occurrencePairs(a[ra], b[rb]), greedy = greedyPairs(a[ra], b[rb])
                pairs += byOccurrence.count >= greedy.count ? byOccurrence : greedy
            } else {
                work.append((lo.0..<ra.upperBound, lo.1..<rb.upperBound))
            }
        }
        pairs += (0..<suffix).map { (a.count - suffix + $0, b.count - suffix + $0) }
        pairs.sort { $0.0 < $1.0 }
        return pairs
    }

    /// The standard library's Myers diff of two ranges, as pairs of equal elements (indices of the ranges' base).
    private static func myersPairs(_ a: ArraySlice<UInt64>, _ b: ArraySlice<UInt64>) -> [(Int, Int)] {
        let difference = Array(b).difference(from: Array(a))
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
            pairs.append((a.startIndex + oi, b.startIndex + ni)); oi += 1; ni += 1
        }
        return pairs
    }

    /// The Myers edit distance of `a` and `b` if it is at most `limit` (nil
    /// otherwise), in O((N + M) × limit) time and O(limit) memory.
    static func editDistance(_ a: ArraySlice<UInt64>, _ b: ArraySlice<UInt64>, limit: Int) -> Int? {
        let n = a.count, m = b.count, ai = a.startIndex, bi = b.startIndex
        let maxD = min(limit, n + m)
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        for d in 0...maxD {
            for k in stride(from: -d, through: d, by: 2) {
                var x = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n && y < m && a[ai + x] == b[bi + y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { return d }
            }
        }
        return nil
    }

    /// A common subsequence found in one pass: each element of `a` matched
    /// with the next occurrence of the same value in `b` after the last
    /// match. Not always the longest, but linear (for ranges of repeated values only).
    static func greedyPairs(_ a: ArraySlice<UInt64>, _ b: ArraySlice<UInt64>) -> [(Int, Int)] {
        var positions: [UInt64: [Int]] = [:]
        for j in b.indices { positions[b[j], default: []].append(j) }
        var next: [UInt64: Int] = [:]   // per value: the first of its positions not yet passed
        var pairs: [(Int, Int)] = []
        var j = b.startIndex
        for i in a.indices {
            guard let list = positions[a[i]] else { continue }
            var c = next[a[i]] ?? 0
            while c < list.count && list[c] < j { c += 1 }
            if c < list.count {
                pairs.append((i, list[c]))
                j = list[c] + 1
                c += 1
            }
            next[a[i]] = c
        }
        return pairs
    }

    /// Elements occurring exactly once in each range, paired, as the longest
    /// run of such pairs in order on both sides (patience diff's anchors).
    static func uniqueAnchors(_ a: ArraySlice<UInt64>, _ b: ArraySlice<UInt64>) -> [(Int, Int)] {
        var inA: [UInt64: Int] = [:], inB: [UInt64: Int] = [:]   // index, or -1 when repeated
        inA.reserveCapacity(a.count); inB.reserveCapacity(b.count)
        for i in a.indices { inA[a[i]] = inA[a[i]] == nil ? i : -1 }
        for j in b.indices { inB[b[j]] = inB[b[j]] == nil ? j : -1 }
        var candidates: [(Int, Int)] = []
        for i in a.indices { if inA[a[i]] == i, let j = inB[a[i]], j >= 0 { candidates.append((i, j)) } }
        return longestIncreasing(candidates)
    }

    /// Each value's k-th occurrence in `a` paired with its k-th in `b`, as the
    /// longest run of such pairs in order on both sides (rotated or shifted
    /// runs of repeated blocks keep what survives).
    static func occurrencePairs(_ a: ArraySlice<UInt64>, _ b: ArraySlice<UInt64>) -> [(Int, Int)] {
        var positions: [UInt64: [Int]] = [:]
        for j in b.indices { positions[b[j], default: []].append(j) }
        var used: [UInt64: Int] = [:]
        var candidates: [(Int, Int)] = []
        for i in a.indices {
            guard let list = positions[a[i]] else { continue }
            let k = used[a[i]] ?? 0
            if k < list.count { candidates.append((i, list[k])); used[a[i]] = k + 1 }
        }
        return longestIncreasing(candidates)
    }

    /// The longest run of `candidates` (in increasing old index) whose new
    /// indices increase too: patience sorting, O(n log n).
    static func longestIncreasing(_ candidates: [(Int, Int)]) -> [(Int, Int)] {
        var tails: [Int] = []                 // candidate index ending the best run of each length
        var previous = [Int](repeating: -1, count: candidates.count)
        for (c, pair) in candidates.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi { let mid = (lo + hi) / 2; if candidates[tails[mid]].1 < pair.1 { lo = mid + 1 } else { hi = mid } }
            if lo > 0 { previous[c] = tails[lo - 1] }
            if lo == tails.count { tails.append(c) } else { tails[lo] = c }
        }
        var out: [(Int, Int)] = []
        var c = tails.last ?? -1
        while c >= 0 { out.append(candidates[c]); c = previous[c] }
        return out.reversed()
    }

    /// Order-preserving maximum-weight matching over pairs with similarity above the threshold.
    static func pairGap(old: [BlockKey], new: [BlockKey]) -> [(Int, Int)] {
        let a = old.count, b = new.count
        if a * b > maxPairingCells { return [] }
        if a == 1 && b == 1 {
            // A one-for-one replacement of the same kind of block is almost always an edit.
            if old[0].kind == new[0].kind { return [(0, 0)] }
            return similarity(old[0], new[0]) >= similarityThreshold || grew(old[0], into: new[0]) ? [(0, 0)] : []
        }
        // Each block's shingles are built once (a + b sets, not 2ab), as
        // sorted ids (a token's id, or a pair of them for a bigram), so a
        // cell is one merge of two short arrays.
        var ids: [String: Int64] = [:]
        func shingleIDs(_ k: BlockKey) -> [Int64] {
            let tokens = Similarity.tokens(k.text).map { t -> Int64 in
                if let v = ids[t] { return v }
                let v = Int64(ids.count + 1); ids[t] = v; return v
            }
            var out = tokens
            if tokens.count >= 2 { for i in 0..<(tokens.count - 1) { out.append(tokens[i] << 32 | tokens[i + 1]) } }
            out.sort()
            var unique: [Int64] = []
            unique.reserveCapacity(out.count)
            for v in out where unique.last != v { unique.append(v) }
            return unique
        }
        let os = old.map(shingleIDs), ns = new.map(shingleIDs)
        var sim = [Double](repeating: 0, count: a * b)
        for i in 0..<a {
            for j in 0..<b {
                var s = similarity(old[i], os[i], new[j], ns[j])
                // A block written half-way that grew (and split into several
                // blocks) is edited, not removed: its text is in the new one.
                if s < similarityThreshold, contained(old[i], os[i], in: new[j], ns[j]) { s = similarityThreshold }
                sim[i * b + j] = s
            }
        }
        // dp[i][j] = best total for old[i...], new[j...]
        let w = b + 1
        var dp = [Double](repeating: 0, count: (a + 1) * w)
        for i in stride(from: a - 1, through: 0, by: -1) {
            for j in stride(from: b - 1, through: 0, by: -1) {
                var best = max(dp[(i + 1) * w + j], dp[i * w + j + 1])
                let s = sim[i * b + j]
                if s >= similarityThreshold { best = max(best, s + dp[(i + 1) * w + j + 1]) }
                dp[i * w + j] = best
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a && j < b {
            let s = sim[i * b + j]
            if s >= similarityThreshold && abs(dp[i * w + j] - (s + dp[(i + 1) * w + j + 1])) < 1e-9 {
                pairs.append((i, j)); i += 1; j += 1
            } else if abs(dp[i * w + j] - dp[(i + 1) * w + j]) < 1e-9 {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// `x` is the start of `y`: a block being streamed in that grew. Of the
    /// same kind, or a paragraph that became another kind once complete (a
    /// table row before its delimiter row, the first backtick of a fence).
    static func grew(_ x: BlockKey, into y: BlockKey) -> Bool {
        guard x.kind == y.kind || x.kind == .paragraph, !x.text.isEmpty, x.text.utf8.count <= y.text.utf8.count else { return false }
        return y.text.hasPrefix(x.text)
    }

    /// `x` grew into `y`, or nearly all of `x`'s shingles are in `y`, a block of the same kind.
    static func contained(_ x: BlockKey, _ xs: [Int64], in y: BlockKey, _ ys: [Int64]) -> Bool {
        if grew(x, into: y) { return true }
        guard x.kind == y.kind, xs.count >= 4, xs.count <= ys.count else { return false }
        var p = 0, q = 0, inter = 0
        while p < xs.count && q < ys.count {
            if xs[p] == ys[q] { inter += 1; p += 1; q += 1 } else if xs[p] < ys[q] { p += 1 } else { q += 1 }
        }
        return Double(inter) >= 0.9 * Double(xs.count)
    }

    /// `similarity` over precomputed sorted shingle ids.
    private static func similarity(_ x: BlockKey, _ xs: [Int64], _ y: BlockKey, _ ys: [Int64]) -> Double {
        let penalty = x.kind == y.kind ? 1.0 : 0.5
        if xs.isEmpty && ys.isEmpty { return x.text == y.text ? penalty : 0 }
        let small = min(xs.count, ys.count), large = max(xs.count, ys.count)
        // Jaccard is at most small / large: skip the merge when that cannot reach the threshold.
        if Double(small) / Double(large) * penalty < similarityThreshold { return 0 }
        var p = 0, q = 0, inter = 0
        while p < xs.count && q < ys.count {
            if xs[p] == ys[q] { inter += 1; p += 1; q += 1 } else if xs[p] < ys[q] { p += 1 } else { q += 1 }
        }
        return Double(inter) / Double(xs.count + ys.count - inter) * penalty
    }

    static func similarity(_ x: BlockKey, _ y: BlockKey) -> Double {
        var s = Similarity.jaccard(x.text, y.text)
        if x.kind != y.kind { s *= 0.5 }
        return s
    }
}
