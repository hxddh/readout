import Foundation

/// Finds the current index of the block the reader was on when the baseline was
/// saved. Block indices shift as agents edit; the saved text excerpt survives that.
public enum ExcerptAnchor {
    /// - Parameter near: the block index where the excerpt was saved. When
    ///   several blocks match (agent plans repeat similar list items), the
    ///   candidate nearest `near` wins instead of always the first.
    public static func index(of excerpt: String, in texts: [String], near: Int? = nil) -> Int? {
        guard !excerpt.isEmpty else { return nil }
        if let near, let i = nearestMatch(in: texts, near: near, by: { $0.hasPrefix(excerpt) }) { return i }
        if let i = texts.firstIndex(where: { $0.hasPrefix(excerpt) }) { return i }
        // Edited mid-block: fall back to containment, first of the whole excerpt,
        // then of its first half. Short excerpts are ambiguous — leave those to
        // the caller's index fallback instead of guessing.
        if excerpt.count >= 24 {
            if let near, let i = nearestMatch(in: texts, near: near, by: { $0.contains(excerpt) }) { return i }
            if let i = texts.firstIndex(where: { $0.contains(excerpt) }) { return i }
            let half = String(excerpt.prefix(max(24, excerpt.count / 2)))
            if half.count >= 24 {
                if let near, let i = nearestMatch(in: texts, near: near, by: { $0.contains(half) }) { return i }
                if let i = texts.firstIndex(where: { $0.contains(half) }) { return i }
            }
        }
        return nil
    }

    /// The block to resume reading at: the saved excerpt's block, else (an
    /// excerpt too short to find, or edited since) the saved index. A
    /// position without an excerpt is not one Readout saves: none (nil). A
    /// document rewritten since it was read has no index fallback: the index
    /// points into unrelated text, and the reader starts at the top (nil).
    public static func resumeIndex(excerpt: String?, index: Int?, in texts: [String], rewritten: Bool) -> Int? {
        guard let excerpt else { return nil }
        if let i = self.index(of: excerpt, in: texts, near: index), i < texts.count { return i }
        if rewritten { return nil }
        if let index, index >= 0, index < texts.count { return index }
        return nil
    }

    private static func nearestMatch(in texts: [String], near: Int, by matches: (String) -> Bool) -> Int? {
        var best: Int?
        for (i, t) in texts.enumerated() where matches(t) {
            if best == nil || abs(i - near) < abs(best! - near) { best = i }
        }
        return best
    }
}
