from pathlib import Path

source_path = Path("BuFi/Core/RecommendationEngine.swift")
test_path = Path("BuFiTests/RecommendationEngineTests.swift")
source = source_path.read_text()
tests = test_path.read_text()


def replace(text: str, old: str, new: str, count: int = 1) -> str:
    actual = text.count(old)
    if actual != count:
        raise SystemExit(
            f"expected {count} matches, found {actual}: {old[:100]!r}"
        )
    return text.replace(old, new, count)


source = replace(
    source,
    '''private struct RecommendationProfile {
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
        for genre in ([song.genre].compactMap { $0 } + (song.genres ?? []).map(\\.name)) {
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
''',
    '''private struct RecommendationCandidateMetadata {
    let artistKey: String
    let albumKey: String
    let genreKeys: [String]
    let moodKeys: [String]
    let timeText: String
    let deduplicationKey: String

    init(song: Song) {
        artistKey = Self.artistKey(for: song)
        albumKey = RecommendationMixer.normalized(song.albumId ?? song.album)
        genreKeys = Self.genreKeys(for: song)
        moodKeys = Self.moodKeys(for: song)
        timeText = RecommendationMixer.normalized(
            (
                [song.genre, song.title].compactMap { $0 }
                + (song.genres ?? []).map(\\.name)
                + (song.moods ?? [])
            ).joined(separator: " ")
        )
        deduplicationKey = RecommendationMixer.deduplicationKey(for: song)
    }

    static func artistKey(for song: Song) -> String {
        RecommendationMixer.normalized(song.artist)
    }

    static func genreKeys(for song: Song) -> [String] {
        normalizedUnique(
            [song.genre].compactMap { $0 }
                + (song.genres ?? []).map(\\.name)
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
    let deduplicationKey: String
    let isDiscovery: Bool
    let isNewArtist: Bool
    let isHiddenGem: Bool
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
'''
)

source = replace(
    source,
    '''        let shortProfile = profile(
            from: allBehaviors.filter { $0.lastPlayed >= shortCutoff },
            date: evaluationDate
        )
        let longProfile = profile(
            from: allBehaviors.filter { $0.lastPlayed >= longCutoff },
            date: evaluationDate
        )
''',
    '''        let temporalProfiles = temporalProfiles(
            from: allBehaviors,
            shortCutoff: shortCutoff,
            longCutoff: longCutoff,
            date: evaluationDate
        )
        let shortProfile = temporalProfiles.short
        let longProfile = temporalProfiles.long
'''
)

source = replace(
    source,
    '''        let knownSongIDs = Set(
            snapshot.starredSongs.map(\\.id)
            + snapshot.mostPlayedSongs.map(\\.id)
            + Array(behavior.songs.keys)
        )
''',
    '''        let starredSongIDs = Set(snapshot.starredSongs.map(\\.id))
        var knownSongIDs = starredSongIDs
        knownSongIDs.formUnion(snapshot.mostPlayedSongs.lazy.map(\\.id))
        knownSongIDs.formUnion(behavior.songs.keys)
'''
)

source = replace(
    source,
    '''        let candidates = unique(sourceLists.flatMap { $0 })
''',
    '''        // Deduplicate while streaming sources; avoid a second flattened corpus.
        let candidates = unique(sourceLists)
'''
)

source = replace(
    source,
    '''            let songBehavior = behavior.songs[song.id]
            let shortAffinity = shortProfile.affinity(for: song)
            let longAffinity = longProfile.affinity(for: song)
''',
    '''            let songBehavior = behavior.songs[song.id]
            let metadata = RecommendationCandidateMetadata(song: song)
            let shortAffinity = shortProfile.affinity(for: metadata)
            let longAffinity = longProfile.affinity(for: metadata)
'''
)

source = replace(
    source,
    '''            let exactFavorite = song.isStarred ? 1.0 : 0.0
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
''',
    '''            // Favorite identity is authoritative even when an earlier source
            // carries stale metadata for the same server song ID.
            let exactFavorite = starredSongIDs.contains(song.id) || song.isStarred
                ? 1.0 : 0.0
            let favoriteAffinity = max(
                exactFavorite,
                favoriteProfile.affinity(for: metadata)
            )
            let serverScore = consensusScore(
                rankScore(song.id, in: serverRanks),
                rankScore(song.id, in: sonicRanks),
                rankScore(song.id, in: similarRanks),
                rankScore(song.id, in: genreRanks),
                rankScore(song.id, in: topArtistRanks)
            )
'''
)

