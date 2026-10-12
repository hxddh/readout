import Foundation
import Testing
@testable import ReadoutCore

@Suite struct CacheTests {
    @Test func cachedReparseIsFastAndIdentical() {
        var parts: [String] = []
        for i in 0..<1500 { parts.append("## S\(i)\n\nPara \(i) with **bold** and `code`.\n\n- a \(i)\n- [ ] t \(i)\n") }
        let src = parts.joined(separator: "\n")
        let cache = MarkdownParser.RenderCache()
        cache.beginGeneration()
        let a = MarkdownParser.parse(src, cache: cache)
        cache.beginGeneration()
        let t = Date()
        let b = MarkdownParser.parse(src, cache: cache)
        print("prof cached reparse: \(Int(Date().timeIntervalSince(t) * 1000)) ms")
        #expect(a.blocks.map(\.html) == b.blocks.map(\.html))
        #expect(a.blocks.map(\.html) == MarkdownParser.parse(src).blocks.map(\.html))
    }

    /// Parses versions the way DocumentLoader does: one incremental parser and render cache.
    static func versions(_ sources: [String], resolver: ResourceResolver? = nil) -> [ParsedDocument] {
        let cache = MarkdownParser.RenderCache()
        let parser = IncrementalParser()
        return sources.map { src in
            cache.beginGeneration()
            return parser.parse(src, resolver: resolver, cache: cache)
        }
    }

    @Test func changedOrDeletedLinkDefinitionIsNotServedFromTheCache() {
        let use = "See the [docs] for details.\n"
        let docs = Self.versions([use + "\n[docs]: https://old.example.com\n",
                                  use + "\n[docs]: https://new.example.com\n",
                                  use])
        #expect(docs[0].blocks[0].html.contains("https://old.example.com"))
        #expect(docs[1].blocks[0].html.contains("https://new.example.com"))
        #expect(docs[2].blocks[0].html == "<p>See the [docs] for details.</p>")
    }

    @Test func blocksThatReadFilesAreNotServedFromTheCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("readout-cache-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolver = FileResolver(baseDirectory: dir)
        let cache = MarkdownParser.RenderCache()
        let src = "# T\n\n![shot](shot.png)\n\nSee `notes.txt` here.\n"
        cache.beginGeneration()
        let before = MarkdownParser.parse(src, resolver: resolver, cache: cache)
        #expect(!before.blocks[1].html.contains("width="))
        #expect(!before.blocks[2].html.contains("path-link"))
        // The image and the file appear; the blocks' source is unchanged.
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        png += [0, 0, 0x02, 0x80, 0, 0, 0x01, 0xE0] + [UInt8](repeating: 0, count: 10)
        try Data(png).write(to: dir.appendingPathComponent("shot.png"))
        try "x".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        cache.beginGeneration()
        let after = MarkdownParser.parse(src.replacingOccurrences(of: "# T", with: "# T2"), resolver: resolver, cache: cache)
        #expect(after.blocks[1].html.contains("width=\"640\" height=\"480\""))
        #expect(after.blocks[2].html.contains("path-link"))
        // Blocks that read no file are still served from the cache.
        cache.beginGeneration()
        let plain = "Plain paragraph with `code`.\n"
        _ = MarkdownParser.parse(plain, resolver: resolver, cache: cache)
        #expect(cache.lookup("\(XXHash64.hash("Plain paragraph with `code`."))|paragraph|") != nil)
    }
}
