import Foundation

/// Local fallback over the already-loaded home snapshot. Search stays useful
/// when the server is slow or unreachable, and while the user is still typing.
enum LocalLibrarySearch {
    static func results(
        for rawQuery: String,
        in snapshot: HomeSnapshot,
        artistLimit: Int = 8,
        albumLimit: Int = 14,
        songLimit: Int = 30
    ) -> SearchResults {
        let query = normalized(rawQuery)
        guard !query.isEmpty else { return .empty }

        let songs = MediaIdentity.uniqueSongs(
            from: HomeSnapshot.songCollections.map { snapshot[keyPath: $0] },
            limit: 400
        )
        let albums = MediaIdentity.unique(
            HomeSnapshot.albumCollections.flatMap { snapshot[keyPath: $0] },
            id: \.id
        )
        let artists = MediaIdentity.uniqueArtists(
            HomeSnapshot.artistCollections.flatMap { snapshot[keyPath: $0] }
        )

        return SearchResults(
            artists: ranked(artists, query: query, limit: artistLimit) {
                fieldMatch($0.name, query: query, field: 0)
            },
            albums: ranked(albums, query: query, limit: albumLimit) { album in
                bestFieldMatch(
                    fieldMatch(album.name, query: query, field: 0),
                    fieldMatch(album.artist, query: query, field: 1)
                )
            },
            songs: ranked(songs, query: query, limit: songLimit) { song in
                bestFieldMatch(
                    fieldMatch(song.title, query: query, field: 0),
                    fieldMatch(song.artist, query: query, field: 1),
                    fieldMatch(song.album, query: query, field: 2)
                )
            }
        )
    }
}

enum SearchPresentationPolicy {
    /// Keep the last useful result set on screen while the query is still
    /// growing or shrinking, so typing does not flash an empty search page.
    static func retainedResults(
        previousQuery: String,
        previousResults: SearchResults,
        nextQuery: String
    ) -> SearchResults {
        guard !previousResults.isEmpty else { return .empty }
        let previous = normalized(previousQuery)
        let next = normalized(nextQuery)
        guard !previous.isEmpty, !next.isEmpty else { return .empty }
        if next.hasPrefix(previous) || previous.hasPrefix(next) {
            return previousResults
        }
        return .empty
    }
}

private enum SearchMatchRank: Int, Comparable {
    case exact = 0
    case prefix = 1
    case contains = 2

    static func < (lhs: SearchMatchRank, rhs: SearchMatchRank) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private struct FieldMatch: Comparable {
    let match: SearchMatchRank
    let field: Int

    static func < (lhs: FieldMatch, rhs: FieldMatch) -> Bool {
        if lhs.match != rhs.match { return lhs.match < rhs.match }
        return lhs.field < rhs.field
    }
}

private func ranked<Item>(
    _ items: [Item],
    query: String,
    limit: Int,
    rank: (Item) -> FieldMatch?
) -> [Item] {
    guard limit > 0 else { return [] }
    return Array(
        items.enumerated()
            .compactMap { offset, item -> (Item, FieldMatch, Int)? in
                guard let match = rank(item) else { return nil }
                return (item, match, offset)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.2 < rhs.2
            }
            .prefix(limit)
            .map(\.0)
    )
}

private func matches(_ value: String, query: String) -> SearchMatchRank? {
    let haystack = normalized(value)
    guard !haystack.isEmpty else { return nil }
    if haystack == query { return .exact }
    if haystack.hasPrefix(query) { return .prefix }
    if haystack.contains(query) { return .contains }

    let tokens = query.split(whereSeparator: \.isWhitespace)
    guard tokens.count > 1,
          tokens.allSatisfy({ haystack.contains($0) }) else {
        return nil
    }
    return .contains
}

private func fieldMatch(
    _ value: String,
    query: String,
    field: Int
) -> FieldMatch? {
    matches(value, query: query).map { FieldMatch(match: $0, field: field) }
}

private func bestFieldMatch(_ ranks: FieldMatch?...) -> FieldMatch? {
    ranks.compactMap { $0 }.min()
}

private func normalized(_ value: String) -> String {
    value
        .folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}
