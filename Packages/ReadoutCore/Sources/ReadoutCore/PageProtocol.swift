import Foundation

/// What the reader page speaks, from its `ready` message (docs/design.md,
/// Pipeline: the page protocol). Version 1 is the page that sends a bare
/// `{type: "ready"}`: every op carries its block's HTML and the page keeps
/// every block. From version 2 the page lists capabilities; the app uses a
/// form only when the page announced it, so a page that does not know it
/// sees nothing change.
public struct PageProtocol: Equatable, Sendable {
    /// The protocol this app speaks.
    public static let current = 2
    /// A page that announced nothing: version 1, no capabilities.
    public static let legacy = PageProtocol(version: 1, capabilities: [])

    public enum Capability: String, Sendable {
        /// The page takes lean patches (`RenderPatch.page(lean:)`: ops
        /// without HTML, with what lays the block out unmounted), asks for
        /// blocks' HTML (`PageMessage.blocks`) and takes the replies
        /// (`window.readout.blocks(BlockReply)`).
        case lean
    }

    public let version: Int
    public let capabilities: Set<Capability>

    public init(version: Int, capabilities: Set<Capability>) {
        self.version = version
        self.capabilities = capabilities
    }

    /// From the page's `ready` message: `{type: "ready", protocol: 2, caps: ["lean"]}`.
    /// Unknown capabilities are ignored; a capability needs version 2.
    public init(ready msg: [String: Any]) {
        let v = (msg["protocol"] as? NSNumber)?.intValue ?? (msg["protocol"] as? Int) ?? 1
        let caps = ((msg["caps"] as? [Any]) ?? []).compactMap { ($0 as? String).flatMap(Capability.init(rawValue:)) }
        self.init(version: max(1, v), capabilities: v >= 2 ? Set(caps) : [])
    }

    /// Patches go to the page lean, and it may ask for blocks.
    public var lean: Bool { version >= 2 && capabilities.contains(.lean) }
}

/// What the page's height estimate of a block it has not mounted takes
/// (web/src/reader/patch.js `estimateHeight`, which today reads it from the
/// HTML): the HTML's length in UTF-16 code units, its line count
/// (`html.split('\n').length`) and its table rows (`<tr>`). With the block's
/// kind, the page lays out a block it does not hold. Derived from the HTML
/// when a lean op is built, not stored.
public struct BlockLayout: Codable, Sendable, Equatable {
    /// `html.length` in the page.
    public let chars: Int
    /// `html.split('\n').length`: 1 for HTML without a line break.
    public let lines: Int
    /// Occurrences of `<tr>`.
    public let rows: Int

    public init(chars: Int, lines: Int, rows: Int) {
        self.chars = chars; self.lines = lines; self.rows = rows
    }

    public init(html: String) {
        var lines = 1, rows = 0
        // `<tr>`: 0x3C 0x74 0x72 0x3E.
        var a: UInt8 = 0, b: UInt8 = 0, c: UInt8 = 0
        for byte in html.utf8 {
            if byte == 0x0A { lines += 1 }
            else if byte == 0x3E, c == 0x72, b == 0x74, a == 0x3C { rows += 1 }
            a = b; b = c; c = byte
        }
        self.init(chars: html.utf16.count, lines: lines, rows: rows)
    }

    // One line and no rows (most blocks) are left out of the JSON.
    enum CodingKeys: String, CodingKey { case chars, lines, rows }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chars = try c.decode(Int.self, forKey: .chars)
        lines = try c.decodeIfPresent(Int.self, forKey: .lines) ?? 1
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chars, forKey: .chars)
        if lines != 1 { try c.encode(lines, forKey: .lines) }
        if rows != 0 { try c.encode(rows, forKey: .rows) }
    }
}

extension RenderPatch {
    /// An op as a lean patch carries it: the op without its HTML, with the
    /// block's layout in its place. An op without HTML (a remove, a replace
    /// whose block renders the same) is the same in both forms. (Its own
    /// type, so the ops the update path builds stay as they were.)
    public struct LeanOp: Encodable, Sendable, Equatable {
        public let op: Op
        public init(_ op: Op) { self.op = op }
        public var layout: BlockLayout? { op.html.map(BlockLayout.init(html:)) }

        enum CodingKeys: String, CodingKey { case op, slot, after, change, kind, cjk, anchor, src, tight, layout }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(op.op, forKey: .op)
            try c.encode(op.slot, forKey: .slot)
            try c.encodeIfPresent(op.after, forKey: .after)
            try c.encodeIfPresent(op.change, forKey: .change)
            try c.encodeIfPresent(op.kind, forKey: .kind)
            try c.encodeIfPresent(op.cjk, forKey: .cjk)
            try c.encodeIfPresent(op.anchor, forKey: .anchor)
            try c.encodeIfPresent(op.src, forKey: .src)
            try c.encodeIfPresent(op.tight, forKey: .tight)
            try c.encodeIfPresent(layout, forKey: .layout)
        }
    }

    /// The patch as a page that announced `lean` takes it: `Page` with lean
    /// ops, and `lean: true`.
    public struct LeanPage: Encodable, Sendable {
        public let version: Int
        public let reset: Bool
        public let rewrite: Bool
        public let ops: [LeanOp]
        public let marks: [Mark]
        public let deletions: [Deletion]
        public let links: [LinkDefinition]?
        public let lean = true
    }

    /// What is sent to the page: `Page`, or `LeanPage` to a page that announced `lean`.
    public enum Outgoing: Encodable, Sendable {
        case full(Page)
        case lean(LeanPage)

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .full(let p): try p.encode(to: encoder)
            case .lean(let p): try p.encode(to: encoder)
            }
        }
    }

    /// The patch for a page that announced `lean` (`lean: true`): every op
    /// without HTML (`LeanOp`), which the page asks for when it mounts the
    /// block (`PageMessage.blocks`). Otherwise `page`, as before.
    public func page(lean: Bool) -> Outgoing {
        guard lean else { return .full(page) }
        return .lean(LeanPage(version: version, reset: reset, rewrite: rewrite, ops: ops.map(LeanOp.init),
                              marks: marks, deletions: deletions, links: links))
    }
}

/// The app's reply to `PageMessage.blocks` (`window.readout.blocks(reply)`):
/// the asked blocks' HTML in the version the session holds now. The session
/// keeps no other version, so a request for an earlier one gets the current
/// HTML with `stale` set; the page uses a reply only when `version` is the
/// version it has applied (a patch the app sent before the reply has
/// reached it first: calls run in order), and asks again otherwise.
public struct BlockReply: Encodable, Sendable, Equatable {
    public struct Served: Encodable, Sendable, Equatable {
        public let slot: Int
        public let html: String
    }
    /// The page's request id, echoed.
    public let request: Int
    /// The version the HTML is of: the session's current.
    public let version: Int
    /// The page asked for another version than `version`.
    public let stale: Bool
    /// The asked blocks this version has, in the order asked (each once).
    public let blocks: [Served]
    /// The asked slots this version has no block for (removed).
    public let missing: [Int]
}
