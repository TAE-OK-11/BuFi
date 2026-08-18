import Foundation

struct RecommendationWeights: Sendable {
    var history: Double
    var favorites: Double
    var serverSimilarity: Double
    var discovery: Double
    var lastFM: Double
    var listenBrainz: Double
    var behavior: Double
    var completion: Double
    var repeatListening: Double
    var recency: Double
    var context: Double
    var localMetadata: Double
    var playlistAffinity: Double
    var albumCompletion: Double
    var forgottenFavorites: Double
    var artistRotation: Double
    var timeAwareness: Double
    var discoveryRatio: Double

    static func current(_ defaults: UserDefaults = .standard) -> RecommendationWeights {
        RecommendationTasteControls.weights(in: defaults)
    }
}

enum RecommendationTasteControls {
    static let nowKey = "recommendation-feel-now"
    static let tasteKey = "recommendation-feel-taste"
    static let freshKey = "recommendation-feel-fresh"

    static let defaultNow = 0.82
    static let defaultTaste = 0.70
    static let defaultFresh = 0.28

    static func clamped(_ defaults: UserDefaults, _ key: String, _ fallback: Double) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return min(max(defaults.double(forKey: key), 0), 1)
    }

    static func weights(in defaults: UserDefaults = .standard) -> RecommendationWeights {
        let now = clamped(defaults, nowKey, defaultNow)
        let taste = clamped(defaults, tasteKey, defaultTaste)
        let fresh = clamped(defaults, freshKey, defaultFresh)
        return RecommendationWeights(
            history: 0.42 + taste * 0.40,
            favorites: 0.48 + taste * 0.42,
            serverSimilarity: 0.78 + (1 - fresh) * 0.16,
            discovery: 0.12 + fresh * 0.70,
            lastFM: 0.70 + fresh * 0.22,
            listenBrainz: 0.70 + fresh * 0.22,
            behavior: 0.52 + taste * 0.36,
            completion: 0.48 + taste * 0.38,
            repeatListening: 0.38 + taste * 0.28,
            recency: 0.42 + now * 0.48,
            context: 0.40 + now * 0.55,
            localMetadata: 0.46 + now * 0.22,
            playlistAffinity: 0.38 + taste * 0.22,
            albumCompletion: 0.32 + now * 0.28,
            forgottenFavorites: 0.22 + taste * 0.28,
            artistRotation: 0.22 + (1 - now) * 0.28,
            timeAwareness: 0.22,
            discoveryRatio: fresh
        )
    }
}

enum RecommendationPurpose: String, Sendable {
    case home
    case daylist
    case taste
    case artistMix
    case discovery
    case frequent
    case autoplay
}

private enum RecommendationFeature: Int, CaseIterable, Hashable {
    case history
    case favorites
    case server
    case discovery
    case lastFM
    case listenBrainz
    case behavior
    case completion
    case repeatListening
    case recency
    case context
    case localMetadata
    case playlistAffinity
    case albumCompletion
    case forgottenFavorites
    case artistRotation
    case timeAwareness
    case popularity
}

private struct StableFingerprint {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func append(_ value: String) {
        append(UInt64(value.utf8.count))
        for byte in value.utf8 {
            self.value ^= UInt64(byte)
            self.value &*= 1_099_511_628_211
        }
    }

    mutating func append(_ value: UInt64) {
        var value = value
        for _ in 0..<8 {
            self.value ^= value & 0xFF
            self.value &*= 1_099_511_628_211
            value >>= 8
        }
    }

    mutating func append(_ value: Int) {
        append(UInt64(bitPattern: Int64(value)))
    }

    mutating func append(_ value: Double) {
        append(value.bitPattern)
    }

    mutating func append(_ value: String?) {
        guard let value else {
            append(UInt64.max)
            return
        }
        append(UInt64.max - 1)
        append(value)
    }

    mutating func append(_ value: Int?) {
        guard let value else {
            append(UInt64.max)
            return
        }
        append(UInt64.max - 1)
        append(value)
    }

    mutating func append(_ value: Double?) {
        guard let value else {
            append(UInt64.max)
            return
        }
        append(UInt64.max - 1)
        append(value)
    }
}

private struct RecommendationPreset {
    let shortTermRatio: Double
    let featureWeights: [RecommendationFeature: Double]

    static func value(for purpose: RecommendationPurpose) -> RecommendationPreset {
        switch purpose {
        case .home, .daylist:
            RecommendationPreset(
                shortTermRatio: purpose == .daylist ? 0.76 : 0.68,
                featureWeights: [
                    .history: 0.20,
                    .favorites: 0.14,
                    .recency: 0.14,
                    .lastFM: 0.22,
                    .listenBrainz: 0.08,
                    .discovery: 0.06,
                    .server: 0.22,
                    .behavior: 0.16,
                    .completion: 0.16,
                    .repeatListening: 0.08,
                    .context: 0.30,
                    .localMetadata: 0.08,
                    .playlistAffinity: 0.07,
                    .albumCompletion: 0.08,
                    .forgottenFavorites: 0.04,
                    .artistRotation: 0.05
                ]
            )
        case .taste:
            RecommendationPreset(
                shortTermRatio: 0.30,
                featureWeights: [
                    .history: 0.34, .favorites: 0.28, .server: 0.16,
                    .behavior: 0.22, .completion: 0.18,
                    .repeatListening: 0.15, .localMetadata: 0.12,
                    .forgottenFavorites: 0.09, .playlistAffinity: 0.08,
                    .artistRotation: 0.07
                ]
            )
        case .artistMix:
            RecommendationPreset(
                shortTermRatio: 0.45,
                featureWeights: [
                    .favorites: 0.20, .server: 0.30, .history: 0.16,
                    .discovery: 0.10, .lastFM: 0.24,
                    .listenBrainz: 0.08, .behavior: 0.12,
                    .localMetadata: 0.18, .artistRotation: 0.05
                ]
            )
        case .discovery:
            RecommendationPreset(
                shortTermRatio: 0.55,
                featureWeights: [
                    .discovery: 0.28, .lastFM: 0.30,
                    .listenBrainz: 0.12, .history: 0.12,
                    .server: 0.22, .context: 0.12,
                    .localMetadata: 0.10, .artistRotation: 0.12
                ]
            )
        case .frequent:
            RecommendationPreset(
                shortTermRatio: 0.42,
                featureWeights: [
                    .behavior: 0.40, .completion: 0.20,
                    .repeatListening: 0.20, .favorites: 0.20,
                    .history: 0.18
                ]
            )
        case .autoplay:
            RecommendationPreset(
                shortTermRatio: 0.78,
                featureWeights: [
                    .context: 0.40, .server: 0.26, .history: 0.10,
                    .favorites: 0.08, .lastFM: 0.20,
                    .listenBrainz: 0.06, .behavior: 0.14,
                    .completion: 0.14, .discovery: 0.06,
                    .localMetadata: 0.12, .artistRotation: 0.06
                ]
            )
        }
    }
}

private struct RecommendationCandidateMetadata {
    let artistKey: String
    let albumKey: String
    let genreKeys: [String]
    let moodKeys: [String]
    let deduplicationKey: String

    init(song: Song) {
        artistKey = Self.artistKey(for: song)
        albumKey = RecommendationMixer.normalized(song.albumId ?? song.album)
        genreKeys = Self.genreKeys(for: song)
        moodKeys = Self.moodKeys(for: song)
        deduplicationKey = RecommendationMixer.deduplicationKey(for: song)
    }

    static func artistKey(for song: Song) -> String {
        RecommendationMixer.normalized(song.artist)
    }

    static func genreKeys(for song: Song) -> [String] {
        normalizedUnique(
            [song.genre].compactMap { $0 }
                + (song.genres ?? []).map(\.name)
        )
    }

    static func moodKeys(for song: Song) -> [String] {
        normalizedUnique(song.moods ?? [])
    }

    private static func normalizedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(values.count)
        for value in values {
            let key = RecommendationMixer.normalized(value)
            if !key.isEmpty, seen.insert(key).inserted {
                result.append(key)
            }
        }
        return result
    }
}

private struct RecommendationProfile {
    var artists: [String: Double] = [:]
    var genres: [String: Double] = [:]
    var moods: [String: Double] = [:]

    func affinity(for metadata: RecommendationCandidateMetadata) -> Double {
        let artist = metadata.artistKey.isEmpty
            ? 0
            : (artists[metadata.artistKey] ?? 0)
        var genre = 0.0
        for key in metadata.genreKeys {
            genre = max(genre, genres[key] ?? 0)
        }
        var mood = 0.0
        for key in metadata.moodKeys {
            mood = max(mood, moods[key] ?? 0)
        }

        // Keep a strong single match, but reward independent corroboration.
        let strongest = max(artist, max(genre, mood))
        let weakest = min(artist, min(genre, mood))
        let middle = artist + genre + mood - strongest - weakest
        return min(1, strongest + middle * 0.18 + weakest * 0.08)
    }
}

private struct RankedRecommendation {
    let song: Song
    var score: Double
    let artistKey: String
    let albumKey: String
    let genreKeys: [String]
    let deduplicationKey: String
    let isDiscovery: Bool
    let isNewArtist: Bool
    let isHiddenGem: Bool
    let persona: ArtistPersona
    let sourceIndex: Int
}

/// First-order session model from the latest plays. Spotify-style radio
/// continues the current lane (artist / genre / observed transitions)
/// without a second pass over the library.
private struct RecommendationSessionIntent {
    let lastArtist: String
    let lastGenres: Set<String>
    let lastAlbum: String
    let lastIDs: Set<String>
    let artistTransitions: [String: Double]
    let genreTransitions: [String: Double]

    static let empty = RecommendationSessionIntent(
        lastArtist: "",
        lastGenres: [],
        lastAlbum: "",
        lastIDs: [],
        artistTransitions: [:],
        genreTransitions: [:]
    )

    static func make(from recentSongs: [Song]) -> RecommendationSessionIntent {
        let window = Array(recentSongs.prefix(24))
        guard let latest = window.first else { return .empty }

        var artistWeights: [String: Double] = [:]
        var genreWeights: [String: Double] = [:]
        // recentSongs is newest-first. Playback order is older -> newer.
        for index in 0..<(window.count - 1) {
            let newer = window[index]
            let older = window[index + 1]
            let recency = 1 - Double(index) / Double(max(window.count, 2))
            let destArtist = RecommendationCandidateMetadata.artistKey(for: newer)
            if !destArtist.isEmpty {
                artistWeights[destArtist, default: 0] += recency
            }
            let destGenres = RecommendationCandidateMetadata.genreKeys(for: newer)
            let sourceGenres = Set(
                RecommendationCandidateMetadata.genreKeys(for: older)
            )
            for genre in destGenres where !genre.isEmpty {
                if sourceGenres.contains(genre) {
                    genreWeights[genre, default: 0] += recency
                } else {
                    genreWeights[genre, default: 0] += recency * 0.45
                }
            }
        }
        normalize(&artistWeights)
        normalize(&genreWeights)
        return RecommendationSessionIntent(
            lastArtist: RecommendationCandidateMetadata.artistKey(for: latest),
            lastGenres: Set(RecommendationCandidateMetadata.genreKeys(for: latest)),
            lastAlbum: RecommendationMixer.normalized(latest.albumId ?? latest.album),
            lastIDs: Set(window.prefix(3).map(\.id)),
            artistTransitions: artistWeights,
            genreTransitions: genreWeights
        )
    }

    func continuationScore(
        for metadata: RecommendationCandidateMetadata,
        songID: String
    ) -> Double {
        if lastArtist.isEmpty, lastGenres.isEmpty {
            return 0
        }
        // The just-played tracks already occupy the session. Do not let them
        // crowd out the next-up recommendation.
        if lastIDs.contains(songID) { return 0.08 }

        var score = 0.0
        if !metadata.artistKey.isEmpty, metadata.artistKey == lastArtist {
            score = max(score, 0.78)
        } else if let transition = artistTransitions[metadata.artistKey] {
            score = max(score, 0.22 + 0.58 * transition)
        }
        if !metadata.albumKey.isEmpty, metadata.albumKey == lastAlbum {
            score = max(score, 0.52)
        }
        var genreMatch = 0.0
        for key in metadata.genreKeys {
            if lastGenres.contains(key) {
                genreMatch = max(genreMatch, 0.70)
            }
            if let transition = genreTransitions[key] {
                genreMatch = max(genreMatch, 0.28 + 0.50 * transition)
            }
        }
        score = max(score, genreMatch)
        return min(1, score)
    }

