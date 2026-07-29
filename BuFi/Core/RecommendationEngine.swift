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

    var coverArts: [String] {
        var values: [String] = []
        var seen = Set<String>()
        for song in songs {
            guard let cover = song.coverArt,
                  !cover.isEmpty,
                  seen.insert(cover).inserted else {
                continue
            }
            values.append(cover)
            if values.count == 4 { break }
        }
        return values
    }

    var showsRanking: Bool { kind == .ranking }
}

enum PersonalizedMixBuilder {
    static func make(
        snapshot: HomeSnapshot,
        date: Date = Date(),
        calendar: Calendar = .current,
        songLimit: Int = 24
    ) -> [PersonalizedMix] {
        let pool = unique(
            snapshot.mostPlayedSongs +
            snapshot.starredSongs +
            snapshot.daylistSongs +
            snapshot.recommendedSongs +
            snapshot.serverRecommendedSongs +
            snapshot.lastFMRecommendedSongs +
            snapshot.listenBrainzRecommendedSongs +
            snapshot.randomSongs
        )
        guard !pool.isEmpty else { return [] }

        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 0
        let year = calendar.component(.year, from: date)
        let dailySeed = year * 1_000 + day
        let daylist = filled(
            preferred: DaylistBuilder.make(
                snapshot: snapshot,
                date: date,
                calendar: calendar,
                limit: songLimit
            ),
            from: pool,
            seed: dailySeed,
            limit: songLimit
        )

        let repeatSongs = filled(
            preferred: snapshot.mostPlayedSongs + snapshot.starredSongs,
            from: pool,
            seed: dailySeed + 11,
            limit: songLimit
        )
        let recentlyPlayed = pool.filter { $0.played != nil }.sorted {
            ($0.played ?? "") > ($1.played ?? "")
        }
        let listenAgain = filled(
            preferred: recentlyPlayed + snapshot.mostPlayedSongs,
            from: pool,
            seed: dailySeed + 23,
            limit: songLimit
        )

        let kPopMatches = pool.filter {
            containsAny(
                searchableText($0),
                tokens: ["k-pop", "kpop", "korean pop", "케이팝"]
            )
        }
        let popMatches = pool.filter {
            containsAny(searchableText($0), tokens: ["pop", "팝"]) &&
                !kPopMatches.contains($0)
        }
        let affinityArtists = highestAffinityArtists(
            in: snapshot,
            fallbackPool: pool,
            limit: 3
        )

        var mixes: [PersonalizedMix] = [
            PersonalizedMix(
                id: "daylist-\(dailySeed)-\(dayPeriod(date, calendar: calendar).id)",
                title: daylistTitle(date, calendar: calendar),
                subtitle: dayPeriod(date, calendar: calendar).subtitle,
                songs: daylist,
                kind: .daylist
            ),
            PersonalizedMix(
                id: "repeat-listening",
                title: String(localized: "반복 듣기"),
                subtitle: String(localized: "자주 찾는 곡을 한데 모았어요"),
                songs: repeatSongs,
                kind: .repeatListening
            ),
            PersonalizedMix(
                id: "listen-again",
                title: String(localized: "한 번 더 듣기"),
                subtitle: String(localized: "최근 취향을 다시 이어 들어보세요"),
                songs: listenAgain,
                kind: .listenAgain
            ),
            PersonalizedMix(
                id: "pop-mix",
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
                id: "k-pop-mix",
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

        for (index, artist) in affinityArtists.enumerated() {
            mixes.append(
                artistMix(
                    artist: artist,
                    pool: pool,
                    seed: dailySeed + 53 + index * 7,
                    limit: songLimit
                )
            )
        }

        mixes.append(contentsOf: [
            moodMix(
                id: "happy-mix",
                title: "Happy Mix",
                subtitle: String(localized: "기분을 환하게 만드는 음악"),
                tokens: ["happy", "smile", "joy", "summer", "disco", "funk", "행복", "여름"],
                pool: pool,
                seed: dailySeed + 61,
                limit: songLimit
            ),
            moodMix(
                id: "upbeat-mix",
                title: "Upbeat Mix",
                subtitle: String(localized: "에너지가 필요한 순간을 위한 음악"),
                tokens: ["dance", "edm", "electronic", "rock", "hip hop", "upbeat", "댄스"],
                pool: pool,
                seed: dailySeed + 67,
                limit: songLimit
            ),
            moodMix(
                id: "love-mix",
                title: "Love Mix",
                subtitle: String(localized: "사랑과 설렘을 담은 음악"),
                tokens: ["love", "romantic", "romance", "r&b", "soul", "ballad", "사랑"],
                pool: pool,
                seed: dailySeed + 71,
                limit: songLimit
            ),
            moodMix(
                id: "chill-mix",
                title: "Chill Mix",
                subtitle: String(localized: "편안하게 흐르는 차분한 음악"),
                tokens: ["chill", "ambient", "acoustic", "jazz", "lo-fi", "indie", "잔잔"],
                pool: pool,
                seed: dailySeed + 79,
                limit: songLimit
            )
        ])

        return mixes.filter { !$0.songs.isEmpty }
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
            title: String(localized: "많이 들은 곡 순위"),
            subtitle: String(localized: "서버와 청취 기록을 반영한 순위"),
            songs: songs,
            kind: .ranking
        )
    }

    private static func artistMix(
        artist: String,
        pool: [Song],
        seed: Int,
        limit: Int
    ) -> PersonalizedMix {
        let normalizedArtist = normalized(artist)
        let primary = ordered(
            pool.filter { normalized($0.artist) == normalizedArtist },
            seed: seed
        )
        let primaryGenres = Set(primary.compactMap { $0.genre.map(normalized) })
        let related = ordered(
            pool.filter { song in
                guard normalized(song.artist) != normalizedArtist else { return false }
                if let genre = song.genre {
                    return primaryGenres.contains(normalized(genre))
                }
                return true
            },
            seed: seed + 7
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
            from: primary + related + pool,
            seed: seed,
            limit: limit
        )
        return PersonalizedMix(
            id: "artist-\(stableHash(artist, seed: 0))",
            title: "\(artist) Mix",
            subtitle: String(
                format: String(localized: "%@ 음악과 비슷한 곡"),
                artist
            ),
            songs: songs,
            kind: .artist
        )
    }

    private static func moodMix(
        id: String,
        title: String,
        subtitle: String,
        tokens: [String],
        pool: [Song],
        seed: Int,
        limit: Int
    ) -> PersonalizedMix {
        let matches = pool.filter {
            containsAny(searchableText($0), tokens: tokens)
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
        Array(
            unique(
                ordered(preferred, seed: seed) +
                ordered(pool, seed: seed + 97)
            )
            .prefix(limit)
        )
    }

    private static func ordered(_ songs: [Song], seed: Int) -> [Song] {
        unique(songs).sorted {
            stableHash($0.id, seed: seed) < stableHash($1.id, seed: seed)
        }
    }

    private static func unique(_ songs: [Song]) -> [Song] {
        var ids = Set<String>()
        return songs.filter { ids.insert($0.id).inserted }
    }

    private static func searchableText(_ song: Song) -> String {
        normalized(
            [song.genre, song.title, song.album, song.artist]
                .compactMap { $0 }
                .joined(separator: " ")
        )
    }

    private static func containsAny(_ value: String, tokens: [String]) -> Bool {
        tokens.contains { value.contains(normalized($0)) }
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 24
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 2 * 1_024 * 1_024,
            diskCapacity: 12 * 1_024 * 1_024
        )
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.allowsConstrainedNetworkAccess = false
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
    let release: NamedValue?
}
