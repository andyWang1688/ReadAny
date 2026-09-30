// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// 极简 Markdown 分块：把 AI 回答切成「普通文本」与「围栏代码块」两类，
/// 好让 SwiftUI 侧对代码块单独排版（SwiftUI 没有现成的 Markdown 渲染器）。
/// 流式输出时 ``` 常常还没闭合，这里按「剩下都算代码块」处理。
public enum MarkdownBlock: Equatable {
    case prose(String)
    case code(language: String?, text: String)

    public static func split(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            prose.removeAll()
            // 纯空白行（例如 "  \n"）不该算一个正文块。
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.prose(text))
            }
        }

        func flushCode() {
            let text = code.joined(separator: "\n").trimmingCharacters(in: .newlines)
            code.removeAll()
            if !text.isEmpty { blocks.append(.code(language: language, text: text)) }
            language = nil
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    inCode = true
                    let name = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    language = name.isEmpty ? nil : name
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }

        if inCode { flushCode() } else { flushProse() }
        return blocks
    }
}