    private static func normalize(_ values: inout [String: Double]) {
        let peak = values.values.max() ?? 0
        guard peak > 0 else { return }
        for key in values.keys {
            values[key] = (values[key] ?? 0) / peak
        }
    }
}

private struct RecommendationScoringPlan {
    let weights: [Double]
    let totalWeight: Double

    @inline(__always)
    func contribution(
        _ feature: RecommendationFeature,
        score: Double
    ) -> Double {
        min(max(score, 0), 1) * weights[feature.rawValue]
    }

    @inline(__always)
    func normalizedScore(_ weightedTotal: Double) -> Double {
        totalWeight > 0 ? weightedTotal / totalWeight : 0
    }
}

private struct RecommendationSourceSignals: Sendable {
    var server = 0.0
    var sonic = 0.0
    var similar = 0.0
    var genre = 0.0
    var topArtist = 0.0
    var recent = 0.0
    var popular = 0.0
    var playlist = 0.0
    var discovery = 0.0
    var lastFM = 0.0
    var listenBrainz = 0.0
}

private struct RecommendationSourceIndex: Sendable {
    private var values: [String: RecommendationSourceSignals] = [:]

    init(snapshot: HomeSnapshot) {
        ingest(snapshot.sonicRecommendedSongs, at: \.sonic)
        ingest(snapshot.similarArtistSongs, at: \.similar)
        ingest(snapshot.genreRecommendedSongs, at: \.genre)
        ingest(snapshot.topArtistSongs, at: \.topArtist)
        ingest(snapshot.recentlyAddedSongs, at: \.recent)
        ingest(
            [snapshot.popularSongs, snapshot.mostPlayedSongs],
            at: \.popular
        )
        ingest(snapshot.playlistAffinitySongs, at: \.playlist)
        ingest(snapshot.randomSongs, at: \.discovery)
        ingest(snapshot.lastFMRecommendedSongs, at: \.lastFM)
        ingest(snapshot.listenBrainzRecommendedSongs, at: \.listenBrainz)
    }

    subscript(songID: String) -> RecommendationSourceSignals {
        values[songID] ?? RecommendationSourceSignals()
    }

    private mutating func ingest(
        _ songs: [Song],
        at keyPath: WritableKeyPath<RecommendationSourceSignals, Double>
    ) {
        ingest([songs], at: keyPath)
    }

    private mutating func ingest(
        _ sources: [[Song]],
        at keyPath: WritableKeyPath<RecommendationSourceSignals, Double>
    ) {
        let capacity = sources.reduce(into: 0) { $0 += $1.count }
        var seen = Set<String>()
        seen.reserveCapacity(capacity)
        var orderedIDs: [String] = []
        orderedIDs.reserveCapacity(capacity)
        var visited = 0
        for source in sources {
            for song in source {
                if visited.isMultiple(of: 64), Task.isCancelled { return }
                visited += 1
                if seen.insert(song.id).inserted {
                    orderedIDs.append(song.id)
                }
            }
        }
        let count = orderedIDs.count
        guard count > 0 else { return }
        for (rank, songID) in orderedIDs.enumerated() {
            var signals = values[songID] ?? RecommendationSourceSignals()
            signals[keyPath: keyPath] = count == 1
                ? 1
                : 1 - Double(rank) / Double(count)
            values[songID] = signals
        }
    }
}

private final class RecommendationMixCache: @unchecked Sendable {
    struct Value {
        let createdAt: Date
        let songs: [Song]
    }

    private let lock = NSLock()
    private var values: [String: Value] = [:]

