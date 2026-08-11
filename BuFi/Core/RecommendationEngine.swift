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
        func value(_ key: String, fallback: Double) -> Double {
            guard defaults.object(forKey: key) != nil else { return fallback }
            return min(max(defaults.double(forKey: key), 0), 1)
        }
        return RecommendationWeights(
            history: value("recommendation-weight-history", fallback: 0.70),
            favorites: value("recommendation-weight-favorites", fallback: 0.80),
            serverSimilarity: value("recommendation-weight-server", fallback: 0.90),
            discovery: value("recommendation-weight-discovery", fallback: 0.35),
            lastFM: value("recommendation-weight-lastfm", fallback: 0.55),
            listenBrainz: value("recommendation-weight-listenbrainz", fallback: 0.55),
            behavior: value("recommendation-weight-behavior", fallback: 0.85),
            completion: value("recommendation-weight-completion", fallback: 0.70),
            repeatListening: value("recommendation-weight-repeat", fallback: 0.55),
            recency: value("recommendation-weight-recency", fallback: 0.65),
            context: value("recommendation-weight-context", fallback: 0.60),
            localMetadata: value("recommendation-weight-metadata", fallback: 0.60),
            playlistAffinity: value(
                "recommendation-weight-playlist-affinity",
                fallback: 0.55
            ),
            albumCompletion: value(
                "recommendation-weight-album-completion",
                fallback: 0.45
            ),
            forgottenFavorites: value(
                "recommendation-weight-forgotten-favorites",
                fallback: 0.50
            ),
            artistRotation: value(
                "recommendation-weight-artist-rotation",
                fallback: 0.45
            ),
            timeAwareness: value(
                "recommendation-weight-time-awareness",
                fallback: 0.30
            ),
            discoveryRatio: value(
                "recommendation-discovery-ratio",
                fallback: 0.35
            )
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
                shortTermRatio: purpose == .daylist ? 0.70 : 0.58,
                featureWeights: [
                    .history: 0.35,
                    .favorites: 0.20,
                    .recency: 0.20,
                    .lastFM: 0.10,
                    .listenBrainz: 0.10,
                    .discovery: 0.05,
                    .server: 0.18,
                    .behavior: 0.22,
                    .completion: 0.16,
                    .repeatListening: 0.10,
                    .context: 0.15,
                    .localMetadata: 0.10,
                    .playlistAffinity: 0.08,
                    .albumCompletion: 0.07,
                    .forgottenFavorites: 0.06,
                    .artistRotation: 0.08,
                    .timeAwareness: purpose == .daylist ? 0.12 : 0.06,
                    .popularity: 0.06
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
                    .favorites: 0.24, .server: 0.32, .history: 0.20,
                    .discovery: 0.10, .lastFM: 0.14,
                    .listenBrainz: 0.14, .behavior: 0.12,
                    .localMetadata: 0.18, .artistRotation: 0.05
                ]
            )
        case .discovery:
            RecommendationPreset(
                shortTermRatio: 0.55,
                featureWeights: [
                    .discovery: 0.35, .lastFM: 0.25,
                    .listenBrainz: 0.25, .history: 0.15,
                    .server: 0.22, .context: 0.12,
                    .localMetadata: 0.10, .artistRotation: 0.12,
                    .timeAwareness: 0.06, .popularity: 0.06
                ]
            )
        case .frequent:
            RecommendationPreset(
                shortTermRatio: 0.42,
                featureWeights: [
                    .popularity: 0.40, .completion: 0.20,
                    .repeatListening: 0.20, .favorites: 0.20,
                    .history: 0.18, .behavior: 0.16
                ]
            )
        case .autoplay:
            RecommendationPreset(
                shortTermRatio: 0.72,
                featureWeights: [
                    .context: 0.28, .server: 0.26, .history: 0.18,
                    .favorites: 0.12, .lastFM: 0.10,
                    .listenBrainz: 0.10, .behavior: 0.16,
                    .completion: 0.12, .discovery: 0.08,
                    .localMetadata: 0.14, .artistRotation: 0.10,
                    .timeAwareness: 0.08
                ]
            )
        }
    }
}

