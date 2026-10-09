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

    @Published var provider: Provider { didSet { if !usesTestOverrides { defaults.set(provider.rawValue, forKey: Keys.provider) } } }
    @Published var baseURL: String { didSet { if !usesTestOverrides { defaults.set(baseURL, forKey: Keys.baseURL) } } }
    @Published var model: String { didSet { if !usesTestOverrides { defaults.set(model, forKey: Keys.model) } } }
    @Published var apiKey: String { didSet { saveAPIKey() } }

    @Published private(set) var apiKeyError: String?

    private let defaults = UserDefaults.standard
    private let usesTestOverrides: Bool
    private var needsKeychainRead = false
    private var isLoadingAPIKey = false

    private enum Keys {
        static let provider = "ai.provider"
        static let baseURL = "ai.baseURL"
        static let model = "ai.model"
        static let apiKey = "ai.apiKey"
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        // 测试端点仅存在于当前进程，初始化和后续编辑均不访问真实配置或钥匙串。
        usesTestOverrides = ["SHUDENG_AI_BASE_URL", "SHUDENG_AI_MODEL", "SHUDENG_AI_API_KEY"]
            .contains { environment[$0] != nil }
        if usesTestOverrides {
            provider = .openai
            baseURL = environment["SHUDENG_AI_BASE_URL"] ?? Provider.openai.defaultBaseURL
            model = environment["SHUDENG_AI_MODEL"] ?? ""
            apiKey = environment["SHUDENG_AI_API_KEY"] ?? ""
        } else {
            let storedProvider = defaults.string(forKey: Keys.provider).flatMap(Provider.init(rawValue:)) ?? .openai
            provider = storedProvider
            baseURL = defaults.string(forKey: Keys.baseURL) ?? storedProvider.defaultBaseURL
            model = defaults.string(forKey: Keys.model) ?? ""
            do {
                apiKey = try Keychain.get(Keys.apiKey)
            } catch {
                apiKey = ""
                needsKeychainRead = true
                apiKeyError = error.localizedDescription
            }
        }
    }

    private func saveAPIKey() {
        guard !usesTestOverrides, !isLoadingAPIKey else { return }
        needsKeychainRead = false
        do {
            try Keychain.set(apiKey, for: Keys.apiKey)
            apiKeyError = nil
        } catch {
            apiKeyError = error.localizedDescription
        }
    }

    func retryKeychain() {
        guard !usesTestOverrides else { return }
        if needsKeychainRead {
            do {
                let value = try Keychain.get(Keys.apiKey)
                isLoadingAPIKey = true
                apiKey = value
                isLoadingAPIKey = false
                needsKeychainRead = false
                apiKeyError = nil
            } catch {
                apiKeyError = error.localizedDescription
            }
        } else {
            saveAPIKey()
        }
    }

    var isConfigured: Bool {
        !model.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
