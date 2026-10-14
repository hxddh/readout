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

    public mutating func next(_ text: String) -> String {
        var base = Slugger.slug(text)
        // Reader chrome ids live under the ro-* namespace (see docs/design.md):
        // a document slug starting with ro- would collide with them, so keep
        // GitHub-compatible slugs otherwise and escape only this case.
        if base.hasPrefix("ro-") { base = "h-" + base }
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
        seen[base] = n + 1
        used.insert(candidate)
        return candidate
    }
}
