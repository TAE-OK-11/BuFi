import Foundation

actor HomeSnapshotStore {
    static let shared = HomeSnapshotStore()

    private struct CachedSnapshot: Codable {
        let savedAt: Date
        let snapshot: HomeSnapshot
    }

    private let keyPrefix = "home-snapshot-v2"
    private let legacyKeyPrefix = "home-snapshot-v1"
    private let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private let maximumBytes = 4 * 1_024 * 1_024

    private init() {}

    func load(accountScope: String) async -> HomeSnapshot? {
        if let snapshot = await AppDatabase.shared.loadHomeSnapshot(
            scope: accountScope,
            maximumAge: maximumAge
        ) {
            removeLegacySnapshot(accountScope: accountScope)
            return snapshot
        }
        guard let cached = legacySnapshot(accountScope: accountScope) else { return nil }
        if await AppDatabase.shared.saveHomeSnapshot(
            cached.snapshot,
            scope: accountScope,
            maximumBytes: maximumBytes
        ) {
            removeLegacySnapshot(accountScope: accountScope)
        }
        return cached.snapshot
    }

    func save(_ snapshot: HomeSnapshot, accountScope: String) async {
        if await AppDatabase.shared.saveHomeSnapshot(
            snapshot,
            scope: accountScope,
            maximumBytes: maximumBytes
        ) {
            removeLegacySnapshot(accountScope: accountScope)
        }
    }

    func remove(accountScope: String) async {
        await AppDatabase.shared.removeHomeSnapshot(scope: accountScope)
        removeLegacySnapshot(accountScope: accountScope)
    }

    private func storageKey(_ accountScope: String) -> String {
        "\(keyPrefix).\(accountScope)"
    }

    private func removeLegacySnapshot(accountScope: String) {
        UserDefaults.standard.removeObject(forKey: storageKey(accountScope))
        UserDefaults.standard.removeObject(
            forKey: "\(legacyKeyPrefix).\(accountScope)"
        )
    }

    private func legacySnapshot(accountScope: String) -> CachedSnapshot? {
        for key in [storageKey(accountScope), "\(legacyKeyPrefix).\(accountScope)"] {
            guard let data = UserDefaults.standard.data(forKey: key),
                  data.count <= maximumBytes,
                  let cached = try? JSONDecoder().decode(CachedSnapshot.self, from: data),
                  Date().timeIntervalSince(cached.savedAt) <= maximumAge else {
                continue
            }
            return cached
        }
        return nil
    }
}
