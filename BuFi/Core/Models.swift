import Foundation

struct ServerCredentials: Codable, Equatable, Sendable {
    var serverURL: String
    var username: String
    var password: String
}

enum StreamQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case aac320
    case opus160
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "자동")
        case .aac320: "AAC 320kbps"
        case .opus160: "Opus 160kbps"
        case .original: String(localized: "원본 무손실")
        }
    }

    var parameters: [String: String] {
        switch self {
        case .automatic: [:]
        case .aac320: ["format": "aac", "maxBitRate": "320"]
        case .opus160: ["format": "opus", "maxBitRate": "160"]
        case .original: ["format": "raw", "maxBitRate": "0"]
        }
    }
}

enum RepeatMode: String, Codable, Sendable {
    case off
    case all
    case one
}

enum ShuffleStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case fewerRepeats
    case standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fewerRepeats: String(localized: "반복 줄이기")
        case .standard: String(localized: "기본 셔플")
        }
    }
}

struct Song: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var artistId: String?
    var albumId: String?
    var coverArt: String?
    var duration: Double?
    var track: Int?
    var suffix: String?
    var contentType: String?
    var starred: String?
    var playCount: Int? = nil
    var played: String? = nil
    var genre: String? = nil
    var genres: [SongGenre]? = nil
    var musicBrainzId: String? = nil
    var isrc: [String]? = nil
    var bpm: Int? = nil
    var moods: [String]? = nil
    var created: String? = nil
    var externalStreamURL: String? = nil

    var isStarred: Bool { starred != nil }
    var safeDuration: Double { max(0, duration ?? 0) }

    /// OpenSubsonic identifiers are opaque, but an empty or whitespace-only
    /// `coverArt` value is equivalent to no artwork. Keeping one normalized
    /// identity prevents visually identical missing values from producing
    /// different cache and SwiftUI task identities.
    var artworkID: String? {
        guard let value = coverArt?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Stable across processes and launches, unlike Swift's randomized
    /// `Hashable` seed. This revision lets playback consumers agree that the
    /// metadata, artwork reference, and stream hints belong to one snapshot.
    var playbackMetadataRevision: String {
        stableMediaRevision([
            id,
            title,
            artist,
            album,
            artistId ?? "",
            albumId ?? "",
            artworkID ?? "",
            duration.map { String($0) } ?? "",
            track.map { String($0) } ?? "",
            suffix ?? "",
            contentType ?? "",
            created ?? "",
            externalStreamURL ?? ""
        ])
    }

    /// Identifies the playable bytes without coupling transport caches to
    /// mutable display metadata such as title, artist, or cover art.
    var audioResourceRevision: String {
        stableMediaRevision([
            id,
            duration.map { String($0) } ?? "",
            suffix ?? "",
            contentType ?? "",
            created ?? ""
        ])
    }

    /// Server creation metadata is the only stable signal available for a
    /// durable downloaded resource. Missing hints remain compatible with a
    /// legacy cache instead of treating an incomplete search row as a change.
    var offlineMediaRevision: String? {
        guard let created = created?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !created.isEmpty else { return nil }
        return stableMediaRevision([id, created])
    }

    /// Artwork deliberately excludes mutable social state such as `starred`
    /// so liking a song never invalidates an otherwise identical image.
    var artworkRevision: String {
        stableMediaRevision([
            albumId ?? "",
            artworkID ?? "",
            created ?? ""
        ])
    }

    private func stableMediaRevision(_ fields: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for field in fields {
            for byte in field.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0xff
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct PlaybackArtworkReference: Equatable, Hashable, Sendable {
    let id: String?
    let revision: String
}

/// Exact visual identity for one committed now-playing occurrence. Views use
/// this value as both their async-result gate and SwiftUI identity so artwork
/// from another play attempt can never be reused as the current cover.
struct PlayerArtworkIdentity: Equatable, Hashable, Sendable {
    let playbackGenerationID: UUID
    let queueEntryID: UUID
    let songID: String
    let coverArtID: String?
    let artworkRevision: String
    let accountScope: String?
}

struct PlaybackStreamReference: Equatable, Hashable, Sendable {
    let songID: String
    let externalURL: String?
    let sourceSuffix: String?
    let contentType: String?
}

/// One logical queue occurrence. Duplicate server song IDs remain distinct so
/// late artwork, metadata, and transport work can be validated against the
/// exact queue entry that requested it.
struct PlaybackQueueEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var song: Song

    init(song: Song, queueEntryID: UUID = UUID()) {
        id = queueEntryID
        self.song = song
    }
}

/// One atomic now-playing value. The occurrence ID distinguishes two
/// consecutive plays of the same server song, while the nested references
/// guarantee that artwork and stream work are derived from the same metadata
/// snapshot rather than independently sampled mutable state.
struct PlaybackMediaItem: Identifiable, Equatable, Sendable {
    /// Changes for every concrete playback attempt, even when the same durable
    /// queue entry is replayed.
    let id: UUID
    /// Stable identity of the queue row. This is persisted and survives
    /// reordering independently of the active playback generation above.
    let queueEntryID: UUID
    let accountScope: String?
    var song: Song

    init(
        song: Song,
        accountScope: String?,
        queueEntryID: UUID = UUID(),
        playbackGenerationID: UUID = UUID()
    ) {
        id = playbackGenerationID
        self.queueEntryID = queueEntryID
        self.accountScope = accountScope
        self.song = song
    }

    var metadataRevision: String { song.playbackMetadataRevision }

    var artwork: PlaybackArtworkReference {
        PlaybackArtworkReference(
            id: song.artworkID,
            revision: song.artworkRevision
        )
    }

    var artworkIdentity: PlayerArtworkIdentity {
        PlayerArtworkIdentity(
            playbackGenerationID: id,
            queueEntryID: queueEntryID,
            songID: song.id,
            coverArtID: artwork.id,
            artworkRevision: artwork.revision,
            accountScope: accountScope
        )
    }

    var stream: PlaybackStreamReference {
        PlaybackStreamReference(
            songID: song.id,
            externalURL: song.externalStreamURL,
            sourceSuffix: song.suffix,
            contentType: song.contentType
        )
    }
}

extension Song {
    private enum CodingKeys: String, CodingKey {
        case id, title, artist, album, artistId, albumId, coverArt, duration
        case track, suffix, contentType, starred, playCount, played, genre
        case genres, musicBrainzId, isrc, bpm, moods, created
        case externalStreamURL
    }

    /// OpenSubsonic Child allows artist and album to be omitted. Decoding them
    /// as empty display values keeps one incomplete child from invalidating an
    /// otherwise usable search, playlist, or home response.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try values.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try values.decodeIfPresent(String.self, forKey: .album) ?? ""
        artistId = try values.decodeIfPresent(String.self, forKey: .artistId)
        albumId = try values.decodeIfPresent(String.self, forKey: .albumId)
        coverArt = try values.decodeIfPresent(String.self, forKey: .coverArt)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        track = try values.decodeIfPresent(Int.self, forKey: .track)
        suffix = try values.decodeIfPresent(String.self, forKey: .suffix)
        contentType = try values.decodeIfPresent(String.self, forKey: .contentType)
        starred = try values.decodeIfPresent(String.self, forKey: .starred)
        playCount = try values.decodeIfPresent(Int.self, forKey: .playCount)
        played = try values.decodeIfPresent(String.self, forKey: .played)
        genre = try values.decodeIfPresent(String.self, forKey: .genre)
        genres = try values.decodeIfPresent([SongGenre].self, forKey: .genres)
        musicBrainzId = try values.decodeIfPresent(String.self, forKey: .musicBrainzId)
        isrc = try values.decodeIfPresent([String].self, forKey: .isrc)
        bpm = try values.decodeIfPresent(Int.self, forKey: .bpm)
        moods = try values.decodeIfPresent([String].self, forKey: .moods)
        created = try values.decodeIfPresent(String.self, forKey: .created)
        externalStreamURL = try values.decodeIfPresent(
            String.self,
            forKey: .externalStreamURL
        )
    }
}

struct SongGenre: Codable, Hashable, Sendable {
    let name: String
}

struct Album: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var artist: String
    var coverArt: String?
    var year: Int?
    var starred: String?
    var playCount: Int? = nil
    var played: String? = nil
    var artistId: String? = nil
    var genre: String? = nil
    var musicBrainzId: String? = nil
    var songCount: Int? = nil
    var releaseTypes: [String]? = nil

    var isStarred: Bool { starred != nil }
}

