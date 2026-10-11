// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ShudengCoreBridge

final class MarkdownBlocksTests: XCTestCase {
    func testSummaryKeepsHeadingParagraphAndListBoundaries() {
        let input = "## 核心主题\n\n第一段。\n\n## 主要要点\n\n1. **网络**：SSE 分片。\n2. **存储**：SQLite。"
        let output = MarkdownBlock.attributedProse(input)
        XCTAssertEqual(String(output.characters), "核心主题\n\n第一段。\n\n主要要点\n\n1. 网络：SSE 分片。\n2. 存储：SQLite。")
        XCTAssertTrue(output.runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    }

    func testNestedListsAndContinuationKeepTheirMeaning() {
        let output = MarkdownBlock.attributedProse("- 外层\n  - 内层\n\n    延续段落\n- 下一项")
        XCTAssertEqual(String(output.characters), "• 外层\n  • 内层\n    延续段落\n• 下一项")
    }

    func testLinksAndInlineEmphasisSurviveLayout() {
        let output = MarkdownBlock.attributedProse("## **标题**\n\n访问 [示例](https://example.com) 和 *斜体*、\u{0060}代码\u{0060}。")
        XCTAssertTrue(output.runs.contains { $0.link?.absoluteString == "https://example.com" })
        XCTAssertTrue(output.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(output.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertFalse(String(output.characters).contains("##"))
    }

    func testQuotesAndTablesKeepSeparators() {
        let output = MarkdownBlock.attributedProse("> 引用\n\n| 名称 | 数量 |\n| --- | --- |\n| 样书 | 2 |")
        XCTAssertEqual(String(output.characters), "│ 引用\n\n名称  |  数量\n样书  |  2")
    }

    func testParagraphAfterListRequiresMarkdownBlankLine() {
        let separate = MarkdownBlock.attributedProse("1. 第一点\n2. 第二点\n\n结尾。")
        XCTAssertEqual(String(separate.characters), "1. 第一点\n2. 第二点\n\n结尾。")
        let continuation = MarkdownBlock.attributedProse("1. 第一点\n接着这一项。")
        XCTAssertEqual(String(continuation.characters), "1. 第一点 接着这一项。")
    }

    func testPartialMarkdownNeverDisappears() {
        for text in ["**尚未结束", "一句话", "[链接", "中文\n下一行"] {
            XCTAssertFalse(MarkdownBlock.attributedProse(text).characters.isEmpty)
        }
    }

    func testSplitsProseAndFencedCode() {
        let markdown = """
        先看这段：

        ```swift
        let a = 1
        print(a)
        ```

        结束。
        """

        XCTAssertEqual(MarkdownBlock.split(markdown), [
            .prose("先看这段："),
            .code(language: "swift", text: "let a = 1\nprint(a)"),
            .prose("结束。"),
        ])
    }

    /// 流式输出里代码块常还没闭合：剩下的都算代码块，别把 ``` 当正文显示。
    func testUnterminatedFenceBecomesCode() {
        let markdown = "看这里：\n```\nnpm run build\n"

        XCTAssertEqual(MarkdownBlock.split(markdown), [
            .prose("看这里："),
            .code(language: nil, text: "npm run build"),
        ])
    }

    func testPlainTextStaysOneBlock() {
        XCTAssertEqual(MarkdownBlock.split("**加粗** 和 `代码`"), [
            .prose("**加粗** 和 `代码`"),
        ])
    }

    func testEmptyInputHasNoBlocks() {
        XCTAssertEqual(MarkdownBlock.split(""), [])
        XCTAssertEqual(MarkdownBlock.split("\n  \n"), [])
        XCTAssertEqual(MarkdownBlock.split("```\n\n```"), [])
    }
}