private struct RecommendationProfile {
    var artists: [String: Double] = [:]
    var genres: [String: Double] = [:]
    var moods: [String: Double] = [:]

    func affinity(for song: Song) -> Double {
        var strongest = 0.0
        if !song.artist.isEmpty {
            strongest = max(
                strongest,
                artists[RecommendationMixer.normalized(song.artist)] ?? 0
            )
        }
        for genre in ([song.genre].compactMap { $0 } + (song.genres ?? []).map(\.name)) {
            if !genre.isEmpty {
                strongest = max(
                    strongest,
                    genres[RecommendationMixer.normalized(genre)] ?? 0
                )
            }
        }
        for mood in song.moods ?? [] {
            strongest = max(
                strongest,
                moods[RecommendationMixer.normalized(mood)] ?? 0
            )
        }
        return strongest
    }
}

private struct RankedRecommendation {
    let song: Song
    var score: Double
    let artistKey: String
    let albumKey: String
    let deduplicationKey: String
    let isDiscovery: Bool
    let isNewArtist: Bool
    let isHiddenGem: Bool
}

private struct RecommendationScoringPlan {
    let weights: [RecommendationFeature: Double]
    let totalWeight: Double
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

enum RecommendationMixer {
    private static let cache = RecommendationMixCache()

    static func mix(
        snapshot: HomeSnapshot,
        weights: RecommendationWeights,
        purpose: RecommendationPurpose = .home,
        behavior: RecommendationBehaviorSnapshot = .empty,
        limit: Int = 30,
        date: Date = Date()
    ) -> [Song] {
        guard limit > 0, !Task.isCancelled else { return [] }
        guard let key = cacheKey(
            snapshot: snapshot,
            weights: weights,
            purpose: purpose,
            behavior: behavior,
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
        let shortProfile = profile(
            from: allBehaviors.filter { $0.lastPlayed >= shortCutoff },
            date: evaluationDate
        )
        let longProfile = profile(
            from: allBehaviors.filter { $0.lastPlayed >= longCutoff },
            date: evaluationDate
        )
        let contextProfile = profile(
            from: behavior.recentSongs.compactMap { behavior.songs[$0.id] },
            date: evaluationDate,
            appliesDecay: false
        )
        let favoriteProfile = profile(
            from: snapshot.starredSongs.map {
                behavior.songs[$0.id]
                    ?? SongBehavior(song: $0, at: evaluationDate)
            },
            date: evaluationDate,
            appliesDecay: false
        )
        guard !Task.isCancelled else { return [] }

        let knownSongIDs = Set(
            snapshot.starredSongs.map(\.id)
            + snapshot.mostPlayedSongs.map(\.id)
            + Array(behavior.songs.keys)
        )
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
            snapshot.serverRecommendedSongs,
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
            snapshot.starredSongs,
            snapshot.daylistSongs,
            snapshot.recommendedSongs
        ]
        let candidates = unique(sourceLists.flatMap { $0 })
        guard !candidates.isEmpty else { return [] }

        let serverRanks = rankMap(snapshot.serverRecommendedSongs)
        let sonicRanks = rankMap(snapshot.sonicRecommendedSongs)
        let similarRanks = rankMap(snapshot.similarArtistSongs)
        let genreRanks = rankMap(snapshot.genreRecommendedSongs)
        let topArtistRanks = rankMap(snapshot.topArtistSongs)
        let recentRanks = rankMap(snapshot.recentlyAddedSongs)
        let popularRanks = rankMap(snapshot.popularSongs + snapshot.mostPlayedSongs)
        let playlistRanks = rankMap(snapshot.playlistAffinitySongs)
        let discoveryRanks = rankMap(snapshot.randomSongs)
        let lastFMRanks = rankMap(snapshot.lastFMRecommendedSongs)
        let listenBrainzRanks = rankMap(snapshot.listenBrainzRecommendedSongs)
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
            coldStart: isColdStart
        )
        let currentHour = Calendar.current.component(.hour, from: evaluationDate)
        let rankingSeed = temporalBucket(for: purpose, date: date)

