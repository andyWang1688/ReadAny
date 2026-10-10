// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

@MainActor final class FixtureDefaults {
    static let standard = FixtureDefaults()
    var values: [String: String] = [:]
    var reads = 0
    var writes = 0
    func string(forKey key: String) -> String? { reads += 1; return values[key] }
    func set(_ value: String, forKey key: String) { writes += 1; values[key] = value }
}

enum SecurityFixture {
    static var stored: String? = "old-key"
    static var updateStatus: OSStatus = errSecSuccess
    static var addStatus: OSStatus = errSecSuccess
    static var readStatus: OSStatus = errSecSuccess
    static var deleteStatus: OSStatus = errSecSuccess
    static var reads = 0
    static var updates = 0
    static var adds = 0
    static var deletes = 0
    static func reset() {
        stored = "old-key"
        updateStatus = errSecSuccess; addStatus = errSecSuccess
        readStatus = errSecSuccess; deleteStatus = errSecSuccess
        reads = 0; updates = 0; adds = 0; deletes = 0
    }
}
func fixtureUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    SecurityFixture.updates += 1
    guard SecurityFixture.updateStatus == errSecSuccess else { return SecurityFixture.updateStatus }
    guard SecurityFixture.stored != nil else { return errSecItemNotFound }
    let data = (attributes as NSDictionary)[kSecValueData] as! Data
    SecurityFixture.stored = String(decoding: data, as: UTF8.self)
    return errSecSuccess
}
func fixtureAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    SecurityFixture.adds += 1
    guard SecurityFixture.addStatus == errSecSuccess else { return SecurityFixture.addStatus }
    let data = (attributes as NSDictionary)[kSecValueData] as! Data
    SecurityFixture.stored = String(decoding: data, as: UTF8.self)
    return errSecSuccess
}
func fixtureDelete(_ query: CFDictionary) -> OSStatus {
    SecurityFixture.deletes += 1
    guard SecurityFixture.deleteStatus == errSecSuccess else { return SecurityFixture.deleteStatus }
    guard SecurityFixture.stored != nil else { return errSecItemNotFound }
    SecurityFixture.stored = nil
    return errSecSuccess
}
func fixtureCopy(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    SecurityFixture.reads += 1
    guard SecurityFixture.readStatus == errSecSuccess else { return SecurityFixture.readStatus }
    guard let value = SecurityFixture.stored else { return errSecItemNotFound }
    result?.pointee = Data(value.utf8) as CFData
    return errSecSuccess
}

@main struct AISettingsStateTests {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        func rejected(_ action: () throws -> Void) -> Bool {
            do { try action(); return false } catch { return true }
        }
        SecurityFixture.reset()
        SecurityFixture.updateStatus = errSecNotAvailable
        check(rejected { try Keychain.set("new-key", for: "fixture") }, "Update failure must propagate")
        check(SecurityFixture.stored == "old-key", "Failed update must retain old key")
        check(SecurityFixture.deletes == 0 && SecurityFixture.adds == 0, "Failed update must not delete or add")
        SecurityFixture.updateStatus = errSecSuccess
        try Keychain.set("new-key", for: "fixture")
        check(SecurityFixture.stored == "new-key", "Update retry must save")
        try Keychain.set("", for: "fixture")
        check(SecurityFixture.stored == nil, "Explicit clear must delete")
        try Keychain.set("", for: "fixture")
        check(SecurityFixture.deletes == 2, "Clearing missing key must succeed")
        SecurityFixture.addStatus = errSecNotAvailable
        check(rejected { try Keychain.set("first-key", for: "fixture") }, "Add failure must propagate")
        check(SecurityFixture.stored == nil, "Failed add must not claim a saved key")
        SecurityFixture.addStatus = errSecSuccess
        try Keychain.set("first-key", for: "fixture")
        check(SecurityFixture.stored == "first-key", "Add retry must save")
        SecurityFixture.deleteStatus = errSecNotAvailable
        check(rejected { try Keychain.set("", for: "fixture") }, "Delete failure must propagate")
        check(SecurityFixture.stored == "first-key", "Failed clear retains persisted key")

        SecurityFixture.reset()
        let settings = AISettings(environment: [:])
        check(settings.apiKey == "old-key", "Production settings must read key")
        SecurityFixture.updateStatus = errSecNotAvailable
        settings.apiKey = "edited-key"
        check(settings.apiKey == "edited-key" && settings.apiKeyError != nil, "Unsaved input and error must remain visible")
        check(SecurityFixture.stored == "old-key", "Settings save failure must retain persisted key")
        settings.retryKeychain()
        check(settings.apiKeyError != nil, "Failed retry must retain error")
        SecurityFixture.updateStatus = errSecSuccess
        settings.retryKeychain()
        check(settings.apiKeyError == nil && SecurityFixture.stored == "edited-key", "Successful retry must save and clear error")

