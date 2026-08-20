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

    func catalogSongs() -> [Song] {
        entries.values.map(\.song)
    }

    private struct PersistenceBatch: Sendable {
        let scope: String
        let generation: UInt64
        let dirty: [String: SongBehavior]
        let deleted: Set<String>
    }

    private let storagePrefix = "listening-history-v2"
    private let legacyStoragePrefix = "listening-history-v1"
    private var activeScope: String?
    private var scopeGeneration: UInt64 = 0
    private var entries: [String: SongBehavior] = [:]
    private var revision: UInt64 = 0
    private var lastStartedSongID: String?
    private var persistenceTask: Task<Void, Never>?
    private var dirtySongIDs: Set<String> = []
    private var deletedSongIDs: Set<String> = []

    private init() {}

    func activate(accountScope: String) async -> AccountSessionToken? {
        if activeScope == accountScope {
            scopeGeneration &+= 1
            return AccountSessionToken(
                accountScope: accountScope,
                generation: scopeGeneration
            )
        }
        let previousScope = activeScope
        persistenceTask?.cancel()
        persistenceTask = nil
        scopeGeneration &+= 1
        let generation = scopeGeneration
        activeScope = nil
        lastStartedSongID = nil

        if let previousScope {
            await persist(
                scope: previousScope,
                generation: generation,
                permitsInactiveScope: true
            )
            guard generation == scopeGeneration, activeScope == nil else { return nil }
        }

        var loaded = await AppDatabase.shared.loadListeningHistory(scope: accountScope)
        guard generation == scopeGeneration, activeScope == nil else { return nil }
        if loaded.isEmpty,
           let legacyEntries = loadLegacyEntries(accountScope: accountScope) {
            loaded = legacyEntries
            if await AppDatabase.shared.replaceListeningHistory(
                legacyEntries,
                scope: accountScope
            ) {
                guard generation == scopeGeneration, activeScope == nil else { return nil }
                removeLegacyStorage(accountScope: accountScope)
            }
        }
        guard generation == scopeGeneration, activeScope == nil else { return nil }
        activeScope = accountScope
        entries = loaded
        dirtySongIDs.removeAll(keepingCapacity: true)
        deletedSongIDs.removeAll(keepingCapacity: true)
        revision &+= 1
        lastStartedSongID = nil
        return AccountSessionToken(
            accountScope: accountScope,
            generation: generation
        )
    }

    @discardableResult
    func deactivate(session: AccountSessionToken) async -> Bool {
        guard session.matches(
            accountScope: activeScope,
            generation: scopeGeneration
        ) else { return false }
        persistenceTask?.cancel()
        persistenceTask = nil
        scopeGeneration &+= 1
        let generation = scopeGeneration
        activeScope = nil
        await persist(
            scope: session.accountScope,
            generation: generation,
            permitsInactiveScope: true
        )
        guard generation == scopeGeneration, activeScope == nil else { return true }
        entries.removeAll(keepingCapacity: false)
        dirtySongIDs.removeAll(keepingCapacity: false)
        deletedSongIDs.removeAll(keepingCapacity: false)
        lastStartedSongID = nil
        revision &+= 1
        return true
    }

    func recordStart(
        _ song: Song,
        origin: PlaybackOrigin,
        session: AccountSessionToken,
        at date: Date = Date()
    ) {
        guard session.matches(
            accountScope: activeScope,
            generation: scopeGeneration
        ), song.externalStreamURL == nil else { return }
        var value = entries[song.id] ?? SongBehavior(song: song, at: date)
        // A list/recommendation row is provisional until playback's getSong
        // resolver calls refreshMetadata. Never let a later stale row
        // downgrade metadata that was already canonicalized in history.
        if value.song.isStarred != song.isStarred {
            value.song.starred = song.starred
        }
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
        didMutate(invalidatesRecommendations: false)
    }

    /// Refreshes persisted display metadata without changing listening counts.
    /// Playback calls this after resolving a cached list item through getSong,
    /// so an old cover-art ID cannot re-enter future mixes through local history.
    func refreshMetadata(
        _ song: Song,
        session: AccountSessionToken
    ) {
        guard session.matches(
                  accountScope: activeScope,
                  generation: scopeGeneration
              ),
              song.externalStreamURL == nil,
              var value = entries[song.id],
              value.song != song else {
            return
        }
        value.song = song
        entries[song.id] = value
        markDirty(song.id)
        didMutate()
    }

    func recordEnd(
        _ song: Song,
        playedSeconds: TimeInterval,
        duration: TimeInterval,
        reason: PlaybackEndReason,
        session: AccountSessionToken
    ) {
        guard session.matches(
                  accountScope: activeScope,
                  generation: scopeGeneration
              ),
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
        if isCompleted || completion >= 0.3 || playedSeconds >= 15 {
            value.playCount += 1
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

    func recordQueueRemoval(
        _ song: Song,
        session: AccountSessionToken
    ) {
        guard session.matches(
                  accountScope: activeScope,
                  generation: scopeGeneration
              ),
              song.externalStreamURL == nil else {
            return
        }
        var value = entries[song.id] ?? SongBehavior(song: song, at: Date())
        if value.song.isStarred != song.isStarred {
            value.song.starred = song.starred
        }
        value.queueRemovalCount += 1
        entries[song.id] = value
        markDirty(song.id)
        didMutate()
    }

    func recordFavorite(
        _ song: Song,
        enabled: Bool,
        session: AccountSessionToken
    ) {
        guard session.matches(
                  accountScope: activeScope,
                  generation: scopeGeneration
              ),
              song.externalStreamURL == nil else {
            return
        }
        var value = entries[song.id] ?? SongBehavior(song: song, at: Date())
        var storedSong = value.song
        storedSong.starred = enabled
            ? (song.starred ?? storedSong.starred ?? Date().ISO8601Format())
            : nil
        value.song = storedSong
        value.favoriteCount = max(0, value.favoriteCount + (enabled ? 1 : -1))
        entries[song.id] = value
        markDirty(song.id)
        didMutate()
    }

    func snapshot(limit: Int = 30) -> ListeningHistorySnapshot {
        let boundedLimit = max(0, limit)
        let mostPlayed = Self.leadingBehaviors(
            in: entries,
            limit: boundedLimit,
            orderedBefore: Self.mostPlayedBefore
        )
        let recent = Self.leadingBehaviors(
            in: entries,
            limit: boundedLimit,
            orderedBefore: Self.recentlyPlayedBefore
        )
        return ListeningHistorySnapshot(
            mostPlayedSongs: mostPlayed.map(\.song),
            recentlyPlayedSongs: recent.map(\.song)
        )
    }

    func recommendationSnapshot(
        recentLimit: Int = 20
    ) -> RecommendationBehaviorSnapshot {
        let boundedLimit = max(0, recentLimit)
        let recent = Self.leadingBehaviors(
            in: entries,
            limit: boundedLimit,
            orderedBefore: Self.recentlyPlayedBefore
        ).map(\.song)
        return RecommendationBehaviorSnapshot(
            songs: entries,
            recentSongs: recent,
            revision: revision
        )
    }

    /// The UI only needs a small prefix (normally 20-30 entries). Maintaining
    /// that prefix directly avoids allocating and sorting all 600 retained
    /// history rows every time recommendations or Home refreshes.
    private static func leadingBehaviors(
        in entries: [String: SongBehavior],
        limit: Int,
        orderedBefore: (SongBehavior, SongBehavior) -> Bool
    ) -> [SongBehavior] {
        guard limit > 0, !entries.isEmpty else { return [] }
        var leading: [SongBehavior] = []
        leading.reserveCapacity(min(limit, entries.count))
        for value in entries.values {
            if leading.count == limit,
               let last = leading.last,
               !orderedBefore(value, last) {
                continue
            }
            var lowerBound = 0
            var upperBound = leading.count
            while lowerBound < upperBound {
                let middle = lowerBound + (upperBound - lowerBound) / 2
                if orderedBefore(value, leading[middle]) {
                    upperBound = middle
                } else {
                    lowerBound = middle + 1
                }
            }
            guard lowerBound < limit else { continue }
            leading.insert(value, at: lowerBound)
            if leading.count > limit { leading.removeLast() }
        }
        return leading
    }

    private static func mostPlayedBefore(
        _ lhs: SongBehavior,
        _ rhs: SongBehavior
    ) -> Bool {
        if lhs.playCount != rhs.playCount { return lhs.playCount > rhs.playCount }
        if lhs.lastPlayed != rhs.lastPlayed { return lhs.lastPlayed > rhs.lastPlayed }
        return lhs.song.id < rhs.song.id
    }

    private static func recentlyPlayedBefore(
        _ lhs: SongBehavior,
        _ rhs: SongBehavior
    ) -> Bool {
        if lhs.lastPlayed != rhs.lastPlayed { return lhs.lastPlayed > rhs.lastPlayed }
        return lhs.song.id < rhs.song.id
    }

    /// Lightweight validation for work that already captured the full
    /// recommendation snapshot. Avoids sorting and copying all entries merely
    /// to learn whether an awaited calculation became stale.
    func recommendationRevision() -> UInt64 {
        revision
    }

    func clear() async {
        guard let scope = activeScope else { return }
        persistenceTask?.cancel()
        persistenceTask = nil
        entries.removeAll(keepingCapacity: false)
        lastStartedSongID = nil
        dirtySongIDs.removeAll(keepingCapacity: true)
        deletedSongIDs.removeAll(keepingCapacity: true)
        await AppDatabase.shared.clearListeningHistory(scope: scope)
        guard activeScope == scope else { return }
        removeLegacyStorage(accountScope: scope)
        revision &+= 1
        RecommendationMixer.invalidateCache()
    }

    private func didMutate(invalidatesRecommendations: Bool = true) {
        revision &+= 1
        trimEntriesIfNeeded()
        schedulePersistence()
        if invalidatesRecommendations {
            RecommendationMixer.invalidateCache()
        }
    }

    func flushPendingWrites() async {
        persistenceTask?.cancel()
        persistenceTask = nil
        guard let scope = activeScope else { return }
        let generation = scopeGeneration
        while AccountSessionToken(
            accountScope: scope,
            generation: generation
        ).matches(accountScope: activeScope, generation: scopeGeneration),
              !dirtySongIDs.isEmpty || !deletedSongIDs.isEmpty {
            let beforeDirty = dirtySongIDs
            let beforeDeleted = deletedSongIDs
            let beforeRevision = revision
            await persist(scope: scope, generation: generation)
            guard dirtySongIDs != beforeDirty
                    || deletedSongIDs != beforeDeleted
                    || revision != beforeRevision else {
                break
            }
        }
    }

    private func trimEntriesIfNeeded() {
        if entries.count > 700 {
            let retained = entries.values
                .sorted { $0.lastPlayed > $1.lastPlayed }
                .prefix(600)
            var retainedEntries: [String: SongBehavior] = [:]
            for value in retained {
                let id = value.song.id
                guard !id.isEmpty else { continue }
                if let existing = retainedEntries[id],
                   existing.lastPlayed >= value.lastPlayed {
                    continue
                }
                retainedEntries[id] = value
            }
            deletedSongIDs.formUnion(entries.keys.filter { retainedEntries[$0] == nil })
            dirtySongIDs.subtract(deletedSongIDs)
            entries = retainedEntries
        }
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        let scope = activeScope
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.flushScheduledPersistence(scope: scope)
        }
    }

    private func flushScheduledPersistence(scope: String?) async {
        guard activeScope == scope else { return }
        persistenceTask = nil
        guard let scope else { return }
        await persist(scope: scope, generation: scopeGeneration)
    }

    private func persist(
        scope: String,
        generation: UInt64,
        permitsInactiveScope: Bool = false
    ) async {
        let token = AccountSessionToken(
            accountScope: scope,
            generation: generation
        )
        guard (permitsInactiveScope
                ? activeScope == nil && scopeGeneration == generation
                : token.matches(
                    accountScope: activeScope,
                    generation: scopeGeneration
                )),
              !dirtySongIDs.isEmpty || !deletedSongIDs.isEmpty else { return }
        let batch = PersistenceBatch(
            scope: scope,
            generation: generation,
            dirty: Dictionary(
                uniqueKeysWithValues: dirtySongIDs.compactMap { id in
                    entries[id].map { (id, $0) }
                }
            ),
            deleted: deletedSongIDs
        )
        guard await AppDatabase.shared.applyListeningHistory(
            batch.dirty,
            deletedIDs: batch.deleted,
            scope: batch.scope
        ) else { return }
        guard permitsInactiveScope
                ? activeScope == nil && scopeGeneration == generation
                : token.matches(
                    accountScope: activeScope,
                    generation: scopeGeneration
                ) else { return }
        // The actor can accept a newer playback event while the database write
        // is suspended. Only acknowledge the exact values that were written;
        // otherwise the newer mutation must remain dirty for the next flush.
        guard batch.generation == generation else { return }
        for (id, savedValue) in batch.dirty where entries[id] == savedValue {
            dirtySongIDs.remove(id)
        }
        for id in batch.deleted where entries[id] == nil {
            deletedSongIDs.remove(id)
        }
    }

    private func markDirty(_ songID: String) {
        dirtySongIDs.insert(songID)
        deletedSongIDs.remove(songID)
    }

    private func loadLegacyEntries(
        accountScope: String
    ) -> [String: SongBehavior]? {
        for key in [
            "\(storagePrefix).\(accountScope)",
            "\(legacyStoragePrefix).\(accountScope)"
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
            forKey: "\(storagePrefix).\(accountScope)"
        )
        UserDefaults.standard.removeObject(
            forKey: "\(legacyStoragePrefix).\(accountScope)"
        )
    }
}