    func value(for key: String, lifetime: TimeInterval, now: Date) -> [Song]? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[key],
              now.timeIntervalSince(value.createdAt) < lifetime else {
            values[key] = nil
            return nil
        }
        return value.songs
    }

    func insert(_ songs: [Song], for key: String, now: Date) {
        lock.lock()
        values[key] = Value(createdAt: now, songs: songs)
        if values.count > 48 {
            let retained = values.sorted {
                $0.value.createdAt > $1.value.createdAt
            }
            values = Dictionary(
                uniqueKeysWithValues: retained.prefix(32).map {
                    ($0.key, $0.value)
                }
            )
        }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        values.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

/// Home snapshots can carry thousands of starred songs. Scoring every
/// unique ID is wasted work because the mixer only publishes a few dozen
/// tracks and source lists are already ordered by usefulness.
enum RecommendationSuppressionPolicy {
    /// Songs the user repeatedly rejects should not come back in a mix.
    static func shouldDrop(_ value: SongBehavior?) -> Bool {
        guard let value else { return false }
        if value.earlySkipCount >= 2, value.earlySkipCount > value.completedCount {
            return true
        }
        if value.queueRemovalCount >= 2, value.playCount <= 2 {
            return true
        }
        if value.skipCount >= 4, value.completedCount == 0 {
            return true
        }
        return false
    }
}

enum RecommendationSeedAffinity {
    /// Distance to the current seed. Same album after a completed listen is
    /// the strongest local radio cue; BPM and genre keep the lane.
    static func score(
        candidate: Song,
        seed: Song,
        seedCompleted: Bool
    ) -> Double {
        if candidate.id == seed.id { return 0 }
        var score = 0.0
        let seedArtist = RecommendationCandidateMetadata.artistKey(for: seed)
        let candidateArtist = RecommendationCandidateMetadata.artistKey(for: candidate)
        if !seedArtist.isEmpty, seedArtist == candidateArtist {
            score = max(score, 0.80)
        }
        let seedAlbum = RecommendationMixer.normalized(seed.albumId ?? seed.album)
        let candidateAlbum = RecommendationMixer.normalized(
            candidate.albumId ?? candidate.album
        )
        if !seedAlbum.isEmpty, seedAlbum == candidateAlbum {
            score = max(score, seedCompleted ? 0.94 : 0.62)
            if seedCompleted,
               let next = candidate.track,
               let current = seed.track,
               next > current,
               next <= current + 3 {
                score = max(score, 0.98)
            }
        }
        let seedGenres = Set(RecommendationCandidateMetadata.genreKeys(for: seed))
        let seedWork = TrackWorkIdentity.coreTitle(seed.title)
        let candidateWork = TrackWorkIdentity.coreTitle(candidate.title)
        if !seedWork.isEmpty, seedWork == candidateWork {
            score = max(score, 0.70)
        }
        if !seedGenres.isEmpty,
           RecommendationCandidateMetadata.genreKeys(for: candidate)
            .contains(where: seedGenres.contains) {
            score = max(score, 0.72)
        }
        if let left = candidate.bpm, let right = seed.bpm, left > 0, right > 0 {
            let delta = abs(left - right)
            if delta <= 8 {
                score = max(score, 0.74)
            } else if delta <= 16 {
                score = max(score, 0.56)
            }
        }
        return min(1, score)
    }
}

enum RecommendationScoringPolicy {
    static let scoringCandidateLimit = 280

    static func boundedCandidates(_ songs: [Song]) -> [Song] {
        guard songs.count > scoringCandidateLimit else { return songs }
        return Array(songs.prefix(scoringCandidateLimit))
    }
}

/// Full-home refreshes re-enter the Last.fm / ListenBrainz path even when the
/// seed and snapshot identity have not changed. Skip that radio work until
/// one of those inputs actually moves.
struct ExternalRecommendationRefreshIdentity: Equatable, Sendable {
    let sessionGeneration: Int
    let snapshotRevision: HomeSnapshotRevision
    let seedSongID: String?
    let includesLastFM: Bool
    let includesListenBrainz: Bool
}

enum ExternalRecommendationRefreshPolicy {
    static func shouldRefresh(
        previous: ExternalRecommendationRefreshIdentity?,
        next: ExternalRecommendationRefreshIdentity
    ) -> Bool {
        previous != next
    }
}

enum RecommendationMixer {
    private static let cache = RecommendationMixCache()

    /// CPU-heavy recommendation scoring deliberately leaves the caller's
    /// actor. The async boundary stays structured, so cancellation belongs to
    /// the request that asked for the mix instead of an orphan detached task.
    @concurrent
    static func mixConcurrently(
        snapshot: HomeSnapshot,
        snapshotRevision: HomeSnapshotRevision? = nil,
        weights: RecommendationWeights,
        purpose: RecommendationPurpose = .home,
        behavior: RecommendationBehaviorSnapshot = .empty,
        seed: Song? = nil,
        limit: Int = 40,
        date: Date = Date()
    ) async -> [Song] {
        guard !Task.isCancelled else { return [] }
        return mix(
            snapshot: snapshot,
            snapshotRevision: snapshotRevision,
            weights: weights,
            purpose: purpose,
            behavior: behavior,
            seed: seed,
            limit: limit,
            date: date
        )
    }

    /// Home and daylist deliberately share one concurrent job and evaluation
    /// timestamp. Running them in parallel would compete for CPU/radio-adjacent
    /// work and increase energy use without improving first-result latency.
    @concurrent
    static func sectionsConcurrently(
        snapshot: HomeSnapshot,
        snapshotRevision: HomeSnapshotRevision? = nil,
        weights: RecommendationWeights,
        behavior: RecommendationBehaviorSnapshot,
        date: Date = Date()
    ) async -> (recommended: [Song], daylist: [Song]) {
        guard !Task.isCancelled else { return ([], []) }
        let seed = behavior.recentSongs.first
        let recommended = mix(
            snapshot: snapshot,
            snapshotRevision: snapshotRevision,
            weights: weights,
            behavior: behavior,
            seed: seed,
            limit: 40,
            date: date
        )
        guard !Task.isCancelled else { return (recommended, []) }
        let daylist = mix(
            snapshot: snapshot,
            snapshotRevision: snapshotRevision,
            weights: weights,
            purpose: .daylist,
            behavior: behavior,
            seed: seed,
            limit: 32,
            date: date
        )
        return (recommended, daylist)
    }

    static func mix(
        snapshot: HomeSnapshot,
        snapshotRevision: HomeSnapshotRevision? = nil,
        weights: RecommendationWeights,
        purpose: RecommendationPurpose = .home,
        behavior: RecommendationBehaviorSnapshot = .empty,
        seed: Song? = nil,
        limit: Int = 40,
        date: Date = Date()
    ) -> [Song] {
        guard limit > 0, !Task.isCancelled else { return [] }
        guard let key = cacheKey(
            snapshot: snapshot,
            snapshotRevision: snapshotRevision,
            weights: weights,
            purpose: purpose,
            behavior: behavior,
            seed: seed,
            limit: limit,
            date: date
        ) else { return [] }
        guard !Task.isCancelled else { return [] }
        if let cached = cache.value(
            for: key,
            lifetime: cacheLifetime(for: purpose),
            now: date
        ) {
            return Task.isCancelled ? [] : cached
        }

        let evaluationDate = temporalEvaluationDate(for: purpose, date: date)
        let preset = RecommendationPreset.value(for: purpose)
        let allBehaviors = behavior.songs.values.sorted {
            if $0.song.id == $1.song.id {
                return $0.lastPlayed < $1.lastPlayed
            }
            return $0.song.id < $1.song.id
        }
        let shortCutoff = evaluationDate.addingTimeInterval(-14 * 86_400)
        let longCutoff = evaluationDate.addingTimeInterval(-365 * 86_400)
        let profiles = temporalProfiles(
            from: allBehaviors,
            shortCutoff: shortCutoff,
            longCutoff: longCutoff,
            date: evaluationDate
        )
        let shortProfile = profiles.short
        let longProfile = profiles.long
        let contextProfile = profile(
            from: behavior.recentSongs.compactMap { behavior.songs[$0.id] },
            date: evaluationDate,
            appliesDecay: false
        )
        let favoriteProfile = profile(
            from: snapshot.starredSongs.map { song in
                var value = behavior.songs[song.id]
                    ?? SongBehavior(song: song, at: evaluationDate)
                // Preserve behavioral evidence but always derive preference
                // dimensions from the authoritative current starred metadata.
                value.song = song
                return value
            },
            date: evaluationDate,
            appliesDecay: false
        )
        guard !Task.isCancelled else { return [] }

        let starredSongIDs = Set(snapshot.starredSongs.map(\.id))
        var knownSongIDs = starredSongIDs
        knownSongIDs.formUnion(snapshot.mostPlayedSongs.lazy.map(\.id))
        knownSongIDs.formUnion(behavior.songs.keys)
        let knownArtists = Set(
            (snapshot.starredSongs + snapshot.mostPlayedSongs)
                .map { normalized($0.artist) }
            + allBehaviors.map { normalized($0.song.artist) }
        )
        let recentArtists = Set(
            behavior.recentSongs.prefix(10).map { normalized($0.artist) }
        )
        let favoriteGenres = Set(
            snapshot.starredSongs.flatMap {
                ([ $0.genre ].compactMap { $0 } + ($0.genres ?? []).map(\.name))
                    .map(normalized)
            }
        )

        let sourceLists: [[Song]] = [
            snapshot.sonicRecommendedSongs,
            snapshot.similarArtistSongs,
            snapshot.genreRecommendedSongs,
            snapshot.topArtistSongs,
            snapshot.recentlyAddedSongs,
            snapshot.popularSongs,
            snapshot.playlistAffinitySongs,
            snapshot.lastFMRecommendedSongs,
            snapshot.listenBrainzRecommendedSongs,
            snapshot.randomSongs,
            snapshot.mostPlayedSongs,
            snapshot.starredSongs
        ]
        // Deduplicate while streaming sources; avoid a second flattened corpus.
        // High-priority recommendation lists come first, so a bounded prefix
        // keeps server/external signals and drops only surplus starred rows.
        let candidates = MediaIdentity.uniqueSongs(
            from: sourceLists,
            limit: RecommendationScoringPolicy.scoringCandidateLimit
        )
        guard !candidates.isEmpty else { return [] }

        let sourceIndex = RecommendationSourceIndex(snapshot: snapshot)
        guard !Task.isCancelled else { return [] }
        let maxRepeat = max(1, allBehaviors.reduce(0) {
            max($0, log1p(Double($1.repeatCount)))
        })
        let behaviorMaxPlayCount = allBehaviors.reduce(0) {
            max($0, $1.playCount)
        }
        let maxPlayCount = max(1, candidates.reduce(Double(behaviorMaxPlayCount)) {
            max($0, Double($1.playCount ?? 0))
        })
        var albumCandidateCounts: [String: Int] = [:]
        for (index, song) in candidates.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return [] }
            if let albumID = song.albumId {
                albumCandidateCounts[albumID, default: 0] += 1
            }
        }
        var playedAlbumCounts: [String: Int] = [:]
        for value in allBehaviors where value.playCount > 0 {
            if let albumID = value.song.albumId {
                playedAlbumCounts[albumID, default: 0] += 1
            }
        }
        let isColdStart = behavior.totalPlayCount < 5
        let scoringPlan = scoringPlan(
            weights: weights,
            preset: preset,
            coldStart: isColdStart,
            hasLastFM: !snapshot.lastFMRecommendedSongs.isEmpty,
            hasListenBrainz: !snapshot.listenBrainzRecommendedSongs.isEmpty
        )
        let rankingSeed = temporalBucket(for: purpose, date: date)
        let sessionIntent = RecommendationSessionIntent.make(
            from: behavior.recentSongs
        )
        let resolvedSeed = seed ?? behavior.recentSongs.first
        let seedBehavior = resolvedSeed.flatMap { behavior.songs[$0.id] }
        let seedCompleted = seedBehavior.map {
            $0.averageCompletion >= 0.65 || $0.completedCount > $0.skipCount
        } ?? false

        var ranked: [RankedRecommendation] = []
        ranked.reserveCapacity(candidates.count)
        for (index, song) in candidates.enumerated() {
            if index.isMultiple(of: 32), Task.isCancelled { return [] }
            let songBehavior = behavior.songs[song.id]
            if RecommendationSuppressionPolicy.shouldDrop(songBehavior) {
                continue
            }
            let metadata = RecommendationCandidateMetadata(song: song)
            let shortAffinity = shortProfile.affinity(for: metadata)
            let longAffinity = longProfile.affinity(for: metadata)
            let historyAffinity =
                shortAffinity * preset.shortTermRatio
                + longAffinity * (1 - preset.shortTermRatio)
            // Favorite identity is authoritative even when an earlier source
            // carries stale metadata for the same server song ID.
            let exactFavorite = starredSongIDs.contains(song.id) || song.isStarred
                ? 1.0 : 0.0
            let favoriteAffinity = max(
                exactFavorite,
                favoriteProfile.affinity(for: metadata)
            )
            let sourceSignals = sourceIndex[song.id]
            let serverScore = consensusScore(
                sourceSignals.server,
                sourceSignals.sonic,
                sourceSignals.similar,
                sourceSignals.genre,
                sourceSignals.topArtist
            )
            let behaviorScore = behaviorAffinity(songBehavior)
            let completionScore = completionAffinity(
                songBehavior?.averageCompletion
            )
            let repeatScore = min(
                1,
                log1p(Double(songBehavior?.repeatCount ?? 0)) / maxRepeat
            )
            let recencyScore = max(
                songBehavior.map {
                    timeDecay(since: $0.lastPlayed, now: evaluationDate)
                } ?? 0,
                sourceSignals.recent
            )
            let metadataScore = localMetadataAffinity(song)
            let playlistScore = max(
                sourceSignals.playlist,
                songBehavior.map {
                    1 - exp(-Double($0.playlistAddCount) * 0.65)
                } ?? 0
            )
            let albumProgress = albumCompletionScore(
                song: song,
                behavior: songBehavior,
                playedAlbumCounts: playedAlbumCounts,
                albumCandidateCounts: albumCandidateCounts
            )
            let forgottenScore = forgottenFavoriteScore(
                song: song,
                behavior: songBehavior,
                favoriteAffinity: favoriteAffinity,
                now: evaluationDate
            )
            let rotationScore = artistRotationScore(
                artistKey: metadata.artistKey,
                favoriteAffinity: favoriteAffinity,
                recentArtists: recentArtists
            )
            let popularityScore = max(
                sourceSignals.popular,
                min(1, log1p(Double(song.playCount ?? 0)) / log1p(maxPlayCount))
            )
            let combinedBehavior = min(
                1,
                behaviorScore * 0.72 + popularityScore * 0.28
            )
            // Dense weights remove an 18-entry Dictionary allocation and
            // Dictionary probes from every candidate in the ranking corpus.
            var weightedTotal = 0.0
            weightedTotal += scoringPlan.contribution(.history, score: historyAffinity)
            weightedTotal += scoringPlan.contribution(.favorites, score: favoriteAffinity)
            weightedTotal += scoringPlan.contribution(.server, score: serverScore)
            weightedTotal += scoringPlan.contribution(
                .discovery,
                score: sourceSignals.discovery
            )
            weightedTotal += scoringPlan.contribution(
                .lastFM,
                score: sourceSignals.lastFM
            )
            weightedTotal += scoringPlan.contribution(
                .listenBrainz,
                score: sourceSignals.listenBrainz
            )
            weightedTotal += scoringPlan.contribution(.behavior, score: combinedBehavior)
            weightedTotal += scoringPlan.contribution(.completion, score: completionScore)
            weightedTotal += scoringPlan.contribution(.repeatListening, score: repeatScore)
            weightedTotal += scoringPlan.contribution(.recency, score: recencyScore)
            let sessionScore = sessionIntent.continuationScore(
                for: metadata,
                songID: song.id
            )
            let seedScore = resolvedSeed.map {
                RecommendationSeedAffinity.score(
                    candidate: song,
                    seed: $0,
                    seedCompleted: seedCompleted
                )
            } ?? 0
            let contextScore = min(
                1,
                contextProfile.affinity(for: metadata) * 0.22
                    + sessionScore * 0.38
                    + seedScore * 1.05
            )
            weightedTotal += scoringPlan.contribution(
                .context,
                score: contextScore
            )
            weightedTotal += scoringPlan.contribution(.localMetadata, score: metadataScore)
            weightedTotal += scoringPlan.contribution(.playlistAffinity, score: playlistScore)
            weightedTotal += scoringPlan.contribution(.albumCompletion, score: albumProgress)
            weightedTotal += scoringPlan.contribution(.forgottenFavorites, score: forgottenScore)
            weightedTotal += scoringPlan.contribution(.artistRotation, score: rotationScore)
            let score = scoringPlan.normalizedScore(weightedTotal)
            let metadataConfidence = metadataConfidence(song)
            let sourceConfidence = sourceConfidence(
                metadata: metadata,
                signals: sourceSignals,
                favoriteGenres: favoriteGenres
            )
            let historyConfidence = historyConfidence(songBehavior)
            let confidence = historyConfidence
                * metadataConfidence
                * sourceConfidence
            let penalty = negativePreferencePenalty(songBehavior)
            let jitter = stableJitter(song.id, seed: rankingSeed)
            let finalScore = max(
                0,
                score * (0.55 + 0.45 * confidence)
                    - penalty * 0.28
                    + jitter
            )
            let isDiscovery = !knownSongIDs.contains(song.id)
            let isNewArtist = !knownArtists.contains(metadata.artistKey)
            // Missing play-count metadata means unknown popularity, not a gem.
            let isHiddenGem = isDiscovery
                && song.playCount.map { $0 <= 2 } == true
                && metadataConfidence >= 0.85
                && sourceConfidence >= 0.45
            let providerRank = max(
                sourceSignals.lastFM,
                sourceSignals.listenBrainz
            )
            let blendedScore = providerRank > 0
                ? finalScore * 0.62 + providerRank * 0.38
                : finalScore
            ranked.append(RankedRecommendation(
                song: song,
                score: blendedScore,
                artistKey: metadata.artistKey,
                albumKey: metadata.albumKey,
                genreKeys: metadata.genreKeys,
                deduplicationKey: metadata.deduplicationKey,
                isDiscovery: isDiscovery,
                isNewArtist: isNewArtist,
                isHiddenGem: isHiddenGem,
                persona: ArtistPersonaCache.shared.resolved(
                    artist: song.artist,
                    genres: metadata.genreKeys,
                    moods: metadata.moodKeys
                ),
                sourceIndex: index
            ))
        }
        guard !Task.isCancelled else { return [] }
        ranked.sort {
            if $0.score == $1.score {
                return $0.sourceIndex < $1.sourceIndex
            }
            return $0.score > $1.score
        }
        ranked = deduplicated(ranked)
        ranked = allocateDiscovery(
            ranked,
            ratio: weights.discoveryRatio,
            limit: limit
        )
        guard !Task.isCancelled else { return [] }
        let result = diversityReranked(
            ranked,
            limit: limit,
            purpose: purpose,
            lane: ArtistPersonaResolver.dominantLane(from: behavior.recentSongs)
        ).map(\.song)
        guard !Task.isCancelled else { return [] }
        cache.insert(result, for: key, now: date)
        return result
    }

    static func invalidateCache() {
        cache.removeAll()
    }

    private static func scoringPlan(
        weights: RecommendationWeights,
        preset: RecommendationPreset,
        coldStart: Bool,
        hasLastFM: Bool = true,
        hasListenBrainz: Bool = true
    ) -> RecommendationScoringPlan {
        var userWeights: [RecommendationFeature: Double] = [
            .history: weights.history,
            .favorites: weights.favorites,
            .server: weights.serverSimilarity,
            .discovery: weights.discovery,
            .lastFM: hasLastFM ? weights.lastFM : 0,
            .listenBrainz: hasListenBrainz ? weights.listenBrainz : 0,
            .behavior: weights.behavior,
            .completion: weights.completion,
            .repeatListening: weights.repeatListening,
            .recency: weights.recency,
            .context: weights.context,
            .localMetadata: weights.localMetadata,
            .playlistAffinity: weights.playlistAffinity,
            .albumCompletion: weights.albumCompletion,
            .forgottenFavorites: weights.forgottenFavorites,
            .artistRotation: weights.artistRotation
        ]
        if !hasLastFM && !hasListenBrainz {
            userWeights[.server] = min(1, (userWeights[.server] ?? 0) + 0.16)
            userWeights[.history] = min(1, (userWeights[.history] ?? 0) + 0.10)
            userWeights[.favorites] = min(1, (userWeights[.favorites] ?? 0) + 0.08)
            userWeights[.context] = min(1, (userWeights[.context] ?? 0) + 0.08)
        }
        if coldStart {
            userWeights[.favorites] = max(userWeights[.favorites] ?? 0, 0.95)
            userWeights[.localMetadata] = max(
                userWeights[.localMetadata] ?? 0,
                0.80
            )
            userWeights[.history] = 0.15
            userWeights[.behavior] = 0.15
        }
        var effectiveWeights = Array(
            repeating: 0.0,
            count: RecommendationFeature.allCases.count
        )
        var totalWeight = 0.0
        for feature in RecommendationFeature.allCases {
            guard let presetWeight = preset.featureWeights[feature] else {
                continue
            }
            let weight = presetWeight * (userWeights[feature] ?? 0)
            guard weight > 0 else { continue }
            effectiveWeights[feature.rawValue] = weight
            totalWeight += weight
        }
        return RecommendationScoringPlan(
            weights: effectiveWeights,
            totalWeight: totalWeight
        )
    }

    private static func profile(
        from values: [SongBehavior],
        date: Date,
        appliesDecay: Bool = true
    ) -> RecommendationProfile {
        var result = RecommendationProfile()
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { break }
            let decay = appliesDecay
                ? timeDecay(since: value.lastPlayed, now: date)
                : 1
            addProfileSignals(
                from: value.song,
                strength: max(0.05, behaviorAffinity(value)) * decay,
                to: &result
            )
        }
        normalizeProfile(&result)
        return result
    }

    private static func temporalProfiles(
        from values: [SongBehavior],
        shortCutoff: Date,
        longCutoff: Date,
        date: Date
    ) -> (short: RecommendationProfile, long: RecommendationProfile) {
        var short = RecommendationProfile()
        var long = RecommendationProfile()
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { break }
            guard value.lastPlayed >= longCutoff else { continue }
            let strength = max(0.05, behaviorAffinity(value))
                * timeDecay(since: value.lastPlayed, now: date)
            addProfileSignals(from: value.song, strength: strength, to: &long)
            if value.lastPlayed >= shortCutoff {
                addProfileSignals(from: value.song, strength: strength, to: &short)
            }
        }
        normalizeProfile(&short)
        normalizeProfile(&long)
        return (short, long)
    }

    private static func addProfileSignals(
        from song: Song,
        strength: Double,
        to result: inout RecommendationProfile
    ) {
        let artistKey = RecommendationCandidateMetadata.artistKey(for: song)
        if !artistKey.isEmpty {
            result.artists[artistKey, default: 0] += strength
        }
        for key in RecommendationCandidateMetadata.genreKeys(for: song) {
            result.genres[key, default: 0] += strength
        }
        for key in RecommendationCandidateMetadata.moodKeys(for: song) {
            result.moods[key, default: 0] += strength
        }
    }

    private static func normalizeProfile(_ value: inout RecommendationProfile) {
        normalizeMap(&value.artists)
        normalizeMap(&value.genres)
        normalizeMap(&value.moods)
    }

    private static func normalizeMap(_ values: inout [String: Double]) {
        guard let maximum = values.values.max(), maximum > 0 else { return }
        values = values.mapValues { min(max($0 / maximum, 0), 1) }
    }

    private static func behaviorAffinity(_ value: SongBehavior?) -> Double {
        guard let value else { return 0.5 }
        let positive =
            Double(value.favoriteCount) * 1.0
            + Double(value.playlistAddCount) * 0.9
            + Double(value.manualPlayCount) * 0.6
            + Double(value.searchPlayCount) * 0.15
            + Double(value.albumSelectionCount) * 0.12
            + Double(value.completedCount) * 0.5
            + Double(value.autoplayCount) * 0.15
        let negative =
            Double(value.earlySkipCount) * 0.8
            + Double(value.repeatedSkipCount) * 1.0
            + Double(value.queueRemovalCount) * 0.65
        let positiveNormalized = 1 - exp(-positive / 4)
        let negativeNormalized = 1 - exp(-negative / 3)
        return min(
            max(0.5 + positiveNormalized * 0.5 - negativeNormalized * 0.8, 0),
            1
        )
    }

    private static func completionAffinity(_ completion: Double?) -> Double {
        guard let completion else { return 0.5 }
        return switch completion {
        case ..<0.10: 0
        case ..<0.40: 0.25
        case ..<0.70: 0.50
        case ..<0.90: 0.75
        default: 1
        }
    }

    private static func timeDecay(since date: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        return switch days {
        case ...1: 1.0
        case ...7: interpolate(days, from: 1, to: 7, high: 1.0, low: 0.9)
        case ...30: interpolate(days, from: 7, to: 30, high: 0.9, low: 0.7)
        case ...90: interpolate(days, from: 30, to: 90, high: 0.7, low: 0.5)
        case ...180: interpolate(days, from: 90, to: 180, high: 0.5, low: 0.3)
        case ...365: interpolate(days, from: 180, to: 365, high: 0.3, low: 0.15)
        default: max(0.04, 0.15 * exp(-(days - 365) / 365))
        }
    }

    private static func interpolate(
        _ value: Double,
        from: Double,
        to: Double,
        high: Double,
        low: Double
    ) -> Double {
        guard to > from else { return low }
        let progress = min(max((value - from) / (to - from), 0), 1)
        return high + (low - high) * progress
    }

    private static func localMetadataAffinity(_ song: Song) -> Double {
        var score = 0.20
        if !song.artist.isEmpty { score += 0.18 }
        if !song.album.isEmpty { score += 0.12 }
        if song.genre?.isEmpty == false || song.genres?.isEmpty == false {
            score += 0.16
        }
        if song.bpm != nil { score += 0.10 }
        if song.moods?.isEmpty == false { score += 0.10 }
        if song.musicBrainzId?.isEmpty == false || song.isrc?.isEmpty == false {
            score += 0.14
        }
        return min(score, 1)
    }

    private static func albumCompletionScore(
        song: Song,
        behavior: SongBehavior?,
        playedAlbumCounts: [String: Int],
        albumCandidateCounts: [String: Int]
    ) -> Double {
        guard behavior == nil,
              let albumID = song.albumId,
              let played = playedAlbumCounts[albumID],
              played >= 2 else {
            return 0
        }
        let available = max(played + 1, albumCandidateCounts[albumID] ?? 0)
        return min(0.95, Double(played) / Double(available))
    }

    private static func forgottenFavoriteScore(
        song: Song,
        behavior: SongBehavior?,
        favoriteAffinity: Double,
        now: Date
    ) -> Double {
        guard favoriteAffinity >= 0.55 else { return 0 }
        guard let lastPlayed = behavior?.lastPlayed else { return 0.45 }
        let days = now.timeIntervalSince(lastPlayed) / 86_400
        guard days >= 45 else { return 0 }
        return min(1, (days - 45) / 180)
    }

    private static func artistRotationScore(
        artistKey: String,
        favoriteAffinity: Double,
        recentArtists: Set<String>
    ) -> Double {
        guard favoriteAffinity > 0 else { return 0 }
        return recentArtists.contains(artistKey)
            ? favoriteAffinity * 0.15
            : favoriteAffinity
    }

    private static func metadataConfidence(_ song: Song) -> Double {
        if song.musicBrainzId?.isEmpty == false || song.isrc?.isEmpty == false {
            return 1
        }
        if !song.artist.isEmpty, !song.title.isEmpty { return 0.95 }
        if !canonicalTitle(song.title).isEmpty { return 0.85 }
        return song.title.isEmpty ? 0.20 : 0.40
    }

    private static func sourceConfidence(
        metadata: RecommendationCandidateMetadata,
        signals: RecommendationSourceSignals,
        favoriteGenres: Set<String>
    ) -> Double {
        let lastFM = signals.lastFM > 0
        let listenBrainz = signals.listenBrainz > 0
        if lastFM, listenBrainz {
            if metadata.genreKeys.contains(where: favoriteGenres.contains) {
                return 0.90
            }
            return 0.75
        }
        if lastFM || listenBrainz { return 0.45 }
        if signals.sonic > 0 { return 0.88 }
        if signals.similar > 0 { return 0.80 }
        return 0.62
    }

    private static func historyConfidence(_ value: SongBehavior?) -> Double {
        guard let value else { return 0.48 }
        let evidence = Double(
            value.playCount + value.completionSamples + value.skipCount
        )
        return min(1, 0.50 + log1p(evidence) / log(41) * 0.50)
    }

    private static func negativePreferencePenalty(_ value: SongBehavior?) -> Double {
        guard let value,
              value.earlySkipCount + value.repeatedSkipCount
                + value.queueRemovalCount > 1 else {
            return 0
        }
        let raw =
            Double(value.earlySkipCount) * 0.8
            + Double(value.repeatedSkipCount)
            + Double(value.queueRemovalCount) * 0.65
        return min(1, 1 - exp(-raw / 3))
    }

    private static func allocateDiscovery(
        _ values: [RankedRecommendation],
        ratio: Double,
        limit: Int
    ) -> [RankedRecommendation] {
        let clampedRatio = min(max(ratio, 0), 1)
        let desiredDiscovery = Int(
            (Double(limit) * clampedRatio).rounded()
        )
        var discoveries: [RankedRecommendation] = []
        var known: [RankedRecommendation] = []
        discoveries.reserveCapacity(values.count)
        known.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return [] }
            if value.isDiscovery {
                discoveries.append(value)
            } else {
                known.append(value)
            }
        }
        let newArtistTarget = Int(
            (Double(desiredDiscovery) * 0.40).rounded()
        )
        let hiddenGemTarget = Int(
            (Double(desiredDiscovery) * 0.30).rounded()
        )
        var result = Array(
            discoveries.filter(\.isNewArtist).prefix(newArtistTarget)
        )
        var selectedIDs = Set(result.map { $0.song.id })
        result.append(
            contentsOf: discoveries
                .filter {
                    $0.isHiddenGem && !selectedIDs.contains($0.song.id)
                }
                .prefix(hiddenGemTarget)
        )
        selectedIDs.formUnion(result.map { $0.song.id })
        result.append(
            contentsOf: discoveries
                .filter { !selectedIDs.contains($0.song.id) }
                .prefix(max(0, desiredDiscovery - result.count))
        )
        result.append(
            contentsOf: known.prefix(max(0, limit - result.count))
        )
        if result.count < limit {
            selectedIDs = Set(result.map { $0.song.id })
            result.append(
                contentsOf: values
                    .filter { !selectedIDs.contains($0.song.id) }
                    .prefix(limit - result.count)
            )
        }
        return result.sorted {
            if $0.score == $1.score {
                return $0.sourceIndex < $1.sourceIndex
            }
            return $0.score > $1.score
        }
    }

    private static func diversityReranked(
        _ values: [RankedRecommendation],
        limit: Int,
        purpose: RecommendationPurpose,
        lane: ArtistPersona
    ) -> [RankedRecommendation] {
        // Keep the incoming order as the base (provider rank + score) and
        // only nudge it. Do not forcibly break a natural same-artist run.
        var result: [RankedRecommendation] = []
        var isRemaining = Array(repeating: true, count: values.count)
        var remainingCount = values.count
        let applyGenreSpread = purpose != .daylist && purpose != .autoplay
        let breatherEvery = Int.random(in: 4...5)
        result.reserveCapacity(min(values.count, limit))
        while remainingCount > 0, result.count < limit {
            if Task.isCancelled { return [] }
            let albumStreak = trailingCount(in: result, key: \.albumKey)
            let artistStreak = trailingCount(in: result, key: \.artistKey)
            let lastGenres = Set(result.last?.genreKeys ?? [])
            let wantsBreather = result.count > 0
                && result.count.isMultiple(of: breatherEvery)
                && lane.complementaryGender != nil
            var bestIndex: Int?
            var bestAdjustedScore = -Double.infinity

            let recentWorks = Set(
                result.suffix(5).compactMap { item -> String? in
                    let key = TrackWorkIdentity.workKey(for: item.song)
                    return key.hasPrefix("\u{1e}") || key.hasSuffix("\u{1e}")
                        ? nil
                        : key
                }
            )
            for index in values.indices where isRemaining[index] {
                let value = values[index]
                let workKey = TrackWorkIdentity.workKey(for: value.song)
                let tooCloseToVariant = !workKey.hasPrefix("\u{1e}")
                    && !workKey.hasSuffix("\u{1e}")
                    && recentWorks.contains(workKey)
                if tooCloseToVariant, remainingCount > 1 {
                    continue
                }
                var adjusted = value.score
                if tooCloseToVariant {
                    adjusted *= 0.12
                }
                if value.albumKey == result.last?.albumKey,
                   let album = result.last?.albumKey,
                   !album.isEmpty {
                    adjusted *= albumStreakPenalty(albumStreak)
                }
                if value.artistKey == result.last?.artistKey,
                   !value.artistKey.isEmpty {
                    adjusted *= artistStreakPenalty(
                        artistStreak,
                        needsVentilation: wantsBreather
                    )
                }
                if applyGenreSpread {
                    // Soft only — do not fight a lane that is naturally narrow.
                    let recentGenreHits = result.suffix(6).reduce(0) { count, item in
                        count + (item.genreKeys.contains(where: value.genreKeys.contains) ? 1 : 0)
                    }
                    if recentGenreHits >= 5 { adjusted *= 0.94 }
                }
                if wantsBreather,
                   let opposite = lane.complementaryGender,
                   value.persona.gender == opposite {
                    let sharesMood = !lastGenres.isEmpty
                        && value.genreKeys.contains(where: lastGenres.contains)
                    adjusted *= sharesMood ? 1.12 : 1.05
                }

                // Stay close to the incoming provider/score order unless
                // another candidate is clearly better.
                let preferEarlier = bestIndex.map { index < $0 } == true
                    && adjusted >= bestAdjustedScore * 0.94
                if bestIndex == nil
                    || adjusted > bestAdjustedScore * 1.06
                    || preferEarlier {
                    bestAdjustedScore = adjusted
                    bestIndex = index
                }
            }

            guard let chosen = bestIndex else { break }
            isRemaining[chosen] = false
            remainingCount -= 1
            result.append(values[chosen])
        }
        return result
    }

    private static func trailingCount(
        in values: [RankedRecommendation],
        key: KeyPath<RankedRecommendation, String>
    ) -> Int {
        guard let last = values.last else { return 0 }
        let needle = last[keyPath: key]
        guard !needle.isEmpty else { return 0 }
        var count = 0
        for item in values.reversed() {
            guard item[keyPath: key] == needle else { break }
            count += 1
        }
        return count
    }

    private static func albumStreakPenalty(_ streak: Int) -> Double {
        // One consecutive album track is fine. 2, 3, 4… fade.
        switch streak {
        case 0, 1: 1.0
        case 2: 0.86
        case 3: 0.70
        default: 0.52
        }
    }

    private static func artistStreakPenalty(
        _ streak: Int,
        needsVentilation: Bool
    ) -> Double {
        // A short same-artist run can stay. Only ease off after ~4,
        // and only push harder when a breather is due.
        switch streak {
        case 0, 1, 2, 3:
            needsVentilation ? 0.90 : 1.0
        case 4:
            needsVentilation ? 0.72 : 0.88
        default:
            needsVentilation ? 0.55 : 0.78
        }
    }

    private static func deduplicated(
        _ values: [RankedRecommendation]
    ) -> [RankedRecommendation] {
        // Taylor's Version replaces the original. Acoustic / deluxe / remake
        // siblings stay in the pool and are spaced later in placement.
        var chosen: [String: Int] = [:]
        var result: [RankedRecommendation] = []
        result.reserveCapacity(values.count)
        for value in values {
            let key = workDeduplicationKey(for: value.song)
            if let index = chosen[key] {
                let existing = result[index].song
                let incomingIsTV = TrackWorkIdentity.editionRank(for: value.song) >= 3
                let existingIsTV = TrackWorkIdentity.editionRank(for: existing) >= 3
                if incomingIsTV || existingIsTV {
                    if TrackWorkIdentity.prefers(value.song, over: existing) {
                        result[index] = value
                    }
                    continue
                }
                result.append(value)
                continue
            }
            chosen[key] = result.count
            result.append(value)
        }
        return result
    }

    fileprivate static func workDeduplicationKey(for song: Song) -> String {
        let key = TrackWorkIdentity.workKey(for: song)
        if key.hasPrefix("\u{1e}") || key.hasSuffix("\u{1e}") {
            return "id:\(song.id)"
        }
        return key
    }

    fileprivate static func deduplicationKey(for song: Song) -> String {
        workDeduplicationKey(for: song)
    }

    private static func canonicalTitle(_ value: String) -> String {
        let folded = normalized(value)
        let patterns = [
            #"\s*[\(\[].*?\b(remaster(?:ed)?|deluxe|live|version|edit|mix)\b.*?[\)\]]"#,
            #"\s+-\s+(remaster(?:ed)?|deluxe|live|version|edit|mix).*$"#
        ]
        return patterns.reduce(folded) { current, pattern in
            current.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @inline(__always)
    private static func consensusScore(
        _ a: Double,
        _ b: Double,
        _ c: Double,
        _ d: Double,
        _ e: Double
    ) -> Double {
        var first = 0.0
        var second = 0.0
        var third = 0.0
        func include(_ score: Double) {
            if score > first {
                third = second
                second = first
                first = score
            } else if score > second {
                third = second
                second = score
            } else if score > third {
                third = score
            }
        }
        include(a)
        include(b)
        include(c)
        include(d)
        include(e)
        return min(1, first + second * 0.18 + third * 0.08)
    }

    private static func unique(_ values: [Song]) -> [Song] {
        MediaIdentity.uniqueSongs(values)
    }

    fileprivate static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stableJitter(_ value: String, seed: Int) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        hash ^= UInt64(bitPattern: Int64(seed))
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return (Double(hash % 1_001) / 1_000 - 0.5) * 0.024
    }

    private static func cacheLifetime(
        for purpose: RecommendationPurpose
    ) -> TimeInterval {
        switch purpose {
        case .artistMix: 6 * 3_600
        case .discovery: 24 * 3_600
        default: 30 * 60
        }
    }

    private static func temporalBucket(
        for purpose: RecommendationPurpose,
        date: Date
    ) -> Int {
        Int(floor(date.timeIntervalSince1970 / cacheLifetime(for: purpose)))
    }

    private static func temporalEvaluationDate(
        for purpose: RecommendationPurpose,
        date: Date
    ) -> Date {
        Date(
            timeIntervalSince1970: Double(temporalBucket(for: purpose, date: date))
                * cacheLifetime(for: purpose)
        )
    }

    private static func cacheKey(
        snapshot: HomeSnapshot,
        snapshotRevision: HomeSnapshotRevision?,
        weights: RecommendationWeights,
        purpose: RecommendationPurpose,
        behavior: RecommendationBehaviorSnapshot,
        seed: Song?,
        limit: Int,
        date: Date
    ) -> String? {
        let snapshotIdentity: String
        if let snapshotRevision {
            snapshotIdentity = [
                snapshotRevision.epoch.uuidString,
                String(snapshotRevision.generation)
            ].joined(separator: ":")
        } else {
            let sources = [
                snapshot.sonicRecommendedSongs,
                snapshot.similarArtistSongs,
                snapshot.genreRecommendedSongs,
                snapshot.topArtistSongs,
                snapshot.recentlyAddedSongs,
                snapshot.popularSongs,
                snapshot.playlistAffinitySongs,
                snapshot.lastFMRecommendedSongs,
                snapshot.listenBrainzRecommendedSongs,
                snapshot.randomSongs,
                snapshot.mostPlayedSongs,
                snapshot.starredSongs
            ]
            var snapshotFingerprint = StableFingerprint()
            for (sourceIndex, source) in sources.enumerated() {
                if sourceIndex.isMultiple(of: 4), Task.isCancelled { return nil }
                snapshotFingerprint.append(sourceIndex)
                snapshotFingerprint.append(source.count)
                for (songIndex, song) in source.enumerated() {
                    if songIndex.isMultiple(of: 64), Task.isCancelled { return nil }
                    append(song, to: &snapshotFingerprint)
                }
            }
            snapshotIdentity = String(snapshotFingerprint.value)
        }

        let behaviorIdentity: String
        if snapshotRevision != nil {
            // ListeningHistoryStore owns a process-monotonic revision. Calls
            // that also carry a HomeSnapshotRevision therefore need no second
            // O(n) traversal of the captured behavior dictionary.
            behaviorIdentity = String(behavior.revision)
        } else {
            var behaviorFingerprint = StableFingerprint()
            behaviorFingerprint.append(behavior.revision)
            let behaviorKeys = behavior.songs.keys.sorted()
            behaviorFingerprint.append(behaviorKeys.count)
            for (index, key) in behaviorKeys.enumerated() {
                if index.isMultiple(of: 32), Task.isCancelled { return nil }
                behaviorFingerprint.append(key)
                if let value = behavior.songs[key] {
                    append(value, to: &behaviorFingerprint)
                }
            }
            behaviorFingerprint.append(behavior.recentSongs.count)
            for (index, song) in behavior.recentSongs.enumerated() {
                if index.isMultiple(of: 64), Task.isCancelled { return nil }
                append(song, to: &behaviorFingerprint)
            }
            behaviorIdentity = String(behaviorFingerprint.value)
        }

        var weightsFingerprint = StableFingerprint()
        let weightValues = [
            weights.history, weights.favorites, weights.serverSimilarity,
            weights.discovery, weights.lastFM, weights.listenBrainz,
            weights.behavior, weights.completion, weights.repeatListening,
            weights.recency, weights.context, weights.localMetadata,
            weights.playlistAffinity, weights.albumCompletion,
            weights.forgottenFavorites, weights.artistRotation,
            weights.timeAwareness, weights.discoveryRatio
        ]
        for value in weightValues { weightsFingerprint.append(value) }
        let calendar = Calendar.current
        return [
            purpose.rawValue,
            String(limit),
            snapshotIdentity,
            behaviorIdentity,
            seed?.id ?? "",
            String(weightsFingerprint.value),
            String(temporalBucket(for: purpose, date: date)),
            String(describing: calendar.identifier),
            calendar.timeZone.identifier
        ].joined(separator: "|")
    }

    private static func append(
        _ song: Song,
        to fingerprint: inout StableFingerprint
    ) {
        fingerprint.append(song.id)
        fingerprint.append(song.title)
        fingerprint.append(song.artist)
        fingerprint.append(song.album)
        fingerprint.append(song.artistId)
        fingerprint.append(song.albumId)
        fingerprint.append(song.coverArt)
        fingerprint.append(song.duration)
        fingerprint.append(song.track)
        fingerprint.append(song.suffix)
        fingerprint.append(song.contentType)
        fingerprint.append(song.starred)
        fingerprint.append(song.playCount)
        fingerprint.append(song.played)
        fingerprint.append(song.genre)
        append(song.genres?.map(\.name), to: &fingerprint)
        fingerprint.append(song.musicBrainzId)
        append(song.isrc, to: &fingerprint)
        fingerprint.append(song.bpm)
        append(song.moods, to: &fingerprint)
        fingerprint.append(song.created)
        fingerprint.append(song.externalStreamURL)
    }

    private static func append(
        _ behavior: SongBehavior,
        to fingerprint: inout StableFingerprint
    ) {
        append(behavior.song, to: &fingerprint)
        fingerprint.append(behavior.playCount)
        fingerprint.append(behavior.firstPlayed.timeIntervalSince1970)
        fingerprint.append(behavior.lastPlayed.timeIntervalSince1970)
        fingerprint.append(behavior.completedCount)
        fingerprint.append(behavior.skipCount)
        fingerprint.append(behavior.earlySkipCount)
        fingerprint.append(behavior.repeatedSkipCount)
        fingerprint.append(behavior.repeatCount)
        fingerprint.append(behavior.manualPlayCount)
        fingerprint.append(behavior.searchPlayCount)
        fingerprint.append(behavior.albumSelectionCount)
        fingerprint.append(behavior.playlistPlayCount)
        fingerprint.append(behavior.autoplayCount)
        fingerprint.append(behavior.queueRemovalCount)
        fingerprint.append(behavior.playlistAddCount)
        fingerprint.append(behavior.favoriteCount)
        fingerprint.append(behavior.totalCompletion)
        fingerprint.append(behavior.completionSamples)
        fingerprint.append(behavior.consecutiveSkips)
    }

    private static func append(
        _ values: [String]?,
        to fingerprint: inout StableFingerprint
    ) {
        guard let values else {
            fingerprint.append(UInt64.max)
            return
        }
        fingerprint.append(values.count)
        for value in values { fingerprint.append(value) }
    }
}