struct Artist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var coverArt: String?
    var albumCount: Int?
    var starred: String?
    var musicBrainzId: String? = nil

    var isStarred: Bool { starred != nil }
}

struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var owner: String?
    var songCount: Int?
    var coverArt: String?
}

struct InternetRadioStation: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var streamUrl: String
    var coverArt: String?

    var playableSong: Song {
        Song(
            id: "radio:\(id)",
            title: name,
            artist: String(localized: "인터넷 라디오"),
            album: "",
            artistId: nil,
            albumId: nil,
            coverArt: coverArt,
            duration: nil,
            track: nil,
            suffix: nil,
            contentType: nil,
            starred: nil,
            externalStreamURL: streamUrl
        )
    }
}

struct HomeSnapshot: Codable, Equatable, Sendable {
    var recentAlbums: [Album] = []
    var recentlyPlayedAlbums: [Album] = []
    var frequentAlbums: [Album] = []
    var randomAlbums: [Album] = []
    var starredAlbums: [Album] = []
    var starredSongs: [Song] = []
    var starredArtists: [Artist] = []
    var artists: [Artist] = []
    var randomSongs: [Song] = []
    var sonicRecommendedSongs: [Song] = []
    var similarArtistSongs: [Song] = []
    var genreRecommendedSongs: [Song] = []
    var topArtistSongs: [Song] = []
    var recentlyAddedSongs: [Song] = []
    var popularSongs: [Song] = []
    var playlistAffinitySongs: [Song] = []
    var serverRecommendedSongs: [Song] = []
    var lastFMRecommendedSongs: [Song] = []
    var listenBrainzRecommendedSongs: [Song] = []
    var recommendedSongs: [Song] = []
    var daylistSongs: [Song] = []
    var offlineBackupSongs: [Song] = []
    var mostPlayedSongs: [Song] = []
    var recommendedArtists: [Artist] = []
    var playlists: [Playlist] = []
    var radioStations: [InternetRadioStation] = []

