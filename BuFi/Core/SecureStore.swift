import Foundation
import Security

enum SecureStoreError: LocalizedError, Sendable {
    case encoding
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encoding:
            String(localized: "보안 저장소 데이터를 인코딩하지 못했습니다.")
        case .keychain(let status):
            String(
                format: String(localized: "Keychain 오류가 발생했습니다. (%d)"),
                status
            )
        }
    }
}

struct SecureBootstrapState: Sendable {
    let credentials: ServerCredentials?
    let hasLastFMKey: Bool
    let hasListenBrainzToken: Bool
}

/// Serializes Security.framework calls away from MainActor. Keychain queries
/// are synchronous and can involve IPC, so UI state owners await this actor
/// instead of performing those calls during view-driven mutations.
actor SecureStore {
    private let service = "cloud.tae00217.BuFi"
    private let account = "server-credentials"

    func save(_ credentials: ServerCredentials) throws {
        guard let data = try? JSONEncoder().encode(credentials) else {
            throw SecureStoreError.encoding
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SecureStoreError.keychain(updateStatus)
        }

        var value = query
        value.merge(update) { _, new in new }
        let status = SecItemAdd(value as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecureStoreError.keychain(status) }
    }

    func load() -> ServerCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(ServerCredentials.self, from: data)
    }

    func loadBootstrapState(
        lastFMAccount: String,
        listenBrainzAccount: String
    ) -> SecureBootstrapState {
        SecureBootstrapState(
            credentials: load(),
            hasLastFMKey: loadSecret(account: lastFMAccount)?.isEmpty == false,
            hasListenBrainzToken: loadSecret(account: listenBrainzAccount)?.isEmpty == false
        )
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        try deleteItem(query)
    }

    func saveSecret(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw SecureStoreError.encoding
        }
        try saveData(data, account: account)
    }

    func loadSecret(account: String) -> String? {
        guard let data = loadData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func loadSecrets(accounts: [String]) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(accounts.count)
        for account in accounts {
            if let value = loadSecret(account: account), !value.isEmpty {
                result[account] = value
            }
        }
        return result
    }

    func deleteSecret(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        try deleteItem(query)
    }

    private func saveData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SecureStoreError.keychain(updateStatus)
        }
        var value = query
        value.merge(update) { _, new in new }
        let status = SecItemAdd(value as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStoreError.keychain(status)
        }
    }

    private func loadData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private func deleteItem(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.keychain(status)
        }
    }
}
