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

struct PlaybackStreamReference: Equatable, Hashable, Sendable {
    let songID: String
    let externalURL: String?
    let sourceSuffix: String?
    let contentType: String?
}

/// One atomic now-playing value. The occurrence ID distinguishes two
/// consecutive plays of the same server song, while the nested references
/// guarantee that artwork and stream work are derived from the same metadata
/// snapshot rather than independently sampled mutable state.
struct PlaybackMediaItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let accountScope: String?
    var song: Song

    init(
        song: Song,
        accountScope: String?,
        occurrenceID: UUID = UUID()
    ) {
        id = occurrenceID
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

struct LyricsDocument: Sendable {
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

struct StatusEnvelope: Decodable {
    let response: StatusBody

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

struct StatusBody: Decodable {
    let status: String
    let version: String?
    let serverVersion: String?
    let error: APIErrorBody?
}

struct APIEnvelope<Payload: Decodable>: Decodable {
    let response: Payload

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

struct EmptyPayload: Decodable {}

struct AlbumListPayload: Decodable {
    let albumList2: AlbumListContainer?
}

struct AlbumListContainer: Decodable {
    let album: [Album]?
}

struct RandomSongsPayload: Decodable {
    let randomSongs: SongContainer?
}

struct SongPayload: Decodable {
    let song: Song?
}

struct SongsByGenrePayload: Decodable {
    let songsByGenre: SongContainer?
}

struct GenresPayload: Decodable {
    let genres: GenreContainer?
}

struct GenreContainer: Decodable {
    let genre: [ServerGenre]?
}

struct ServerGenre: Decodable, Sendable {
    let value: String
    let songCount: Int?
    let albumCount: Int?
}

struct OpenSubsonicExtensionsPayload: Decodable {
    let openSubsonicExtensions: [OpenSubsonicExtension]?
}

struct OpenSubsonicExtension: Decodable, Sendable {
    let name: String
    let versions: [Int]
}

struct SimilarSongsPayload: Decodable {
    let similarSongs2: SongContainer?
    let similarSongs: SongContainer?
}

struct SonicSimilarPayload: Decodable {
    let sonicMatch: [SonicMatch]?
}

struct SonicMatch: Decodable {
    let entry: Song
    let similarity: Double?
}

struct InternetRadioStationsPayload: Decodable {
    let internetRadioStations: InternetRadioStationContainer?
}

struct InternetRadioStationContainer: Decodable {
    let internetRadioStation: [InternetRadioStation]?
}

struct SongContainer: Decodable {
    let song: [Song]?
}

struct StarredPayload: Decodable {
    let starred2: StarredContainer?
}

struct StarredContainer: Decodable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
}

struct PlaylistsPayload: Decodable {
    let playlists: PlaylistContainer?
}

struct PlaylistContainer: Decodable {
    let playlist: [Playlist]?
}

struct AlbumPayload: Decodable {
    let album: AlbumWithSongs?
}

struct AlbumWithSongs: Decodable {
    let id: String?
    let name: String?
    let artist: String?
    let coverArt: String?
    let year: Int?
    let starred: String?
    let songCount: Int?
    let song: [Song]?
}

struct PlaylistPayload: Decodable {
    let playlist: PlaylistWithSongs?
}

struct PlaylistWithSongs: Decodable {
    let id: String?
    let name: String?
    let owner: String?
    let songCount: Int?
    let coverArt: String?
    let entry: [Song]?
}

struct SearchPayload: Decodable {
    let searchResult3: SearchContainer?
    let searchResult2: SearchContainer?
}

struct SearchContainer: Decodable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
}


struct ArtistInfoPayload: Decodable {
    let artistInfo2: ArtistInfo?
}

struct ArtistInfo: Decodable, Sendable {
    let biography: String?
    let similarArtist: [Artist]?
}

struct ArtistAlbumsPayload: Decodable {
    let artist: ArtistWithAlbums?
}

struct ArtistsPayload: Decodable {
    let artists: ArtistsContainer?
}

struct ArtistsContainer: Decodable {
    let index: [ArtistIndex]?
}

struct ArtistIndex: Decodable {
    let artist: [Artist]?
}

struct ArtistWithAlbums: Decodable {
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

struct TopSongsPayload: Decodable {
    let topSongs: SongContainer?
}

struct LyricsPayload: Decodable {
    let lyricsList: LyricsList?
}

struct LyricsList: Decodable {
    let structuredLyrics: [StructuredLyrics]?
}

struct StructuredLyrics: Decodable {
    let offset: Int?
    let synced: Bool?
    let line: [StructuredLyricLine]?
}

struct StructuredLyricLine: Decodable {
    let start: Int?
    let value: String?
}

struct PlayQueuePayload: Decodable {
    let playQueue: PlayQueueContainer?
}

struct PlayQueueContainer: Decodable {
    let current: String?
    let position: Int?
    let entry: [Song]?
}
