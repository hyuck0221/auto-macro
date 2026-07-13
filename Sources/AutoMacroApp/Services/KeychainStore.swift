import Foundation
#if canImport(Security)
import Security
#endif

struct KeychainStore: Sendable {
    static let customAPIConfigurationAccount = "custom-api.configuration.v1"

    let service: String

    init(service: String = "app.automacro.desktop") {
        self.service = service
    }

    func save(_ secret: String, for account: String) throws {
#if canImport(Security)
        let data = Data(secret.utf8)
        let query = baseQuery(for: account)
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw statusError(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw statusError(addStatus) }
#else
        throw AIProviderError.keychain("이 플랫폼에서는 Keychain을 사용할 수 없습니다.")
#endif
    }

    func value(for account: String) throws -> String? {
#if canImport(Security)
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw statusError(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AIProviderError.keychain("저장된 키 데이터 형식이 올바르지 않습니다.")
        }
        return value
#else
        throw AIProviderError.keychain("이 플랫폼에서는 Keychain을 사용할 수 없습니다.")
#endif
    }

    func deleteValue(for account: String) throws {
#if canImport(Security)
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw statusError(status)
        }
#else
        throw AIProviderError.keychain("이 플랫폼에서는 Keychain을 사용할 수 없습니다.")
#endif
    }

    func saveAPIKey(_ key: String, for provider: AIProviderKind) throws {
        guard let account = provider.keychainAccount else {
            throw AIProviderError.invalidRequest("\(provider.displayName)은 API 키를 사용하지 않습니다.")
        }
        try save(key.trimmingCharacters(in: .whitespacesAndNewlines), for: account)
    }

    func apiKey(for provider: AIProviderKind) throws -> String? {
        guard let account = provider.keychainAccount else { return nil }
        return try value(for: account)
    }

    func deleteAPIKey(for provider: AIProviderKind) throws {
        guard let account = provider.keychainAccount else { return }
        try deleteValue(for: account)
    }

    func saveCustomAPIConfiguration(_ configuration: CustomAPIConfiguration) throws {
        let encoder = JSONEncoder()
        guard let value = String(data: try encoder.encode(configuration), encoding: .utf8) else {
            throw AIProviderError.keychain("외부 API 설정을 저장할 수 있는 형식으로 만들지 못했습니다.")
        }
        try save(value, for: Self.customAPIConfigurationAccount)
    }

    func customAPIConfiguration() throws -> CustomAPIConfiguration? {
        guard let value = try value(for: Self.customAPIConfigurationAccount),
              let data = value.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(CustomAPIConfiguration.self, from: data)
        } catch {
            throw AIProviderError.keychain("저장된 외부 API 설정 형식이 올바르지 않습니다.")
        }
    }

    func deleteCustomAPIConfiguration() throws {
        try deleteValue(for: Self.customAPIConfigurationAccount)
    }

#if canImport(Security)
    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func statusError(_ status: OSStatus) -> AIProviderError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .keychain(message)
    }
#endif
}
