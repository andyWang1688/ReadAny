// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ShudengCoreBridge

final class MarkdownBlocksTests: XCTestCase {
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
