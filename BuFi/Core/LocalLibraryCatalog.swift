import Foundation

/// On-device song catalog for instant Last.fm / ListenBrainz matching.
///
/// Structured keys (MBID, ISRC, normalized title+artist) are the only lookup
/// used on the radio path. Neural embeddings were removed from launch because
/// NLContextualEmbedding.load() can abort the process when language assets
/// are missing.
actor LocalLibraryCatalog {
    static let shared = LocalLibraryCatalog()

    static let maximumSongs = 2_500

    private struct Entry: Sendable {
        var song: Song
        var titleKey: String
        var artistKey: String
        var albumKey: String
        var mbid: String
        var isrc: String
        var identityKey: String
    }

    private var activeScope: String?
    private var scopeGeneration: UInt64 = 0
    private var entries: [String: Entry] = [:]
    private var songsByMBID: [String: String] = [:]
    private var songsByISRC: [String: String] = [:]
    private var songsByIdentity: [String: String] = [:]
    private var persistTask: Task<Void, Never>?

    private init() {}

    @discardableResult
    func activate(accountScope: String) async -> AccountSessionToken? {
        if activeScope == accountScope {
            scopeGeneration &+= 1
            return AccountSessionToken(
                accountScope: accountScope,
                generation: scopeGeneration
            )
        }
        persistTask?.cancel()
        persistTask = nil
        scopeGeneration &+= 1
        let generation = scopeGeneration
        if let previous = activeScope {
            await persist(scope: previous)
            guard generation == scopeGeneration else { return nil }
        }
        let loaded = await AppDatabase.shared.loadLibraryCatalog(scope: accountScope)
        guard generation == scopeGeneration else { return nil }
        activeScope = accountScope
        entries.removeAll(keepingCapacity: true)
        songsByMBID.removeAll(keepingCapacity: true)
        songsByISRC.removeAll(keepingCapacity: true)
        songsByIdentity.removeAll(keepingCapacity: true)
        for record in loaded {
            guard let song = try? Self.decodeSong(record.songData) else { continue }
            install(makeEntry(song))
        }
        evictIfNeeded()
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
        scopeGeneration &+= 1
        if let scope = activeScope {
            await persist(scope: scope)
        }
        activeScope = nil
        entries.removeAll(keepingCapacity: false)
        songsByMBID.removeAll(keepingCapacity: false)
        songsByISRC.removeAll(keepingCapacity: false)
        songsByIdentity.removeAll(keepingCapacity: false)
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
            install(makeEntry(song))
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
        await persist(scope: scope)
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
        if !additionalSongs.isEmpty {
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
        }
    }

    private func makeEntry(_ song: Song) -> Entry {
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

    private func schedulePersist() {
        persistTask?.cancel()
        guard let scope = activeScope else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.persist(scope: scope)
        }
    }

    private func persist(scope: String) async {
        let records = entries.values.map { entry in
            LibraryCatalogRecord(
                songID: entry.song.id,
                songData: (try? Self.encodeSong(entry.song)) ?? Data(),
                titleKey: entry.titleKey,
                artistKey: entry.artistKey,
                albumKey: entry.albumKey,
                mbid: entry.mbid,
                isrc: entry.isrc,
                hashEmbedding: Data(),
                neuralEmbedding: Data()
            )
        }.filter { !$0.songData.isEmpty }
        _ = await AppDatabase.shared.replaceLibraryCatalog(
            records,
            scope: scope
        )
    }

    private static func normalizedKey(_ value: String?) -> String {
        guard let value else { return "" }
        return value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func encodeSong(_ song: Song) throws -> Data {
        try JSONEncoder().encode(song)
    }

    private static func decodeSong(_ data: Data) throws -> Song {
        try JSONDecoder().decode(Song.self, from: data)
    }
}