enum DaylistBuilder {
    static func make(
        snapshot: HomeSnapshot,
        date: Date = Date(),
        calendar: Calendar = .current,
        limit: Int = 24
    ) -> [Song] {
        let hour = calendar.component(.hour, from: date)
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 0
        let period: Int
        let familiarSlots: Int
        switch hour {
        case 5..<12:
            period = 0
            familiarSlots = 2
        case 12..<19:
            period = 1
            familiarSlots = 1
        default:
            period = 2
            familiarSlots = 3
        }
        let seed = day * 3 + period
        let familiar = ordered(
            unique(
                snapshot.mostPlayedSongs +
                snapshot.starredSongs +
                snapshot.recentlyPlayedAlbums.flatMap { album in
                    snapshot.recommendedSongs.filter { $0.albumId == album.id }
                }
            ),
            seed: seed
        )
        let discovery = ordered(
            unique(
                snapshot.serverRecommendedSongs +
                snapshot.lastFMRecommendedSongs +
                snapshot.listenBrainzRecommendedSongs +
                snapshot.randomSongs +
                snapshot.recommendedSongs
            ),
            seed: seed + 17
        )

        var result: [Song] = []
        var ids = Set<String>()
        var artistCounts: [String: Int] = [:]
        var familiarIndex = 0
        var discoveryIndex = 0
        while result.count < limit &&
                (familiarIndex < familiar.count ||
                    discoveryIndex < discovery.count) {
            for slot in 0..<4 where result.count < limit {
                let prefersFamiliar = slot < familiarSlots
                let candidate: Song?
                if prefersFamiliar, familiarIndex < familiar.count {
                    candidate = familiar[familiarIndex]
                    familiarIndex += 1
                } else if discoveryIndex < discovery.count {
                    candidate = discovery[discoveryIndex]
                    discoveryIndex += 1
                } else if familiarIndex < familiar.count {
                    candidate = familiar[familiarIndex]
                    familiarIndex += 1
                } else {
                    candidate = nil
                }
                guard let candidate, ids.insert(candidate.id).inserted else {
                    continue
                }
                let artist = normalized(candidate.artist)
                guard (artistCounts[artist] ?? 0) < 2 else { continue }
                artistCounts[artist, default: 0] += 1
                result.append(candidate)
            }
        }
        if result.count < limit {
            for song in unique(familiar + discovery)
                where result.count < limit && ids.insert(song.id).inserted {
                result.append(song)
            }
        }
        return result
    }

