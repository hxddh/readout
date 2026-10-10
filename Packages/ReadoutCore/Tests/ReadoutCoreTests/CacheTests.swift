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
}
