// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// AI 回答的 Markdown 渲染：正文交给 AttributedString，围栏代码块单独排版。
struct MarkdownText: View {
    let text: String
    /// 这条内容还在流式输出（源码是半截的），mermaid 图表要等写完再画。
    var streaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.split(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let value):
                    Text(Self.attributed(value))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let value):
                    if language?.lowercased() == "mermaid" {
                        // ```mermaid 交给 core 画图，别再当代码块显示。
                        MermaidBlockView(source: value, streaming: streaming)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                        if let language, !language.isEmpty {
                            Text(language)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(value)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
                    }
                }
            }
        }
    }

    /// Markdown 解析失败时退回原始文本，别让消息消失。
    private static func attributed(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .full)))
            ?? AttributedString(value)
    }
}
