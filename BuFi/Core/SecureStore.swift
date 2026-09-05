import Foundation
import os
import Security

enum SecureStoreError: LocalizedError, Sendable {
    case encoding
    case keychain(OSStatus)
    case verification

    var errorDescription: String? {
        switch self {
        case .encoding:
            String(localized: "보안 저장소 데이터를 인코딩하지 못했습니다.")
        case .keychain(let status):
            String(
                format: String(localized: "Keychain 오류가 발생했습니다. (%d)"),
                status
            )
        case .verification:
            String(localized: "API 키를 Keychain에 저장했지만 다시 읽어오지 못했습니다.")
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

    // API settings are loaded through short-lived SecureStore actors in a few
    // recommendation paths. Keep only secrets that have already been verified
    // against Keychain so a transient Security.framework read immediately
    // after a successful write cannot make the next actor think the key is
    // absent. This cache never replaces persistent Keychain storage and is
    // discarded with the process. OSAllocatedUnfairLock keeps the shared
    // dictionary Sendable without nonisolated(unsafe).
    private static let secretCache = OSAllocatedUnfairLock(
        initialState: [String: String]()
    )

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
        if updateStatus == errSecSuccess {
            try verifySavedCredentials(expected: credentials)
            return
        }

        // Older installs can already contain this item with attributes that the
        // current signer/access group is allowed to read and update but not
        // mutate. Preserve those attributes and update only the payload before
        // treating the write as failed.
        if updateStatus != errSecItemNotFound {
            let valueOnlyStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if valueOnlyStatus == errSecSuccess {
                try verifySavedCredentials(expected: credentials)
                return
            }
            guard valueOnlyStatus == errSecItemNotFound else {
                throw SecureStoreError.keychain(valueOnlyStatus)
            }
        }

        var value = query
        value.merge(update) { _, new in new }
        let status = SecItemAdd(value as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecureStoreError.keychain(status) }
        try verifySavedCredentials(expected: credentials)
    }

    private func verifySavedCredentials(expected: ServerCredentials) throws {
        guard let loaded = load(), loaded == expected else {
            throw SecureStoreError.verification
        }
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

        // Do not report success until the exact bytes can be read back from
        // Keychain. This prevents UI state from claiming that a Gemini/Groq key
        // exists while the recommendation runtime receives an empty secret.
        guard let verifiedData = loadData(account: account),
              verifiedData == data,
              let verified = String(data: verifiedData, encoding: .utf8),
              verified == value else {
            Self.removeCachedSecret(account: account)
            throw SecureStoreError.verification
        }
        Self.cacheSecret(verified, account: account)
    }

    func loadSecret(account: String) -> String? {
        if let data = loadData(account: account),
           let value = String(data: data, encoding: .utf8),
           !value.isEmpty {
            Self.cacheSecret(value, account: account)
            return value
        }

        // A verified write from another SecureStore actor in this process is a
        // safe fallback for a transient Keychain read miss. Persistent truth is
        // still Keychain: this memory value disappears on app termination.
        return Self.cachedSecret(account: account)
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
        Self.removeCachedSecret(account: account)
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

        // A legacy Keychain row may reject an accessibility-attribute mutation
        // even though its value is writable. Retry the safe operation we really
        // need: replace only the secret bytes and keep the existing attributes.
        if updateStatus != errSecItemNotFound {
            let valueOnlyStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if valueOnlyStatus == errSecSuccess { return }
            guard valueOnlyStatus == errSecItemNotFound else {
                throw SecureStoreError.keychain(valueOnlyStatus)
            }
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

    private static func cacheSecret(_ value: String, account: String) {
        let key = cacheKey(account: account)
        secretCache.withLock { cache in
            cache[key] = value
        }
    }

    private static func cachedSecret(account: String) -> String? {
        let key = cacheKey(account: account)
        return secretCache.withLock { $0[key] }
    }

    private static func removeCachedSecret(account: String) {
        let key = cacheKey(account: account)
        secretCache.withLock { cache in
            cache.removeValue(forKey: key)
        }
    }

    private static func cacheKey(account: String) -> String {
        "cloud.tae00217.BuFi\u{1f}\(account)"
    }
}
