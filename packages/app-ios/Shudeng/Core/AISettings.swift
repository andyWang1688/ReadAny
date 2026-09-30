// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// AI 端点配置：非机密进 UserDefaults，API Key 进 Keychain。
@MainActor
final class AISettings: ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case openai
        case anthropic
        case google
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .openai: "OpenAI 兼容"
            case .anthropic: "Anthropic"
            case .google: "Gemini"
            case .custom: "自定义（OpenAI 兼容）"
            }
        }

        var defaultBaseURL: String {
            switch self {
            case .openai: "https://api.openai.com/v1"
            case .anthropic: "https://api.anthropic.com"
            case .google: "https://generativelanguage.googleapis.com/v1beta/openai"
            case .custom: ""
            }
        }
    }

    @Published var provider: Provider { didSet { defaults.set(provider.rawValue, forKey: Keys.provider) } }
    @Published var baseURL: String { didSet { defaults.set(baseURL, forKey: Keys.baseURL) } }
    @Published var model: String { didSet { defaults.set(model, forKey: Keys.model) } }
    @Published var apiKey: String { didSet { Keychain.set(apiKey, for: Keys.apiKey) } }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let provider = "ai.provider"
        static let baseURL = "ai.baseURL"
        static let model = "ai.model"
        static let apiKey = "ai.apiKey"
    }

    init() {
        let storedProvider = defaults.string(forKey: Keys.provider).flatMap(Provider.init(rawValue:)) ?? .openai
        provider = storedProvider
        baseURL = defaults.string(forKey: Keys.baseURL) ?? storedProvider.defaultBaseURL
        model = defaults.string(forKey: Keys.model) ?? ""
        apiKey = Keychain.get(Keys.apiKey)
        applyTestOverrides()
    }

    /// 模拟器 UI 测试用：用环境变量顶掉端点，测试进程不必碰 Keychain。
    private func applyTestOverrides() {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["SHUDENG_AI_BASE_URL"], !value.isEmpty { baseURL = value }
        if let value = environment["SHUDENG_AI_MODEL"], !value.isEmpty { model = value }
        if let value = environment["SHUDENG_AI_API_KEY"], !value.isEmpty { apiKey = value }
    }

    var isConfigured: Bool {
        !model.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