source = replace(
    source,
    '''            let rotationScore = artistRotationScore(
                song: song,
                favoriteAffinity: favoriteAffinity,
                recentArtists: recentArtists
            )
            let timeScore = timeAwarenessScore(song, hour: currentHour)
''',
    '''            let rotationScore = artistRotationScore(
                artistKey: metadata.artistKey,
                favoriteAffinity: favoriteAffinity,
                recentArtists: recentArtists
            )
            let timeScore = timeAwarenessScore(
                song,
                normalizedText: metadata.timeText,
                hour: currentHour
            )
'''
)

source = replace(
    source,
    '''            let features: [RecommendationFeature: Double] = [
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
''',
    '''            // Dense weights remove an 18-entry Dictionary allocation and
            // Dictionary probes from every candidate in the ranking corpus.
            var weightedTotal = 0.0
            weightedTotal += scoringPlan.contribution(.history, score: historyAffinity)
            weightedTotal += scoringPlan.contribution(.favorites, score: favoriteAffinity)
            weightedTotal += scoringPlan.contribution(.server, score: serverScore)
            weightedTotal += scoringPlan.contribution(
                .discovery,
                score: rankScore(song.id, in: discoveryRanks)
            )
            weightedTotal += scoringPlan.contribution(
                .lastFM,
                score: rankScore(song.id, in: lastFMRanks)
            )
            weightedTotal += scoringPlan.contribution(
                .listenBrainz,
                score: rankScore(song.id, in: listenBrainzRanks)
            )
            weightedTotal += scoringPlan.contribution(.behavior, score: behaviorScore)
            weightedTotal += scoringPlan.contribution(.completion, score: completionScore)
            weightedTotal += scoringPlan.contribution(.repeatListening, score: repeatScore)
            weightedTotal += scoringPlan.contribution(.recency, score: recencyScore)
            weightedTotal += scoringPlan.contribution(
                .context,
                score: contextProfile.affinity(for: metadata)
            )
            weightedTotal += scoringPlan.contribution(.localMetadata, score: metadataScore)
            weightedTotal += scoringPlan.contribution(.playlistAffinity, score: playlistScore)
            weightedTotal += scoringPlan.contribution(.albumCompletion, score: albumProgress)
            weightedTotal += scoringPlan.contribution(.forgottenFavorites, score: forgottenScore)
            weightedTotal += scoringPlan.contribution(.artistRotation, score: rotationScore)
            weightedTotal += scoringPlan.contribution(.timeAwareness, score: timeScore)
            weightedTotal += scoringPlan.contribution(.popularity, score: popularityScore)
            let score = scoringPlan.normalizedScore(weightedTotal)
'''
)

source = replace(
    source,
    '''            let sourceConfidence = sourceConfidence(
                song: song,
                lastFMRanks: lastFMRanks,
                listenBrainzRanks: listenBrainzRanks,
                sonicRanks: sonicRanks,
                similarRanks: similarRanks,
                favoriteGenres: favoriteGenres
            )
''',
    '''            let sourceConfidence = sourceConfidence(
                song: song,
                metadata: metadata,
                lastFMRanks: lastFMRanks,
                listenBrainzRanks: listenBrainzRanks,
                sonicRanks: sonicRanks,
                similarRanks: similarRanks,
                favoriteGenres: favoriteGenres
            )
'''
)

source = replace(
    source,
    '''            let isDiscovery = !knownSongIDs.contains(song.id)
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
''',
    '''            let isDiscovery = !knownSongIDs.contains(song.id)
            let isNewArtist = !knownArtists.contains(metadata.artistKey)
            // Missing play-count metadata means unknown popularity, not a gem.
            let isHiddenGem = isDiscovery
                && song.playCount.map { $0 <= 2 } == true
                && metadataConfidence >= 0.85
                && sourceConfidence >= 0.45
            ranked.append(RankedRecommendation(
                song: song,
                score: finalScore,
                artistKey: metadata.artistKey,
                albumKey: metadata.albumKey,
                deduplicationKey: metadata.deduplicationKey,
                isDiscovery: isDiscovery,
                isNewArtist: isNewArtist,
                isHiddenGem: isHiddenGem
            ))
'''
)

source = replace(
    source,
    '''        var effectiveWeights: [RecommendationFeature: Double] = [:]
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
''',
    '''        var effectiveWeights = Array(
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
'''
)

