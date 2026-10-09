// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// API Key 只进 Keychain，不落 UserDefaults。
enum Keychain {
    private static let service = "com.wangxinxin.shudeng"

    struct StorageError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "无法访问钥匙串（错误 \(status)），请重试。" }
    }

    static func set(_ value: String, for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
        } else {
            let update = [kSecValueData as String: Data(value.utf8)]
            let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if updated == errSecItemNotFound {
                var attributes = query
                attributes[kSecValueData as String] = Data(value.utf8)
                status = SecItemAdd(attributes as CFDictionary, nil)
            } else {
                status = updated
            }
        }
        guard status == errSecSuccess else { throw StorageError(status: status) }
    }

    static func get(_ key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw StorageError(status: status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw StorageError(status: errSecDecode)
        }
        return value
    }
}
