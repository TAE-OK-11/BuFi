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

    var isStarred: Bool { starred != nil }
    var safeDuration: Double { max(0, duration ?? 0) }
}

struct Album: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var artist: String
    var coverArt: String?
    var year: Int?
    var starred: String?

    var isStarred: Bool { starred != nil }
}

struct Artist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var coverArt: String?
    var albumCount: Int?
    var starred: String?

    var isStarred: Bool { starred != nil }
}

struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var owner: String?
    var songCount: Int?
    var coverArt: String?
}

struct HomeSnapshot: Equatable, Sendable {
    var recentAlbums: [Album] = []
    var randomAlbums: [Album] = []
    var starredAlbums: [Album] = []
    var starredSongs: [Song] = []
    var starredArtists: [Artist] = []
    var artists: [Artist] = []
    var randomSongs: [Song] = []
    var playlists: [Playlist] = []

    static let empty = HomeSnapshot()
}

struct SearchResults: Sendable {
    var artists: [Artist] = []
    var albums: [Album] = []
    var songs: [Song] = []

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
    static let empty = SearchResults()
}

struct AlbumDetail: Sendable {
    var songs: [Song]
}

struct PlaylistDetail: Sendable {
    var songs: [Song]
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
    let song: [Song]?
}

struct PlaylistPayload: Decodable {
    let playlist: PlaylistWithSongs?
}

struct PlaylistWithSongs: Decodable {
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
