import Foundation
import NaturalLanguage

/// On-device song catalog for instant Last.fm / ListenBrainz matching.
///
/// Structured keys (MBID, ISRC, normalized title+artist) handle the common
/// case. A hashed n-gram vector plus Apple's NLContextualEmbedding (Core ML)
/// cover fuzzy title/artist matches without calling search3 on the radio path.
actor LocalLibraryCatalog {
    static let shared = LocalLibraryCatalog()

    static let maximumSongs = 2_500
    static let hashDimensions = 64

    private struct Entry: Sendable {
        var song: Song
        var titleKey: String
        var artistKey: String
        var albumKey: String
        var mbid: String
        var isrc: String
        var identityKey: String
        var hashEmbedding: [Float]
        var neuralEmbedding: [Float]
    }

    private var activeScope: String?
    private var scopeGeneration: UInt64 = 0
    private var entries: [String: Entry] = [:]
    private var songsByMBID: [String: String] = [:]
    private var songsByISRC: [String: String] = [:]
    private var songsByIdentity: [String: String] = [:]
    private var persistTask: Task<Void, Never>?
    private var embeddingTask: Task<Void, Never>?
    private var englishEmbedding: NLContextualEmbedding?
    private var koreanEmbedding: NLContextualEmbedding?
    private var didAttemptNeuralLoad = false

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
        embeddingTask?.cancel()
        embeddingTask = nil
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
            install(
                makeEntry(
                    song,
                    hashEmbedding: Self.decodeEmbedding(record.hashEmbedding),
                    neuralEmbedding: Self.decodeEmbedding(record.neuralEmbedding)
                )
            )
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
        embeddingTask?.cancel()
        embeddingTask = nil
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
            let previous = entries[song.id]
            install(
                makeEntry(
                    song,
                    hashEmbedding: previous?.hashEmbedding
                        ?? Self.hashEmbedding(for: song),
                    neuralEmbedding: previous?.neuralEmbedding ?? []
                )
            )
            inserted = true
        }
        if inserted {
            evictIfNeeded()
            schedulePersist()
            scheduleNeuralEmbeddings()
        }
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
        if let mbid = Self.normalizedKey(candidate.recordingMBID),
           let id = songsByMBID[mbid],
           let song = entries[id]?.song {
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

    private func makeEntry(
        _ song: Song,
        hashEmbedding: [Float],
        neuralEmbedding: [Float]
    ) -> Entry {
        let titleKey = Self.normalizedKey(song.title)
        let artistKey = Self.normalizedKey(song.artist)
        return Entry(
            song: song,
            titleKey: titleKey,
            artistKey: artistKey,
            albumKey: Self.normalizedKey(song.album),
            mbid: Self.normalizedKey(song.musicBrainzId),
            isrc: Self.normalizedKey(song.isrc?.first),
            identityKey: titleKey + "\u{1F}" + artistKey,
            hashEmbedding: hashEmbedding.isEmpty
                ? Self.hashEmbedding(for: song)
                : hashEmbedding,
            neuralEmbedding: neuralEmbedding
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
                hashEmbedding: Self.encodeEmbedding(entry.hashEmbedding),
                neuralEmbedding: Self.encodeEmbedding(entry.neuralEmbedding)
            )
        }.filter { !$0.songData.isEmpty }
        _ = await AppDatabase.shared.replaceLibraryCatalog(
            records,
            scope: scope
        )
    }

    private func scheduleNeuralEmbeddings() {
        guard embeddingTask == nil else { return }
        embeddingTask = Task(priority: .utility) { [weak self] in
            await self?.fillNeuralEmbeddings()
        }
    }

    private func fillNeuralEmbeddings() async {
        await loadNeuralModelsIfNeeded()
        guard englishEmbedding != nil || koreanEmbedding != nil else {
            embeddingTask = nil
            return
        }
        let pending = entries.values
            .filter { $0.neuralEmbedding.isEmpty }
            .prefix(400)
            .map(\.song)
        for song in pending {
            guard !Task.isCancelled else { break }
            let vector = neuralVector(
                title: song.title,
                artist: song.artist,
                album: song.album
            )
            guard !vector.isEmpty, var entry = entries[song.id] else { continue }
            entry.neuralEmbedding = vector
            entries[song.id] = entry
        }
        schedulePersist()
        embeddingTask = nil
    }

    private func loadNeuralModelsIfNeeded() async {
        guard !didAttemptNeuralLoad else { return }
        didAttemptNeuralLoad = true
        englishEmbedding = Self.loadEmbedding(for: .english)
        koreanEmbedding = Self.loadEmbedding(for: .korean)
    }

    private func neuralVector(
        title: String,
        artist: String,
        album: String
    ) -> [Float] {
        let text = [title, artist, album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
        guard !text.isEmpty else { return [] }
        let language = Self.dominantLanguage(in: text)
        let model = language == .korean ? koreanEmbedding : englishEmbedding
        guard let model else { return [] }
        return Self.sentenceVector(text, embedding: model, language: language)
    }

    private static func loadEmbedding(
        for language: NLLanguage
    ) -> NLContextualEmbedding? {
        guard let embedding = try? NLContextualEmbedding(language: language) else {
            return nil
        }
        do {
            try embedding.load()
            return embedding
        } catch {
            return nil
        }
    }

    private static func dominantLanguage(in text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if recognizer.dominantLanguage == .korean { return .korean }
        return .english
    }

    private static func sentenceVector(
        _ text: String,
        embedding: NLContextualEmbedding,
        language: NLLanguage
    ) -> [Float] {
        guard let result = try? embedding.embeddingResult(
            for: text,
            language: language
        ) else { return [] }
        var sum: [Double] = []
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) {
            vector,
            _ in
            if sum.isEmpty {
                sum = vector
            } else if vector.count == sum.count {
                for index in sum.indices {
                    sum[index] += vector[index]
                }
            }
            count += 1
            return true
        }
        guard count > 0, !sum.isEmpty else { return [] }
        let scale = 1 / Double(count)
        var floats = sum.map { Float($0 * scale) }
        l2Normalize(&floats)
        return floats
    }

    private static func hashEmbedding(for song: Song) -> [Float] {
        hashEmbedding(
            title: song.title,
            artist: song.artist,
            album: song.album,
            genre: ([song.genre].compactMap { $0 }
                + (song.genres ?? []).map(\.name)).joined(separator: " ")
        )
    }

    private static func hashEmbedding(
        title: String,
        artist: String,
        album: String,
        genre: String
    ) -> [Float] {
        var vector = [Float](repeating: 0, count: hashDimensions)
        let text = normalizedKey(
            [title, artist, album, genre].joined(separator: " ")
        )
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 2 else {
            l2Normalize(&vector)
            return vector
        }
        let limit = scalars.count - 2
        for index in 0...limit {
            var hash: UInt64 = 1_469_598_103_934_665_603
            for offset in 0..<3 {
                hash ^= UInt64(scalars[index + offset].value)
                hash &*= 1_099_511_628_211
            }
            vector[Int(hash % UInt64(hashDimensions))] += 1
        }
        l2Normalize(&vector)
        return vector
    }

    private static func l2Normalize(_ values: inout [Float]) {
        var sum: Float = 0
        for value in values { sum += value * value }
        let norm = sum.squareRoot()
        guard norm > 0 else { return }
        let scale = 1 / norm
        for index in values.indices {
            values[index] *= scale
        }
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

    private static func encodeEmbedding(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    private static func decodeEmbedding(_ data: Data) -> [Float] {
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else {
            return []
        }
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}