        SecurityFixture.reset()
        SecurityFixture.readStatus = errSecNotAvailable
        let unreadable = AISettings(environment: [:])
        check(unreadable.apiKeyError != nil && SecurityFixture.updates == 0, "Failed read must not overwrite unknown saved key")
        unreadable.retryKeychain()
        check(unreadable.apiKeyError != nil && SecurityFixture.updates == 0, "Read retry must remain a read")
        SecurityFixture.readStatus = errSecSuccess
        unreadable.retryKeychain()
        check(unreadable.apiKey == "old-key" && unreadable.apiKeyError == nil, "Read retry must restore key")
        check(SecurityFixture.updates == 0 && SecurityFixture.adds == 0 && SecurityFixture.deletes == 0, "Read recovery must not save")

        for environment in [
            ["SHUDENG_AI_API_KEY": "test-key", "SHUDENG_AI_MODEL": "test-model", "SHUDENG_AI_BASE_URL": "http://fixture.invalid"],
            ["SHUDENG_AI_BASE_URL": "http://fixture.invalid"],
            ["SHUDENG_AI_API_KEY": ""],
        ] {
            SecurityFixture.reset()
            FixtureDefaults.standard.reads = 0; FixtureDefaults.standard.writes = 0
            let isolated = AISettings(environment: environment)
            check(isolated.apiKey == (environment["SHUDENG_AI_API_KEY"] ?? ""), "Override must apply without inheriting real key")
            isolated.apiKey = "test-edited"; isolated.baseURL = "test-endpoint"
            isolated.model = "test-model-edited"; isolated.provider = .custom
            isolated.retryKeychain()
            check(SecurityFixture.reads == 0 && SecurityFixture.updates == 0 && SecurityFixture.adds == 0 && SecurityFixture.deletes == 0, "Test session must never touch Keychain")
            check(FixtureDefaults.standard.reads == 0 && FixtureDefaults.standard.writes == 0, "Test session must never touch real defaults")
        }
        let endpoint = AISettings(environment: ["SHUDENG_AI_BASE_URL": "not-a-url", "SHUDENG_AI_MODEL": "fixture"])
        check(!endpoint.isConfigured, "Malformed URL must not allow sending a request")
        check(AISettings.Provider.deepseek.defaultBaseURL == "https://api.deepseek.com", "DeepSeek must use its documented base URL")
        check(AISettings.Provider.deepseek.defaultModel == "deepseek-flash", "DeepSeek must default to Flash")
        endpoint.baseURL = ""
        endpoint.model = ""
        endpoint.applyProviderDefaults(for: .deepseek)
        check(endpoint.baseURL == AISettings.Provider.deepseek.defaultBaseURL, "Selecting DeepSeek must fill its base URL")
        check(endpoint.model == AISettings.Provider.deepseek.defaultModel, "Selecting DeepSeek must fill Flash model")
        endpoint.apiKey = "fixture-key"
        for provider in [AISettings.Provider.openai, .anthropic, .google] {
            endpoint.model = "another-provider-model"
            endpoint.applyProviderDefaults(for: provider)
            check(endpoint.baseURL == provider.defaultBaseURL, "Switching provider must update its base URL")
            check(endpoint.model == "another-provider-model", "Switching providers must retain the user's model")
            check(endpoint.apiKey == "fixture-key", "Switching provider must preserve entered Key")
        }
        endpoint.baseURL = "https://custom.fixture/v1"
        endpoint.model = "custom-model"
        endpoint.applyProviderDefaults(for: .custom)
        check(endpoint.baseURL == "https://custom.fixture/v1" && endpoint.model == "custom-model", "Custom selection must keep the connection available for editing")
        for address in ["", "https://", "ftp://fixture.invalid", "https://host name.invalid", "https://fixture.invalid/\npath"] {
            endpoint.baseURL = address
            check(!endpoint.isConfigured, "Invalid endpoint must be blocked: \(address)")
        }
        for address in ["https://fixture.invalid/v1", "http://127.0.0.1:8799/v1", "  https://fixture.invalid/v1  "] {
            endpoint.baseURL = address
            check(endpoint.isConfigured, "Valid endpoint must remain usable")
        }
        endpoint.model = "\n  "
        check(!endpoint.isConfigured, "Whitespace-only model is not configured")
        print("AI settings / Keychain: \(checks) checks passed")
    }
}
