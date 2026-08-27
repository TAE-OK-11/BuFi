import Foundation

struct LocalLibrarySearchSong: Sendable, Equatable {
    let song: Song
    let normalizedTitle: String
    let normalizedArtist: String
    let normalizedAlbum: String
}

struct LocalLibrarySearchAlbum: Sendable, Equatable {
    let album: Album
    let normalizedName: String
    let normalizedArtist: String
}

struct LocalLibrarySearchArtist: Sendable, Equatable {
    let artist: Artist
    let normalizedName: String
}

/// Pre-deduplicated local search pool built once per home snapshot refresh.
struct LocalLibrarySearchCorpus: Sendable, Equatable {
    let songs: [LocalLibrarySearchSong]
    let albums: [LocalLibrarySearchAlbum]
    let artists: [LocalLibrarySearchArtist]

    static let empty = LocalLibrarySearchCorpus(
        songs: [],
        albums: [],
        artists: []
    )

    static func make(from snapshot: HomeSnapshot) -> LocalLibrarySearchCorpus {
        LocalLibrarySearchCorpus(
            songs: MediaIdentity.uniqueSongs(
                from: HomeSnapshot.songCollections.map { snapshot[keyPath: $0] },
                limit: 400
            ).map { song in
                LocalLibrarySearchSong(
                    song: song,
                    normalizedTitle: normalized(song.title),
                    normalizedArtist: normalized(song.artist),
                    normalizedAlbum: normalized(song.album)
                )
            },
            albums: MediaIdentity.unique(
                HomeSnapshot.albumCollections.flatMap { snapshot[keyPath: $0] },
                id: \.id
            ).map { album in
                LocalLibrarySearchAlbum(
                    album: album,
                    normalizedName: normalized(album.name),
                    normalizedArtist: normalized(album.artist)
                )
            },
            artists: MediaIdentity.uniqueArtists(
                HomeSnapshot.artistCollections.flatMap { snapshot[keyPath: $0] }
            ).map { artist in
                LocalLibrarySearchArtist(
                    artist: artist,
                    normalizedName: normalized(artist.name)
                )
            }
        )
    }

    @concurrent
    static func makeConcurrently(
        from snapshot: HomeSnapshot
    ) async -> LocalLibrarySearchCorpus {
        guard !Task.isCancelled else { return .empty }
        let value = make(from: snapshot)
        return Task.isCancelled ? .empty : value
    }
}

/// Local fallback over the already-loaded home snapshot. Search stays useful
/// when the server is slow or unreachable, and while the user is still typing.
enum LocalLibrarySearch {
    static func results(
        for rawQuery: String,
        in corpus: LocalLibrarySearchCorpus,
        artistLimit: Int = 8,
        albumLimit: Int = 14,
        songLimit: Int = 30
    ) -> SearchResults {
        let query = PreparedSearchQuery(rawQuery)
        guard !query.value.isEmpty else { return .empty }

        return SearchResults(
            artists: ranked(corpus.artists, limit: artistLimit) { entry in
                fieldMatch(entry.normalizedName, query: query, field: 0)
            }.map(\.artist),
            albums: ranked(corpus.albums, limit: albumLimit) { entry in
                bestFieldMatch(
                    fieldMatch(entry.normalizedName, query: query, field: 0),
                    fieldMatch(entry.normalizedArtist, query: query, field: 1)
                )
            }.map(\.album),
            songs: ranked(corpus.songs, limit: songLimit) { entry in
                bestFieldMatch(
                    fieldMatch(entry.normalizedTitle, query: query, field: 0),
                    fieldMatch(entry.normalizedArtist, query: query, field: 1),
                    fieldMatch(entry.normalizedAlbum, query: query, field: 2)
                )
            }.map(\.song)
        )
    }

    @concurrent
    static func resultsConcurrently(
        for rawQuery: String,
        in corpus: LocalLibrarySearchCorpus,
        artistLimit: Int = 8,
        albumLimit: Int = 14,
        songLimit: Int = 30
    ) async -> SearchResults {
        guard !Task.isCancelled else { return .empty }
        let value = results(
            for: rawQuery,
            in: corpus,
            artistLimit: artistLimit,
            albumLimit: albumLimit,
            songLimit: songLimit
        )
        return Task.isCancelled ? .empty : value
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
    _ haystack: String,
    query: PreparedSearchQuery
) -> SearchMatchRank? {
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
    _ haystack: String,
    query: PreparedSearchQuery,
    field: Int
) -> FieldMatch? {
    matches(haystack, query: query).map { FieldMatch(match: $0, field: field) }
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
