// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// 书灯的视觉系统：黑白为主，颜色只留给「书封」和「高亮」。
enum Theme {
    static let accent = Color.primary
    static let coverRadius: CGFloat = 6
    /// 输入框、次级按钮这类控件的圆角；比卡片小，比封面大。
    static let controlRadius: CGFloat = 10
    static let cardRadius: CGFloat = 14
    static let hairline = Color(.separator).opacity(0.5)
    static let coverBorder = Color.primary.opacity(0.07)
    /// 书封的落影：让封面像实物一样「立」在背景上，而不是漂在灰底上。
    static let coverShadow = Color.black.opacity(0.16)
}

/// 没有封面的书：一张干净的纸，书名居中，左侧压一道书脊。
struct CoverPlaceholder: View {
    let title: String
    let author: String

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.coverRadius, style: .continuous)
            .fill(Color(.systemGray5))
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(.footnote, design: .serif).weight(.medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                    if !author.isEmpty {
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 16, height: 0.5)
                        Text(author)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
            }
    }
}
