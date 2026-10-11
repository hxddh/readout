import Foundation
import Testing
@testable import ReadoutCore

/// The real-agent corpus (web/test/corpus) is rendered by the WebKit screenshot
/// tests from patch JSON produced here. This test keeps those patches in step
/// with the parser: any parser change that alters output fails until the
/// patches (and therefore the screenshots) are regenerated and reviewed.
///
/// Regenerate: READOUT_UPDATE_CORPUS=1 swift test --filter CorpusTests
@Suite struct CorpusTests {
    static let corpus = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("web/test/corpus")

    static func documents() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" && $0.lastPathComponent.first?.isNumber == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Hermetic: no base directory, so path links and local images never
    /// depend on the machine running the test.
    static func patchJSON(_ url: URL) throws -> Data {
        let text = FileContent.decode(try Data(contentsOf: url)).text
        let doc = MarkdownParser.parse(text, resolver: FileResolver(baseDirectory: nil))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(DocumentSession().load(doc))
    }

    @Test func corpusIsPresent() {
        #expect(Self.documents().count >= 30)
    }

    @Test func patchesAreCurrent() throws {
        let update = ProcessInfo.processInfo.environment["READOUT_UPDATE_CORPUS"] == "1"
        let dir = Self.corpus.appendingPathComponent("patches")
        if update { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        var stale: [String] = []
        for doc in Self.documents() {
            let name = doc.deletingPathExtension().lastPathComponent + ".json"
            let target = dir.appendingPathComponent(name)
            let fresh = try Self.patchJSON(doc)
            if update { try fresh.write(to: target); continue }
            if (try? Data(contentsOf: target)) != fresh { stale.append(name) }
        }
        #expect(stale.isEmpty, "Parser output changed for \(stale). Regenerate with READOUT_UPDATE_CORPUS=1 swift test --filter CorpusTests, then update screenshots (web: npm run corpus -- --update) and review the diffs.")
    }

    @Test func parsingIsDeterministic() throws {
        for doc in Self.documents().prefix(5) {
            #expect(try Self.patchJSON(doc) == Self.patchJSON(doc))
        }
    }
}
