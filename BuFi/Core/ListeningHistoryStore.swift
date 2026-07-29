import Foundation

enum PlaybackOrigin: String, Codable, Sendable {
    case manual
    case search
    case album
    case playlist
    case queue
    case autoplay
    case restored
}

enum PlaybackEndReason: String, Codable, Sendable {
    case completed
    case skipped
    case replaced
    case queueRemoved
    case stopped
}

struct SongBehavior: Codable, Sendable {
    var song: Song
    var playCount: Int
    var firstPlayed: Date
    var lastPlayed: Date
    var completedCount: Int
    var skipCount: Int
    var earlySkipCount: Int
    var repeatedSkipCount: Int
    var repeatCount: Int
    var manualPlayCount: Int
    var searchPlayCount: Int
    var albumSelectionCount: Int
    var playlistPlayCount: Int
    var autoplayCount: Int
    var queueRemovalCount: Int
    var playlistAddCount: Int
    var favoriteCount: Int
    var totalCompletion: Double
    var completionSamples: Int
    var consecutiveSkips: Int

    var averageCompletion: Double {
        guard completionSamples > 0 else { return 0 }
        return min(max(totalCompletion / Double(completionSamples), 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case song
        case playCount
        case firstPlayed
        case lastPlayed
        case completedCount
        case skipCount
        case earlySkipCount
        case repeatedSkipCount
        case repeatCount
        case manualPlayCount
        case searchPlayCount
        case albumSelectionCount
        case playlistPlayCount
        case autoplayCount
        case queueRemovalCount
        case playlistAddCount
        case favoriteCount
        case totalCompletion
        case completionSamples
        case consecutiveSkips
    }

    init(song: Song, at date: Date) {
        self.song = song
        playCount = 0
        firstPlayed = date
        lastPlayed = date
        completedCount = 0
        skipCount = 0
        earlySkipCount = 0
        repeatedSkipCount = 0
        repeatCount = 0
        manualPlayCount = 0
        searchPlayCount = 0
        albumSelectionCount = 0
        playlistPlayCount = 0
        autoplayCount = 0
        queueRemovalCount = 0
        playlistAddCount = 0
        favoriteCount = 0
        totalCompletion = 0
        completionSamples = 0
        consecutiveSkips = 0
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        song = try values.decode(Song.self, forKey: .song)
        playCount = try values.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        lastPlayed = try values.decodeIfPresent(Date.self, forKey: .lastPlayed)
            ?? .distantPast
        firstPlayed = try values.decodeIfPresent(Date.self, forKey: .firstPlayed)
            ?? lastPlayed
        completedCount = try values.decodeIfPresent(
            Int.self,
            forKey: .completedCount
        ) ?? 0
        skipCount = try values.decodeIfPresent(Int.self, forKey: .skipCount) ?? 0
        earlySkipCount = try values.decodeIfPresent(
            Int.self,
            forKey: .earlySkipCount
        ) ?? 0
        repeatedSkipCount = try values.decodeIfPresent(
            Int.self,
            forKey: .repeatedSkipCount
        ) ?? 0
        repeatCount = try values.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 0
        manualPlayCount = try values.decodeIfPresent(
            Int.self,
            forKey: .manualPlayCount
        ) ?? playCount
        searchPlayCount = try values.decodeIfPresent(
            Int.self,
            forKey: .searchPlayCount
        ) ?? 0
        albumSelectionCount = try values.decodeIfPresent(
            Int.self,
            forKey: .albumSelectionCount
        ) ?? 0
        playlistPlayCount = try values.decodeIfPresent(
            Int.self,
            forKey: .playlistPlayCount
        ) ?? 0
        autoplayCount = try values.decodeIfPresent(
            Int.self,
            forKey: .autoplayCount
        ) ?? 0
        queueRemovalCount = try values.decodeIfPresent(
            Int.self,
            forKey: .queueRemovalCount
        ) ?? 0
        playlistAddCount = try values.decodeIfPresent(
            Int.self,
            forKey: .playlistAddCount
        ) ?? 0
        favoriteCount = try values.decodeIfPresent(
            Int.self,
            forKey: .favoriteCount
        ) ?? 0
        totalCompletion = try values.decodeIfPresent(
            Double.self,
            forKey: .totalCompletion
        ) ?? Double(completedCount)
        completionSamples = try values.decodeIfPresent(
            Int.self,
            forKey: .completionSamples
        ) ?? completedCount
        consecutiveSkips = try values.decodeIfPresent(
            Int.self,
            forKey: .consecutiveSkips
        ) ?? 0
    }
}

struct ListeningHistorySnapshot: Sendable {
    let mostPlayedSongs: [Song]
    let recentlyPlayedSongs: [Song]
}

struct RecommendationBehaviorSnapshot: Sendable {
    let songs: [String: SongBehavior]
    let recentSongs: [Song]
    let revision: UInt64

    var totalPlayCount: Int {
        songs.values.reduce(0) { $0 + $1.playCount }
    }

    static let empty = RecommendationBehaviorSnapshot(
        songs: [:],
        recentSongs: [],
        revision: 0
    )
}

actor ListeningHistoryStore {
    static let shared = ListeningHistoryStore()

    private let storagePrefix = "listening-history-v2"
    private let legacyStoragePrefix = "listening-history-v1"
    private var activeScope: String?
    private var entries: [String: SongBehavior] = [:]
    private var revision: UInt64 = 0
    private var lastStartedSongID: String?

    private init() {}

    func activate(accountScope: String) {
        guard activeScope != accountScope else { return }
        activeScope = accountScope
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let values = try? JSONDecoder().decode(
               [String: SongBehavior].self,
               from: data
           ) {
            entries = values
        } else if let data = UserDefaults.standard.data(forKey: legacyStorageKey),
                  let values = try? JSONDecoder().decode(
                      [String: SongBehavior].self,
                      from: data
                  ) {
            entries = values
            persist()
            UserDefaults.standard.removeObject(forKey: legacyStorageKey)
        } else {
            entries = [:]
        }
        revision &+= 1
        lastStartedSongID = nil
    }

    func deactivate(accountScope: String) {
        guard activeScope == accountScope else { return }
        activeScope = nil
        entries.removeAll(keepingCapacity: false)
        lastStartedSongID = nil
        revision &+= 1
    }

    func recordStart(
        _ song: Song,
        origin: PlaybackOrigin,
        at date: Date = Date()
    ) {
        guard activeScope != nil, song.externalStreamURL == nil else { return }
        var value = entries[song.id] ?? SongBehavior(song: song, at: date)
        value.song = song
        value.playCount += 1
        value.lastPlayed = date
        if lastStartedSongID == song.id {
            value.repeatCount += 1
        }
        switch origin {
        case .search:
            value.manualPlayCount += 1
            value.searchPlayCount += 1
        case .album:
            value.manualPlayCount += 1
            value.albumSelectionCount += 1
        case .playlist:
            value.manualPlayCount += 1
            value.playlistPlayCount += 1
        case .autoplay:
            value.autoplayCount += 1
        case .manual, .queue:
            value.manualPlayCount += 1
        case .restored:
            break
        }
        entries[song.id] = value
        lastStartedSongID = song.id
        didMutate()
    }

    func recordEnd(
        _ song: Song,
        playedSeconds: TimeInterval,
        duration: TimeInterval,
        reason: PlaybackEndReason
    ) {
        guard activeScope != nil,
              song.externalStreamURL == nil,
              var value = entries[song.id] else {
            return
        }
        let completion: Double
        if duration.isFinite, duration > 0 {
            completion = min(max(playedSeconds / duration, 0), 1)
        } else {
            completion = reason == .completed ? 1 : 0
        }
        value.totalCompletion += completion
        value.completionSamples += 1

        let isCompleted = reason == .completed || completion >= 0.9
        let isSkip = reason == .skipped
            || reason == .queueRemoved
            || (reason == .replaced && completion < 0.4)
        if reason == .queueRemoved {
            value.queueRemovalCount += 1
        }
        if isCompleted {
            value.completedCount += 1
            value.consecutiveSkips = 0
        } else if isSkip {
            value.skipCount += 1
            if completion <= 0.1 {
                value.earlySkipCount += 1
            }
            if value.consecutiveSkips > 0 {
                value.repeatedSkipCount += 1
            }
            value.consecutiveSkips += 1
        } else if completion >= 0.7 {
            value.consecutiveSkips = 0
        }
        entries[song.id] = value
        didMutate()
    }

    func recordQueueRemoval(_ song: Song) {
        guard activeScope != nil,
              song.externalStreamURL == nil else {
            return
        }
        var value = entries[song.id] ?? SongBehavior(song: song, at: Date())
        value.song = song
        value.queueRemovalCount += 1
        entries[song.id] = value
        didMutate()
    }

    func recordPlaylistAdd(_ song: Song) {
        guard activeScope != nil,
              song.externalStreamURL == nil else {
            return
        }
        var value = entries[song.id] ?? SongBehavior(song: song, at: Date())
        value.song = song
        value.playlistAddCount += 1
        entries[song.id] = value
        didMutate()
    }

    func recordFavorite(_ song: Song, enabled: Bool) {
        guard activeScope != nil,
              song.externalStreamURL == nil else {
            return
        }
        var value = entries[song.id] ?? SongBehavior(song: song, at: Date())
        value.song = song
        value.favoriteCount = max(0, value.favoriteCount + (enabled ? 1 : -1))
        entries[song.id] = value
        didMutate()
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

    func recommendationSnapshot(
        recentLimit: Int = 20
    ) -> RecommendationBehaviorSnapshot {
        let recent = entries.values
            .sorted { $0.lastPlayed > $1.lastPlayed }
            .prefix(recentLimit)
            .map(\.song)
        return RecommendationBehaviorSnapshot(
            songs: entries,
            recentSongs: Array(recent),
            revision: revision
        )
    }

    func clear() {
        guard activeScope != nil else { return }
        entries.removeAll(keepingCapacity: false)
        lastStartedSongID = nil
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
        revision &+= 1
        RecommendationMixer.invalidateCache()
    }

    private var storageKey: String {
        "\(storagePrefix).\(activeScope ?? "inactive")"
    }

    private var legacyStorageKey: String {
        "\(legacyStoragePrefix).\(activeScope ?? "inactive")"
    }

    private func didMutate() {
        revision &+= 1
        trimAndPersist()
        RecommendationMixer.invalidateCache()
    }

    private func trimAndPersist() {
        if entries.count > 700 {
            let retained = entries.values
                .sorted { $0.lastPlayed > $1.lastPlayed }
                .prefix(600)
            entries = Dictionary(uniqueKeysWithValues: retained.map {
                ($0.song.id, $0)
            })
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