        var ranked: [RankedRecommendation] = []
        ranked.reserveCapacity(candidates.count)
        for (index, song) in candidates.enumerated() {
            if index.isMultiple(of: 32), Task.isCancelled { return [] }
            let songBehavior = behavior.songs[song.id]
            let shortAffinity = shortProfile.affinity(for: song)
            let longAffinity = longProfile.affinity(for: song)
            let historyAffinity =
                shortAffinity * preset.shortTermRatio
                + longAffinity * (1 - preset.shortTermRatio)
            let exactFavorite = song.isStarred ? 1.0 : 0.0
            let favoriteAffinity = max(
                exactFavorite,
                favoriteProfile.affinity(for: song)
            )
            let serverScore = [
                rankScore(song.id, in: serverRanks),
                rankScore(song.id, in: sonicRanks),
                rankScore(song.id, in: similarRanks),
                rankScore(song.id, in: genreRanks),
                rankScore(song.id, in: topArtistRanks)
            ].max() ?? 0
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
                rankScore(song.id, in: recentRanks)
            )
            let metadataScore = localMetadataAffinity(song)
            let playlistScore = max(
                rankScore(song.id, in: playlistRanks),
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
                song: song,
                favoriteAffinity: favoriteAffinity,
                recentArtists: recentArtists
            )
            let timeScore = timeAwarenessScore(song, hour: currentHour)
            let popularityScore = max(
                rankScore(song.id, in: popularRanks),
                min(1, log1p(Double(song.playCount ?? 0)) / log1p(maxPlayCount))
            )
            let features: [RecommendationFeature: Double] = [
                .history: historyAffinity,
                .favorites: favoriteAffinity,
                .server: serverScore,
                .discovery: rankScore(song.id, in: discoveryRanks),
                .lastFM: rankScore(song.id, in: lastFMRanks),
                .listenBrainz: rankScore(song.id, in: listenBrainzRanks),
                .behavior: behaviorScore,
                .completion: completionScore,
                .repeatListening: repeatScore,
                .recency: recencyScore,
                .context: contextProfile.affinity(for: song),
                .localMetadata: metadataScore,
                .playlistAffinity: playlistScore,
                .albumCompletion: albumProgress,
                .forgottenFavorites: forgottenScore,
                .artistRotation: rotationScore,
                .timeAwareness: timeScore,
                .popularity: popularityScore
            ]
            let score = weightedScore(
                features: features,
                plan: scoringPlan
            )
            let metadataConfidence = metadataConfidence(song)
            let sourceConfidence = sourceConfidence(
                song: song,
                lastFMRanks: lastFMRanks,
                listenBrainzRanks: listenBrainzRanks,
                sonicRanks: sonicRanks,
                similarRanks: similarRanks,
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
            let artistKey = normalized(song.artist)
            let isNewArtist = !knownArtists.contains(artistKey)
            let isHiddenGem = isDiscovery
                && (song.playCount ?? 0) <= 2
            ranked.append(RankedRecommendation(
                song: song,
                score: finalScore,
                artistKey: artistKey,
                albumKey: normalized(song.albumId ?? song.album),
                deduplicationKey: deduplicationKey(for: song),
                isDiscovery: isDiscovery,
                isNewArtist: isNewArtist,
                isHiddenGem: isHiddenGem
            ))
        }
        guard !Task.isCancelled else { return [] }
        ranked.sort {
            if $0.score == $1.score { return $0.song.id < $1.song.id }
            return $0.score > $1.score
        }
        ranked = deduplicated(ranked)
        ranked = allocateDiscovery(
            ranked,
            ratio: weights.discoveryRatio,
            limit: limit
        )
        guard !Task.isCancelled else { return [] }
        let result = diversityReranked(ranked, limit: limit).map(\.song)
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
        coldStart: Bool
    ) -> RecommendationScoringPlan {
        var userWeights: [RecommendationFeature: Double] = [
            .history: weights.history,
            .favorites: weights.favorites,
            .server: weights.serverSimilarity,
            .discovery: weights.discovery,
            .lastFM: weights.lastFM,
            .listenBrainz: weights.listenBrainz,
            .behavior: weights.behavior,
            .completion: weights.completion,
            .repeatListening: weights.repeatListening,
            .recency: weights.recency,
            .context: weights.context,
            .localMetadata: weights.localMetadata,
            .playlistAffinity: weights.playlistAffinity,
            .albumCompletion: weights.albumCompletion,
            .forgottenFavorites: weights.forgottenFavorites,
            .artistRotation: weights.artistRotation,
            .timeAwareness: weights.timeAwareness,
            .popularity: 0.65
        ]
        if coldStart {
            userWeights[.favorites] = max(userWeights[.favorites] ?? 0, 0.95)
            userWeights[.localMetadata] = max(
                userWeights[.localMetadata] ?? 0,
                0.80
            )
            userWeights[.popularity] = 0.78
            userWeights[.history] = 0.15
            userWeights[.behavior] = 0.15
        }
        var effectiveWeights: [RecommendationFeature: Double] = [:]
        effectiveWeights.reserveCapacity(preset.featureWeights.count)
        for feature in RecommendationFeature.allCases {
            guard let presetWeight = preset.featureWeights[feature] else {
                continue
            }
            let weight = presetWeight * (userWeights[feature] ?? 0)
            if weight > 0 { effectiveWeights[feature] = weight }
        }
        return RecommendationScoringPlan(
            weights: effectiveWeights,
            totalWeight: RecommendationFeature.allCases.reduce(0) {
                $0 + (effectiveWeights[$1] ?? 0)
            }
        )
    }

