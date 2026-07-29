import Foundation

actor HomeSnapshotStore {
    static let shared = HomeSnapshotStore()

    private struct CachedSnapshot: Codable {
        let savedAt: Date
        let snapshot: HomeSnapshot
    }

    private let keyPrefix = "home-snapshot-v1"
    private let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private let maximumBytes = 4 * 1_024 * 1_024

    private init() {}

    func load(accountScope: String) -> HomeSnapshot? {
        guard let data = UserDefaults.standard.data(
            forKey: storageKey(accountScope)
        ), data.count <= maximumBytes,
           let cached = try? JSONDecoder().decode(
               CachedSnapshot.self,
               from: data
           ), Date().timeIntervalSince(cached.savedAt) <= maximumAge else {
            return nil
        }
        return cached.snapshot
    }

    func save(_ snapshot: HomeSnapshot, accountScope: String) {
        let value = CachedSnapshot(savedAt: Date(), snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(value),
              data.count <= maximumBytes else {
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey(accountScope))
    }

    func remove(accountScope: String) {
        UserDefaults.standard.removeObject(forKey: storageKey(accountScope))
    }

    private func storageKey(_ accountScope: String) -> String {
        "\(keyPrefix).\(accountScope)"
    }
}
