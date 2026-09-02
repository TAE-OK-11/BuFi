import Foundation

/// On-device song catalog for instant Last.fm / ListenBrainz matching.
///
/// Structured keys (MBID, ISRC, normalized title+artist) are the only lookup
/// used on the radio path. Neural embeddings were removed from launch because
/// NLContextualEmbedding.load() can abort the process when language assets
/// are missing.
actor LocalLibraryCatalog {
    static let shared = LocalLibraryCatalog()

    private nonisolated static let songDecoder = JSONDecoder()
    private nonisolated static let songEncoder = JSONEncoder()

    static let maximumSongs = 2_500

    private struct Entry: Sendable, Equatable {
        var song: Song
        var titleKey: String
        var artistKey: String
        var albumKey: String
        var mbid: String
        var isrc: String
        var identityKey: String
    }

    private struct PersistenceBatch: Sendable {
        let scope: String
        let generation: UInt64
        let dirty: [String: Entry]
        let deleted: Set<String>
    }

    private struct DecodedRecords: Sendable {
        let entries: [Entry]
        let invalidSongIDs: Set<String>
    }

    private var activeScope: String?
    private var scopeGeneration: UInt64 = 0
    private var entries: [String: Entry] = [:]
    private var songsByMBID: [String: String] = [:]
    private var songsByISRC: [String: String] = [:]
    private var songsByIdentity: [String: String] = [:]
    private var persistTask: Task<Void, Never>?
    private var persistenceRetryCount = 0
    private var dirtySongIDs: Set<String> = []
    private var deletedSongIDs: Set<String> = []
    private static let maximumPersistenceRetryCount = 3

    private init() {}

    @discardableResult
    func activate(accountScope: String) async -> AccountSessionToken? {
        if activeScope == accountScope {
            persistTask?.cancel()
            persistTask = nil
            scopeGeneration &+= 1
            if hasPendingPersistence {
                schedulePersist()
            }
            return AccountSessionToken(
                accountScope: accountScope,
                generation: scopeGeneration
            )
        }
        persistTask?.cancel()
        persistTask = nil
        persistenceRetryCount = 0
        scopeGeneration &+= 1
        let generation = scopeGeneration
        let previousScope = activeScope
        activeScope = nil
        if let previousScope {
            _ = await persist(
                scope: previousScope,
                generation: generation,
                permitsInactiveScope: true
            )
            guard generation == scopeGeneration else { return nil }
        }
        let loaded = await AppDatabase.shared.loadLibraryCatalog(scope: accountScope)
        guard generation == scopeGeneration, activeScope == nil else { return nil }
        let decoded: DecodedRecords
        do {
            decoded = try await Self.decodeRecordsConcurrently(loaded)
        } catch {
            return nil
        }
        guard generation == scopeGeneration, activeScope == nil else { return nil }
        activeScope = accountScope
        entries.removeAll(keepingCapacity: true)
        songsByMBID.removeAll(keepingCapacity: true)
        songsByISRC.removeAll(keepingCapacity: true)
        songsByIdentity.removeAll(keepingCapacity: true)
        dirtySongIDs.removeAll(keepingCapacity: true)
        deletedSongIDs.removeAll(keepingCapacity: true)
        deletedSongIDs.formUnion(decoded.invalidSongIDs)
        for entry in decoded.entries { install(entry) }
        evictIfNeeded()
        if hasPendingPersistence {
            schedulePersist()
        }
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
        persistTask?.cancel()
        persistTask = nil
        persistenceRetryCount = 0
        scopeGeneration &+= 1
        let generation = scopeGeneration
        activeScope = nil
        _ = await persist(
            scope: session.accountScope,
            generation: generation,
            permitsInactiveScope: true
        )
        guard generation == scopeGeneration, activeScope == nil else { return true }
        entries.removeAll(keepingCapacity: false)
        songsByMBID.removeAll(keepingCapacity: false)
        songsByISRC.removeAll(keepingCapacity: false)
        songsByIdentity.removeAll(keepingCapacity: false)
        dirtySongIDs.removeAll(keepingCapacity: false)
        deletedSongIDs.removeAll(keepingCapacity: false)
        return true
    }

    func ingest(_ songs: [Song]) {
        guard activeScope != nil else { return }
        var inserted = false
        for song in songs {
            guard song.externalStreamURL == nil, !song.id.isEmpty else { continue }
            if let existing = entries[song.id], existing.song == song {
                continue
            }
            install(Self.makeEntry(song))
            dirtySongIDs.insert(song.id)
            deletedSongIDs.remove(song.id)
            inserted = true
        }
        if inserted {
            evictIfNeeded()
            schedulePersist()
        }
    }

    func persistNow() async {
        persistTask?.cancel()
        persistTask = nil
        guard let scope = activeScope else { return }
        let generation = scopeGeneration
        let saved = await persist(scope: scope, generation: generation)
        guard !saved else {
            persistenceRetryCount = 0
            return
        }
        schedulePersistenceRetry(scope: scope, generation: generation)
    }

    func cachedMatches(
        source: String,
        key: String,
        maximumAge: TimeInterval
    ) async -> [Song] {
        guard let scope = activeScope, !key.isEmpty else { return [] }
        return await AppDatabase.shared.loadExternalRecommendationCache(
            scope: scope,
            source: source,
            key: key,
            maximumAge: maximumAge
        )
    }

    func storeCachedMatches(
        _ songs: [Song],
        source: String,
        key: String
    ) async {
        guard let scope = activeScope, !key.isEmpty, !songs.isEmpty else { return }
        _ = await AppDatabase.shared.saveExternalRecommendationCache(
            songs,
            scope: scope,
            source: source,
            key: key
        )
    }

    func songIDs() -> Set<String> {
        Set(entries.keys)
    }

    func match(
        _ candidates: [ExternalRecommendationCandidate],
        additionalSongs: [Song] = [],
        limit: Int
    ) -> [Song] {
        let bounded = max(0, limit)
        guard bounded > 0 else { return [] }
        if !additionalSongs.isEmpty, entries.count < 256 {
            ingest(additionalSongs)
        }

        var matches: [Song] = []
        var seen = Set<String>()
        matches.reserveCapacity(min(bounded, candidates.count))

        for candidate in candidates {
            guard matches.count < bounded else { break }
            if let song = exactMatch(candidate), seen.insert(song.id).inserted {
                matches.append(song)
            }
        }
        return matches
    }

    private func exactMatch(
        _ candidate: ExternalRecommendationCandidate
    ) -> Song? {
        // Title + artist only. Album / year / extra artist metadata stays
        // off this path so Last.fm and ListenBrainz keep their own order.
        let mbid = Self.normalizedKey(candidate.recordingMBID)
        if !mbid.isEmpty, let id = songsByMBID[mbid], let song = entries[id]?.song {
            return song
        }
        let title = Self.normalizedKey(candidate.title)
        let artist = Self.normalizedKey(candidate.artist)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let identity = title + "\u{1F}" + artist
        return songsByIdentity[identity].flatMap { entries[$0]?.song }
    }

    private func install(_ entry: Entry) {
        if let previous = entries[entry.song.id] {
            removeIndexes(previous)
        }
        entries[entry.song.id] = entry
        if !entry.mbid.isEmpty { songsByMBID[entry.mbid] = entry.song.id }
        if !entry.isrc.isEmpty { songsByISRC[entry.isrc] = entry.song.id }
        if !entry.identityKey.hasPrefix("\u{1F}") {
            songsByIdentity[entry.identityKey] = entry.song.id
        }
    }

    private func removeIndexes(_ entry: Entry) {
        if songsByMBID[entry.mbid] == entry.song.id {
            songsByMBID[entry.mbid] = nil
        }
        if songsByISRC[entry.isrc] == entry.song.id {
            songsByISRC[entry.isrc] = nil
        }
        if songsByIdentity[entry.identityKey] == entry.song.id {
            songsByIdentity[entry.identityKey] = nil
        }
    }

    private func evictIfNeeded() {
        guard entries.count > Self.maximumSongs else { return }
        let surplus = entries.count - Self.maximumSongs
        let victims = entries.values
            .sorted { lhs, rhs in
                (lhs.song.playCount ?? 0, lhs.song.id)
                    < (rhs.song.playCount ?? 0, rhs.song.id)
            }
            .prefix(surplus)
        for entry in victims {
            removeIndexes(entry)
            entries[entry.song.id] = nil
            dirtySongIDs.remove(entry.song.id)
            deletedSongIDs.insert(entry.song.id)
        }
    }

    private static func makeEntry(_ song: Song) -> Entry {
        let titleKey = Self.normalizedKey(song.title)
        let artistKey = Self.normalizedKey(song.artist)
        return Entry(
            song: song,
            titleKey: titleKey,
            artistKey: artistKey,
            albumKey: Self.normalizedKey(song.album),
            mbid: Self.normalizedKey(song.musicBrainzId),
            isrc: Self.normalizedKey(song.isrc?.first),
            identityKey: titleKey + "\u{1F}" + artistKey
        )
    }

    @concurrent
    private static func decodeRecordsConcurrently(
        _ records: [LibraryCatalogRecord]
    ) async throws -> DecodedRecords {
        try Task.checkCancellation()
        var entries: [Entry] = []
        entries.reserveCapacity(records.count)
        var invalidSongIDs = Set<String>()
        let decoder = songDecoder
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            guard let song = try? decoder.decode(Song.self, from: record.songData),
                  song.id == record.songID,
                  !song.id.isEmpty else {
                invalidSongIDs.insert(record.songID)
                continue
            }
            entries.append(makeEntry(song))
        }
        return DecodedRecords(
            entries: entries,
            invalidSongIDs: invalidSongIDs
        )
    }

    private func schedulePersist(
        retryDelay: Duration? = nil,
        resetRetry: Bool = true
    ) {
        if resetRetry { persistenceRetryCount = 0 }
        persistTask?.cancel()
        guard let scope = activeScope else { return }
        let generation = scopeGeneration
        let delay = retryDelay ?? .seconds(2)
        persistTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.flushScheduledPersistence(
                scope: scope,
                generation: generation
            )
        }
    }

    private var hasPendingPersistence: Bool {
        !dirtySongIDs.isEmpty || !deletedSongIDs.isEmpty
    }

    private func flushScheduledPersistence(
        scope: String,
        generation: UInt64
    ) async {
        guard AccountSessionToken(
            accountScope: scope,
            generation: generation
        ).matches(accountScope: activeScope, generation: scopeGeneration) else {
            return
        }
        persistTask = nil
        let saved = await persist(scope: scope, generation: generation)
        guard AccountSessionToken(
            accountScope: scope,
            generation: generation
        ).matches(accountScope: activeScope, generation: scopeGeneration) else {
            return
        }
        if saved {
            persistenceRetryCount = 0
        } else {
            schedulePersistenceRetry(scope: scope, generation: generation)
        }
    }

    private func schedulePersistenceRetry(
        scope: String,
        generation: UInt64
    ) {
        guard AccountSessionToken(
            accountScope: scope,
            generation: generation
        ).matches(accountScope: activeScope, generation: scopeGeneration),
              hasPendingPersistence else { return }
        persistenceRetryCount += 1
        guard persistenceRetryCount <= Self.maximumPersistenceRetryCount else {
            return
        }
        let delay: Duration = switch persistenceRetryCount {
        case 1: .seconds(1)
        case 2: .seconds(2)
        default: .seconds(4)
        }
        schedulePersist(retryDelay: delay, resetRetry: false)
    }

    private func persist(
        scope: String,
        generation: UInt64,
        permitsInactiveScope: Bool = false
    ) async -> Bool {
        let token = AccountSessionToken(
            accountScope: scope,
            generation: generation
        )
        let ownsGeneration = permitsInactiveScope
            ? activeScope == nil && scopeGeneration == generation
            : token.matches(
                accountScope: activeScope,
                generation: scopeGeneration
            )
        guard ownsGeneration, hasPendingPersistence else { return true }

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
        let records: [LibraryCatalogRecord]
        do {
            records = try await Self.encodeRecordsConcurrently(batch.dirty)
        } catch {
            return false
        }
        guard await AppDatabase.shared.applyLibraryCatalog(
            records,
            deletedIDs: batch.deleted,
            scope: batch.scope
        ) else { return false }

        let stillOwnsGeneration = permitsInactiveScope
            ? activeScope == nil && scopeGeneration == generation
            : token.matches(
                accountScope: activeScope,
                generation: scopeGeneration
            )
        guard stillOwnsGeneration, batch.generation == generation else {
            return true
        }
        for (id, savedEntry) in batch.dirty where entries[id] == savedEntry {
            dirtySongIDs.remove(id)
        }
        for id in batch.deleted where entries[id] == nil {
            deletedSongIDs.remove(id)
        }
        return true
    }

    @concurrent
    private static func encodeRecordsConcurrently(
        _ entries: [String: Entry]
    ) async throws -> [LibraryCatalogRecord] {
        try Task.checkCancellation()
        var records: [LibraryCatalogRecord] = []
        records.reserveCapacity(entries.count)
        let encoder = songEncoder
        for (index, pair) in entries.enumerated() {
            if index.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            let entry = pair.value
            records.append(LibraryCatalogRecord(
                songID: pair.key,
                songData: try encoder.encode(entry.song),
                titleKey: entry.titleKey,
                artistKey: entry.artistKey,
                albumKey: entry.albumKey,
                mbid: entry.mbid,
                isrc: entry.isrc,
                hashEmbedding: Data(),
                neuralEmbedding: Data()
            ))
        }
        return records
    }

    private static func normalizedKey(_ value: String?) -> String {
        guard let value else { return "" }
        return value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
