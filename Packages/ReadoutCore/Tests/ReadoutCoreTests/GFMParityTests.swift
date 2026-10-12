import Foundation
import Testing
@testable import ReadoutCore

/// Small differences from cmark-gfm and GitHub, each checked against the
/// reference renderer.
@Suite struct GFMParityTests {
    func html(_ s: String) -> String { MarkdownParser.parse(s).blocks.map(\.html).joined() }

    /// cmark-gfm links an email only when its last character is a letter.
    @Test func versionsAreNotEmails() {
        let h = html("npm i react@18.3.1 and pkg@1.0.0, commit abc@1.2.3, a@b.co2; mail x@y.c-d or q@h.io.\n")
        #expect(!h.contains("mailto:react") && !h.contains("mailto:pkg") && !h.contains("mailto:abc") && !h.contains("mailto:a@"))
        #expect(h.contains("<a href=\"mailto:x@y.c-d\">x@y.c-d</a>"))
        #expect(h.contains("<a href=\"mailto:q@h.io\">q@h.io</a>"))
    }

    /// Anchors and TOC titles come from the heading's text: no backticks, no raw tags.
    @Test func headingTextLeavesOutMarkup() {
        let doc = MarkdownParser.parse("## <code>foo</code> bar\n\n## Install `npm` <sub>beta</sub>\n\n## API: `GET /users/{id}`\n")
        #expect(doc.blocks.map(\.anchor) == ["foo-bar", "install-npm-beta", "api-get-usersid"])
        #expect(doc.blocks.map(\.headingTitle) == ["foo bar", "Install npm beta", "API: GET /users/{id}"])
        #expect(doc.blocks[0].html.contains("<code>foo</code> bar"))
    }

    @Test func slugsKeepEveryKindOfNumber() {
        #expect(Slugger.slug("x² and ½") == "x²-and-½")
        #expect(Slugger.slug("Step 2: Setup") == "step-2-setup")
    }

    /// Spec example 79: a blank line between an item's paragraph and its nested list makes the list loose.
    @Test func blankLineBeforeANestedListMakesTheListLoose() {
        #expect(html("1.  foo\n\n    - bar\n").contains("<li><p>foo</p><ul"))
        #expect(html("- a\n\n  - b\n").contains("<li><p>a</p><ul"))
        // No blank line: tight, also when the nested list itself is loose.
        #expect(html("- a\n  - b\n\n  - c\n").hasPrefix("<ul class=\"li-block li-first li-last\"><li>a\n<ul>"))
    }

    @Test func frontMatterMustLookLikeYAML() {
        // Spec examples 66 and 68, and a break, a paragraph and a break.
        #expect(MarkdownParser.parse("---\nFoo\n---\nBar\n---\nBaz\n").blocks.map(\.kind) == [.rule, .heading, .heading, .paragraph])
        #expect(MarkdownParser.parse("---\n---\n").blocks.map(\.kind) == [.rule, .rule])
        #expect(MarkdownParser.parse("---\n\nIntro paragraph\n\n---\n\nMore\n").blocks.map(\.kind) == [.rule, .paragraph, .rule, .paragraph])
        // Still front matter: keys, or only a comment.
        #expect(MarkdownParser.parse("---\ntitle: x\n---\n# Heading\n").blocks.map(\.kind) == [.frontMatter, .heading])
        #expect(MarkdownParser.parse("---\n# docs/spec.md\n---\n\n# Body\n").blocks.map(\.kind) == [.frontMatter, .heading])
        // The incremental parser follows the same rule.
        let src = "---\n\nIntro paragraph\n\n---\n\nMore\n"
        #expect(IncrementalParser().parse(src).blocks.map(\.html) == MarkdownParser.parse(src).blocks.map(\.html))
    }

    @Test func imageTitlesAreKept() {
        #expect(html("![alt](a.png \"The title\")\n").contains("alt=\"alt\" title=\"The title\""))
        let resolved = MarkdownParser.parse("![alt](a.png 'T')\n", resolver: FileResolver(baseDirectory: nil)).blocks[0].html
        #expect(resolved.contains("title=\"T\""))
    }
}