    static let empty = HomeSnapshot()

    func knownSongs() -> [Song] {
        MediaIdentity.uniqueSongs(
            from: Self.songCollections.map { self[keyPath: $0] }
        )
    }

    // WritableKeyPath is a class and is not Sendable. These tables are
    // immutable after initialization and only used as collection indexes.
    nonisolated(unsafe) static let songCollections:
        [WritableKeyPath<HomeSnapshot, [Song]>] = [
        \.starredSongs,
        \.randomSongs,
        \.sonicRecommendedSongs,
        \.similarArtistSongs,
        \.genreRecommendedSongs,
        \.topArtistSongs,
        \.recentlyAddedSongs,
        \.popularSongs,
        \.playlistAffinitySongs,
        \.serverRecommendedSongs,
        \.lastFMRecommendedSongs,
        \.listenBrainzRecommendedSongs,
        \.recommendedSongs,
        \.daylistSongs,
        \.offlineBackupSongs,
        \.mostPlayedSongs
    ]

    nonisolated(unsafe) static let albumCollections:
        [WritableKeyPath<HomeSnapshot, [Album]>] = [
        \.recentAlbums,
        \.recentlyPlayedAlbums,
        \.frequentAlbums,
        \.randomAlbums,
        \.starredAlbums
    ]

    nonisolated(unsafe) static let artistCollections:
        [WritableKeyPath<HomeSnapshot, [Artist]>] = [
        \.starredArtists,
        \.artists,
        \.recommendedArtists
    ]

    mutating func mapSongs(_ transform: (Song) -> Song) {
        for path in Self.songCollections {
            self[keyPath: path] = self[keyPath: path].map(transform)
        }
    }

    mutating func mapAlbums(_ transform: (Album) -> Album) {
        for path in Self.albumCollections {
            self[keyPath: path] = self[keyPath: path].map(transform)
        }
    }

