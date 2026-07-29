import Foundation

struct ListeningHistorySnapshot: Sendable {
    let mostPlayedSongs: [Song]
    let recentlyPlayedSongs: [Song]
}

actor ListeningHistoryStore {
    static let shared = ListeningHistoryStore()

    private struct Entry: Codable {
        var song: Song
        var playCount: Int
        var lastPlayed: Date
    }

    private let storagePrefix = "listening-history-v1"
    private var activeScope: String?
    private var entries: [String: Entry] = [:]

    private init() {}

    func activate(accountScope: String) {
        guard activeScope != accountScope else { return }
        activeScope = accountScope
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let values = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = values
        } else {
            entries = [:]
        }
    }

    func deactivate(accountScope: String) {
        guard activeScope == accountScope else { return }
        activeScope = nil
        entries.removeAll(keepingCapacity: false)
    }

    func record(_ song: Song, at date: Date = Date()) {
        guard activeScope != nil, song.externalStreamURL == nil else { return }
        var value = entries[song.id] ?? Entry(
            song: song,
            playCount: 0,
            lastPlayed: date
        )
        value.song = song
        value.playCount += 1
        value.lastPlayed = date
        entries[song.id] = value
        trimAndPersist()
    }

    func snapshot(limit: Int = 30) -> ListeningHistorySnapshot {
        let values = Array(entries.values)
        let mostPlayed = values.sorted {
            if $0.playCount == $1.playCount {
                return $0.lastPlayed > $1.lastPlayed
            }
            return $0.playCount > $1.playCount
        }
        let recent = values.sorted { $0.lastPlayed > $1.lastPlayed }
        return ListeningHistorySnapshot(
            mostPlayedSongs: Array(mostPlayed.prefix(limit).map(\.song)),
            recentlyPlayedSongs: Array(recent.prefix(limit).map(\.song))
        )
    }

    func clear() {
        guard activeScope != nil else { return }
        entries.removeAll(keepingCapacity: false)
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private var storageKey: String {
        "\(storagePrefix).\(activeScope ?? "inactive")"
    }

    private func trimAndPersist() {
        if entries.count > 500 {
            let retained = entries.values
                .sorted { $0.lastPlayed > $1.lastPlayed }
                .prefix(400)
            entries = Dictionary(uniqueKeysWithValues: retained.map {
                ($0.song.id, $0)
            })
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
