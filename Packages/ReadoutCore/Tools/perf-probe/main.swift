// Development and CI tool: the update path of PerformanceBudgetTests (an
// agent rewriting 20 paragraphs of a corpus-built document) as a program,
// and the other paths CI counts.
//
// Usage: perf-probe CORPUS_DIR BYTES [RUNS | load | bytes] [SCENARIO]
//   SCENARIO: update (default): load the document, then 20 paragraphs edited;
//             append: load it, then one paragraph appended at the end (an agent writing on);
//             open-unique: the first open of a document whose blocks are all distinct
//             (the corpus repeated with every repetition's prose lines marked), so
//             nothing is shared between its blocks.
//   RUNS > 0: prints the fastest and median wall time of RUNS measured steps.
//   RUNS = 0 (default): runs up to and including the measured step once.
//   load: runs up to the measured step only (for update and append, loads the document).
//   bytes: prints the size of the measured step's patch as sent to the page (JSON).
// The step's instruction count, which does not depend on the machine, is
// the difference between RUNS = 0 and load under valgrind (Tools/perf-instructions.sh).
// Parsing runs on several threads, so the count covers the whole process.
// Documents are built as in PerformanceBudgetTests.document / .edited.
import Foundation
import ReadoutCore

let args = CommandLine.arguments
guard args.count >= 3, let bytes = Int(args[2]) else {
    FileHandle.standardError.write("usage: perf-probe CORPUS_DIR BYTES [RUNS | load | bytes] [update | append | open-unique]\n".data(using: .utf8)!)
    exit(2)
}
let corpus = URL(fileURLWithPath: args[1])
let loadOnly = args.count > 3 && args[3] == "load"
let printBytes = args.count > 3 && args[3] == "bytes"
let runs = args.count > 3 ? Int(args[3]) ?? 0 : 0
let scenario = args.count > 4 ? args[4] : "update"
guard ["update", "append", "open-unique"].contains(scenario) else {
    FileHandle.standardError.write("unknown scenario \(scenario)\n".data(using: .utf8)!)
    exit(2)
}

let docs = ((try? FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "md" && $0.lastPathComponent.first?.isNumber == true }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
guard !docs.isEmpty else {
    FileHandle.standardError.write("no corpus documents in \(corpus.path)\n".data(using: .utf8)!)
    exit(2)
}

func document(bytes: Int, unique: Bool = false) -> String {
    var out = ""
    var i = 0
    while out.utf8.count < bytes { out += (unique ? marked(docs[i % docs.count], i / docs.count) : docs[i % docs.count]) + "\n\n"; i += 1 }
    var cut = out.utf8.prefix(bytes)
    if let r = String(decoding: cut, as: UTF8.self).range(of: "\n\n", options: .backwards) {
        cut = Substring(String(decoding: cut, as: UTF8.self)[..<r.lowerBound]).utf8[...]
    }
    return String(decoding: cut, as: UTF8.self)
}

/// `text` with ` r<round>` after each prose line (not in code, tables, HTML,
/// rules, link definitions or display math), so each round of the corpus differs.
func marked(_ text: String, _ round: Int) -> String {
    guard round > 0 else { return text }
    var inFence = false
    return text.split(separator: "\n", omittingEmptySubsequences: false).map { l -> String in
        let t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); return String(l) }
        if inFence || t.isEmpty || t.hasPrefix("|") || t.hasPrefix("<") || t.hasPrefix("---") || t.hasPrefix("[")
            || t.hasPrefix("$$") || t.hasSuffix("$$") { return String(l) }
        return String(l) + " r\(round)"
    }.joined(separator: "\n")
}

func edited(_ text: String, count: Int) -> String {
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

/// The measured update: hash, decode, parse with the render cache, diff into a patch.
@inline(never)
func measuredUpdate(_ data: Data, _ parser: IncrementalParser, _ session: DocumentSession,
                    _ cache: MarkdownParser.RenderCache, _ resolver: FileResolver) -> RenderPatch? {
    _ = XXHash64.hash(data)
    let text = FileContent.decode(data).text
    cache.beginGeneration()
    let doc = parser.parse(text, resolver: resolver, cache: cache)
    return session.update(doc)
}

/// The measured first open: the same, into a new session.
@inline(never)
func measuredOpen(_ data: Data, _ parser: IncrementalParser, _ session: DocumentSession,
                  _ cache: MarkdownParser.RenderCache, _ resolver: FileResolver) -> RenderPatch? {
    _ = XXHash64.hash(data)
    let text = FileContent.decode(data).text
    cache.beginGeneration()
    let doc = parser.parse(text, resolver: resolver, cache: cache)
    return session.load(doc)
}

let original = document(bytes: bytes, unique: scenario == "open-unique")
let data: Data
switch scenario {
case "append": data = Data((original + "\n\nThe agent appended this new paragraph describing the next step of the plan.\n").utf8)
case "open-unique": data = Data(original.utf8)
default: data = Data(edited(original, count: 20).utf8)
}
var samples: [Double] = []
for _ in 0..<max(runs, 1) {
    let cache = MarkdownParser.RenderCache(), session = DocumentSession(), parser = IncrementalParser()
    let resolver = FileResolver(baseDirectory: nil)
    if scenario != "open-unique" {
        cache.beginGeneration()
        _ = session.load(parser.parse(original, resolver: resolver, cache: cache))
    }
    if loadOnly { print("loaded"); exit(0) }
    let start = DispatchTime.now().uptimeNanoseconds
    let patch = scenario == "open-unique"
        ? measuredOpen(data, parser, session, cache, resolver)
        : measuredUpdate(data, parser, session, cache, resolver)
    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    let ops = patch?.ops.count ?? -1
    precondition(ops > 0, "edit produced no patch")
    if printBytes {
        // As the app sends it (ReaderWebView: JSONEncoder, slashes not escaped).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        print((try? encoder.encode(patch!.page).count) ?? -1)
        exit(0)
    }
    // Exit as `load` does, without freeing the documents, so the two runs differ by the measured step only.
    if runs == 0 { print("ops \(ops)"); exit(0) }
}
if runs > 0 {
    let sorted = samples.sorted()
    print(String(format: "%@ %d bytes: min %.2f ms, median %.2f ms (%d runs)",
                 scenario, original.utf8.count, sorted[0], sorted[sorted.count / 2], runs))
}