    mutating func mapArtists(_ transform: (Artist) -> Artist) {
        for path in Self.artistCollections {
            self[keyPath: path] = self[keyPath: path].map(transform)
        }
    }

    mutating func adoptServerEnrichment(from other: HomeSnapshot) {
        sonicRecommendedSongs = other.sonicRecommendedSongs
        similarArtistSongs = other.similarArtistSongs
        genreRecommendedSongs = other.genreRecommendedSongs
        topArtistSongs = other.topArtistSongs
        recentlyAddedSongs = other.recentlyAddedSongs
        popularSongs = other.popularSongs
        playlistAffinitySongs = other.playlistAffinitySongs
        serverRecommendedSongs = other.serverRecommendedSongs
        recommendedSongs = other.recommendedSongs
        mostPlayedSongs = other.mostPlayedSongs
        recommendedArtists = other.recommendedArtists
    }
}

enum MediaIdentity {
    static func uniqueSongs(
        _ songs: [Song],
        limit: Int = .max
    ) -> [Song] {
        unique(songs, id: \.id, limit: limit)
    }

    static func uniqueSongs(
        from sources: [[Song]],
        limit: Int = .max
    ) -> [Song] {
        guard limit > 0 else { return [] }
        let capacity = min(limit, sources.reduce(into: 0) { $0 += $1.count })
        var ids = Set<String>()
        ids.reserveCapacity(capacity)
        var result: [Song] = []
        result.reserveCapacity(capacity)
        var visited = 0
        for source in sources {
            for song in source {
                if visited.isMultiple(of: 64), Task.isCancelled { return [] }
                visited += 1
                if ids.insert(song.id).inserted {
                    result.append(song)
                    if result.count == limit { return result }
                }
            }
        }
        return result
    }

    static func uniqueArtists(_ artists: [Artist]) -> [Artist] {
        unique(artists, id: \.id)
    }

    static func unique<Value, ID: Hashable>(
        _ values: [Value],
        id: (Value) -> ID,
        limit: Int = .max
    ) -> [Value] {
        guard limit > 0 else { return [] }
        var seen = Set<ID>()
        seen.reserveCapacity(min(limit, values.count))
        var result: [Value] = []
        result.reserveCapacity(min(limit, values.count))
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return [] }
            if seen.insert(id(value)).inserted {
                result.append(value)
                if result.count == limit { return result }
            }
        }
        return result
    }
}

/// Same artist + same title is one recording. Live/acoustic siblings stay
/// in the pool but should not sit next to each other in a radio block.
enum TrackWorkIdentity {
    static func recordingKey(for song: Song) -> String {
        "\(normalized(song.artist))\u{1e}\(normalized(song.title))"
    }

    static func workKey(for song: Song) -> String {
        "\(normalized(song.artist))\u{1e}\(coreTitle(song.title))"
    }

    static func uniqueRecordings(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        var result: [Song] = []
        result.reserveCapacity(songs.count)
        for song in songs {
            let key = recordingKey(for: song)
            guard !key.hasPrefix("\u{1e}"), seen.insert(key).inserted else {
                continue
            }
            result.append(song)
        }
        return result
    }

    static func isNearVariant(
        _ song: Song,
        of recent: [Song],
        window: Int = 2
    ) -> Bool {
        let key = workKey(for: song)
        guard key.split(separator: "\u{1e}").count == 2 else { return false }
        return recent.suffix(window).contains { workKey(for: $0) == key }
    }

    static func editionRank(for song: Song) -> Int {
        let blob = editionText(song.title) + " " + editionText(song.album)
        if blob.contains("taylors version") || blob.contains("from the vault") {
            return 3
        }
        if blob.contains("remake") || blob.contains("리메이크")
            || blob.contains("rerecord") || blob.contains("re record") {
            return 2
        }
        return 1
    }

    static func prefers(_ song: Song, over other: Song) -> Bool {
        editionRank(for: song) > editionRank(for: other)
    }

