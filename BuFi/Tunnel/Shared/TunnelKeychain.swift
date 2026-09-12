import Foundation
import Security

enum TunnelKeychainError: LocalizedError, Sendable {
    case unavailableAccessGroup
    case invalidSecret
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailableAccessGroup: "The shared Tunnel Keychain access group is unavailable."
        case .invalidSecret: "The WireGuard key is not exactly 32 bytes."
        case .keychain(let status): "Tunnel Keychain error (\(status))."
        }
    }
}

/// The main app and extension use the same explicit Keychain access group.
/// Only opaque references are persisted in profile metadata.
struct TunnelKeychain: Sendable {
    private let service = "cloud.tae00217.BuFi.Tunnel.Keys"

    func save(_ secret: Data, reference: String) throws {
        guard secret.count == 32 else { throw TunnelKeychainError.invalidSecret }
        let query = try baseQuery(reference: reference)
        let attributes: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw TunnelKeychainError.keychain(status) }
        var item = query
        item.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw TunnelKeychainError.keychain(addStatus) }
    }

    func load(reference: String) throws -> Data {
        var query = try baseQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw TunnelKeychainError.keychain(status) }
        guard let data = result as? Data, data.count == 32 else {
            throw TunnelKeychainError.invalidSecret
        }
        return data
    }

    func delete(reference: String) throws {
        let status = SecItemDelete(try baseQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TunnelKeychainError.keychain(status)
        }
    }

    private func baseQuery(reference: String) throws -> [String: Any] {
        guard let group = TunnelConstants.keychainAccessGroup, !group.isEmpty else {
            throw TunnelKeychainError.unavailableAccessGroup
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrAccessGroup as String: group
        ]
    }
}

