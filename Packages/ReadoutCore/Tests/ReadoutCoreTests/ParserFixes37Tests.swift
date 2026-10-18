import Foundation
import Testing
@testable import ReadoutCore

/// 3.7 parser and rendering fixes. Each test failed on 3.6.0.
@Suite struct ParserFixes37Tests {
    func html(_ md: String) -> String { MarkdownParser.parse(md).blocks.map(\.html).joined(separator: "\n") }

    /// The incremental parser (fresh, and after an edit from a neutral
    /// version) gives exactly the full parse.
    func expectIncrementalMatchesFull(_ text: String, _ note: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        let full = MarkdownParser.parse(text)
        let fresh = IncrementalParser().parse(text)
        #expect(fresh.blocks == full.blocks && fresh.title == full.title, note, sourceLocation: sourceLocation)
        let warm = IncrementalParser()
        _ = warm.parse("Intro.\n\n" + text)
        let edited = warm.parse(text)
        #expect(edited.blocks == full.blocks && edited.title == full.title, note, sourceLocation: sourceLocation)
    }

    // MARK: L1: a tab-indented line after a table

    /// A line indented by a tab (4 columns) after a table is not a row: the
    /// fence tracker counted spaces only and saw a row where cmark ends the
    /// table, so a fence after it split differently (fuzz seeds 480 and 530).
    @Test func tabIndentedLineAfterTableMatchesIncremental() {
        expectIncrementalMatchesFull("x|d\n-|-\n\td\n$$\n<a>\n```\n\ne")
        expectIncrementalMatchesFull("$$ $$\n```\n```\n\nn|||\n-|-|-\n\t[^3]\n[^3]:")
        expectIncrementalMatchesFull("| a | b |\n| - | - |\n\tcode\n```\nx\n```\n\nafter")
        expectIncrementalMatchesFull("||\n|-|\n\tx\n```\n\ny")
    }

    // MARK: T5: a line break between wide CJK characters is no space

    func paragraph(_ md: String) -> String { MarkdownParser.parse(md).blocks[0].html }

    @Test func softBreakBetweenWideCJKIsRemoved() {
        #expect(paragraph("第一行的文字\n第二行的文字") == "<p>第一行的文字第二行的文字</p>")
        #expect(paragraph("日本語の文章が\nここで続きます。") == "<p>日本語の文章がここで続きます。</p>")
        #expect(paragraph("句号结束。\n下一句") == "<p>句号结束。下一句</p>")
        // Through emphasis and links: the characters on both sides decide.
        #expect(paragraph("**注意**\n这里") == "<p><strong>注意</strong>这里</p>")
        #expect(paragraph("见[文档](a.md)\n后面") == "<p>见<a href=\"a.md\">文档</a>后面</p>")
    }

    @Test func softBreakNextToOtherTextStays() {
        #expect(paragraph("中文句子\nEnglish line") == "<p>中文句子\nEnglish line</p>")
        #expect(paragraph("English line\n中文句子") == "<p>English line\n中文句子</p>")
        #expect(paragraph("한국어 문장\n다음 줄") == "<p>한국어 문장\n다음 줄</p>")   // Hangul uses spaces
        #expect(paragraph("中文”\n“引号") == "<p>中文”\n“引号</p>")   // quotation marks are ambiguous width
        #expect(paragraph("中文 `code`\n中文") == "<p>中文 <code>code</code>\n中文</p>")
        #expect(paragraph("one\ntwo") == "<p>one\ntwo</p>")
        // `Key：value` lines keep their line breaks.
        #expect(paragraph("状态：完成\n结果：通过") == "<p>状态：完成<br>结果：通过</p>")
    }

    // MARK: T10: CJK-friendly emphasis

