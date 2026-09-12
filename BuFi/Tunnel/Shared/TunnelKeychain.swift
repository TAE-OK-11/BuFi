import Foundation
import os
import Security

enum TunnelKeychainError: LocalizedError, Equatable, Sendable {
    case sharedAccessGroupUnavailable
    case missingEntitlement
    case invalidSecret
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sharedAccessGroupUnavailable:
            String(localized: "This build is not signed with the shared Tunnel Keychain entitlement. The profile is stored securely, but Packet Tunnel access is unavailable.")
        case .missingEntitlement:
            String(localized: "The signed app is missing a required Keychain entitlement.")
        case .invalidSecret:
            String(localized: "The WireGuard key is not exactly 32 bytes.")
        case .keychain(let status):
            String(
                format: String(localized: "Tunnel Keychain error (%d)."),
                locale: .current,
                status
            )
        }
    }

    static func from(status: OSStatus) -> TunnelKeychainError {
        status == errSecMissingEntitlement ? .missingEntitlement : .keychain(status)
    }
}

struct TunnelKeychainCapability: Equatable, Sendable {
    let defaultAccessGroup: String?
    let sharedAccessGroup: String?
    let canUseSharedAccessGroup: Bool
}

/// Stores only WireGuard secret bytes. Profile metadata contains opaque
/// references and a scope marker, never key material.
///
/// A shared access group is used only after the Security framework confirms
/// that the currently signed process possesses it. Re-signed builds can create
/// profiles in their normal target-local Keychain without sending an
/// unavailable access group to SecItem.
struct TunnelKeychain: Sendable {
    private static let capabilityCache = OSAllocatedUnfairLock<TunnelKeychainCapability?>(
        initialState: nil
    )

    private let service = "cloud.tae00217.BuFi.Tunnel.Keys"

    func capability() -> TunnelKeychainCapability {
        if let cached = Self.capabilityCache.withLock({ $0 }) { return cached }

        let defaultGroup = discoverDefaultAccessGroup()
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        let sharedGroup = defaultGroup.flatMap {
            TunnelConstants.sharedKeychainAccessGroup(
                defaultAccessGroup: $0,
                bundleIdentifier: bundleIdentifier
            )
        }
        let result = TunnelKeychainCapability(
            defaultAccessGroup: defaultGroup,
            sharedAccessGroup: sharedGroup,
            canUseSharedAccessGroup: sharedGroup.map(canUseAccessGroup) ?? false
        )
        return Self.capabilityCache.withLock { cached in
            if let cached { return cached }
            cached = result
            return result
        }
    }

    func preferredScope() -> TunnelSecretScope {
        capability().canUseSharedAccessGroup ? .sharedAccessGroup : .mainAppOnly
    }

    func save(_ secret: Data, reference: String, scope: TunnelSecretScope) throws {
        guard secret.count == 32 else { throw TunnelKeychainError.invalidSecret }
        let query = try baseQuery(reference: reference, scope: scope)
        let attributes: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw TunnelKeychainError.from(status: status) }
        var item = query
        item.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw TunnelKeychainError.from(status: addStatus) }
    }

    func load(reference: String, scope: TunnelSecretScope) throws -> Data {
        var query = try baseQuery(reference: reference, scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw TunnelKeychainError.from(status: status) }
        guard let data = result as? Data, data.count == 32 else {
            throw TunnelKeychainError.invalidSecret
        }
        return data
    }

    func delete(reference: String, scope: TunnelSecretScope) throws {
        let status = SecItemDelete(try baseQuery(reference: reference, scope: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TunnelKeychainError.from(status: status)
        }
    }

    func baseQuery(reference: String, scope: TunnelSecretScope) throws -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference
        ]
        if scope == .sharedAccessGroup {
            let capability = capability()
            guard capability.canUseSharedAccessGroup,
                  let group = capability.sharedAccessGroup else {
                throw TunnelKeychainError.sharedAccessGroupUnavailable
            }
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    private func discoverDefaultAccessGroup() -> String? {
        let account = "access-group-probe-\(UUID().uuidString)"
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cloud.tae00217.BuFi.Tunnel.KeychainProbe",
            kSecAttrAccount as String: account
        ]
        var item = identity
        item[kSecValueData as String] = Data([0])
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false

        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return nil }
        defer { _ = SecItemDelete(identity as CFDictionary) }

        var query = identity
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else {
            return nil
        }
        return attributes[kSecAttrAccessGroup as String] as? String
    }

    private func canUseAccessGroup(_ group: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cloud.tae00217.BuFi.Tunnel.AccessGroupProbe",
            kSecAttrAccount as String: "capability",
            kSecAttrAccessGroup as String: group,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