source = replace(
    source,
    '''    private static func profile(
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
                + (value.song.genres ?? []).map(\\.name)
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
''',
    '''    private static func profile(
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
'''
)

source = replace(
    source,
    '''    private static func artistRotationScore(
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
                + (song.genres ?? []).map(\\.name)
                + (song.moods ?? [])
            )
                .joined(separator: " ")
        )
''',
    '''    private static func artistRotationScore(
        artistKey: String,
        favoriteAffinity: Double,
        recentArtists: Set<String>
    ) -> Double {
        guard favoriteAffinity > 0 else { return 0 }
        return recentArtists.contains(artistKey)
            ? favoriteAffinity * 0.15
            : favoriteAffinity
    }

    private static func timeAwarenessScore(
        _ song: Song,
        normalizedText text: String,
        hour: Int
    ) -> Double {
'''
)

source = replace(
    source,
    '''    private static func sourceConfidence(
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
                + (song.genres ?? []).map(\\.name)
            if genres.contains(where: {
                favoriteGenres.contains(normalized($0))
            }) {
                return 0.90
            }
            return 0.75
        }
''',
    '''    private static func sourceConfidence(
        song: Song,
        metadata: RecommendationCandidateMetadata,
        lastFMRanks: [String: Int],
        listenBrainzRanks: [String: Int],
        sonicRanks: [String: Int],
        similarRanks: [String: Int],
        favoriteGenres: Set<String>
    ) -> Double {
        let lastFM = lastFMRanks[song.id] != nil
        let listenBrainz = listenBrainzRanks[song.id] != nil
        if lastFM, listenBrainz {
            if metadata.genreKeys.contains(where: favoriteGenres.contains) {
                return 0.90
            }
            return 0.75
        }
'''
)

source = replace(
    source,
    '''            for index in values.indices where isRemaining[index] {
                let value = values[index]
                let artistCount = artistCounts[value.artistKey, default: 0]
''',
    '''            for index in values.indices where isRemaining[index] {
                let value = values[index]
                // Input is score-descending and diversity factors never exceed 1.
                // Once a base score cannot beat the current adjusted winner,
                // no later candidate can beat it either.
                if bestIndex != nil, value.score <= bestAdjustedScore { break }
                let artistCount = artistCounts[value.artistKey, default: 0]
'''
)

source = replace(
    source,
    '    private static func deduplicationKey(for song: Song) -> String {\n',
    '    fileprivate static func deduplicationKey(for song: Song) -> String {\n'
)

source = replace(
    source,
    '''    private static func rankMap(_ values: [Song]) -> [String: Int] {
''',
    '''    @inline(__always)
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

    private static func rankMap(_ values: [Song]) -> [String: Int] {
'''
)

source = replace(
    source,
    '''    private static func unique(_ values: [Song]) -> [Song] {
        var ids = Set<String>()
        var result: [Song] = []
        result.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return [] }
            if ids.insert(value.id).inserted { result.append(value) }
        }
        return result
    }
''',
    '''    private static func unique(_ values: [Song]) -> [Song] {
        var ids = Set<String>()
        var result: [Song] = []
        result.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return [] }
            if ids.insert(value.id).inserted { result.append(value) }
        }
        return result
    }

    private static func unique(_ sources: [[Song]]) -> [Song] {
        let capacity = sources.reduce(into: 0) { $0 += $1.count }
        var ids = Set<String>()
        ids.reserveCapacity(capacity)
        var result: [Song] = []
        result.reserveCapacity(capacity)
        var visited = 0
        for source in sources {
            for song in source {
                if visited.isMultiple(of: 64), Task.isCancelled { return [] }
                visited += 1
                if ids.insert(song.id).inserted { result.append(song) }
            }
        }
        return result
    }
'''
)

