import Foundation

/// What a slug keeps beyond ASCII letters and digits (built once: building it per call is slow).
private let slugKeep = CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters)

/// GitHub-compatible heading slugs, with per-document de-duplication.
public struct Slugger {
    private var seen: [String: Int] = [:]
    private var used: Set<String> = []
    public init() {}

    public static func slug(_ text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar == " " { out += "-"; continue }
            if scalar == "-" || scalar == "_" { out.unicodeScalars.append(scalar); continue }
            // Letters, marks and numbers of every kind (², ½, Ⅻ), as GitHub keeps them.
            if scalar.isASCII ? (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
                : slugKeep.contains(scalar) || scalar.properties.numericType != nil {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Base slugs by heading text, kept by `IncrementalParser` across
    /// versions (a document's headings are slugged again on every update).
    /// Not thread-safe: one per parser, used from its queue.
    final class Memo: @unchecked Sendable {
        var map: [String: String] = [:]
        func base(_ text: String) -> String {
            if let b = map[text] { return b }
            let base = Slugger.base(text)
            if map.count > 20_000 { map = [:] }
            map[text] = base
            return base
        }
    }

    /// What one `next` changed, to take it back (`undo`): `IncrementalParser`
    /// resumes assembly at a fragment with the anchors given after it taken back.
    struct Undo {
        let base: String
        let seen: Int?
        let candidate: String
    }

    static func base(_ text: String) -> String {
        let base = Slugger.slug(text)
        // Reader chrome ids live under the ro-* namespace (see docs/design.md):
        // a document slug starting with ro- would collide with them, so keep
        // GitHub-compatible slugs otherwise and escape only this case.
        return base.hasPrefix("ro-") ? "h-" + base : base
    }

    public mutating func next(_ text: String) -> String {
        var log: [Undo]? = nil
        return next(text, memo: nil, log: &log)
    }

    mutating func next(_ text: String, memo: Memo?, log: inout [Undo]?) -> String {
        let base = memo?.base(text) ?? Slugger.base(text)
        // An explicit "Notes-1" heading followed by a repeated "Notes" would
        // otherwise both claim "notes-1": keep probing until the candidate is
        // actually unused.
        var n = seen[base] ?? 0
        var candidate = base
        if n > 0 { candidate = "\(base)-\(n)" }
        while used.contains(candidate) {
            n += 1
            candidate = "\(base)-\(n)"
        }
        log?.append(Undo(base: base, seen: seen[base], candidate: candidate))
        seen[base] = n + 1
        used.insert(candidate)
        return candidate
    }

    /// Takes back the `next` that logged `u` (the last one not yet taken back).
    mutating func undo(_ u: Undo) {
        seen[u.base] = u.seen
        used.remove(u.candidate)
    }
}