    static func coreTitle(_ title: String) -> String {
        var value = editionText(title)
        var changed = true
        while changed {
            changed = false
            if let range = trailingWrappedRange(in: value) {
                let inner = editionText(String(value[range]))
                if containsVariantMarker(inner) {
                    value = value[..<range.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    continue
                }
            }
            if let dash = value.range(of: " - ", options: .backwards) {
                let tail = editionText(String(value[dash.upperBound...]))
                if containsVariantMarker(tail) {
                    value = value[..<dash.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }
        return value
    }

    private static func editionText(_ value: String) -> String {
        normalized(value)
            .replacingOccurrences(of: "['’‘`´]", with: "", options: .regularExpression)
    }

    private static func containsVariantMarker(_ value: String) -> Bool {
        let markers = [
            "live", "acoustic", "어쿠스틱", "라이브", "remix", "mix",
            "instrumental", "inst", "demo", "unplugged", "radio edit",
            "remaster", "remastered", "version", "ver", "session",
            "piano", "stripped", "reprise", "bonus",
            "taylors version", "from the vault",
            "remake", "리메이크", "rerecord", "re record"
        ]
        return markers.contains { value.contains($0) }
    }

    private static func trailingWrappedRange(
        in value: String
    ) -> Range<String.Index>? {
        let pairs: [(Character, Character)] = [("(", ")"), ("[", "]"), ("{", "}")]
        for (open, close) in pairs {
            guard value.last == close,
                  let start = value.lastIndex(of: open) else {
                continue
            }
            return start..<value.endIndex
        }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Collision-safe identity for an in-memory home snapshot. The generation is
/// monotonic within one HomeLibraryState, while the epoch prevents static
/// presentation/recommendation caches from reusing a prior model instance.
struct HomeSnapshotRevision: Hashable, Sendable {
    let epoch: UUID
    let generation: UInt64

    init(epoch: UUID = UUID(), generation: UInt64 = 0) {
        self.epoch = epoch
        self.generation = generation
    }

    func advanced() -> HomeSnapshotRevision {
        HomeSnapshotRevision(epoch: epoch, generation: generation &+ 1)
    }
}

struct HomeLoadResult: Sendable {
    var snapshot: HomeSnapshot
    var hasAuthoritativeStarredState: Bool
}

struct SearchResults: Equatable, Sendable {
    var artists: [Artist] = []
    var albums: [Album] = []
    var songs: [Song] = []

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
    static let empty = SearchResults()
}

struct AlbumDetail: Sendable {
    var songs: [Song]
    var album: Album? = nil
}

struct PlaylistDetail: Sendable {
    var songs: [Song]
    var playlist: Playlist? = nil
}

struct ArtistDetail: Sendable {
    var artist: Artist
    var albums: [Album]
    var topSongs: [Song]
    var info: ArtistInfo?
}

struct LyricLine: Identifiable, Hashable, Sendable {
    let id: Int
    let start: TimeInterval
    let text: String
}

struct LyricsDocument: Equatable, Sendable {
    var synced: Bool
    var lines: [LyricLine]

    static let empty = LyricsDocument(synced: false, lines: [])
}

struct ServerPlayQueue: Sendable {
    var songs: [Song]
    var currentID: String?
    var position: TimeInterval
}

struct APIErrorBody: Decodable, Sendable {
    let code: Int?
    let message: String?
}

struct StatusEnvelope: Decodable, Sendable {
    let response: StatusBody

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

struct StatusBody: Decodable, Sendable {
    let status: String
    let version: String?
    let serverVersion: String?
    let error: APIErrorBody?
}

struct APIEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let response: Payload

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

struct EmptyPayload: Decodable, Sendable {}

struct AlbumListPayload: Decodable, Sendable {
    let albumList2: AlbumListContainer?
}

struct AlbumListContainer: Decodable, Sendable {
    let album: [Album]?
}

struct RandomSongsPayload: Decodable, Sendable {
    let randomSongs: SongContainer?
}

struct SongPayload: Decodable, Sendable {
    let song: Song?
}

struct SongsByGenrePayload: Decodable, Sendable {
    let songsByGenre: SongContainer?
}

struct GenresPayload: Decodable, Sendable {
    let genres: GenreContainer?
}

struct GenreContainer: Decodable, Sendable {
    let genre: [ServerGenre]?
}

struct ServerGenre: Decodable, Sendable {
    let value: String
    let songCount: Int?
    let albumCount: Int?
}

struct OpenSubsonicExtensionsPayload: Decodable, Sendable {
    let openSubsonicExtensions: [OpenSubsonicExtension]?
}

struct OpenSubsonicExtension: Decodable, Sendable {
    let name: String
    let versions: [Int]
}

struct SimilarSongsPayload: Decodable, Sendable {
    let similarSongs2: SongContainer?
    let similarSongs: SongContainer?
}

struct SonicSimilarPayload: Decodable, Sendable {
    let sonicMatch: [SonicMatch]?
}

struct SonicMatch: Decodable, Sendable {
    let entry: Song
    let similarity: Double?
}

struct InternetRadioStationsPayload: Decodable, Sendable {
    let internetRadioStations: InternetRadioStationContainer?
}

struct InternetRadioStationContainer: Decodable, Sendable {
    let internetRadioStation: [InternetRadioStation]?
}

struct SongContainer: Decodable, Sendable {
    let song: [Song]?
}

struct StarredPayload: Decodable, Sendable {
    let starred2: StarredContainer?
}

struct StarredContainer: Decodable, Sendable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
}

struct PlaylistsPayload: Decodable, Sendable {
    let playlists: PlaylistContainer?
}

struct PlaylistContainer: Decodable, Sendable {
    let playlist: [Playlist]?
}

struct AlbumPayload: Decodable, Sendable {
    let album: AlbumWithSongs?
}

struct AlbumWithSongs: Decodable, Sendable {
    let id: String?
    let name: String?
    let artist: String?
    let coverArt: String?
    let year: Int?
    let starred: String?
    let songCount: Int?
    let song: [Song]?
}

struct PlaylistPayload: Decodable, Sendable {
    let playlist: PlaylistWithSongs?
}

struct PlaylistWithSongs: Decodable, Sendable {
    let id: String?
    let name: String?
    let owner: String?
    let songCount: Int?
    let coverArt: String?
    let entry: [Song]?
}

struct SearchPayload: Decodable, Sendable {
    let searchResult3: SearchContainer?
    let searchResult2: SearchContainer?
}

struct SearchContainer: Decodable, Sendable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
}


struct ArtistInfoPayload: Decodable, Sendable {
    let artistInfo2: ArtistInfo?
}

struct ArtistInfo: Decodable, Sendable {
    let biography: String?
    let similarArtist: [Artist]?
}

struct ArtistAlbumsPayload: Decodable, Sendable {
    let artist: ArtistWithAlbums?
}

struct ArtistsPayload: Decodable, Sendable {
    let artists: ArtistsContainer?
}

struct ArtistsContainer: Decodable, Sendable {
    let index: [ArtistIndex]?
}

struct ArtistIndex: Decodable, Sendable {
    let artist: [Artist]?
}

struct ArtistWithAlbums: Decodable, Sendable {
    let id: String
    let name: String
    let coverArt: String?
    let albumCount: Int?
    let starred: String?
    let album: [Album]?

    var artistValue: Artist {
        Artist(
            id: id,
            name: name,
            coverArt: coverArt,
            albumCount: albumCount,
            starred: starred
        )
    }
}

struct TopSongsPayload: Decodable, Sendable {
    let topSongs: SongContainer?
}

struct LyricsPayload: Decodable, Sendable {
    let lyricsList: LyricsList?
}

struct LegacyLyricsPayload: Decodable, Sendable {
    let lyrics: LegacyLyrics?
}

struct LegacyLyrics: Decodable, Sendable {
    let artist: String?
    let title: String?
    let value: String?
}

struct LyricsList: Decodable, Sendable {
    let structuredLyrics: [StructuredLyrics]?
}

struct StructuredLyrics: Decodable, Sendable {
    let lang: String?
    let offset: Int?
    let synced: Bool?
    let line: [StructuredLyricLine]?
}

struct StructuredLyricLine: Decodable, Sendable {
    let start: Int?
    let value: String?
}

struct PlayQueuePayload: Decodable, Sendable {
    let playQueue: PlayQueueContainer?
}

struct PlayQueueContainer: Decodable, Sendable {
    let current: String?
    let position: Int?
    let entry: [Song]?
}
