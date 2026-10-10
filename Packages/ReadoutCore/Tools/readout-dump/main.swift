// Development tool: prints the render patches the app would send for a file, or for an edit between two files.
// Usage: readout-dump FILE [EDITED_FILE]
import Foundation
import ReadoutCore

let args = CommandLine.arguments.dropFirst()
guard let first = args.first else {
    FileHandle.standardError.write("usage: readout-dump FILE [EDITED_FILE]\n".data(using: .utf8)!)
    exit(2)
}

func parse(_ path: String) -> ParsedDocument {
    let url = URL(fileURLWithPath: path)
    let data = (try? Data(contentsOf: url)) ?? Data()
    let text = FileContent.decode(data).text
    return MarkdownParser.parse(text, resolver: FileResolver(baseDirectory: url.deletingLastPathComponent()))
}

let session = DocumentSession()
var patches: [RenderPatch] = [session.load(parse(first))]
if args.count > 1, let p = session.update(parse(args[args.index(after: args.startIndex)])) { patches.append(p) }
let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]
FileHandle.standardOutput.write(try! encoder.encode(patches))
