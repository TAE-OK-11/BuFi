import Foundation
import Security

enum SecureStoreError: LocalizedError {
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

struct SecureStore {
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

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
