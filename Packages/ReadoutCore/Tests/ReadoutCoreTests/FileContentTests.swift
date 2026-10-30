import Foundation
import Testing
@testable import ReadoutCore

@Suite struct FileContentTests {
    @Test func stripsBOM() {
        let d = FileContent.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hi".utf8))
        #expect(d.text == "hi")
    }

    @Test func utf16WithAndWithoutByteOrderMark() {
        let text = "# Hi\n\n中文 and English.\n"
        let le = FileContent.decode(Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!)
        let be = FileContent.decode(Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!)
        let bare = FileContent.decode(text.data(using: .utf16LittleEndian)!)
        for d in [le, be, bare] {
            #expect(d.text == text)
            #expect(d.fallbackEncoding?.hasPrefix("UTF-16") == true)
            #expect(!d.truncatedTail)
        }
        // Half a code unit at the end: still being written.
        let cut = FileContent.decode((Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!).dropLast())
        #expect(cut.truncatedTail && cut.text == "# Hi\n\n中文 and English.")
        // Cut between the two halves of a surrogate pair: also a half-written tail.
        let emoji = Data([0xFF, 0xFE]) + "# Hi 🚀".data(using: .utf16LittleEndian)!
        let half = FileContent.decode(emoji.dropLast(2))
        #expect(half.truncatedTail && half.text == "# Hi ")
        #expect(!half.text.contains("\u{FFFD}"))
        // UTF-8 stays UTF-8.
        #expect(FileContent.decode(Data(text.utf8)).fallbackEncoding == nil)
    }

    @Test func truncatedUTF8Tail() {
        let full = Data("中文".utf8)
        let d = FileContent.decode(full.dropLast(1))
        #expect(d.truncatedTail)
        #expect(d.text == "中")
    }

    /// Only an incomplete UTF-8 sequence at the end is a cut: a Latin-1 or
    /// Windows-1252 character before the last line break is another
    /// encoding, and dropping bytes would lose text.
    @Test func otherEncodingsAreNotATruncatedTail() {
        for (bytes, start) in [(Data([0x63, 0x61, 0x66, 0xE9, 0x0A]), "caf"), (Data([0x35, 0x80, 0x0A]), "5")] {
            let d = FileContent.decode(bytes)
            #expect(!d.truncatedTail)
            #expect(d.fallbackEncoding != nil)
            #expect(d.text.hasPrefix(start) && d.text.hasSuffix("\n"))
            #expect(d.text.components(separatedBy: "\n").count == 2)
        }
        // Ending in ASCII, or continuation bytes with no lead byte before them: no cut.
        #expect(!FileContent.decode(Data([0xE9, 0x61])).truncatedTail)
        let cut = FileContent.decode(Data("a中".utf8).prefix(3))
        #expect(cut.truncatedTail && cut.text == "a")
        let cut2 = FileContent.decode(Data("a 🚀".utf8).dropLast(1))
        #expect(cut2.truncatedTail && cut2.text == "a ")
        #expect(FileContent.incompleteTail(Data([0x61, 0x80, 0x80])) == 0)
    }

    @Test func halfWriteVerdicts() {
        #expect(FileContent.verdict(newSize: 0, previousSize: 100, secondsSincePreviousWrite: 5, truncatedTail: false, retriesSoFar: 0) == .waitForMore)
        #expect(FileContent.verdict(newSize: 10, previousSize: 100, secondsSincePreviousWrite: 0.2, truncatedTail: false, retriesSoFar: 0) == .waitForMore)
        #expect(FileContent.verdict(newSize: 10, previousSize: 100, secondsSincePreviousWrite: 5, truncatedTail: false, retriesSoFar: 0) == .accept)
        #expect(FileContent.verdict(newSize: 0, previousSize: 100, secondsSincePreviousWrite: 0.1, truncatedTail: false, retriesSoFar: 2) == .accept)
        #expect(FileContent.verdict(newSize: 120, previousSize: nil, secondsSincePreviousWrite: nil, truncatedTail: true, retriesSoFar: 0) == .waitForMore)
    }

    @Test func largeDocumentPerformance() {
        var parts: [String] = []
        for i in 0..<1500 {
            parts.append("## Section \(i)\n\nThis is paragraph \(i) with `code` and **bold** text and a [link](https://example.com/\(i)).\n\n- item a \(i)\n- [ ] task \(i)\n\n```swift\nlet value\(i) = \(i)\n```\n")
        }
        let src = parts.joined(separator: "\n")
        let t0 = Date()
        let doc = MarkdownParser.parse(src)
        let parseTime = Date().timeIntervalSince(t0)
        let s = DocumentSession()
        _ = s.load(doc)
        var edited = parts
        edited[700] += "\nAn inserted paragraph.\n"
        let doc2 = MarkdownParser.parse(edited.joined(separator: "\n"))
        let t1 = Date()
        let patch = s.update(doc2)
        let diffTime = Date().timeIntervalSince(t1)
        print("perf: \(src.utf8.count) bytes, \(doc.blocks.count) blocks, parse \(Int(parseTime * 1000)) ms, diff \(Int(diffTime * 1000)) ms")
        #expect(patch?.ops.count == 1)
        #expect(parseTime < 5)
    }
}
