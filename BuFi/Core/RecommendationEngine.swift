import Foundation

struct RecommendationWeights: Sendable {
    var history: Double
    var favorites: Double
    var serverSimilarity: Double
    var discovery: Double
    var lastFM: Double
    var listenBrainz: Double

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
            listenBrainz: value("recommendation-weight-listenbrainz", fallback: 0.55)
        )
    }
}

enum RecommendationMixer {
    static func mix(
        snapshot: HomeSnapshot,
        weights: RecommendationWeights,
        limit: Int = 30
    ) -> [Song] {
        let favoriteArtists = Set(snapshot.starredSongs.map {
            normalized($0.artist)
        })
        let favoriteGenres = Set(snapshot.starredSongs.compactMap {
            $0.genre.map(normalized)
        })
        let historyArtists = Set(snapshot.mostPlayedSongs.map {
            normalized($0.artist)
        })
        let historyGenres = Set(snapshot.mostPlayedSongs.compactMap {
            $0.genre.map(normalized)
        })
        let serverRanks = rankMap(snapshot.serverRecommendedSongs)
        let discoveryRanks = rankMap(snapshot.randomSongs)
        let lastFMRanks = rankMap(snapshot.lastFMRecommendedSongs)
        let listenBrainzRanks = rankMap(snapshot.listenBrainzRecommendedSongs)

        let candidates = unique(
            snapshot.serverRecommendedSongs +
            snapshot.lastFMRecommendedSongs +
            snapshot.listenBrainzRecommendedSongs +
            snapshot.randomSongs
        )
        let starredIDs = Set(snapshot.starredSongs.map(\.id))
        return candidates
            .filter { !starredIDs.contains($0.id) }
            .map { song in
                let artistMatch = favoriteArtists.contains(normalized(song.artist))
                let genreMatch = song.genre.map { favoriteGenres.contains(normalized($0)) } ?? false
                let favoriteAffinity = artistMatch ? 1.0 : (genreMatch ? 0.62 : 0)
                let historyArtistMatch = historyArtists.contains(normalized(song.artist))
                let historyGenreMatch = song.genre.map {
                    historyGenres.contains(normalized($0))
                } ?? false
                let historyAffinity = historyArtistMatch
                    ? 1.0
                    : (historyGenreMatch ? 0.58 : 0)
                let score =
                    weights.history * historyAffinity +
                    weights.favorites * favoriteAffinity +
                    weights.serverSimilarity * rankScore(song.id, in: serverRanks) +
                    weights.discovery * rankScore(song.id, in: discoveryRanks) +
                    weights.lastFM * rankScore(song.id, in: lastFMRanks) +
                    weights.listenBrainz * rankScore(song.id, in: listenBrainzRanks) +
                    stableTieBreaker(song.id)
                return (song, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.id < rhs.0.id }
                return lhs.1 > rhs.1
            }
            .prefix(limit)
            .map { $0.0 }
    }

    private static func rankMap(_ values: [Song]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: unique(values).enumerated().map {
            ($0.element.id, $0.offset)
        })
    }

    private static func rankScore(_ id: String, in ranks: [String: Int]) -> Double {
        guard let rank = ranks[id] else { return 0 }
        return 1 / (1 + Double(rank) * 0.12)
    }

    private static func unique(_ values: [Song]) -> [Song] {
        var ids = Set<String>()
        return values.filter { ids.insert($0.id).inserted }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stableTieBreaker(_ value: String) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Double(hash % 997) / 997_000
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
        case 5..<11:
            period = 0
            familiarSlots = 2
        case 11..<17:
            period = 1
            familiarSlots = 1
        case 17..<22:
            period = 2
            familiarSlots = 2
        default:
            period = 3
            familiarSlots = 3
        }
        let seed = day * 4 + period
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
        songs.sorted {
            stableHash($0.id, seed: seed) < stableHash($1.id, seed: seed)
        }
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

struct ExternalRecommendationCandidate: Sendable {
    enum Source: Sendable {
        case lastFM
        case listenBrainz
    }

    let title: String
    let artist: String
    let recordingMBID: String?
    let score: Double
    let source: Source
}

actor ExternalRecommendationClient {
    static let shared = ExternalRecommendationClient()

    private let session: URLSession
    private let decoder = JSONDecoder()

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 24
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 2 * 1_024 * 1_024,
            diskCapacity: 12 * 1_024 * 1_024
        )
        session = URLSession(configuration: configuration)
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
            URLQueryItem(name: "inc", value: "artist")
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
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BuFi/1.4.0", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count <= 4 * 1_024 * 1_024 else {
                return nil
            }
            return try decoder.decode(Value.self, from: data)
        } catch {
            return nil
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
}
