import Foundation

/// Local-only recent search history. Never calls the server.
enum RecentSearchStore {
    static let storageKey = "search-recent-items-v1"
    static let maximumCount = 16

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    static func decode(_ value: String) -> [RecentSearchItem] {
        guard let data = value.data(using: .utf8),
              let items = try? decoder.decode([RecentSearchItem].self, from: data) else {
            return []
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
            .prefix(maximumCount)
            .map { $0 }
    }

    static func encode(_ items: [RecentSearchItem]) -> String {
        let trimmed = Array(items.prefix(maximumCount))
        guard let data = try? encoder.encode(trimmed),
              let encoded = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return encoded
    }

    static func recording(_ item: RecentSearchItem, into value: String) -> String {
        let next = [item] + decode(value).filter { $0.id != item.id }
        return encode(next)
    }

    static func removing(id: String, from value: String) -> String {
        encode(decode(value).filter { $0.id != id })
    }
}

struct RecentSearchItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case query
        case artist
        case album
        case song
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let coverArt: String?
    let queryText: String?
    let artist: Artist?
    let album: Album?
    let song: Song?

    static func query(_ text: String) -> RecentSearchItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RecentSearchItem(
            id: "query:\(trimmed.lowercased())",
            kind: .query,
            title: trimmed,
            subtitle: "검색",
            coverArt: nil,
            queryText: trimmed,
            artist: nil,
            album: nil,
            song: nil
        )
    }

    static func artist(_ artist: Artist) -> RecentSearchItem {
        RecentSearchItem(
            id: "artist:\(artist.id)",
            kind: .artist,
            title: artist.name,
            subtitle: String(localized: "아티스트"),
            coverArt: artist.coverArt,
            queryText: nil,
            artist: artist,
            album: nil,
            song: nil
        )
    }

    static func album(_ album: Album) -> RecentSearchItem {
        RecentSearchItem(
            id: "album:\(album.id)",
            kind: .album,
            title: album.name,
            subtitle: "앨범 · \(album.artist)",
            coverArt: album.coverArt,
            queryText: nil,
            artist: nil,
            album: album,
            song: nil
        )
    }

    static func song(_ song: Song) -> RecentSearchItem {
        RecentSearchItem(
            id: "song:\(song.id)",
            kind: .song,
            title: song.title,
            subtitle: "곡 · \(song.artist)",
            coverArt: song.coverArt,
            queryText: nil,
            artist: nil,
            album: nil,
            song: song
        )
    }
}