    private static func ordered(_ songs: [Song], seed: Int) -> [Song] {
        let hashed: [(index: Int, song: Song, hash: UInt64)] =
            songs.enumerated().map { index, song in
                (
                    index: index,
                    song: song,
                    hash: stableHash(song.id, seed: seed)
                )
            }
        let ordered = hashed.sorted { lhs, rhs in
            lhs.hash == rhs.hash
                ? lhs.index < rhs.index
                : lhs.hash < rhs.hash
        }
        return ordered.map(\.song)
    }

    private static func unique(_ songs: [Song]) -> [Song] {
        MediaIdentity.uniqueSongs(songs)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stableHash(_ value: String, seed: Int) -> UInt64 {
        var hash = UInt64(bitPattern: Int64(seed)) ^ 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

struct PersonalizedMix: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case daylist
        case repeatListening
        case listenAgain
        case genre
        case artist
        case mood
        case favorites
        case ranking
    }

    let id: String
    let title: String
    let subtitle: String
    let songs: [Song]
    let kind: Kind
    var artworkCoverArt: String? = nil

    var showsRanking: Bool { kind == .ranking }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.kind == rhs.kind
            && lhs.artworkCoverArt == rhs.artworkCoverArt
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(subtitle)
        hasher.combine(kind)
        hasher.combine(artworkCoverArt)
    }
}

