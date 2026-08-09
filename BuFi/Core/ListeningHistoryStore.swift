import Foundation

protocol ListeningHistoryPersistence: Sendable {
    func loadListeningHistory(scope: String) async -> [String: SongBehavior]

    func applyListeningHistory(
        _ values: [String: SongBehavior],
        deletedIDs: Set<String>,
        scope: String
    ) async -> Bool

    func replaceListeningHistory(
        _ values: [String: SongBehavior],
        scope: String
    ) async -> Bool

    func clearListeningHistory(scope: String) async
}

extension AppDatabase: ListeningHistoryPersistence {}

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

struct SongBehavior: Codable, Sendable, Equatable {
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

    init(
        song: Song,
        playCount: Int,
        firstPlayed: Date,
        lastPlayed: Date,
        completedCount: Int,
        skipCount: Int,
        earlySkipCount: Int,
        repeatedSkipCount: Int,
        repeatCount: Int,
        manualPlayCount: Int,
        searchPlayCount: Int,
        albumSelectionCount: Int,
        playlistPlayCount: Int,
        autoplayCount: Int,
        queueRemovalCount: Int,
        playlistAddCount: Int,
        favoriteCount: Int,
        totalCompletion: Double,
        completionSamples: Int,
        consecutiveSkips: Int
    ) {
        self.song = song
        self.playCount = playCount
        self.firstPlayed = firstPlayed
        self.lastPlayed = lastPlayed
        self.completedCount = completedCount
        self.skipCount = skipCount
        self.earlySkipCount = earlySkipCount
        self.repeatedSkipCount = repeatedSkipCount
        self.repeatCount = repeatCount
        self.manualPlayCount = manualPlayCount
        self.searchPlayCount = searchPlayCount
        self.albumSelectionCount = albumSelectionCount
        self.playlistPlayCount = playlistPlayCount
        self.autoplayCount = autoplayCount
        self.queueRemovalCount = queueRemovalCount
        self.playlistAddCount = playlistAddCount
        self.favoriteCount = favoriteCount
        self.totalCompletion = totalCompletion
        self.completionSamples = completionSamples
        self.consecutiveSkips = consecutiveSkips
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
    private let database: any ListeningHistoryPersistence
    private var activeScope: String?
    private var entries: [String: SongBehavior] = [:]
    private var revision: UInt64 = 0
    private var scopeGeneration: UInt64 = 0
    private var scopeTransitionGeneration: UInt64?
    private var lastStartedSongID: String?
    private var persistenceTask: Task<Void, Never>?
    private var persistenceTaskToken: UUID?
    private var dirtySongIDs: Set<String> = []
    private var deletedSongIDs: Set<String> = []
    private var preparedOrdering: PreparedOrdering?

    init(database: any ListeningHistoryPersistence = AppDatabase.shared) {
        self.database = database
    }

    @discardableResult
    func activate(accountScope: String) async -> Bool {
        guard activeScope != accountScope || scopeTransitionGeneration != nil else {
            return true
        }
        let previousScope = activeScope
        let generation = beginScopeTransition()
        if let previousScope {
            let persisted = await persistPendingWrites(
                scope: previousScope,
                generation: generation,
                retryOnFailure: true
            )
            guard isCurrentTransition(generation) else { return false }
            guard persisted, !Task.isCancelled else {
                abortScopeTransition(generation)
                return false
            }
        }

        activeScope = accountScope
        entries.removeAll(keepingCapacity: false)
        dirtySongIDs.removeAll(keepingCapacity: true)
        deletedSongIDs.removeAll(keepingCapacity: true)
        lastStartedSongID = nil
        preparedOrdering = nil

        var loadedEntries = await database.loadListeningHistory(
            scope: accountScope
        )
        guard isCurrentTransition(
            generation,
            accountScope: accountScope
        ) else { return false }
        if loadedEntries.isEmpty,
           let legacyEntries = loadLegacyEntries(accountScope: accountScope) {
            if await database.replaceListeningHistory(
                legacyEntries,
                scope: accountScope
            ) {
                removeLegacyStorage(accountScope: accountScope)
            }
            guard isCurrentTransition(
                generation,
                accountScope: accountScope
            ) else { return false }
            loadedEntries = legacyEntries
        }
        guard isCurrentTransition(
            generation,
            accountScope: accountScope
        ) else { return false }
        entries = loadedEntries
        dirtySongIDs.removeAll(keepingCapacity: true)
        deletedSongIDs.removeAll(keepingCapacity: true)
        lastStartedSongID = nil
        preparedOrdering = nil
        scopeTransitionGeneration = nil
        return true
    }

    func isActive(accountScope: String) -> Bool {
        activeScope == accountScope && scopeTransitionGeneration == nil
    }

    func deactivate(accountScope: String) async {
        guard activeScope == accountScope else { return }
        let generation = beginScopeTransition()
        let persisted = await persistPendingWrites(
            scope: accountScope,
            generation: generation,
            retryOnFailure: true
        )
        guard isCurrentTransition(
            generation,
            accountScope: accountScope
        ) else { return }
        guard persisted, !Task.isCancelled else {
            abortScopeTransition(generation)
            return
        }
        activeScope = nil
        entries.removeAll(keepingCapacity: false)
        dirtySongIDs.removeAll(keepingCapacity: false)
        deletedSongIDs.removeAll(keepingCapacity: false)
        lastStartedSongID = nil
        preparedOrdering = nil
        scopeTransitionGeneration = nil
    }

    func recordStart(
        _ song: Song,
        accountScope: String,
        origin: PlaybackOrigin,
        at date: Date = Date()
    ) {
        guard activeScope == accountScope,
              scopeTransitionGeneration == nil,
              song.externalStreamURL == nil else { return }
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
        markDirty(song.id)
        lastStartedSongID = song.id
        didMutate()
    }

    func recordEnd(
        _ song: Song,
        accountScope: String,
        playedSeconds: TimeInterval,
        duration: TimeInterval,
        reason: PlaybackEndReason
    ) {
        guard activeScope == accountScope,
              scopeTransitionGeneration == nil,
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
        markDirty(song.id)
        didMutate()
    }

    func recordQueueRemoval(_ song: Song, accountScope: String) {
        guard activeScope == accountScope,
              scopeTransitionGeneration == nil,
              song.externalStreamURL == nil else {
            return
        }
        var value = entries[song.id] ?? SongBehavior(song: song, at: Date())
        value.song = song
        value.queueRemovalCount += 1
        entries[song.id] = value
        markDirty(song.id)
        didMutate()
    }

    func recordFavorite(
        _ song: Song,
        accountScope: String,
        enabled: Bool
    ) {
        guard activeScope == accountScope,
              scopeTransitionGeneration == nil,
              song.externalStreamURL == nil else {
            return
        }
        var value = entries[song.id] ?? SongBehavior(song: song, at: Date())
        value.song = song
        value.favoriteCount = max(0, value.favoriteCount + (enabled ? 1 : -1))
        entries[song.id] = value
        markDirty(song.id)
        didMutate()
    }

    func snapshot(limit: Int = 30) -> ListeningHistorySnapshot {
        let boundedLimit = max(0, limit)
        guard scopeTransitionGeneration == nil, boundedLimit > 0 else {
            return ListeningHistorySnapshot(
                mostPlayedSongs: [],
                recentlyPlayedSongs: []
            )
        }
        let ordering = preparedBehaviorOrdering()
        return ListeningHistorySnapshot(
            mostPlayedSongs: Array(
                ordering.mostPlayed.prefix(boundedLimit).map(\.song)
            ),
            recentlyPlayedSongs: Array(
                ordering.recent.prefix(boundedLimit).map(\.song)
            )
        )
    }

    func recommendationSnapshot(
        recentLimit: Int = 20
    ) -> RecommendationBehaviorSnapshot {
        let boundedLimit = max(0, recentLimit)
        guard scopeTransitionGeneration == nil else {
            return RecommendationBehaviorSnapshot(
                songs: [:],
                recentSongs: [],
                revision: revision
            )
        }
        let recent = boundedLimit > 0
            ? preparedBehaviorOrdering().recent
                .prefix(boundedLimit)
                .map(\.song)
            : []
        return RecommendationBehaviorSnapshot(
            songs: entries,
            recentSongs: Array(recent),
            revision: revision
        )
    }

    func clear() async {
        guard scopeTransitionGeneration == nil,
              let scope = activeScope else { return }
        persistenceTask?.cancel()
        persistenceTask = nil
        persistenceTaskToken = nil
        entries.removeAll(keepingCapacity: false)
        lastStartedSongID = nil
        dirtySongIDs.removeAll(keepingCapacity: true)
        deletedSongIDs.removeAll(keepingCapacity: true)
        preparedOrdering = nil
        revision &+= 1
        RecommendationMixer.invalidateCache()
        await database.clearListeningHistory(scope: scope)
        removeLegacyStorage(accountScope: scope)
    }

    private func storageKey(accountScope: String) -> String {
        "\(storagePrefix).\(accountScope)"
    }

    private func legacyStorageKey(accountScope: String) -> String {
        "\(legacyStoragePrefix).\(accountScope)"
    }

    private func didMutate() {
        revision &+= 1
        preparedOrdering = nil
        trimEntriesIfNeeded()
        schedulePersistence()
        RecommendationMixer.invalidateCache()
    }

    func flushPendingWrites() async {
        persistenceTask?.cancel()
        persistenceTask = nil
        persistenceTaskToken = nil
        guard let scope = activeScope else { return }
        _ = await persistPendingWrites(
            scope: scope,
            generation: scopeGeneration,
            retryOnFailure: true
        )
    }

    private func trimEntriesIfNeeded() {
        if entries.count > 700 {
            let retained = entries.values
                .sorted { $0.lastPlayed > $1.lastPlayed }
                .prefix(600)
            let retainedEntries = Dictionary(uniqueKeysWithValues: retained.map {
                ($0.song.id, $0)
            })
            deletedSongIDs.formUnion(entries.keys.filter { retainedEntries[$0] == nil })
            dirtySongIDs.subtract(deletedSongIDs)
            entries = retainedEntries
        }
    }

    private func schedulePersistence() {
        guard let scope = activeScope,
              scopeTransitionGeneration == nil else { return }
        persistenceTask?.cancel()
        let token = UUID()
        persistenceTaskToken = token
        let generation = scopeGeneration
        persistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return
            }
            await self?.flushScheduledPersistence(
                scope: scope,
                generation: generation,
                token: token
            )
        }
    }

    private func flushScheduledPersistence(
        scope: String,
        generation: UInt64,
        token: UUID
    ) async {
        guard activeScope == scope,
              scopeGeneration == generation,
              scopeTransitionGeneration == nil,
              persistenceTaskToken == token else { return }
        persistenceTask = nil
        persistenceTaskToken = nil
        _ = await persistPendingWrites(
            scope: scope,
            generation: generation,
            retryOnFailure: true
        )
    }

    private enum PersistenceAttempt {
        case saved
        case failed
        case stale
    }

    private static let maximumPersistenceRetryCount = 2

    private func persistPendingWrites(
        scope: String,
        generation: UInt64,
        retryOnFailure: Bool
    ) async -> Bool {
        var retryCount = 0
        while activeScope == scope,
              scopeGeneration == generation,
              (!dirtySongIDs.isEmpty || !deletedSongIDs.isEmpty) {
            switch await persist(
                scope: scope,
                generation: generation
            ) {
            case .saved:
                retryCount = 0
                if Task.isCancelled {
                    return dirtySongIDs.isEmpty && deletedSongIDs.isEmpty
                }
            case .failed:
                guard retryOnFailure,
                      retryCount < Self.maximumPersistenceRetryCount else {
                    return false
                }
                retryCount += 1
                let delay: Duration = retryCount == 1
                    ? .milliseconds(250)
                    : .milliseconds(750)
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return false
                }
            case .stale:
                return false
            }
        }
        return activeScope == scope
            && scopeGeneration == generation
            && dirtySongIDs.isEmpty
            && deletedSongIDs.isEmpty
    }

    private func persist(
        scope: String,
        generation: UInt64
    ) async -> PersistenceAttempt {
        guard activeScope == scope, scopeGeneration == generation else {
            return .stale
        }
        let dirty = Dictionary(uniqueKeysWithValues: dirtySongIDs.compactMap { id in
            entries[id].map { (id, $0) }
        })
        let deleted = deletedSongIDs
        let saved = await database.applyListeningHistory(
            dirty,
            deletedIDs: deleted,
            scope: scope
        )
        guard activeScope == scope, scopeGeneration == generation else {
            return .stale
        }
        guard saved else { return .failed }
        // The actor can accept a newer playback event while the database write
        // is suspended. Only acknowledge the exact values that were written;
        // otherwise the newer mutation must remain dirty for the next flush.
        for (id, savedValue) in dirty where entries[id] == savedValue {
            dirtySongIDs.remove(id)
        }
        for id in deleted where entries[id] == nil {
            deletedSongIDs.remove(id)
        }
        return .saved
    }

    private func markDirty(_ songID: String) {
        dirtySongIDs.insert(songID)
        deletedSongIDs.remove(songID)
    }

    private struct PreparedOrdering {
        let revision: UInt64
        let mostPlayed: [SongBehavior]
        let recent: [SongBehavior]
    }

    private func preparedBehaviorOrdering() -> PreparedOrdering {
        if let preparedOrdering, preparedOrdering.revision == revision {
            return preparedOrdering
        }
        let values = Array(entries.values)
        let value = PreparedOrdering(
            revision: revision,
            mostPlayed: values.sorted {
                if $0.playCount == $1.playCount {
                    return $0.lastPlayed > $1.lastPlayed
                }
                return $0.playCount > $1.playCount
            },
            recent: values.sorted { $0.lastPlayed > $1.lastPlayed }
        )
        preparedOrdering = value
        return value
    }

    private func beginScopeTransition() -> UInt64 {
        scopeGeneration &+= 1
        let generation = scopeGeneration
        scopeTransitionGeneration = generation
        persistenceTask?.cancel()
        persistenceTask = nil
        persistenceTaskToken = nil
        preparedOrdering = nil
        revision &+= 1
        RecommendationMixer.invalidateCache()
        return generation
    }

    private func abortScopeTransition(_ generation: UInt64) {
        guard isCurrentTransition(generation) else { return }
        scopeTransitionGeneration = nil
        if !dirtySongIDs.isEmpty || !deletedSongIDs.isEmpty {
            schedulePersistence()
        }
    }

    private func isCurrentTransition(
        _ generation: UInt64,
        accountScope: String? = nil
    ) -> Bool {
        guard scopeGeneration == generation,
              scopeTransitionGeneration == generation else {
            return false
        }
        return accountScope.map { activeScope == $0 } ?? true
    }

    private func loadLegacyEntries(
        accountScope: String
    ) -> [String: SongBehavior]? {
        for key in [
            storageKey(accountScope: accountScope),
            legacyStorageKey(accountScope: accountScope)
        ] {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let values = try? JSONDecoder().decode(
                      [String: SongBehavior].self,
                      from: data
                  ) else { continue }
            return values
        }
        return nil
    }

    private func removeLegacyStorage(accountScope: String) {
        UserDefaults.standard.removeObject(
            forKey: storageKey(accountScope: accountScope)
        )
        UserDefaults.standard.removeObject(
            forKey: legacyStorageKey(accountScope: accountScope)
        )
    }
}
