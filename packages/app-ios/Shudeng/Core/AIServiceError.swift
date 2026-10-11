// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// AI 页面共用的服务错误文案，保留其它服务错误的具体原因。
enum AIServiceError {
    static func message(_ error: String) -> String {
        if error.localizedCaseInsensitiveContains("connection") {
            return "无法连接 AI 服务，请检查网络或服务地址后重试。"
        }
        return "AI 服务返回错误：\(error)"
    }
}