enum ArtistMixPreferences {
    static let storageKey = "artist-mix-selected-artists-v1"
    static let maximumCount = 4

    static func decode(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let artists = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        var seen = Set<String>()
        return artists.filter {
            let key = normalized($0)
            return !key.isEmpty && seen.insert(key).inserted
        }
        .prefix(maximumCount)
        .map { $0 }
    }

    static func adding(_ artist: String, to value: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return value }
        let key = normalized(trimmed)
        let artists = [trimmed] + decode(value).filter {
            normalized($0) != key
        }
        let result = Array(artists.prefix(maximumCount))
        guard let data = try? JSONEncoder().encode(result),
              let encoded = String(data: data, encoding: .utf8) else {
            return value
        }
        return encoded
    }

    static func contains(_ artist: String, in value: String) -> Bool {
        let key = normalized(artist)
        return decode(value).contains { normalized($0) == key }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum PersonalizedSnapshotCacheKey: Equatable {
    case revision(HomeSnapshotRevision)
    case snapshot(HomeSnapshot)
}

private struct PersonalizedMixCacheKey: Equatable {
    let snapshot: PersonalizedSnapshotCacheKey
    let year: Int
    let day: Int
    let period: String
    let calendarIdentifier: String
    let timeZoneIdentifier: String
    let localeIdentifier: String
    let songLimit: Int
    let selectedArtists: [String]
}

private final class PersonalizedMixResultCache: @unchecked Sendable {
    private let lock = NSLock()
    private var key: PersonalizedMixCacheKey?
    private var mixes: [PersonalizedMix] = []
    private var corpusKey: PersonalizedSnapshotCacheKey?
    private var corpus: PersonalizedSongCorpus?

    func value(for requestedKey: PersonalizedMixCacheKey) -> [PersonalizedMix]? {
        lock.lock()
        defer { lock.unlock() }
        return key == requestedKey ? mixes : nil
    }

    func insert(_ value: [PersonalizedMix], for newKey: PersonalizedMixCacheKey) {
        lock.lock()
        key = newKey
        mixes = value
        lock.unlock()
    }

    func corpus(for requestedKey: PersonalizedSnapshotCacheKey) -> PersonalizedSongCorpus? {
        lock.lock()
        defer { lock.unlock() }
        return corpusKey == requestedKey ? corpus : nil
    }

    func insert(_ value: PersonalizedSongCorpus, for newKey: PersonalizedSnapshotCacheKey) {
        lock.lock()
        corpusKey = newKey
        corpus = value
        lock.unlock()
    }
}

private struct PersonalizedSongCorpus {
    let pool: [Song]
    let canonicalSongs: [String: Song]
    let searchableTexts: [String: String]
    let normalizedArtists: [String: String]
    let normalizedGenres: [String: [String]]
    let songsByArtist: [String: [Song]]
    let songsByGenre: [String: [Song]]
    let songsWithoutGenre: [Song]

    init(snapshot: HomeSnapshot) {
        let resolvedPool = PersonalizedMixBuilder.unique(
            snapshot.serverRecommendedSongs
                + snapshot.lastFMRecommendedSongs
                + snapshot.listenBrainzRecommendedSongs
                + snapshot.randomSongs
                + snapshot.recommendedSongs
                + snapshot.daylistSongs
                + snapshot.starredSongs
                + snapshot.mostPlayedSongs
        )
        pool = resolvedPool
        canonicalSongs = Dictionary(
            uniqueKeysWithValues: resolvedPool.map { ($0.id, $0) }
        )
        var searchableTexts: [String: String] = [:]
        var normalizedArtists: [String: String] = [:]
        var normalizedGenres: [String: [String]] = [:]
        var songsByArtist: [String: [Song]] = [:]
        var songsByGenre: [String: [Song]] = [:]
        var songsWithoutGenre: [Song] = []
        searchableTexts.reserveCapacity(pool.count)
        normalizedArtists.reserveCapacity(pool.count)
        normalizedGenres.reserveCapacity(pool.count)
        for (index, song) in pool.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { break }
            let artist = PersonalizedMixBuilder.normalized(song.artist)
            searchableTexts[song.id] = PersonalizedMixBuilder.searchableText(song)
            normalizedArtists[song.id] = artist
            songsByArtist[artist, default: []].append(song)
            let genreKeys = RecommendationCandidateMetadata.genreKeys(for: song)
            if genreKeys.isEmpty {
                songsWithoutGenre.append(song)
            } else {
                normalizedGenres[song.id] = genreKeys
                for genreKey in genreKeys {
                    songsByGenre[genreKey, default: []].append(song)
                }
            }
        }
        self.searchableTexts = searchableTexts
        self.normalizedArtists = normalizedArtists
        self.normalizedGenres = normalizedGenres
        self.songsByArtist = songsByArtist
        self.songsByGenre = songsByGenre
        self.songsWithoutGenre = songsWithoutGenre
    }
}

private struct StableOrderedSong {
    let index: Int
    let song: Song
    let hash: UInt64
}

enum PersonalizedMixBuilder {
    private static let cache = PersonalizedMixResultCache()

