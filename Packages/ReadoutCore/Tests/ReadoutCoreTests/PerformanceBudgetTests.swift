import Foundation
import Testing
@testable import ReadoutCore

/// Speed of the update path an agent write triggers: decode, hash, parse
/// (with the render cache) and diff into a patch. Inputs are built from the
/// real-agent corpus, so the mix of prose, code, tables and CJK matches what
/// Readout actually reads.
///
/// This suite only measures. Budgets live in tools/perf-budgets.json and are
/// checked by tools/perf-assert.py on the macOS CI runner, where a release
/// build writes its numbers to `READOUT_PERF_OUT`.
@Suite(.serialized) struct PerformanceBudgetTests {
    nonisolated(unsafe) static var results: [String: Any] = [:]

    /// Corpus documents concatenated (in order, repeating) to `bytes`, cut at a block boundary.
    static func document(bytes: Int) -> String {
        let docs = CorpusTests.documents().map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
        var out = ""
        var i = 0
        while out.utf8.count < bytes {
            out += docs[i % docs.count] + "\n\n"
            i += 1
        }
        var cut = out.utf8.prefix(bytes)
        // Back up to the last blank line so the document ends on a block boundary.
        if let r = String(decoding: cut, as: UTF8.self).range(of: "\n\n", options: .backwards) {
            cut = Substring(String(decoding: cut, as: UTF8.self)[..<r.lowerBound]).utf8[...]
        }
        return String(decoding: cut, as: UTF8.self)
    }

    /// The same document with `count` paragraphs edited, spread evenly: what
    /// an agent rewriting a plan in place produces.
    static func edited(_ text: String, count: Int) -> String {
        var paragraphs = text.components(separatedBy: "\n\n")
        let candidates = paragraphs.indices.filter {
            let p = paragraphs[$0]
            return !p.hasPrefix("```") && !p.hasPrefix("|") && !p.hasPrefix("#") && p.count > 40
        }
        guard !candidates.isEmpty else { return text }
        let step = max(1, candidates.count / count)
        for k in stride(from: 0, to: candidates.count, by: step).prefix(count) {
            paragraphs[candidates[k]] += " (revised: clarified the failure mode and added a rollback step)"
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Median wall time of the full update path, in milliseconds.
    static func measureUpdate(original: String, edited: String, runs: Int = 9) -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            // The app's path: one incremental parser per document (DocumentLoader).
            let cache = MarkdownParser.RenderCache()
            let session = DocumentSession()
            let parser = IncrementalParser()
            let resolver = FileResolver(baseDirectory: nil)
            cache.beginGeneration()
            _ = session.load(parser.parse(original, resolver: resolver, cache: cache))
            let data = Data(edited.utf8)
            let start = DispatchTime.now().uptimeNanoseconds
            _ = XXHash64.hash(data)
            let text = FileContent.decode(data).text
            cache.beginGeneration()
            let doc = parser.parse(text, resolver: resolver, cache: cache)
            let patch = session.update(doc)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            precondition(patch != nil, "edit produced no patch")
            samples.append(elapsed)
        }
        return samples.sorted()[samples.count / 2]
    }

    func record(_ name: String, measured: Double, detail: [String: Any]) {
        var entry = detail
        entry["ms"] = (measured * 10).rounded() / 10
        Self.results[name] = entry
        print("perf \(name): \(String(format: "%.1f", measured)) ms")
        Self.write()
    }

    static func write() {
        guard let path = ProcessInfo.processInfo.environment["READOUT_PERF_OUT"],
              let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    @Test func update100KB() {
        let doc = Self.document(bytes: 100_000)
        let ms = Self.measureUpdate(original: doc, edited: Self.edited(doc, count: 20))
        record("update_100kb", measured: ms,
              detail: ["bytes": doc.utf8.count, "edits": 20])
    }

    @Test func update1MB() {
        let doc = Self.document(bytes: 1_000_000)
        let ms = Self.measureUpdate(original: doc, edited: Self.edited(doc, count: 20), runs: 5)
        record("update_1mb", measured: ms,
              detail: ["bytes": doc.utf8.count, "edits": 20])
    }

    @Test func editsAreRealistic() {
        let doc = Self.document(bytes: 100_000)
        let edited = Self.edited(doc, count: 20)
        #expect(doc.utf8.count > 90_000 && doc.utf8.count <= 100_000)
        #expect(edited.components(separatedBy: "(revised:").count - 1 == 20)
    }
}
