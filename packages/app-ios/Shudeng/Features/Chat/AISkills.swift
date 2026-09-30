// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// 一个 AI 技能（core 的 builtin skill + 书灯的中文文案）。
struct AISkill: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let desc: String
    /// 需要用户先给一段输入时，这里是输入框的提示（例如「要解释的概念」）。
    let needsInput: String?
    /// 输入框里那段文字要填给哪个参数。
    let inputParam: String?

    var requiresInput: Bool { inputParam != nil }
}

extension AISkill {
    @MainActor
    static func load(using runtime: RuntimeHost, language: String) -> [AISkill] {
        let payload = ["language": language]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return [] }
        let raw = runtime.appJSONOr("ShudengApp.skills(\(json))", fallback: "[]", timeout: 30)
        return (try? JSONDecoder().decode([AISkill].self, from: Data(raw.utf8))) ?? []
    }
}