source = replace(
    source,
    '''    let normalizedGenres: [String: String]
''',
    '''    let normalizedGenres: [String: [String]]
'''
)
source = replace(
    source,
    '''        var normalizedGenres: [String: String] = [:]
''',
    '''        var normalizedGenres: [String: [String]] = [:]
'''
)
source = replace(
    source,
    '''            songsByArtist[artist, default: []].append(song)
            if let genre = song.genre {
                let normalizedGenre = PersonalizedMixBuilder.normalized(genre)
                normalizedGenres[song.id] = normalizedGenre
                songsByGenre[normalizedGenre, default: []].append(song)
            } else {
                songsWithoutGenre.append(song)
            }
''',
    '''            songsByArtist[artist, default: []].append(song)
            let genreKeys = RecommendationCandidateMetadata.genreKeys(for: song)
            if genreKeys.isEmpty {
                songsWithoutGenre.append(song)
            } else {
                normalizedGenres[song.id] = genreKeys
                for genreKey in genreKeys {
                    songsByGenre[genreKey, default: []].append(song)
                }
            }
'''
)
source = replace(
    source,
    '''        let primaryGenres = Set(primary.compactMap {
            corpus.normalizedGenres[$0.id]
        })
''',
    '''        let primaryGenres = Set(primary.flatMap {
            corpus.normalizedGenres[$0.id] ?? []
        })
'''
)
source = replace(
    source,
    '''    fileprivate static func searchableText(_ song: Song) -> String {
        normalized(
            [song.genre, song.title, song.album, song.artist]
                .compactMap { $0 }
                .joined(separator: " ")
        )
    }
''',
    '''    fileprivate static func searchableText(_ song: Song) -> String {
        normalized(
            (
                [song.genre, song.title, song.album, song.artist].compactMap { $0 }
                + (song.genres ?? []).map(\\.name)
                + (song.moods ?? [])
            ).joined(separator: " ")
        )
    }
'''
)

insert_anchor = '''    func testArtistMixPreferencesDeduplicateAndKeepFourRecentArtists() {
'''
new_tests = '''    func testFavoriteIdentitySurvivesStaleCandidateMetadata() {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let staleFavorite = song(
            id: "favorite-id",
            title: "Favorite",
            artist: "Old Metadata Artist"
        )
        let currentFavorite = song(
            id: "favorite-id",
            title: "Favorite",
            artist: "Current Favorite Artist",
            starred: "2026-08-01T00:00:00Z"
        )
        let competitor = song(
            id: "known-competitor",
            title: "Competitor",
            artist: "Other Artist"
        )
        var recommendationWeights = isolatedWeights()
        recommendationWeights.favorites = 1
        recommendationWeights.discoveryRatio = 0

        let result = RecommendationMixer.mix(
            snapshot: HomeSnapshot(
                serverRecommendedSongs: [staleFavorite, competitor],
                mostPlayedSongs: [competitor],
                starredSongs: [currentFavorite]
            ),
            weights: recommendationWeights,
            purpose: .taste,
            limit: 2,
            date: date
        )

        XCTAssertEqual(result.first?.id, "favorite-id")
    }

    func testLocalRecommendationConsensusOutranksSingleSourceSignal() {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let consensus = song(
            id: "consensus-local",
            title: "Consensus",
            artist: "Consensus Artist"
        )
        let single = song(
            id: "single-local",
            title: "Single",
            artist: "Single Artist"
        )
        func filler(_ id: String) -> Song {
            song(id: id, title: id, artist: "Filler \\(id)")
        }
        var recommendationWeights = isolatedWeights()
        recommendationWeights.serverSimilarity = 1
        recommendationWeights.discoveryRatio = 1
        let snapshot = HomeSnapshot(
            serverRecommendedSongs: [filler("s0"), consensus, filler("s2")],
            sonicRecommendedSongs: [filler("q0"), single, consensus],
            similarArtistSongs: [filler("m0"), consensus, filler("m2")],
            genreRecommendedSongs: [filler("g0"), consensus, filler("g2")]
        )

        let result = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: recommendationWeights,
            purpose: .artistMix,
            limit: 20,
            date: date
        )
        let consensusIndex = result.firstIndex { $0.id == consensus.id }
        let singleIndex = result.firstIndex { $0.id == single.id }

        XCTAssertNotNil(consensusIndex)
        XCTAssertNotNil(singleIndex)
        if let consensusIndex, let singleIndex {
            XCTAssertLessThan(consensusIndex, singleIndex)
        }
    }

    func testPersonalizedSearchableTextIncludesSecondaryGenresAndMoods() {
        var value = song(
            id: "secondary-metadata",
            title: "Neutral Title",
            artist: "Artist"
        )
        value.genres = [SongGenre(name: "K-Pop")]
        value.moods = ["Happy"]

        let text = PersonalizedMixBuilder.searchableText(value)

        XCTAssertTrue(text.contains("k-pop"))
        XCTAssertTrue(text.contains("happy"))
    }

'''
tests = replace(tests, insert_anchor, new_tests + insert_anchor)

source_path.write_text(source)
test_path.write_text(tests)
