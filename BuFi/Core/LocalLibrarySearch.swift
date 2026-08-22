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
        let query = PreparedSearchQuery(rawQuery)
        guard !query.value.isEmpty else { return .empty }

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
            artists: ranked(artists, limit: artistLimit) {
                fieldMatch($0.name, query: query, field: 0)
            },
            albums: ranked(albums, limit: albumLimit) { album in
                bestFieldMatch(
                    fieldMatch(album.name, query: query, field: 0),
                    fieldMatch(album.artist, query: query, field: 1)
                )
            },
            songs: ranked(songs, limit: songLimit) { song in
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

private enum SearchMatchRank: Int, Comparable, Hashable {
    case exact = 0
    case prefix = 1
    case contains = 2

    static func < (lhs: SearchMatchRank, rhs: SearchMatchRank) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

private struct FieldMatch: Comparable, Hashable {
    let match: SearchMatchRank
    let field: Int

    static func < (lhs: FieldMatch, rhs: FieldMatch) -> Bool {
        if lhs.match != rhs.match { return lhs.match < rhs.match }
        return lhs.field < rhs.field
    }
}

private struct PreparedSearchQuery {
    let value: String
    let tokens: [String]

    init(_ rawValue: String) {
        let normalizedValue = normalized(rawValue)
        value = normalizedValue
        tokens = normalizedValue
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}

private func ranked<Item>(
    _ items: [Item],
    limit: Int,
    rank: (Item) -> FieldMatch?
) -> [Item] {
    guard limit > 0 else { return [] }
    // FieldMatch has only a handful of possible ranks. Stable buckets avoid
    // sorting every match when the UI only needs a small prefix.
    var buckets: [FieldMatch: [Item]] = [:]
    for item in items {
        guard let match = rank(item) else { continue }
        buckets[match, default: []].append(item)
    }
    var result: [Item] = []
    result.reserveCapacity(min(limit, items.count))
    for match in buckets.keys.sorted() {
        for item in buckets[match, default: []] {
            result.append(item)
            if result.count == limit { return result }
        }
    }
    return result
}

private func matches(
    _ value: String,
    query: PreparedSearchQuery
) -> SearchMatchRank? {
    let haystack = normalized(value)
    guard !haystack.isEmpty else { return nil }
    if haystack == query.value { return .exact }
    if haystack.hasPrefix(query.value) { return .prefix }
    if haystack.contains(query.value) { return .contains }

    guard query.tokens.count > 1,
          query.tokens.allSatisfy({ haystack.contains($0) }) else {
        return nil
    }
    return .contains
}

private func fieldMatch(
    _ value: String,
    query: PreparedSearchQuery,
    field: Int
) -> FieldMatch? {
    matches(value, query: query).map { FieldMatch(match: $0, field: field) }
}

private func bestFieldMatch(
    _ first: FieldMatch?,
    _ second: FieldMatch?
) -> FieldMatch? {
    guard let first else { return second }
    guard let second else { return first }
    return min(first, second)
}

private func bestFieldMatch(
    _ first: FieldMatch?,
    _ second: FieldMatch?,
    _ third: FieldMatch?
) -> FieldMatch? {
    bestFieldMatch(bestFieldMatch(first, second), third)
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
