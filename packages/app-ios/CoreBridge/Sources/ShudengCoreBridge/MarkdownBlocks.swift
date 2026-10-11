// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// 极简 Markdown 分块：把 AI 回答切成「普通文本」与「围栏代码块」两类，
/// 好让 SwiftUI 侧对代码块单独排版（SwiftUI 没有现成的 Markdown 渲染器）。
/// 流式输出时 ``` 常常还没闭合，这里按「剩下都算代码块」处理。
public enum MarkdownBlock: Equatable {
    case prose(String)
    case code(language: String?, text: String)

    /// SwiftUI Text 需要显式字符表达块间距，不能只依赖 presentationIntent。
    public static func attributedProse(_ value: String) -> AttributedString {
        guard let parsed = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .full)) else {
            return AttributedString(value)
        }
        var result = AttributedString()
        var previousList: Int?
        var previousTable: Int?
        var previousRow: Int?
        var seenItems: Set<Int> = []

        // 按系统解析出的块分组，保留组内链接、强调和行内代码，不另写 Markdown 解析器。
        for (intent, range) in parsed.runs[\.presentationIntent] {
            var content = AttributedString(parsed[range])
            var lists: [Int] = []
            var item: (id: Int, ordinal: Int)?
            var ordered = false
            var emphasized = false
            var quoteDepth = 0
            var table: Int?
            var row: Int?
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header:
                    emphasized = true
                case .listItem(let ordinal):
                    if item == nil { item = (component.identity, ordinal) }
                case .orderedList:
                    if lists.isEmpty { ordered = true }
                    lists.append(component.identity)
                case .unorderedList:
                    lists.append(component.identity)
                case .blockQuote:
                    quoteDepth += 1
                case .table:
                    table = component.identity
                case .tableHeaderRow:
                    row = component.identity
                    emphasized = true
                case .tableRow:
                    row = component.identity
                default:
                    break
                }
            }
            if !result.characters.isEmpty {
                let separator: String
                if let table, table == previousTable {
                    separator = row == previousRow ? "  |  " : "\n"
                } else if let list = lists.last, list == previousList {
                    separator = "\n"
                } else {
                    separator = "\n\n"
                }
                result.append(AttributedString(separator))
            }
            var prefix = String(repeating: "│ ", count: quoteDepth)
            if let item {
                let firstParagraph = seenItems.insert(item.id).inserted
                prefix += String(repeating: "  ", count: max(lists.count - 1, 0))
                prefix += firstParagraph ? (ordered ? "\(item.ordinal). " : "• ") : "  "
            }
            result.append(AttributedString(prefix))
            if emphasized {
                for (inline, inlineRange) in content.runs[\.inlinePresentationIntent] {
                    content[inlineRange].inlinePresentationIntent = (inline ?? []).union(.stronglyEmphasized)
                }
            }
            result.append(content)
            previousList = lists.last
            previousTable = table
            previousRow = row
        }
        return result
    }

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
