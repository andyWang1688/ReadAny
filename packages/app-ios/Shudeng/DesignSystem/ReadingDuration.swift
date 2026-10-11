// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// 统计、报告和 AI 输入共用的分钟显示规则，避免把短阅读显示成零。
enum ReadingDuration {
    static func minutesValue(_ minutes: Double) -> String {
        if minutes > 0 && minutes < 1 { return "<1" }
        return String(Int(minutes.rounded()))
    }

    static func minutes(_ minutes: Double) -> String {
        "\(minutesValue(minutes)) 分钟"
    }
}