    /// /tmp/claude-0/v37/type/docs/flank.md: CommonMark keeps the asterisks.
    @Test func emphasisNextToCJKPunctuation() {
        #expect(paragraph("**注意：**这里是正文。") == "<p><strong>注意：</strong>这里是正文。</p>")
        #expect(paragraph("**“引号加粗”**之后的文字。") == "<p><strong>“引号加粗”</strong>之后的文字。</p>")
        #expect(paragraph("这是**加粗（括号）**的文字。") == "<p>这是<strong>加粗（括号）</strong>的文字。</p>")
        #expect(paragraph("*强调。*后面") == "<p><em>强调。</em>后面</p>")
        #expect(paragraph("使用`code`**粗体**结束。") == "<p>使用<code>code</code><strong>粗体</strong>结束。</p>")
        #expect(paragraph("**C#**や**F#**は**「.NET」**というプラットフォーム上で動作します。")
                == "<p><strong>C#</strong>や<strong>F#</strong>は<strong>「.NET」</strong>というプラットフォーム上で動作します。</p>")
        #expect(paragraph("**推荐几个框架：**React、Vue等前端框架。") == "<p><strong>推荐几个框架：</strong>React、Vue等前端框架。</p>")
        #expect(paragraph("- **步骤一：**安装依赖") == "<ul><li><strong>步骤一：</strong>安装依赖</li></ul>"
                || paragraph("- **步骤一：**安装依赖").contains("<strong>步骤一：</strong>安装依赖"))
        #expect(paragraph("> **提示：**先备份").contains("<strong>提示：</strong>先备份"))
        // Underscores: the character a variation selector varies decides.
        #expect(paragraph("正體字。︁_Traditional._") == "<p>正體字。︁<em>Traditional.</em></p>")
        #expect(paragraph("“︁Git”︁__Hub__") == "<p>“︁Git”︁<strong>Hub</strong></p>")
    }

    /// Non-CJK text keeps CommonMark's rule.
    @Test func emphasisWithoutCJKIsUnchanged() {
        #expect(paragraph("**Note:**text") == "<p>**Note:**text</p>")
        #expect(paragraph("a**\"b\"**c") == "<p>a**&quot;b&quot;**c</p>")
        #expect(paragraph("snake_case_name and 变量_名_称") == "<p>snake_case_name and 变量_名_称</p>")
    }

    /// The markers never reach the page, the outline or an attribute.
    @Test func emphasisMarkersNeverShow() {
        let doc = MarkdownParser.parse("""
            ## **注意：**标题

            ![**图示：**说明](a.png "**标题：**x") [**链接：**文字](https://example.com "**说明：**y")

            | 列 |
            | --- |
            | **注意：**这里 |

            脚注[^1]。

            [^1]: **脚注：**内容
            """)
        for b in doc.blocks {
            #expect(!b.html.unicodeScalars.contains { $0 == CJKEmphasis.neutral || $0 == CJKEmphasis.punctuation }, "\(b.html)")
        }
        #expect(doc.blocks[0].headingTitle == "注意：标题")
        #expect(doc.blocks[0].html.contains("<strong>注意：</strong>标题"))
        var slugger = Slugger()
        #expect(doc.blocks[0].anchor == slugger.next("注意：标题"))
        #expect(doc.blocks.contains { $0.html.contains("<strong>注意：</strong>这里") })
        #expect(doc.blocks.contains { $0.html.contains("<strong>脚注：</strong>内容") })
    }

    /// A document holding a marker character itself keeps it (and keeps
    /// CommonMark's emphasis rule).
    @Test func literalMarkerCharactersSurvive() {
        let doc = MarkdownParser.parse("**注意：**这里\n\n```\n\u{1BC9F} and \u{E005}\n```")
        #expect(doc.blocks[1].html.contains("\u{1BC9F} and \u{E005}"))
        #expect(doc.blocks[0].html == "<p>**注意：**这里</p>")
    }

    /// Code, math, links and HTML keep their text exactly.
    @Test func emphasisLeavesCodeMathAndLinksAlone() {
        #expect(paragraph("见`**注意：**这里`") == "<p>见<code>**注意：**这里</code></p>")
        #expect(html("```\n**注意：**这里\n```").contains("**注意：**这里"))
        #expect(html("    **注意：**这里").contains("**注意：**这里"))
        #expect(paragraph("<https://例子.com/**注意：**x>").contains("href=\"https://例子.com/**注意：**x\""))
        #expect(paragraph("[文字](https://example.com/**注意：**x)").contains("href=\"https://example.com/**注意：**x\""))
        #expect(paragraph("算 $a**b：**c$ 后").contains("data-tex=\"a**b：**c\""))
    }

    /// The test cases of markdown-cjk-friendly (MIT, Tatsunori Uchino):
    /// every `**` around kana, Han and Hangul becomes strong emphasis, none
    /// next to non-CJK punctuation does, and underscores next to CJK
    /// punctuation emphasize.
    @Test func markdownCJKFriendlyTestCases() {
        let strong = """
            これは**私のやりたかったこと。**だからするの。

            **[製品ほげ](./product-foo)**と**[製品ふが](./product-bar)**をお試しください

            単語と**[単語と](word-and)**単語

            **これは太字になりません。**ご注意ください。

            カッコに注意**（太字にならない）**文が続く場合に要警戒。

            **[リンク](https://example.com)**も注意。（画像も同様）

            先頭の**`コード`も注意。**

            **末尾の`コード`**も注意。

            税込**¥10,000**で入手できます。

            正解は**④**です。

            太郎は**「こんにちわ」**といった

            太郎は**"こんにちわ"**といった

            太郎は**こんにちわ**といった

            太郎は**「Hello」**といった

            太郎は**"Hello"**といった

            太郎は**Hello**といった

            太郎は**「Oh my god」**といった

            太郎は**"Oh my god"**といった

            太郎は**Oh my god**といった

            **C#**や**F#**は**「.NET」**というプラットフォーム上で動作します。

            IDが**001号**になります。

            IDが**００１号**になります。

            Go**「初心者」**を対象とした記事です。

            **⻲田太郎**と申します

            ・**㋐**:選択肢１つ目

            **真，**她

            **真。**她

            **真、**她

            **真；**她

            **真：**她

            **真？**她

            **真！**她

            **真“**她

            **真”**她

            **真‘**她

            **真’**她

            **真（**她

            真**（她**

            **真）**她

            **真【**她

            真**【她**

            **真】**她

            **真《**她

            真**《她**

            **真》**她

            **真—**她

            **真～**她

            **真…**她

            **真·**她

            **真〃**她

            **真-**她

            **真々**她

            **真**她

            **真，** 她

            **真**，她

            **真，**&ZeroWidthSpace;她

            私は**⻲田太郎**と申します

            選択肢**㋐**: 1つ目の選択肢

            **さようなら︙**と太郎はいった。

            .NET**（.NET Frameworkは不可）**では、

            「禰󠄀」の偏は示ではなく**礻**です。

            Git**（注：不是GitHub）**

            𰻞𰻞**（ビャンビャン）**麺

            𰻞𰻞**(ビャンビャン)**麺

            ハイパーテキストコーヒーポット制御プロトコル**(HTCPCP)**

            﨑**(崎)**

            国際規格**[ECMA-262](https://tc39.es/ecma262/)**

            㐧**(第の俗字)**

            𠮟**(こちらが正式表記)**

            𪜈**(トモの合略仮名)**

            𫠉**(馬の俗字)**

            谺𬤲**(こだま)**石神社

            石𮧟**(いしただら)**

            葛󠄀**(こちらが正式表記)**城市

            禰󠄀**(こちらが正式表記)**豆子

            𱟛**(U+317DB)**

            阿寒湖アイヌシアターイコㇿ**(Akanko Ainu Theater Ikor)**

            あ𛀙**(か)**よろし

            𮹝**(simplified form of 龘 in China)**

            大塚︀**(U+585A U+FE00)** 大塚**(U+FA10)**

            〽︎**(庵点)**は、

            **“︁Git”︁**Hub
            """
        let korean = """
            **이 [링크](https://example.kr/)**만을 강조하고 싶다.

            **스크립트(script)**라고

            패키지를 발행하려면 **`npm publish`**를 실행하십시오.

            **안녕(hello)**하세요.

            ᅡ**(a)**

            **(k)**ᄏ
            """
        let pseudoEmoji = "a**〰**a\n\na**〽**a\n\na**🈂**a\n\na**🈷**a\n\na**㊗**a\n\na**㊙**a"
        for (name, text) in [("strong", strong), ("korean", korean), ("pseudo-emoji", pseudoEmoji)] {
            let doc = MarkdownParser.parse(text)
            for b in doc.blocks {
                #expect(b.html.range(of: #"\*\*[^\n]+\*\*"#, options: .regularExpression) == nil, "\(name): \(b.html)")
                #expect(b.html.contains("<strong>"), "\(name): \(b.html)")
            }
            expectIncrementalMatchesFull(text, "\(name)")
        }
        // (Their `∇` and `𝜵` cases are left out: symbols are punctuation since
        // CommonMark 0.31, not yet to cmark-gfm, CJK or not.)
        let nonBMP = "a**a«**a\n\na**»a**a\n\na**𐬻a**a\n\na**a𐬻**a"
        for b in MarkdownParser.parse(nonBMP).blocks { #expect(!b.html.contains("<strong>"), "\(b.html)") }
        let underscore = """
            __注意__：注意事項

            注意：__注意事項__

            正體字。︁_Traditional._

            正體字。︁__Hong Kong and Taiwan.__

            简体字 / 新字体。︀_Simplified._

            简体字 / 新字体。︀__Mainland China or Japan.__

            “︁Git”︁__Hub__
            """
        for b in MarkdownParser.parse(underscore).blocks { #expect(!b.html.contains("_"), "\(b.html)") }
    }

    /// No CommonMark spec example (0.31.2) and no GFM extension example gets
    /// a marker: outside CJK text the parse is cmark's, byte for byte.
    @Test func specExamplesAreUntouched() throws {
        struct Examples: Decodable { let examples: [String] }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let commonMark = try JSONDecoder().decode(Examples.self, from: Data(contentsOf: dir.appendingPathComponent("commonmark-examples.json"))).examples
        #expect(commonMark.count == 652)
        for md in commonMark + GFMSpecTests.examples.map(\.markdown) {
            var p = MathProtector()
            _ = p.protect(md)
            #expect(p.emphasisMarks == 0, "\(md.debugDescription)")
        }
    }
}
