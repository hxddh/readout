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

    public init(fingerprint: UInt64, kind: BlockKind, text: String) {
        self.fingerprint = fingerprint
        self.kind = kind
        // Similarity matching only needs a prefix: token-bigram Jaccard
        // converges well before 500 characters, and the common case (exact
        // fingerprint match) needs no text at all.
        if text.count >= 500 {
            self.text = String(text.prefix(500))
            self.full = text
        } else {
            self.text = text
            self.full = nil
        }
    }

    /// The block's whole text, or nil when only a prefix was kept (an older baseline).
    public var wholeText: String? { full ?? (text.count < 500 ? text : nil) }

    public init(_ block: Block) {
        self.init(fingerprint: block.fingerprint, kind: block.kind, text: block.text)
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
    public static let maxPairingCells = 40_000

    public static func diff(old: [BlockKey], new: [BlockKey]) -> DiffResult {
        // Step 1: exact matches via Myers diff on fingerprints.
        let oldFP = old.map(\.fingerprint), newFP = new.map(\.fingerprint)
        let difference = newFP.difference(from: oldFP)
        var removedOld = Set<Int>(), insertedNew = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removedOld.insert(offset)
            case let .insert(offset, _, _): insertedNew.insert(offset)
            }
        }
        var equalPairs: [(Int, Int)] = []
        var oi = 0, ni = 0
        while oi < old.count && ni < new.count {
            if removedOld.contains(oi) { oi += 1; continue }
            if insertedNew.contains(ni) { ni += 1; continue }
            equalPairs.append((oi, ni)); oi += 1; ni += 1
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
        let rewrite = old.count >= 5 && new.count >= 1
            && Double(equalPairs.count) / Double(max(old.count, new.count)) < 0.2
        return DiffResult(changes: changes, removed: removed, rewrite: rewrite)
    }

    /// Order-preserving maximum-weight matching over pairs with similarity above the threshold.
    static func pairGap(old: [BlockKey], new: [BlockKey]) -> [(Int, Int)] {
        let a = old.count, b = new.count
        if a * b > maxPairingCells { return [] }
        if a == 1 && b == 1 {
            // A one-for-one replacement of the same kind of block is almost always an edit.
            if old[0].kind == new[0].kind { return [(0, 0)] }
            return similarity(old[0], new[0]) >= similarityThreshold ? [(0, 0)] : []
        }
        var sim = [[Double]](repeating: [Double](repeating: 0, count: b), count: a)
        for i in 0..<a { for j in 0..<b { sim[i][j] = similarity(old[i], new[j]) } }
        // dp[i][j] = best total for old[i...], new[j...]
        var dp = [[Double]](repeating: [Double](repeating: 0, count: b + 1), count: a + 1)
        for i in stride(from: a - 1, through: 0, by: -1) {
            for j in stride(from: b - 1, through: 0, by: -1) {
                var best = max(dp[i + 1][j], dp[i][j + 1])
                if sim[i][j] >= similarityThreshold { best = max(best, sim[i][j] + dp[i + 1][j + 1]) }
                dp[i][j] = best
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a && j < b {
            if sim[i][j] >= similarityThreshold && abs(dp[i][j] - (sim[i][j] + dp[i + 1][j + 1])) < 1e-9 {
                pairs.append((i, j)); i += 1; j += 1
            } else if abs(dp[i][j] - dp[i + 1][j]) < 1e-9 {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    static func similarity(_ x: BlockKey, _ y: BlockKey) -> Double {
        var s = Similarity.jaccard(x.text, y.text)
        if x.kind != y.kind { s *= 0.5 }
        return s
    }
}