    static func make(
        snapshot: HomeSnapshot,
        snapshotRevision: HomeSnapshotRevision? = nil,
        date: Date = Date(),
        calendar: Calendar = .current,
        songLimit: Int = 32,
        selectedArtists: [String] = []
    ) -> [PersonalizedMix] {
        guard songLimit > 0 else { return [] }
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 0
        let year = calendar.component(.year, from: date)
        let period = dayPeriod(date, calendar: calendar)
        let snapshotKey = snapshotRevision.map(PersonalizedSnapshotCacheKey.revision)
            ?? .snapshot(snapshot)
        let cacheKey = PersonalizedMixCacheKey(
            snapshot: snapshotKey,
            year: year,
            day: day,
            period: period.id,
            calendarIdentifier: String(describing: calendar.identifier),
            timeZoneIdentifier: calendar.timeZone.identifier,
            localeIdentifier: Locale.current.identifier,
            songLimit: songLimit,
            selectedArtists: selectedArtists
        )
        if let cached = cache.value(for: cacheKey) { return cached }

        guard !Task.isCancelled else { return [] }
        let corpus: PersonalizedSongCorpus
        if let cached = cache.corpus(for: snapshotKey) {
            corpus = cached
        } else {
            let built = PersonalizedSongCorpus(snapshot: snapshot)
            guard !Task.isCancelled else { return [] }
            cache.insert(built, for: snapshotKey)
            corpus = built
        }
        guard !Task.isCancelled else { return [] }
        let pool = corpus.pool
        guard !pool.isEmpty else { return [] }
        let searchableTexts = corpus.searchableTexts
        func canonicalized(_ songs: [Song]) -> [Song] {
            songs.map { corpus.canonicalSongs[$0.id] ?? $0 }
        }

        let dailySeed = year * 1_000 + day
        let daylist = filled(
            preferred: canonicalized(
                DaylistBuilder.make(
                    snapshot: snapshot,
                    date: date,
                    calendar: calendar,
                    limit: songLimit
                )
            ),
            from: pool,
            seed: dailySeed,
            limit: songLimit
        )

        let repeatSongs = filled(
            preferred: canonicalized(
                snapshot.mostPlayedSongs + snapshot.starredSongs
            ),
            from: pool,
            seed: dailySeed + 11,
            limit: songLimit
        )
        let recentlyPlayed = pool.filter { $0.played != nil }.sorted {
            ($0.played ?? "") > ($1.played ?? "")
        }
        let listenAgain = filled(
            preferred: canonicalized(
                recentlyPlayed + snapshot.mostPlayedSongs
            ),
            from: pool,
            seed: dailySeed + 23,
            limit: songLimit
        )

        let kPopTokens = normalizedTokens(
            ["k-pop", "kpop", "korean pop", "케이팝"]
        )
        let popTokens = normalizedTokens(["pop", "팝"])
        let kPopMatches = pool.filter { song in
            containsAny(
                searchableTexts[song.id] ?? "",
                normalizedTokens: kPopTokens
            )
        }
        let kPopIDs = Set(kPopMatches.map(\.id))
        let popMatches = pool.filter { song in
            containsAny(
                searchableTexts[song.id] ?? "",
                normalizedTokens: popTokens
            ) && !kPopIDs.contains(song.id)
        }
        let affinityCandidates = highestAffinityArtists(
            in: snapshot,
            fallbackPool: pool,
            limit: 12
        )
        let customArtists = Array(
            selectedArtists.prefix(ArtistMixPreferences.maximumCount)
        )
        let customArtistKeys = Set(customArtists.map(normalized))
        var defaultArtists = affinityCandidates.filter {
            !customArtistKeys.contains(normalized($0))
        }
        if let taylorSwift = affinityCandidates.first(where: {
            normalized($0) == "taylor swift"
        }) {
            defaultArtists.removeAll {
                normalized($0) == "taylor swift"
            }
            defaultArtists.insert(taylorSwift, at: 0)
        }
        defaultArtists = Array(defaultArtists.prefix(6))
        let artistArtwork = (
            snapshot.starredArtists + snapshot.artists +
            snapshot.recommendedArtists
        ).reduce(into: [String: String]()) { result, artist in
            let key = normalized(artist.name)
            if result[key] == nil, let coverArt = artist.coverArt {
                result[key] = coverArt
            }
        }

        var mixes: [PersonalizedMix] = [
            PersonalizedMix(
                id: "daylist-\(dailySeed)-\(period.id)",
                title: daylistTitle(date, calendar: calendar),
                subtitle: period.subtitle,
                songs: daylist,
                kind: .daylist
            ),
            PersonalizedMix(
                id: "repeat-listening-\(dailySeed)",
                title: String(localized: "반복 듣기"),
                subtitle: String(localized: "자주 찾는 곡을 한데 모았어요"),
                songs: repeatSongs,
                kind: .repeatListening
            ),
            PersonalizedMix(
                id: "listen-again-\(dailySeed)",
                title: String(localized: "한 번 더 듣기"),
                subtitle: String(localized: "최근 취향을 다시 이어 들어보세요"),
                songs: listenAgain,
                kind: .listenAgain
            ),
            PersonalizedMix(
                id: "pop-mix-\(dailySeed)",
                title: "Pop Mix",
                subtitle: String(localized: "취향에 맞춘 팝 중심 믹스"),
                songs: filled(
                    preferred: popMatches,
                    from: pool,
                    seed: dailySeed + 37,
                    limit: songLimit
                ),
                kind: .genre
            ),
            PersonalizedMix(
                id: "k-pop-mix-\(dailySeed)",
                title: "K-Pop Mix",
                subtitle: String(localized: "즐겨 듣는 K-Pop과 비슷한 곡"),
                songs: filled(
                    preferred: kPopMatches,
                    from: pool,
                    seed: dailySeed + 41,
                    limit: songLimit
                ),
                kind: .genre
            )
        ]

        for (index, artist) in (defaultArtists + customArtists).enumerated() {
            if Task.isCancelled { return [] }
            mixes.append(
                artistMix(
                    artist: artist,
                    corpus: corpus,
                    seed: dailySeed + 53 + index * 7,
                    limit: songLimit,
                    artworkCoverArt: artistArtwork[normalized(artist)]
                )
            )
        }

        mixes.append(contentsOf: [
            moodMix(
                id: "happy-mix-\(dailySeed)",
                title: "Happy Mix",
                subtitle: String(localized: "기분을 환하게 만드는 음악"),
                tokens: ["happy", "smile", "joy", "summer", "disco", "funk", "행복", "여름"],
                pool: pool,
                searchableTexts: searchableTexts,
                seed: dailySeed + 61,
                limit: songLimit
            ),
            moodMix(
                id: "upbeat-mix-\(dailySeed)",
                title: "Upbeat Mix",
                subtitle: String(localized: "에너지가 필요한 순간을 위한 음악"),
                tokens: ["dance", "edm", "electronic", "rock", "hip hop", "upbeat", "댄스"],
                pool: pool,
                searchableTexts: searchableTexts,
                seed: dailySeed + 67,
                limit: songLimit
            ),
            moodMix(
                id: "love-mix-\(dailySeed)",
                title: "Love Mix",
                subtitle: String(localized: "사랑과 설렘을 담은 음악"),
                tokens: ["love", "romantic", "romance", "r&b", "soul", "ballad", "사랑"],
                pool: pool,
                searchableTexts: searchableTexts,
                seed: dailySeed + 71,
                limit: songLimit
            ),
            moodMix(
                id: "chill-mix-\(dailySeed)",
                title: "Chill Mix",
                subtitle: String(localized: "편안하게 흐르는 차분한 음악"),
                tokens: ["chill", "ambient", "acoustic", "jazz", "lo-fi", "indie", "잔잔"],
                pool: pool,
                searchableTexts: searchableTexts,
                seed: dailySeed + 79,
                limit: songLimit
            )
        ])

        guard !Task.isCancelled else { return [] }
        let result = mixes.filter { !$0.songs.isEmpty }
        cache.insert(result, for: cacheKey)
        return result
    }

    static func favoriteSongs(_ songs: [Song]) -> PersonalizedMix {
        PersonalizedMix(
            id: "favorite-songs",
            title: String(localized: "좋아요 표시한 곡"),
            subtitle: String(
                format: String(localized: "%d곡"),
                songs.count
            ),
            songs: songs,
            kind: .favorites
        )
    }

    static func mostPlayedSongs(_ songs: [Song]) -> PersonalizedMix {
        PersonalizedMix(
            id: "most-played-ranking",
            title: String(localized: "자주 들은 곡"),
            subtitle: String(localized: "서버와 청취 기록을 반영한 순위"),
            songs: songs,
            kind: .ranking
        )
    }

    private static func artistMix(
        artist: String,
        corpus: PersonalizedSongCorpus,
        seed: Int,
        limit: Int,
        artworkCoverArt: String?
    ) -> PersonalizedMix {
        let normalizedArtist = normalized(artist)
        let primary = orderedPrefix(
            corpus.songsByArtist[normalizedArtist] ?? [],
            seed: seed,
            limit: limit
        )
        let primaryGenres = Set(primary.flatMap {
            corpus.normalizedGenres[$0.id] ?? []
        })
        let relatedPool = primaryGenres.sorted().flatMap {
            corpus.songsByGenre[$0] ?? []
        } + corpus.songsWithoutGenre
        let related = orderedPrefix(
            relatedPool.filter { song in
                corpus.normalizedArtists[song.id] != normalizedArtist
            },
            seed: seed + 7,
            limit: limit
        )

        var songs: [Song] = []
        var primaryIndex = 0
        var relatedIndex = 0
        while songs.count < limit &&
                (primaryIndex < primary.count || relatedIndex < related.count) {
            for _ in 0..<3 where primaryIndex < primary.count && songs.count < limit {
                songs.append(primary[primaryIndex])
                primaryIndex += 1
            }
            for _ in 0..<2 where relatedIndex < related.count && songs.count < limit {
                songs.append(related[relatedIndex])
                relatedIndex += 1
            }
        }
        songs = filled(
            preferred: songs,
            from: primary + related + corpus.pool,
            seed: seed,
            limit: limit
        )
        return PersonalizedMix(
            id: "artist-\(stableHash(artist, seed: seed))",
            title: "\(artist) Mix",
            subtitle: "Featuring \(artist) and similar artists",
            songs: songs,
            kind: .artist,
            artworkCoverArt: artworkCoverArt ?? primary.first?.coverArt
        )
    }

    private static func moodMix(
        id: String,
        title: String,
        subtitle: String,
        tokens: [String],
        pool: [Song],
        searchableTexts: [String: String],
        seed: Int,
        limit: Int
    ) -> PersonalizedMix {
        let tokens = normalizedTokens(tokens)
        let matches = pool.filter { song in
            containsAny(
                searchableTexts[song.id] ?? "",
                normalizedTokens: tokens
            )
        }
        return PersonalizedMix(
            id: id,
            title: title,
            subtitle: subtitle,
            songs: filled(
                preferred: matches,
                from: pool,
                seed: seed,
                limit: limit
            ),
            kind: .mood
        )
    }

    private static func highestAffinityArtists(
        in snapshot: HomeSnapshot,
        fallbackPool: [Song],
        limit: Int
    ) -> [String] {
        var scores: [String: Int] = [:]
        var displayNames: [String: String] = [:]
        func score(_ songs: [Song], value: Int) {
            for song in songs where !song.artist.isEmpty {
                let key = normalized(song.artist)
                scores[key, default: 0] += value
                displayNames[key] = song.artist
            }
        }
        score(snapshot.mostPlayedSongs, value: 4)
        score(snapshot.starredSongs, value: 3)
        score(snapshot.recommendedSongs, value: 1)
        for artist in snapshot.starredArtists where !artist.name.isEmpty {
            let key = normalized(artist.name)
            scores[key, default: 0] += 5
            displayNames[key] = artist.name
        }
        let orderedKeys = scores.keys.sorted(by: {
            let left = scores[$0, default: 0]
            let right = scores[$1, default: 0]
            return left == right ? $0 < $1 : left > right
        })

        var result: [String] = []
        var seen = Set<String>()
        for key in orderedKeys {
            guard let name = displayNames[key],
                  seen.insert(key).inserted else {
                continue
            }
            result.append(name)
            if result.count == limit { return result }
        }
        for song in fallbackPool where !song.artist.isEmpty {
            let key = normalized(song.artist)
            guard seen.insert(key).inserted else { continue }
            result.append(song.artist)
            if result.count == limit { break }
        }
        return result
    }

    private static func filled(
        preferred: [Song],
        from pool: [Song],
        seed: Int,
        limit: Int
    ) -> [Song] {
        let fallbackLimit = limit > Int.max / 2 ? Int.max : limit * 2
        return Array(
            unique(
                orderedPrefix(preferred, seed: seed, limit: limit) +
                orderedPrefix(pool, seed: seed + 97, limit: fallbackLimit)
            )
            .prefix(limit)
        )
    }

    private static func orderedPrefix(
        _ songs: [Song],
        seed: Int,
        limit: Int
    ) -> [Song] {
        guard limit > 0 else { return [] }
        let values = unique(songs)
        guard !Task.isCancelled else { return [] }
        var heap: [StableOrderedSong] = []
        heap.reserveCapacity(min(values.count, limit))
        for (index, song) in values.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return [] }
            let candidate = StableOrderedSong(
                index: index,
                song: song,
                hash: stableHash(song.id, seed: seed)
            )
            if heap.count < limit {
                heap.append(candidate)
                siftUpLatest(&heap, from: heap.count - 1)
            } else if let latest = heap.first,
                      isEarlier(candidate, than: latest) {
                heap[0] = candidate
                siftDownLatest(&heap, from: 0)
            }
        }
        return heap.sorted {
            isEarlier($0, than: $1)
        }
        .map(\.song)
    }

    private static func isEarlier(
        _ lhs: StableOrderedSong,
        than rhs: StableOrderedSong
    ) -> Bool {
        lhs.hash == rhs.hash ? lhs.index < rhs.index : lhs.hash < rhs.hash
    }

    private static func siftUpLatest(
        _ heap: inout [StableOrderedSong],
        from startIndex: Int
    ) {
        var child = startIndex
        while child > 0 {
            let parent = (child - 1) / 2
            guard isEarlier(heap[parent], than: heap[child]) else { return }
            heap.swapAt(parent, child)
            child = parent
        }
    }

    private static func siftDownLatest(
        _ heap: inout [StableOrderedSong],
        from startIndex: Int
    ) {
        var parent = startIndex
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { return }
            let right = left + 1
            var latest = left
            if right < heap.count, isEarlier(heap[left], than: heap[right]) {
                latest = right
            }
            guard isEarlier(heap[parent], than: heap[latest]) else { return }
            heap.swapAt(parent, latest)
            parent = latest
        }
    }

    fileprivate static func unique(_ songs: [Song]) -> [Song] {
        MediaIdentity.uniqueSongs(songs)
    }

    static func searchableText(_ song: Song) -> String {
        normalized(
            (
                [song.genre, song.title, song.album, song.artist].compactMap { $0 }
                + (song.genres ?? []).map(\.name)
                + (song.moods ?? [])
            ).joined(separator: " ")
        )
    }

    private static func normalizedTokens(_ values: [String]) -> [String] {
        values.map(normalized)
    }

    private static func containsAny(
        _ value: String,
        normalizedTokens: [String]
    ) -> Bool {
        normalizedTokens.contains { value.contains($0) }
    }

    fileprivate static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stableHash(_ value: String, seed: Int) -> UInt64 {
        var hash = UInt64(bitPattern: Int64(seed)) ^ 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func daylistTitle(
        _ date: Date,
        calendar: Calendar
    ) -> String {
        let weekday = date.formatted(.dateTime.weekday(.wide))
        return String(
            format: dayPeriod(date, calendar: calendar).titleFormat,
            weekday
        )
    }

    private static func dayPeriod(
        _ date: Date,
        calendar: Calendar
    ) -> (id: String, titleFormat: String, subtitle: String) {
        switch calendar.component(.hour, from: date) {
        case 5..<12:
            (
                "morning",
                String(localized: "%@ 아침 daylist"),
                String(localized: "가볍게 하루를 시작하는 맞춤 음악")
            )
        case 12..<19:
            (
                "afternoon",
                String(localized: "%@ 오후 daylist"),
                String(localized: "오후의 흐름에 맞춘 익숙함과 발견")
            )
        default:
            (
                "night",
                String(localized: "%@ 밤 daylist"),
                String(localized: "밤에 어울리는 익숙하고 편안한 음악")
            )
        }
    }
}

