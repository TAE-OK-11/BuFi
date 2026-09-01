import Foundation

/// Precomputed catalog for local search over the home snapshot.
struct LocalLibrarySearchIndex: Sendable {
    fileprivate struct IndexedSong: Sendable {
        let song: Song
        let titleKey: String
        let artistKey: String
        let albumKey: String
    }

    fileprivate struct IndexedAlbum: Sendable {
        let album: Album
        let nameKey: String
        let artistKey: String
    }

    fileprivate struct IndexedArtist: Sendable {
        let artist: Artist
        let nameKey: String
    }

    fileprivate let songs: [IndexedSong]
    fileprivate let albums: [IndexedAlbum]
    fileprivate let artists: [IndexedArtist]
    fileprivate let songTokenIndex: [String: [Int]]

    static func build(from snapshot: HomeSnapshot) -> LocalLibrarySearchIndex {
        let uniqueSongs = MediaIdentity.uniqueSongs(
            from: HomeSnapshot.songCollections.map { snapshot[keyPath: $0] },
            limit: 400
        )
        let uniqueAlbums = MediaIdentity.unique(
            HomeSnapshot.albumCollections.flatMap { snapshot[keyPath: $0] },
            id: \.id
        )
        let uniqueArtists = MediaIdentity.uniqueArtists(
            HomeSnapshot.artistCollections.flatMap { snapshot[keyPath: $0] }
        )
        let indexedSongs = uniqueSongs.map {
            IndexedSong(
                song: $0,
                titleKey: normalizedSearchKey($0.title),
                artistKey: normalizedSearchKey($0.artist),
                albumKey: normalizedSearchKey($0.album)
            )
        }
        return LocalLibrarySearchIndex(
            songs: indexedSongs,
            albums: uniqueAlbums.map {
                IndexedAlbum(
                    album: $0,
                    nameKey: normalizedSearchKey($0.name),
                    artistKey: normalizedSearchKey($0.artist)
                )
            },
            artists: uniqueArtists.map {
                IndexedArtist(
                    artist: $0,
                    nameKey: normalizedSearchKey($0.name)
                )
            },
            songTokenIndex: Self.buildSongTokenIndex(for: indexedSongs)
        )
    }

    private static func buildSongTokenIndex(
        for songs: [IndexedSong]
    ) -> [String: [Int]] {
        var buckets: [String: [Int]] = [:]
        buckets.reserveCapacity(songs.count * 2)
        for (index, entry) in songs.enumerated() {
            var tokens = Set<String>()
            for key in [entry.titleKey, entry.artistKey, entry.albumKey] where !key.isEmpty {
                for token in key.split(whereSeparator: \.isWhitespace) {
                    tokens.insert(String(token))
                }
            }
            for token in tokens {
                buckets[token, default: []].append(index)
            }
        }
        return buckets
    }

    func results(
        for rawQuery: String,
        artistLimit: Int = 8,
        albumLimit: Int = 14,
        songLimit: Int = 30
    ) -> SearchResults {
        let query = PreparedSearchQuery(rawQuery)
        guard !query.value.isEmpty else { return .empty }

        return SearchResults(
            artists: rankedIndexedArtists(artists, limit: artistLimit, query: query),
            albums: rankedIndexedAlbums(albums, limit: albumLimit, query: query),
            songs: rankedIndexedSongs(
                songs,
                tokenIndex: songTokenIndex,
                limit: songLimit,
                query: query
            )
        )
    }
}

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
        LocalLibrarySearchIndex.build(from: snapshot).results(
            for: rawQuery,
            artistLimit: artistLimit,
            albumLimit: albumLimit,
            songLimit: songLimit
        )
    }

    static func results(
        for rawQuery: String,
        using index: LocalLibrarySearchIndex,
        artistLimit: Int = 8,
        albumLimit: Int = 14,
        songLimit: Int = 30
    ) -> SearchResults {
        index.results(
            for: rawQuery,
            artistLimit: artistLimit,
            albumLimit: albumLimit,
            songLimit: songLimit
        )
    }
}

enum SearchPresentationPolicy {
    static func retainedResults(
        previousQuery: String,
        previousResults: SearchResults,
        nextQuery: String
    ) -> SearchResults {
        guard !previousResults.isEmpty else { return .empty }
        let previous = normalizedSearchKey(previousQuery)
        let next = normalizedSearchKey(nextQuery)
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
        let normalizedValue = normalizedSearchKey(rawValue)
        value = normalizedValue
        tokens = normalizedValue
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}

private func rankedIndexedSongs(
    _ items: [LocalLibrarySearchIndex.IndexedSong],
    tokenIndex: [String: [Int]],
    limit: Int,
    query: PreparedSearchQuery
) -> [Song] {
    guard limit > 0 else { return [] }
    let candidates = candidateSongIndices(for: query, tokenIndex: tokenIndex)
    let searchItems: [LocalLibrarySearchIndex.IndexedSong]
    if let candidates {
        searchItems = candidates.compactMap { index in
            guard items.indices.contains(index) else { return nil }
            return items[index]
        }
    } else {
        searchItems = items
    }
    var buckets: [FieldMatch: [Song]] = [:]
    for entry in searchItems {
        guard let match = bestFieldMatch(
            fieldMatch(entry.titleKey, query: query, field: 0),
            fieldMatch(entry.artistKey, query: query, field: 1),
            fieldMatch(entry.albumKey, query: query, field: 2)
        ) else { continue }
        buckets[match, default: []].append(entry.song)
    }
    return takeRankedMatches(from: buckets, limit: limit)
}

private func candidateSongIndices(
    for query: PreparedSearchQuery,
    tokenIndex: [String: [Int]]
) -> [Int]? {
    guard !query.tokens.isEmpty else { return nil }
    if query.tokens.count == 1, let token = query.tokens.first {
        return tokenIndex[token]
    }
    var candidates: Set<Int>?
    for token in query.tokens {
        guard let indices = tokenIndex[token] else { return [] }
        let bucket = Set(indices)
        if let existing = candidates {
            candidates = existing.intersection(bucket)
        } else {
            candidates = bucket
        }
        if candidates?.isEmpty == true { return [] }
    }
    return candidates.map(Array.init)
}

private func rankedIndexedAlbums(
    _ items: [LocalLibrarySearchIndex.IndexedAlbum],
    limit: Int,
    query: PreparedSearchQuery
) -> [Album] {
    guard limit > 0 else { return [] }
    var buckets: [FieldMatch: [Album]] = [:]
    for entry in items {
        guard let match = bestFieldMatch(
            fieldMatch(entry.nameKey, query: query, field: 0),
            fieldMatch(entry.artistKey, query: query, field: 1)
        ) else { continue }
        buckets[match, default: []].append(entry.album)
    }
    return takeRankedMatches(from: buckets, limit: limit)
}

private func rankedIndexedArtists(
    _ items: [LocalLibrarySearchIndex.IndexedArtist],
    limit: Int,
    query: PreparedSearchQuery
) -> [Artist] {
    guard limit > 0 else { return [] }
    var buckets: [FieldMatch: [Artist]] = [:]
    for entry in items {
        guard let match = fieldMatch(entry.nameKey, query: query, field: 0) else {
            continue
        }
        buckets[match, default: []].append(entry.artist)
    }
    return takeRankedMatches(from: buckets, limit: limit)
}

private func takeRankedMatches<Item>(
    from buckets: [FieldMatch: [Item]],
    limit: Int
) -> [Item] {
    var result: [Item] = []
    result.reserveCapacity(limit)
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

private func normalizedSearchKey(_ value: String) -> String {
    value
        .folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}