    private static func weightedScore(
        features: [RecommendationFeature: Double],
        plan: RecommendationScoringPlan
    ) -> Double {
        var total = 0.0
        for feature in RecommendationFeature.allCases {
            guard let featureScore = features[feature],
                  let weight = plan.weights[feature] else { continue }
            total += min(max(featureScore, 0), 1) * weight
        }
        return plan.totalWeight > 0 ? total / plan.totalWeight : 0
    }

    private static func profile(
        from values: [SongBehavior],
        date: Date,
        appliesDecay: Bool = true
    ) -> RecommendationProfile {
        var result = RecommendationProfile()
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { break }
            let behavior = behaviorAffinity(value)
            let decay = appliesDecay
                ? timeDecay(since: value.lastPlayed, now: date)
                : 1
            let strength = max(0.05, behavior) * decay
            if !value.song.artist.isEmpty {
                result.artists[normalized(value.song.artist), default: 0] += strength
            }
            for genre in (
                [value.song.genre].compactMap { $0 }
                + (value.song.genres ?? []).map(\.name)
            ) where !genre.isEmpty {
                result.genres[normalized(genre), default: 0] += strength
            }
            for mood in value.song.moods ?? [] where !mood.isEmpty {
                result.moods[normalized(mood), default: 0] += strength
            }
        }
        normalizeMap(&result.artists)
        normalizeMap(&result.genres)
        normalizeMap(&result.moods)
        return result
    }

    private static func normalizeMap(_ values: inout [String: Double]) {
        guard let maximum = values.values.max(), maximum > 0 else { return }
        for key in values.keys.sorted() {
            values[key] = min(max((values[key] ?? 0) / maximum, 0), 1)
        }
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
        song: Song,
        favoriteAffinity: Double,
        recentArtists: Set<String>
    ) -> Double {
        guard favoriteAffinity > 0 else { return 0 }
        return recentArtists.contains(normalized(song.artist))
            ? favoriteAffinity * 0.15
            : favoriteAffinity
    }

    private static func timeAwarenessScore(_ song: Song, hour: Int) -> Double {
        let text = normalized(
            (
                [song.genre, song.title].compactMap { $0 }
                + (song.genres ?? []).map(\.name)
                + (song.moods ?? [])
            )
                .joined(separator: " ")
        )
        let calmTokens = ["chill", "ambient", "acoustic", "jazz", "ballad", "sleep", "잔잔"]
        let activeTokens = ["dance", "edm", "rock", "hip hop", "workout", "upbeat", "댄스"]
        let bpm = song.bpm ?? 0
        if hour >= 22 || hour < 6 {
            return calmTokens.contains(where: text.contains) || (bpm > 0 && bpm < 105)
                ? 1 : 0.35
        }
        if (7...9).contains(hour) || (17...19).contains(hour) {
            return activeTokens.contains(where: text.contains) || bpm >= 115
                ? 1 : 0.45
        }
        return 0.65
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
        song: Song,
        lastFMRanks: [String: Int],
        listenBrainzRanks: [String: Int],
        sonicRanks: [String: Int],
        similarRanks: [String: Int],
        favoriteGenres: Set<String>
    ) -> Double {
        let lastFM = lastFMRanks[song.id] != nil
        let listenBrainz = listenBrainzRanks[song.id] != nil
        if lastFM, listenBrainz {
            let genres = [song.genre].compactMap { $0 }
                + (song.genres ?? []).map(\.name)
            if genres.contains(where: {
                favoriteGenres.contains(normalized($0))
            }) {
                return 0.90
            }
            return 0.75
        }
        if lastFM || listenBrainz { return 0.45 }
        if sonicRanks[song.id] != nil { return 0.88 }
        if similarRanks[song.id] != nil { return 0.80 }
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
            if $0.score == $1.score { return $0.song.id < $1.song.id }
            return $0.score > $1.score
        }
    }

    private static func diversityReranked(
        _ values: [RankedRecommendation],
        limit: Int
    ) -> [RankedRecommendation] {
        var remaining = values
        var result: [RankedRecommendation] = []
        var artistCounts: [String: Int] = [:]
        var albumCounts: [String: Int] = [:]
        while !remaining.isEmpty, result.count < limit {
            if Task.isCancelled { return [] }
            var bestIndex = 0
            var bestAdjustedScore = -Double.infinity
            for (index, value) in remaining.enumerated() {
                let artistCount = artistCounts[value.artistKey, default: 0]
                let albumCount = albumCounts[value.albumKey, default: 0]
                let adjusted = value.score
                    * diversityFactor(for: artistCount)
                    * diversityFactor(for: albumCount)
                if adjusted > bestAdjustedScore {
                    bestAdjustedScore = adjusted
                    bestIndex = index
                }
            }
            let selected = remaining.remove(at: bestIndex)
            result.append(selected)
            artistCounts[selected.artistKey, default: 0] += 1
            albumCounts[selected.albumKey, default: 0] += 1
        }
        return result
    }

    private static func diversityFactor(for existingCount: Int) -> Double {
        switch existingCount {
        case 0: 1.0
        case 1: 0.90
        case 2: 0.75
        default: 0.55
        }
    }

    private static func deduplicated(
        _ values: [RankedRecommendation]
    ) -> [RankedRecommendation] {
        var keys = Set<String>()
        return values.filter { value in
            keys.insert(value.deduplicationKey).inserted
        }
    }

    private static func deduplicationKey(for song: Song) -> String {
        if let mbid = song.musicBrainzId, !mbid.isEmpty {
            return "mbid:\(normalized(mbid))"
        }
        if let isrc = song.isrc?.first, !isrc.isEmpty {
            return "isrc:\(normalized(isrc))"
        }
        return [
            normalized(song.artist),
            canonicalTitle(song.title)
        ].joined(separator: "\u{1F}")
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

    private static func rankMap(_ values: [Song]) -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(values.count)
        for (index, song) in values.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return [:] }
            if result[song.id] == nil { result[song.id] = result.count }
        }
        return result
    }

    private static func rankScore(_ id: String, in ranks: [String: Int]) -> Double {
        guard let rank = ranks[id] else { return 0 }
        guard !ranks.isEmpty else { return 0 }
        if ranks.count == 1 { return 1 }
        return 1 - Double(rank) / Double(ranks.count)
    }

    private static func unique(_ values: [Song]) -> [Song] {
        var ids = Set<String>()
        var result: [Song] = []
        result.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return [] }
            if ids.insert(value.id).inserted { result.append(value) }
        }
        return result
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
        weights: RecommendationWeights,
        purpose: RecommendationPurpose,
        behavior: RecommendationBehaviorSnapshot,
        limit: Int,
        date: Date
    ) -> String? {
        let sources = [
            snapshot.serverRecommendedSongs,
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
            snapshot.starredSongs,
            snapshot.daylistSongs,
            snapshot.recommendedSongs
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
            String(snapshotFingerprint.value),
            String(behaviorFingerprint.value),
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
        var ids = Set<String>()
        return songs.filter { ids.insert($0.id).inserted }
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

private struct PersonalizedMixCacheKey: Equatable {
    let snapshot: HomeSnapshot
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
}

private struct PersonalizedSongCorpus {
    let pool: [Song]
    let canonicalSongs: [String: Song]
    let searchableTexts: [String: String]
    let normalizedArtists: [String: String]
    let normalizedGenres: [String: String]
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
        var normalizedGenres: [String: String] = [:]
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
            if let genre = song.genre {
                let normalizedGenre = PersonalizedMixBuilder.normalized(genre)
                normalizedGenres[song.id] = normalizedGenre
                songsByGenre[normalizedGenre, default: []].append(song)
            } else {
                songsWithoutGenre.append(song)
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
        date: Date = Date(),
        calendar: Calendar = .current,
        songLimit: Int = 24,
        selectedArtists: [String] = []
    ) -> [PersonalizedMix] {
        guard songLimit > 0 else { return [] }
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 0
        let year = calendar.component(.year, from: date)
        let period = dayPeriod(date, calendar: calendar)
        let cacheKey = PersonalizedMixCacheKey(
            snapshot: snapshot,
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
        let corpus = PersonalizedSongCorpus(snapshot: snapshot)
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
        let primaryGenres = Set(primary.compactMap {
            corpus.normalizedGenres[$0.id]
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
        var ids = Set<String>()
        var result: [Song] = []
        result.reserveCapacity(songs.count)
        for (index, song) in songs.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return [] }
            if ids.insert(song.id).inserted { result.append(song) }
        }
        return result
    }

    fileprivate static func searchableText(_ song: Song) -> String {
        normalized(
            [song.genre, song.title, song.album, song.artist]
                .compactMap { $0 }
                .joined(separator: " ")
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

    private let session: URLSession
    private let decoder = JSONDecoder()

    private init() {
        let configuration = ModernNetworkPolicy.makeCachedConfiguration(
            requestTimeout: 12,
            resourceTimeout: 24,
            maximumConnectionsPerHost: 2,
            memoryCapacity: 2 * 1_024 * 1_024,
            diskCapacity: 12 * 1_024 * 1_024,
            allowsExpensiveNetworkAccess: true,
            allowsConstrainedNetworkAccess: false
        )
        session = URLSession(
            configuration: configuration,
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
              let response: LastFMResponse = await decode(url: url) else {
            return []
        }
        return (response.similartracks?.track ?? []).compactMap { item in
            guard !item.name.isEmpty, !item.artist.name.isEmpty else { return nil }
            return ExternalRecommendationCandidate(
                title: item.name,
                artist: item.artist.name,
                album: nil,
                recordingMBID: nil,
                score: Double(item.match) ?? 0.5,
                source: .lastFM
            )
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
                token: token
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
            URLQueryItem(name: "inc", value: "artist release")
        ]
        guard let resolvedURL = metadataURL.url,
              let metadata: [String: ListenBrainzMetadata] = await decode(
                url: resolvedURL,
                token: token
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
        token: String? = nil
    ) async -> Value? {
        do {
            let data = try await responseData(
                url: url,
                token: token,
                acceptsZstandard: true
            )
            return try decoder.decode(Value.self, from: data)
        } catch let error as URLError where error.code == .cannotDecodeContentData {
            do {
                let data = try await responseData(
                    url: url,
                    token: token,
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
        request.setValue("BuFi/1.0.0", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        let decoded = try HTTPContentDecoder.decode(
            data,
            contentEncoding: http.value(forHTTPHeaderField: "Content-Encoding")
        )
        guard decoded.count <= 4 * 1_024 * 1_024 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        return decoded
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
    }

    let recording: NamedValue?
    let artist: NamedValue?
    let release: NamedValue?
}