struct ExternalRecommendationCandidate: Sendable {
    enum Source: Sendable {
        case lastFM
        case listenBrainz
    }

    let title: String
    let artist: String
    let album: String?
    let recordingMBID: String?
    let score: Double
    let source: Source
}

actor ExternalRecommendationClient {
    static let shared = ExternalRecommendationClient()

    private let publicSession: URLSession
    private let privateSession: URLSession
    private let decoder = JSONDecoder()

    private init() {
        let configuration = ModernNetworkPolicy.makeCachedConfiguration(
            requestTimeout: 12,
            resourceTimeout: 24,
            maximumConnectionsPerHost: 2,
            memoryCapacity: 2 * 1_024 * 1_024,
            diskCapacity: 0,
            allowsExpensiveNetworkAccess: true,
            allowsConstrainedNetworkAccess: false
        )
        publicSession = URLSession(
            configuration: configuration,
            delegate: HTTPSOnlyURLSessionDelegate(),
            delegateQueue: nil
        )
        privateSession = URLSession(
            configuration: ModernNetworkPolicy.makeEphemeralConfiguration(
                requestTimeout: 12,
                resourceTimeout: 24,
                maximumConnectionsPerHost: 2,
                allowsExpensiveNetworkAccess: true,
                allowsConstrainedNetworkAccess: false
            ),
            delegate: HTTPSOnlyURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    func lastFM(
        seed: Song,
        apiKey: String,
        limit: Int = 12
    ) async -> [ExternalRecommendationCandidate] {
        guard !apiKey.isEmpty,
              var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "method", value: "track.getSimilar"),
            URLQueryItem(name: "artist", value: seed.artist),
            URLQueryItem(name: "track", value: seed.title),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url,
              let response: LastFMResponse = await decode(
                url: url,
                allowsCaching: false
              ) else {
            return []
        }
        let tracks = response.similartracks?.track ?? []
        var candidates: [ExternalRecommendationCandidate] = []
        candidates.reserveCapacity(tracks.count)
        for item in tracks {
            guard !item.name.isEmpty, !item.artist.name.isEmpty else { continue }
            candidates.append(
                ExternalRecommendationCandidate(
                    title: item.name,
                    artist: item.artist.name,
                    album: nil,
                    recordingMBID: nil,
                    score: Double(item.match) ?? 0.5,
                    source: .lastFM
                )
            )
        }
        await resolveArtistPersonas(
            names: [seed.artist] + candidates.map(\.artist),
            apiKey: apiKey
        )
        return candidates
    }

    func resolveArtistPersonas(names: [String], apiKey: String) async {
        guard !apiKey.isEmpty else { return }
        var seen = Set<String>()
        var pending: [String] = []
        pending.reserveCapacity(8)
        for name in names {
            let key = ArtistPersonaResolver.normalized(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let cached = ArtistPersonaCache.shared.resolved(artist: name)
            if cached.gender == .unknown {
                pending.append(name)
            }
            if pending.count == 8 { break }
        }
        await withTaskGroup(of: Void.self) { group in
            for name in pending {
                group.addTask { [self] in
                    await self.fetchAndStoreArtistPersona(
                        name: name,
                        apiKey: apiKey
                    )
                }
            }
        }
    }

    private func fetchAndStoreArtistPersona(
        name: String,
        apiKey: String
    ) async {
        guard var components = URLComponents(
            string: "https://ws.audioscrobbler.com/2.0/"
        ) else { return }
        components.queryItems = [
            URLQueryItem(name: "method", value: "artist.getInfo"),
            URLQueryItem(name: "artist", value: name),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url,
              let response: LastFMArtistInfoResponse = await decode(
                url: url,
                allowsCaching: false
              ) else {
            return
        }
        let tags = (response.artist?.tags?.tag ?? [])
            + (response.artist?.toptags?.tag ?? [])
        let persona = ArtistPersonaResolver.infer(
            artist: response.artist?.name ?? name,
            tags: tags.map(\.name)
        )
        ArtistPersonaCache.shared.store(persona, for: name)
        if let resolvedName = response.artist?.name {
            ArtistPersonaCache.shared.store(persona, for: resolvedName)
        }
    }

    func listenBrainz(
        username: String,
        token: String?,
        limit: Int = 12
    ) async -> [ExternalRecommendationCandidate] {
        guard !username.isEmpty else { return [] }
        var allowedUsernameCharacters = CharacterSet.alphanumerics
        allowedUsernameCharacters.insert(charactersIn: "-._~")
        guard let escaped = username.addingPercentEncoding(
            withAllowedCharacters: allowedUsernameCharacters
        ) else {
            return []
        }
        guard var components = URLComponents(
            string: "https://api.listenbrainz.org/1/cf/recommendation/user/\(escaped)/recording"
        ) else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "count", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "0")
        ]
        guard let url = components.url,
              let response: ListenBrainzRecommendationResponse = await decode(
                url: url,
                token: token,
                allowsCaching: token?.isEmpty ?? true
              ) else {
            return []
        }
        let mbids = response.payload.mbids.map(\.recording_mbid)
        guard !mbids.isEmpty,
              var metadataURL = URLComponents(
                string: "https://api.listenbrainz.org/1/metadata/recording/"
              ) else {
            return []
        }
        metadataURL.queryItems = [
            URLQueryItem(name: "recording_mbids", value: mbids.joined(separator: ",")),
            URLQueryItem(name: "inc", value: "artist release tag")
        ]
        guard let resolvedURL = metadataURL.url,
              let metadata: [String: ListenBrainzMetadata] = await decode(
                url: resolvedURL,
                token: token,
                allowsCaching: token?.isEmpty ?? true
              ) else {
            return []
        }
        let scores = response.payload.mbids.reduce(into: [String: Double]()) {
            result, recommendation in
            result[recommendation.recording_mbid] = max(
                result[recommendation.recording_mbid] ?? 0,
                recommendation.score
            )
        }
        return mbids.compactMap { mbid in
            guard let value = metadata[mbid],
                  let title = value.recording?.name,
                  let artist = value.artist?.name,
                  !title.isEmpty,
                  !artist.isEmpty else {
                return nil
            }
            if let personaTags = value.artist?.personaTags, !personaTags.isEmpty {
                ArtistPersonaCache.shared.store(
                    ArtistPersonaResolver.infer(artist: artist, tags: personaTags),
                    for: artist
                )
            }
            return ExternalRecommendationCandidate(
                title: title,
                artist: artist,
                album: value.release?.name,
                recordingMBID: mbid,
                score: scores[mbid] ?? 0.5,
                source: .listenBrainz
            )
        }
    }

    private func decode<Value: Decodable>(
        url: URL,
        token: String? = nil,
        allowsCaching: Bool = true
    ) async -> Value? {
        do {
            let data = try await responseData(
                url: url,
                token: token,
                allowsCaching: allowsCaching,
                acceptsZstandard: true
            )
            return try decoder.decode(Value.self, from: data)
        } catch let error as URLError where error.code == .cannotDecodeContentData {
            do {
                let data = try await responseData(
                    url: url,
                    token: token,
                    allowsCaching: false,
                    acceptsZstandard: false
                )
                return try decoder.decode(Value.self, from: data)
            } catch {
                return nil
            }
        } catch {
            return nil
        }
    }

    private func responseData(
        url: URL,
        token: String?,
        allowsCaching: Bool,
        acceptsZstandard: Bool
    ) async throws -> Data {
        var request = URLRequest(url: url)
        ModernNetworkPolicy.prepareExternalAPIRequest(
            &request,
            acceptsZstandard: acceptsZstandard
        )
        if !acceptsZstandard {
            // Do not let a malformed zstd response cached by an intermediary
            // satisfy the compatibility retry with the same bytes.
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        if !allowsCaching {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        request.setValue("BuFi/1.0.0", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }

        let session = allowsCaching ? publicSession : privateSession
        let retryPolicy = ReadRequestRetryPolicy()
        var retryCount = 0
        while true {
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard retryCount < ReadRequestRetryPolicy.maximumRetryCount,
                      retryPolicy.shouldRetry(error: error),
                      let delay = retryPolicy.delay(
                        retryNumber: retryCount + 1,
                        retryAfterHeader: nil,
                        jitter: Double.random(in: 0.75...1.25)
                      ) else {
                    throw error
                }
                retryCount += 1
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
                continue
            }

            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                guard retryCount < ReadRequestRetryPolicy.maximumRetryCount,
                      retryPolicy.shouldRetry(statusCode: http.statusCode),
                      let delay = retryPolicy.delay(
                        retryNumber: retryCount + 1,
                        retryAfterHeader: http.value(
                            forHTTPHeaderField: "Retry-After"
                        ),
                        jitter: Double.random(in: 0.75...1.25)
                      ) else {
                    throw URLError(.badServerResponse)
                }
                retryCount += 1
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
                continue
            }
            guard data.count <= 4 * 1_024 * 1_024 else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            let decoded = try await HTTPContentDecoder.decodeAsync(
                data,
                contentEncoding: http.value(forHTTPHeaderField: "Content-Encoding")
            )
            guard decoded.count <= 4 * 1_024 * 1_024 else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            return decoded
        }
    }
}

private struct LastFMResponse: Decodable {
    let similartracks: LastFMSimilarTracks?
}

private struct LastFMSimilarTracks: Decodable {
    let track: [LastFMTrack]
}

private struct LastFMTrack: Decodable {
    let name: String
    let match: String
    let artist: LastFMArtist
}

private struct LastFMArtist: Decodable {
    let name: String
}

private struct LastFMArtistInfoResponse: Decodable {
    let artist: LastFMArtistInfo?
}

private struct LastFMArtistInfo: Decodable {
    let name: String?
    let tags: LastFMTagList?
    let toptags: LastFMTagList?
}

private struct LastFMTagList: Decodable {
    let tag: [LastFMNamedTag]
}

private struct LastFMNamedTag: Decodable {
    let name: String
}

private struct ListenBrainzRecommendationResponse: Decodable {
    let payload: ListenBrainzRecommendationPayload
}

private struct ListenBrainzRecommendationPayload: Decodable {
    let mbids: [ListenBrainzRecommendation]
}

private struct ListenBrainzRecommendation: Decodable {
    let recording_mbid: String
    let score: Double
}

private struct ListenBrainzMetadata: Decodable {
    struct NamedValue: Decodable {
        let name: String?
        let type: String?
        let gender: String?

        var personaTags: [String] {
            [type, gender].compactMap { $0 }
        }
    }

    let recording: NamedValue?
    let artist: NamedValue?
    let release: NamedValue?
}
