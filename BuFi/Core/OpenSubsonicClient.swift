import CryptoKit
import Foundation
import OSLog
import SwiftSonic

enum OpenSubsonicError: LocalizedError, Equatable {
    case invalidServerURL
    case insecureServerURL
    case credentialsEmbeddedInServerURL
    case invalidResponse
    case server(code: Int?, message: String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            String(localized: "서버 주소가 올바르지 않습니다.")
        case .insecureServerURL:
            String(localized: "보안을 위해 HTTPS 서버 주소만 사용할 수 있습니다.")
        case .credentialsEmbeddedInServerURL:
            String(localized: "서버 주소에 아이디나 비밀번호를 넣지 마세요.")
        case .invalidResponse:
            String(localized: "OpenSubsonic 응답 형식이 올바르지 않습니다.")
        case .server(_, let message):
            message
        case .http(let status):
            String(
                format: String(localized: "서버가 HTTP %d로 응답했습니다."),
                status
            )
        }
    }
}

enum PlaylistAffinityRanking {
    private struct FirstPosition: Comparable {
        let playlist: Int
        let song: Int

        static func < (lhs: FirstPosition, rhs: FirstPosition) -> Bool {
            lhs.playlist == rhs.playlist
                ? lhs.song < rhs.song
                : lhs.playlist < rhs.playlist
        }
    }

    static func rank(
        _ values: [(playlistIndex: Int, songs: [Song])],
        limit: Int
    ) -> [Song] {
        guard limit > 0 else { return [] }
        var appearances: [String: Int] = [:]
        var songsByID: [String: Song] = [:]
        var firstPositions: [String: FirstPosition] = [:]
        for (playlistIndex, playlistSongs) in values.sorted(by: {
            $0.playlistIndex < $1.playlistIndex
        }) {
            var seenInPlaylist = Set<String>()
            for (songIndex, song) in playlistSongs.enumerated()
                where seenInPlaylist.insert(song.id).inserted {
                appearances[song.id, default: 0] += 1
                if songsByID[song.id] == nil {
                    songsByID[song.id] = song
                    firstPositions[song.id] = FirstPosition(
                        playlist: playlistIndex,
                        song: songIndex
                    )
                }
            }
        }
        return Array(
            songsByID.values.sorted { lhs, rhs in
                let leftAppearances = appearances[lhs.id, default: 0]
                let rightAppearances = appearances[rhs.id, default: 0]
                if leftAppearances != rightAppearances {
                    return leftAppearances > rightAppearances
                }
                let leftPlayCount = lhs.playCount ?? 0
                let rightPlayCount = rhs.playCount ?? 0
                if leftPlayCount != rightPlayCount {
                    return leftPlayCount > rightPlayCount
                }
                let leftPosition = firstPositions[lhs.id]
                    ?? FirstPosition(playlist: .max, song: .max)
                let rightPosition = firstPositions[rhs.id]
                    ?? FirstPosition(playlist: .max, song: .max)
                if leftPosition != rightPosition {
                    return leftPosition < rightPosition
                }
                return lhs.id < rhs.id
            }
            .prefix(limit)
        )
    }
}

enum AlbumSongMetadataResolver {
    static func resolve(
        songs: [Song],
        albumID: String,
        coverArt: String?
    ) -> [Song] {
        guard let coverArt = coverArt?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !coverArt.isEmpty else {
            return songs
        }
        return songs.map { song in
            guard song.artworkID == nil,
                  song.albumId == nil || song.albumId == albumID else {
                return song
            }
            var resolved = song
            resolved.coverArt = coverArt
            return resolved
        }
    }
}

enum PlaybackMetadataResolver {
    /// Transport fields come from a fresh getSong response, while a cover that
    /// was already presented in the tapped row remains visually stable for the
    /// active occurrence. This prevents an older or incomplete getSong
    /// representation from replacing the artwork the user selected.
    static func resolve(canonical: Song, provisional: Song) -> Song {
        var resolved = canonical
        resolved.starred = provisional.starred
        if let provisionalArtwork = provisional.artworkID {
            resolved.coverArt = provisionalArtwork
        }
        return resolved
    }
}

enum OpenSubsonicCacheDependency: String, CaseIterable, Hashable, Sendable {
    case favorites
    case songDetails
    case albumDetails
    case artistDetails
    case libraryLists
    case recommendations
    case playQueue
}

struct OpenSubsonicMutationImpact: Equatable, Sendable {
    let invalidatedDependencies: Set<OpenSubsonicCacheDependency>

    static let none = OpenSubsonicMutationImpact(invalidatedDependencies: [])

    static func invalidating(
        _ dependencies: Set<OpenSubsonicCacheDependency>
    ) -> OpenSubsonicMutationImpact {
        OpenSubsonicMutationImpact(invalidatedDependencies: dependencies)
    }

    var participatesInStaleReadBarrier: Bool {
        !invalidatedDependencies.isEmpty
    }
}

struct OpenSubsonicResponseCachePolicy: Equatable, Sendable {
    enum RevalidationStrategy: Equatable, Sendable {
        case timeToLive
        case conditionalValidators
    }

    let lifetime: TimeInterval
    let staleGrace: TimeInterval
    let dependencies: Set<OpenSubsonicCacheDependency>
    let revalidation: RevalidationStrategy

    init(
        lifetime: TimeInterval,
        staleGrace: TimeInterval = 0,
        dependencies: Set<OpenSubsonicCacheDependency> = [],
        revalidation: RevalidationStrategy = .conditionalValidators
    ) {
        self.lifetime = max(0, lifetime)
        self.staleGrace = max(0, staleGrace)
        self.dependencies = dependencies
        self.revalidation = revalidation
    }
}

enum OpenSubsonicRequestPolicy {
    static let homeEnrichmentConcurrencyLimit = 3
    static let homeRecommendationSeedLimit = 2
    static let homeGenreLimit = 2
    static let homeTopArtistLimit = 2
    static let homeAlbumTrackLimit = 2
    static let homePlaylistLimit = 2
    static let homeMostPlayedAlbumLimit = 4
    static let homeSimilarArtistLimit = 2
    static let homeEnrichmentResultLimit = 16

    private static let favoriteRepresentations: Set<OpenSubsonicCacheDependency> = [
        .favorites,
        .songDetails,
        .albumDetails,
        .artistDetails,
        .libraryLists,
        .recommendations,
        .playQueue
    ]

    static func responseCachePolicy(
        for endpoint: String,
        queryItems: [URLQueryItem] = []
    ) -> OpenSubsonicResponseCachePolicy {
        switch endpoint {
        case "getOpenSubsonicExtensions":
            return OpenSubsonicResponseCachePolicy(lifetime: 60 * 60)
        case "getLyricsBySongId", "getLyrics":
            // Raw empty lyric payloads are not authoritative and must not
            // suppress a later successful response. Parsed, non-empty lyric
            // documents use a separate positive-only cache below.
            return OpenSubsonicResponseCachePolicy(lifetime: 0)
        case "getGenres", "getInternetRadioStations":
            return OpenSubsonicResponseCachePolicy(lifetime: 30 * 60)
        case "getArtistInfo2":
            return OpenSubsonicResponseCachePolicy(lifetime: 15 * 60)
        case "getPlaylists":
            return OpenSubsonicResponseCachePolicy(
                lifetime: 5 * 60,
                staleGrace: 20 * 60,
                dependencies: [.libraryLists]
            )
        case "getStarred2", "getStarred":
            // Star/unstar already invalidates `.favorites`. The longer TTL
            // avoids refetching a potentially huge starred catalog on every
            // incremental home refresh.
            return OpenSubsonicResponseCachePolicy(
                lifetime: 3 * 60,
                staleGrace: 20 * 60,
                dependencies: [.favorites]
            )
        case "getSong":
            // Canonical transport metadata is immutable for the overwhelming
            // majority of a listening session. Playback prewarms the next
            // entry, and app-side mutations invalidate `.songDetails`, so a
            // longer positive lifetime avoids re-fetching long tracks without
            // allowing favorite changes to remain stale.
            return OpenSubsonicResponseCachePolicy(
                lifetime: 30 * 60,
                staleGrace: 6 * 60 * 60,
                dependencies: [.songDetails]
            )
        case "getAlbum":
            return OpenSubsonicResponseCachePolicy(
                lifetime: 5 * 60,
                staleGrace: 15 * 60,
                dependencies: [.albumDetails]
            )
        case "getArtist":
            return OpenSubsonicResponseCachePolicy(
                lifetime: 5 * 60,
                staleGrace: 15 * 60,
                dependencies: [.artistDetails]
            )
        case "getPlaylist":
            return OpenSubsonicResponseCachePolicy(
                lifetime: 2 * 60,
                staleGrace: 15 * 60,
                dependencies: [.libraryLists]
            )
        case "getPlayQueue":
            return OpenSubsonicResponseCachePolicy(
                lifetime: 15,
                dependencies: [.playQueue]
            )
        case "search2", "search3":
            return OpenSubsonicResponseCachePolicy(
                lifetime: 5 * 60,
                staleGrace: 30 * 60,
                dependencies: [.libraryLists]
            )
        case "getArtists":
            return OpenSubsonicResponseCachePolicy(
                lifetime: 15 * 60,
                staleGrace: 30 * 60,
                dependencies: [.libraryLists]
            )
        case "getAlbumList2", "getAlbumList":
            let listType = queryItems.first { $0.name == "type" }?.value
            let lifetime: TimeInterval = switch listType {
            case "random", "recent", "frequent": 30
            case "newest", "highest": 2 * 60
            default: 60
            }
            return OpenSubsonicResponseCachePolicy(
                lifetime: lifetime,
                staleGrace: 15 * 60,
                dependencies: [.libraryLists]
            )
        case "getRandomSongs":
            return OpenSubsonicResponseCachePolicy(
                lifetime: 30,
                staleGrace: 10 * 60,
                dependencies: [.libraryLists, .recommendations]
            )
        case "getSongsByGenre", "getTopSongs":
            return OpenSubsonicResponseCachePolicy(
                lifetime: 2 * 60,
                staleGrace: 15 * 60,
                dependencies: [.libraryLists, .recommendations]
            )
        case "getSonicSimilarTracks", "getSimilarSongs2", "getSimilarSongs":
            return OpenSubsonicResponseCachePolicy(
                lifetime: 2 * 60,
                staleGrace: 15 * 60,
                dependencies: [.recommendations]
            )
        default:
            // Unknown endpoints are deliberately opt-in. This avoids keeping
            // an unclassified mutable representation alive under a generic
            // fallback TTL, while still protecting its live response across
            // a conservatively classified mutation boundary.
            return OpenSubsonicResponseCachePolicy(
                lifetime: 0,
                dependencies: favoriteRepresentations
            )
        }
    }

    static func mutationImpact(
        for endpoint: String,
        queryItems: [URLQueryItem] = []
    ) -> OpenSubsonicMutationImpact {
        switch endpoint {
        case "reportPlayback", "scrobble":
            return .none
        case "savePlayQueue":
            return .invalidating([.playQueue])
        case "star", "unstar":
            let names = Set(queryItems.map(\.name))
            if names.contains("id") {
                return .invalidating([
                    .favorites,
                    .songDetails,
                    .albumDetails,
                    .libraryLists,
                    .recommendations,
                    .playQueue
                ])
            }
            if names.contains("albumId") {
                return .invalidating([
                    .favorites,
                    .albumDetails,
                    .artistDetails,
                    .libraryLists,
                    .recommendations
                ])
            }
            if names.contains("artistId") {
                return .invalidating([
                    .favorites,
                    .artistDetails,
                    .libraryLists,
                    .recommendations
                ])
            }
            return .invalidating(favoriteRepresentations)
        default:
            // New mutation endpoints must be classified before they can keep
            // any favorite-bearing representation alive.
            return .invalidating(favoriteRepresentations)
        }
    }
}

struct OpenSubsonicCacheRevision: Hashable, Sendable {
    struct Entry: Hashable, Sendable {
        let dependency: OpenSubsonicCacheDependency
        let value: UInt64
    }

    let entries: [Entry]
}

struct OpenSubsonicCacheRevisionState: Sendable {
    private var revisions: [OpenSubsonicCacheDependency: UInt64] = [:]
    private var mutationsInFlight: [OpenSubsonicCacheDependency: Int] = [:]

    func revision(
        for dependencies: Set<OpenSubsonicCacheDependency>
    ) -> OpenSubsonicCacheRevision {
        OpenSubsonicCacheRevision(
            entries: dependencies
                .sorted { $0.rawValue < $1.rawValue }
                .map {
                    OpenSubsonicCacheRevision.Entry(
                        dependency: $0,
                        value: revisions[$0, default: 0]
                    )
                }
        )
    }

    func hasMutation(
        affecting dependencies: Set<OpenSubsonicCacheDependency>
    ) -> Bool {
        dependencies.contains {
            mutationsInFlight[$0, default: 0] > 0
        }
    }

    mutating func begin(_ impact: OpenSubsonicMutationImpact) {
        for dependency in impact.invalidatedDependencies {
            revisions[dependency, default: 0] &+= 1
            mutationsInFlight[dependency, default: 0] += 1
        }
    }

    mutating func finish(_ impact: OpenSubsonicMutationImpact) {
        for dependency in impact.invalidatedDependencies {
            revisions[dependency, default: 0] &+= 1
            let remaining = max(
                0,
                mutationsInFlight[dependency, default: 0] - 1
            )
            if remaining == 0 {
                mutationsInFlight[dependency] = nil
            } else {
                mutationsInFlight[dependency] = remaining
            }
        }
    }
}

actor HomeEnrichmentRequestLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    let limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func withPermit<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        let waiterID = UUID()
        let _: Void = try await withTaskCancellationHandler(
            operation: { [self] in
                try await waitForPermit(waiterID)
            },
            onCancel: { [self] in
                requestCancellation(of: waiterID)
            }
        )
    }

    private func waitForPermit(_ waiterID: UUID) async throws {
        try Task.checkCancellation()
        guard activeCount >= limit else {
            activeCount += 1
            return
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            waiters.append(Waiter(
                id: waiterID,
                continuation: continuation
            ))
        }
    }

    nonisolated private func requestCancellation(of waiterID: UUID) {
        Task { await self.cancel(waiterID) }
    }

    private func release() {
        guard !waiters.isEmpty else {
            activeCount = max(0, activeCount - 1)
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume()
    }

    private func cancel(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

struct LyricsDocumentCache: Sendable {
    private struct Entry: Sendable {
        let document: LyricsDocument
        let storedAt: ContinuousClock.Instant
        var accessOrdinal: UInt64
    }

    let countLimit: Int
    private var entries: [String: Entry] = [:]
    private var accessClock: UInt64 = 0

    var count: Int { entries.count }

    init(countLimit: Int) {
        self.countLimit = max(0, countLimit)
    }

    mutating func value(
        for songID: String,
        maximumAge: TimeInterval,
        emptyMaximumAge: TimeInterval = 30 * 60,
        now: ContinuousClock.Instant = ContinuousClock().now
    ) -> LyricsDocument? {
        guard var entry = entries[songID] else { return nil }
        let allowedAge = entry.document.lines.isEmpty ? emptyMaximumAge : maximumAge
        guard allowedAge > 0,
              entry.storedAt.duration(to: now) <= .seconds(allowedAge) else {
            entries.removeValue(forKey: songID)
            return nil
        }
        entry.accessOrdinal = nextAccessOrdinal()
        entries[songID] = entry
        return entry.document
    }

    mutating func insert(
        _ document: LyricsDocument,
        for songID: String,
        now: ContinuousClock.Instant = ContinuousClock().now
    ) {
        guard countLimit > 0 else { return }
        entries[songID] = Entry(
            document: document,
            storedAt: now,
            accessOrdinal: nextAccessOrdinal()
        )
        while entries.count > countLimit,
              let leastRecentlyUsed = entries.min(by: {
                  $0.value.accessOrdinal < $1.value.accessOrdinal
              })?.key {
            entries.removeValue(forKey: leastRecentlyUsed)
        }
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        accessClock = 0
    }

    private mutating func nextAccessOrdinal() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }
}

enum LyricsDocumentParser {
    static func parse(_ payload: LyricsPayload) -> LyricsDocument {
        guard let sources = payload.lyricsList?.structuredLyrics else {
            return .empty
        }

        // OpenSubsonic may return independent lyric representations. Preserve
        // server preference order, but skip empty or whitespace-only entries.
        for source in sources {
            let validLines = (source.line ?? []).enumerated().compactMap {
                index, item -> (index: Int, start: Int?, text: String)? in
                guard let text = item.value?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ), !text.isEmpty else {
                    return nil
                }
                return (index, item.start, text)
            }
            guard !validLines.isEmpty else { continue }

            let isSynced = source.synced == true
                && validLines.allSatisfy { $0.start != nil }
            let offset = TimeInterval(source.offset ?? 0) / 1_000
            var lines = validLines.map { item in
                LyricLine(
                    id: item.index,
                    start: isSynced
                        ? max(0, TimeInterval(item.start ?? 0) / 1_000 + offset)
                        : 0,
                    text: item.text
                )
            }
            if isSynced {
                lines.sort {
                    $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
                }
            }
            return LyricsDocument(synced: isSynced, lines: lines)
        }
        return .empty
    }

    static func parse(_ payload: LegacyLyricsPayload) -> LyricsDocument {
        guard let value = payload.lyrics?.value else { return .empty }
        let lines = value
            .components(separatedBy: .newlines)
            .enumerated()
            .compactMap { index, value -> LyricLine? in
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return LyricLine(id: index, start: 0, text: text)
            }
        return LyricsDocument(synced: false, lines: lines)
    }
}

private struct HomeEnrichmentIdentity: Equatable, Sendable {
    let seedSongIDs: [String]
    let starredArtistIDs: [String]
    let frequentAlbumIDs: [String]
    let recentAlbumIDs: [String]
    let playlistIDs: [String]
    let genreKeys: [String]

    init(
        starredSongs: [Song],
        randomSongs: [Song],
        starredArtists: [Artist],
        frequentAlbums: [Album],
        recentAlbums: [Album],
        playlists: [Playlist],
        genres: [String]
    ) {
        seedSongIDs = Array(
            (starredSongs + randomSongs)
                .prefix(OpenSubsonicRequestPolicy.homeRecommendationSeedLimit)
                .map(\.id)
        )
        starredArtistIDs = Array(
            starredArtists
                .prefix(OpenSubsonicRequestPolicy.homeSimilarArtistLimit)
                .map(\.id)
        )
        frequentAlbumIDs = Array(
            frequentAlbums
                .prefix(OpenSubsonicRequestPolicy.homeMostPlayedAlbumLimit)
                .map(\.id)
        )
        recentAlbumIDs = Array(
            recentAlbums
                .prefix(OpenSubsonicRequestPolicy.homeAlbumTrackLimit)
                .map(\.id)
        )
        playlistIDs = Array(
            playlists
                .prefix(OpenSubsonicRequestPolicy.homePlaylistLimit)
                .map(\.id)
        )
        var seen = Set<String>()
        var keys: [String] = []
        keys.reserveCapacity(OpenSubsonicRequestPolicy.homeGenreLimit)
        for genre in genres {
            let key = Self.normalized(genre)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            keys.append(key)
            if keys.count == OpenSubsonicRequestPolicy.homeGenreLimit {
                break
            }
        }
        genreKeys = keys
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(snapshot: HomeSnapshot) {
        let genres = snapshot.starredSongs.flatMap { song -> [String] in
            ([song.genre].compactMap { $0 } + (song.genres ?? []).map(\.name))
        } + snapshot.genreRecommendedSongs.compactMap(\.genre)
        self.init(
            starredSongs: snapshot.starredSongs,
            randomSongs: snapshot.randomSongs,
            starredArtists: snapshot.starredArtists,
            frequentAlbums: snapshot.frequentAlbums,
            recentAlbums: snapshot.recentAlbums,
            playlists: snapshot.playlists,
            genres: MediaIdentity.unique(genres, id: { $0.lowercased() })
        )
    }
}

actor OpenSubsonicClient {
    static let apiVersion = "1.16.1"
    static let clientName = "BuFi"
    private static let maximumResponseBytes = 64 * 1_024 * 1_024
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BuFi",
        category: "OpenSubsonic"
    )

    let credentials: ServerCredentials
    let accountScope: String
    private let session: URLSession
    private nonisolated let swiftSonic: SwiftSonicClient
    private let retryPolicy = ReadRequestRetryPolicy()
    private let authenticationQueryItems: [URLQueryItem]
    private var supportedExtensions: Set<String>?
    private var apiFamily: SubsonicAPIFamily = .openSubsonic
    private var allowsZstandardResponses = true
    private var preferredFallbackEndpoints: [String: String] = [:]
    private var inFlightReadRequests: [ReadRequestKey: InFlightReadRequest] = [:]
    private var cacheRevisionState = OpenSubsonicCacheRevisionState()

    private enum RequestSemantics {
        case readOnly
        case mutation(OpenSubsonicMutationImpact)
    }

    private typealias ReadRequestKey = OpenSubsonicReadRequestKey

    /// Sendable transport value used by coalesced requests. Foundation's
    /// HTTPURLResponse is a reference type, so extract only the immutable
    /// fields needed after the URLSession boundary.
    private struct HTTPResponseData: Sendable {
        let data: Data
        let statusCode: Int
        let retryAfter: String?
        let validators: ResponseBodyCache.Validators
        let decodeIdentity: UUID
    }

    private struct ZstandardNegotiationError: Error, Sendable {}

    private struct InFlightReadRequest {
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<HTTPResponseData, Error>]
    }

    private struct MutationWaiter {
        let dependencies: Set<OpenSubsonicCacheDependency>
        let continuation: CheckedContinuation<Void, Error>
    }

    private var mutationWaiters: [UUID: MutationWaiter] = [:]

    private enum ReadResponseSource {
        case network
        case freshCache(storedAt: ContinuousClock.Instant)
        case revalidatedCache
        case staleFallback
    }

    private struct DecodedResponseCacheEntry {
        let payload: any Sendable
        let storedAt: ContinuousClock.Instant
        let byteCost: Int
        let dependencies: Set<OpenSubsonicCacheDependency>
        var accessOrdinal: UInt64
    }

    private struct DecodedResponseRequestKey: Hashable, Sendable {
        let responseKey: String
        let payloadType: String
        let responseIdentity: UUID
    }

    private struct InFlightDecodedResponse {
        let token: UUID
        let task: Task<any Sendable, Error>
    }

    private static let responseCacheLimit = 192
    private static let responseCacheByteLimit = 16 * 1_024 * 1_024
    private static let maximumCachedResponseBytes = 2 * 1_024 * 1_024
    private static let decodedResponseCacheLimit = 64
    private static let decodedResponseCacheByteLimit = 8 * 1_024 * 1_024
    private static let persistedLyricsMaximumAge: TimeInterval = 7 * 24 * 60 * 60
    private var responseCache = ResponseBodyCache(
        countLimit: OpenSubsonicClient.responseCacheLimit,
        byteLimit: OpenSubsonicClient.responseCacheByteLimit,
        maximumEntryBytes: OpenSubsonicClient.maximumCachedResponseBytes
    )
    private var decodedResponseCache: [String: DecodedResponseCacheEntry] = [:]
    private var decodedResponseCacheByteCount = 0
    private var decodedResponseAccessClock: UInt64 = 0
    private var inFlightDecodedResponses: [
        DecodedResponseRequestKey: InFlightDecodedResponse
    ] = [:]
    private var lyricsCache = LyricsDocumentCache(countLimit: 96)

    private struct ServerRecommendationSources: Sendable {
        var sonic: [Song] = []
        var similarArtists: [Song] = []

        var combined: [Song] {
            OpenSubsonicClient.uniqueSongs(sonic + similarArtists)
        }
    }

    init(
        credentials: ServerCredentials,
        waitsForConnectivity: Bool = true,
        requestTimeout: TimeInterval = 18,
        resourceTimeout: TimeInterval = 60
    ) throws {
        let normalized = try ServerURLNormalization.resolvedURL(
            from: credentials.serverURL
        )
        let username = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCredentials = ServerCredentials(
            serverURL: ServerURLNormalization.persistedServerURL(from: normalized),
            username: username,
            password: credentials.password
        )
        self.credentials = normalizedCredentials
        self.accountScope = AccountScope.identifier(for: normalizedCredentials)
        self.authenticationQueryItems = Self.makeAuthenticationItems(
            for: normalizedCredentials
        )
        self.swiftSonic = SwiftSonicClient(
            configuration: ServerConfiguration(
                serverURL: normalized,
                username: username,
                password: credentials.password,
                reusesSalt: true,
                clientName: Self.clientName,
                apiVersion: Self.apiVersion,
                requestTimeout: requestTimeout,
                resourceTimeout: resourceTimeout
            )
        )

        let configuration = ModernNetworkPolicy.makeEphemeralConfiguration(
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            maximumConnectionsPerHost: 6,
            allowsExpensiveNetworkAccess: true,
            allowsConstrainedNetworkAccess: true,
            waitsForConnectivity: waitsForConnectivity
        )
        self.session = URLSession(
            configuration: configuration,
            delegate: HTTPSOnlyURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    func shutdown() {
        for request in inFlightReadRequests.values {
            request.task.cancel()
            for waiter in request.waiters.values {
                waiter.resume(throwing: CancellationError())
            }
        }
        inFlightReadRequests.removeAll(keepingCapacity: false)
        for waiter in mutationWaiters.values {
            waiter.continuation.resume(throwing: CancellationError())
        }
        mutationWaiters.removeAll(keepingCapacity: false)
        for request in inFlightDecodedResponses.values {
            request.task.cancel()
        }
        inFlightDecodedResponses.removeAll(keepingCapacity: false)
        decodedResponseCache.removeAll(keepingCapacity: false)
        decodedResponseCacheByteCount = 0
        decodedResponseAccessClock = 0
        session.invalidateAndCancel()
    }

    private static func makeAuthenticationItems(
        for credentials: ServerCredentials
    ) -> [URLQueryItem] {
        // Subsonic token authentication does not require a new salt for every
        // request. Keep one random pair for this client session, matching the
        // SwiftSonic `reusesSalt` configuration used by the same account.
        let salt = (0..<12)
            .map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }
            .joined()
        let tokenData = Data((credentials.password + salt).utf8)
        let token = Insecure.MD5.hash(data: tokenData)
            .map { String(format: "%02hhx", $0) }
            .joined()
        return [
            URLQueryItem(name: "u", value: credentials.username),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName)
        ]
    }

    private func authenticationItems() -> [URLQueryItem] {
        authenticationQueryItems
    }

    func endpointURL(
        _ endpoint: String,
        parameters: [String: String] = [:],
        json: Bool = true
    ) throws -> URL {
        try endpointURL(
            endpoint,
            queryItems: parameters
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) },
            json: json
        )
    }

    private func endpointURL(
        _ endpoint: String,
        queryItems: [URLQueryItem],
        json: Bool = true
    ) throws -> URL {
        guard var components = URLComponents(string: credentials.serverURL + "/rest/\(endpoint).view") else {
            throw OpenSubsonicError.invalidServerURL
        }
        var items = authenticationItems()
        if json { items.append(URLQueryItem(name: "f", value: "json")) }
        items.append(contentsOf: queryItems)
        components.queryItems = items
        guard let url = components.url else { throw OpenSubsonicError.invalidServerURL }
        return url
    }

    private func formRequest(
        _ endpoint: String,
        queryItems: [URLQueryItem],
        json: Bool = true
    ) throws -> URLRequest {
        guard let url = URL(
            string: credentials.serverURL + "/rest/\(endpoint).view"
        ), url.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.invalidServerURL
        }
        var items = authenticationItems()
        if json { items.append(URLQueryItem(name: "f", value: "json")) }
        items.append(contentsOf: queryItems)
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = items
        guard let body = bodyComponents.percentEncodedQuery?.data(using: .utf8) else {
            throw OpenSubsonicError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        return request
    }

    private func readRequest<Payload: Decodable & Sendable>(
        _ endpoint: String,
        parameters: [String: String] = [:],
        allowsCachedResponse: Bool = true
    ) async throws -> Payload {
        let queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await performRequest(
            endpoint,
            queryItems: queryItems,
            semantics: .readOnly,
            allowsCachedResponse: allowsCachedResponse
        )
    }

    private func mutationRequest<Payload: Decodable & Sendable>(
        _ endpoint: String,
        parameters: [String: String]
    ) async throws -> Payload {
        let queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await performRequest(
            endpoint,
            queryItems: queryItems,
            semantics: .mutation(
                OpenSubsonicRequestPolicy.mutationImpact(
                    for: endpoint,
                    queryItems: queryItems
                )
            )
        )
    }

    private func mutationRequest<Payload: Decodable & Sendable>(
        _ endpoint: String,
        queryItems: [URLQueryItem]
    ) async throws -> Payload {
        try await performRequest(
            endpoint,
            queryItems: queryItems,
            semantics: .mutation(
                OpenSubsonicRequestPolicy.mutationImpact(
                    for: endpoint,
                    queryItems: queryItems
                )
            )
        )
    }

    private func formMutationRequest<Payload: Decodable & Sendable>(
        _ endpoint: String,
        queryItems: [URLQueryItem]
    ) async throws -> Payload {
        let impact = OpenSubsonicRequestPolicy.mutationImpact(
            for: endpoint,
            queryItems: queryItems
        )
        beginMutation(impact)
        do {
            let request = try formRequest(endpoint, queryItems: queryItems)
            let response = try await responseData(
                from: request,
                // savePlayQueue replaces one complete server-side snapshot;
                // replaying the exact POST after a transient transport failure
                // is idempotent. Other form mutations remain single-attempt.
                allowsRetry: Self.allowsIdempotentMutationRetry(endpoint)
            )
            let payload: Payload = try await decodeResponse(response)
            finishMutation(impact)
            return payload
        } catch {
            finishMutation(impact)
            logFailure(error, endpoint: endpoint)
            throw error
        }
    }

    private func performRequest<Payload: Decodable & Sendable>(
        _ endpoint: String,
        queryItems: [URLQueryItem],
        semantics: RequestSemantics,
        allowsCachedResponse: Bool = true,
        staleReadRetryCount: Int = 0
    ) async throws -> Payload {
        let cachePolicy = OpenSubsonicRequestPolicy.responseCachePolicy(
            for: endpoint,
            queryItems: queryItems
        )
        let requestRevision = cacheRevisionState.revision(
            for: cachePolicy.dependencies
        )
        let cacheKey = Self.responseCacheKey(
            endpoint: endpoint,
            queryItems: queryItems,
            revision: requestRevision
        )

        if case .readOnly = semantics,
           allowsCachedResponse,
           cachePolicy.lifetime > 0,
           !cacheRevisionState.hasMutation(
               affecting: cachePolicy.dependencies
           ),
           let cached: Payload = cachedDecodedPayload(
               for: cacheKey,
               maximumAge: cachePolicy.lifetime
           ) {
            return cached
        }

        do {
            let response: HTTPResponseData
            let responseSource: ReadResponseSource
            switch semantics {
            case .readOnly:
                (response, responseSource) = try await readResponse(
                    endpoint: endpoint,
                    queryItems: queryItems,
                    cacheKey: cacheKey,
                    cachePolicy: cachePolicy,
                    requestRevision: requestRevision,
                    allowsCachedResponse: allowsCachedResponse
                )
            case .mutation(let impact):
                beginMutation(impact)
                let url = try endpointURL(endpoint, queryItems: queryItems)
                response = try await responseData(
                    from: url,
                    allowsRetry: Self.allowsIdempotentMutationRetry(endpoint)
                )
                responseSource = .network
            }
            let payload: Payload
            switch semantics {
            case .readOnly:
                payload = try await decodeReadResponse(
                    response,
                    cacheKey: cacheKey
                )
            case .mutation(_):
                payload = try await decodeResponse(response)
            }
            switch semantics {
            case .readOnly where !cacheRevisionState.hasMutation(
                    affecting: cachePolicy.dependencies
                )
                    && cacheRevisionState.revision(
                        for: cachePolicy.dependencies
                    ) == requestRevision:
                if cachePolicy.lifetime > 0 {
                    switch responseSource {
                    case .network, .revalidatedCache:
                        // Store only a body that decoded into the endpoint's
                        // expected payload, never an HTTP/schema error body.
                        storeResponse(
                            response,
                            for: cacheKey,
                            dependencies: cachePolicy.dependencies
                        )
                        if response.data.count <= Self.maximumCachedResponseBytes {
                            storeDecodedPayload(
                                payload,
                                for: cacheKey,
                                byteCost: response.data.count,
                                storedAt: ContinuousClock().now,
                                dependencies: cachePolicy.dependencies
                            )
                        }
                    case .freshCache(let storedAt):
                        if response.data.count <= Self.maximumCachedResponseBytes {
                            storeDecodedPayload(
                                payload,
                                for: cacheKey,
                                byteCost: response.data.count,
                                storedAt: storedAt,
                                dependencies: cachePolicy.dependencies
                            )
                        }
                    case .staleFallback:
                        // stale-if-error data must not become fresh merely
                        // because decoding the fallback succeeded.
                        break
                    }
                }
            case .readOnly:
                // Never hand a caller a representation that completed across
                // a relevant mutation boundary.
                guard staleReadRetryCount < 2 else {
                    throw CancellationError()
                }
                try await waitForRelevantMutations(
                    affecting: cachePolicy.dependencies
                )
                return try await performRequest(
                    endpoint,
                    queryItems: queryItems,
                    semantics: semantics,
                    allowsCachedResponse: allowsCachedResponse,
                    staleReadRetryCount: staleReadRetryCount + 1
                )
            case .mutation(let impact):
                finishMutation(impact)
            }
            return payload
        } catch let requestError {
            if case .mutation(let impact) = semantics {
                finishMutation(impact)
            }
            if case .readOnly = semantics,
               allowsCachedResponse,
               TransientServiceFailurePolicy.allowsCachedFallback(requestError),
               let cached = staleCachedResponse(
                   for: cacheKey,
                   cachePolicy: cachePolicy
               ) {
                let payload: Payload
                do {
                    let fallback = HTTPResponseData(
                        data: cached.data,
                        statusCode: 200,
                        retryAfter: nil,
                        validators: cached.validators,
                        decodeIdentity: cached.identity
                    )
                    payload = try await decodeReadResponse(
                        fallback,
                        cacheKey: cacheKey
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The cache only contains bodies that decoded successfully,
                    // but a future model migration could still make an old body
                    // incompatible. Preserve the original network/server error.
                    logFailure(requestError, endpoint: endpoint)
                    throw requestError
                }

                let crossedMutationBoundary = cacheRevisionState.hasMutation(
                    affecting: cachePolicy.dependencies
                ) || cacheRevisionState.revision(
                    for: cachePolicy.dependencies
                ) != requestRevision
                if crossedMutationBoundary {
                    guard staleReadRetryCount < 2 else {
                        throw CancellationError()
                    }
                    try await waitForRelevantMutations(
                        affecting: cachePolicy.dependencies
                    )
                    return try await performRequest(
                        endpoint,
                        queryItems: queryItems,
                        semantics: semantics,
                        allowsCachedResponse: allowsCachedResponse,
                        staleReadRetryCount: staleReadRetryCount + 1
                    )
                }
                return payload
            }
            logFailure(requestError, endpoint: endpoint)
            throw requestError
        }
    }

    private func bestEffortRequest<Payload: Decodable & Sendable>(
        _ endpoint: String,
        parameters: [String: String] = [:]
    ) async throws -> Payload? {
        do {
            return try await readRequest(endpoint, parameters: parameters)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if TransientServiceFailurePolicy.isAuthenticationFailure(error) {
                throw error
            }
            return nil
        }
    }

    private struct DecoderCapture: Decodable {
        let decoder: Decoder
        init(from decoder: Decoder) throws {
            self.decoder = decoder
        }
    }

    private func decodeResponse<Payload: Decodable & Sendable>(
        _ response: HTTPResponseData
    ) async throws -> Payload {
        guard (200..<300).contains(response.statusCode) else {
            throw OpenSubsonicError.http(response.statusCode)
        }
        return try await decodeResponseData(response.data)
    }

    private func decodeReadResponse<Payload: Decodable & Sendable>(
        _ response: HTTPResponseData,
        cacheKey: String
    ) async throws -> Payload {
        guard (200..<300).contains(response.statusCode) else {
            throw OpenSubsonicError.http(response.statusCode)
        }
        let key = DecodedResponseRequestKey(
            responseKey: cacheKey,
            payloadType: String(reflecting: Payload.self),
            responseIdentity: response.decodeIdentity
        )
        let request: InFlightDecodedResponse
        if let existing = inFlightDecodedResponses[key] {
            request = existing
        } else {
            let token = UUID()
            let task = Task<any Sendable, Error> {
                let payload: Payload = try await Self.decodePayloadConcurrently(
                    response.data
                )
                return payload
            }
            request = InFlightDecodedResponse(token: token, task: task)
            inFlightDecodedResponses[key] = request
        }

        do {
            let value = try await request.task.value
            try Task.checkCancellation()
            if inFlightDecodedResponses[key]?.token == request.token {
                inFlightDecodedResponses[key] = nil
            }
            guard let payload = value as? Payload else {
                throw OpenSubsonicError.invalidResponse
            }
            return payload
        } catch {
            if inFlightDecodedResponses[key]?.token == request.token {
                inFlightDecodedResponses[key] = nil
            }
            throw error
        }
    }

    private func decodeResponseData<Payload: Decodable & Sendable>(
        _ data: Data
    ) async throws -> Payload {
        try await Self.decodePayloadConcurrently(data)
    }

    @concurrent
    private static func decodePayloadConcurrently<Payload: Decodable & Sendable>(
        _ data: Data
    ) async throws -> Payload {
        try Task.checkCancellation()
        return try decodePayload(data)
    }

    private nonisolated static func decodePayload<Payload: Decodable & Sendable>(
        _ data: Data
    ) throws -> Payload {
        let decoder = JSONDecoder()
        let capture = try decoder.decode(DecoderCapture.self, from: data)
        let statusEnvelope = try StatusEnvelope(from: capture.decoder)
        guard statusEnvelope.response.status == "ok" else {
            throw OpenSubsonicError.server(
                code: statusEnvelope.response.error?.code,
                message: statusEnvelope.response.error?.message
                    ?? String(localized: "서버 요청이 실패했습니다.")
            )
        }
        return try APIEnvelope<Payload>(from: capture.decoder).response
    }

    func ping() async throws -> StatusBody {
        let endpoint = "ping"
        do {
            let response = try await coalescedReadResponse(
                endpoint: endpoint,
                queryItems: [],
                key: ReadRequestKey(
                    endpoint: endpoint,
                    queryItems: [],
                    cacheRevision: OpenSubsonicCacheRevision(entries: [])
                )
            )
            guard (200..<300).contains(response.statusCode) else {
                throw OpenSubsonicError.http(response.statusCode)
            }
            let envelope = try await Self.decodeStatusEnvelope(response.data)
            guard envelope.response.status == "ok" else {
                throw OpenSubsonicError.server(
                    code: envelope.response.error?.code,
                    message: envelope.response.error?.message
                        ?? String(localized: "서버 연결에 실패했습니다.")
                )
            }
            return envelope.response
        } catch {
            logFailure(error, endpoint: endpoint)
            throw error
        }
    }

    func applyPingStatus(_ status: StatusBody) {
        let previousFamily = apiFamily
        apiFamily = SubsonicCompatibilityPolicy.family(from: status)
        if status.advertisesOpenSubsonic {
            apiFamily = .openSubsonic
        }
        if apiFamily != previousFamily {
            preferredFallbackEndpoints.removeAll(keepingCapacity: true)
        }
    }

    private func readWithFallback<Payload: Decodable & Sendable>(
        _ endpoints: [String],
        parameters: [String: String] = [:],
        allowsCachedResponse: Bool = true
    ) async throws -> Payload {
        let fallbackKey = endpoints.joined(separator: "\u{1F}")
        var orderedEndpoints = endpoints
        if let preferredEndpoint = preferredFallbackEndpoints[fallbackKey],
           let preferredIndex = orderedEndpoints.firstIndex(of: preferredEndpoint),
           preferredIndex != orderedEndpoints.startIndex {
            orderedEndpoints.remove(at: preferredIndex)
            orderedEndpoints.insert(preferredEndpoint, at: orderedEndpoints.startIndex)
        }

        var lastError: Error = OpenSubsonicError.invalidResponse
        for endpoint in orderedEndpoints {
            do {
                let payload: Payload = try await readRequest(
                    endpoint,
                    parameters: parameters,
                    allowsCachedResponse: allowsCachedResponse
                )
                preferredFallbackEndpoints[fallbackKey] = endpoint
                return payload
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard SubsonicCompatibilityPolicy.shouldContinueFallback(error) else {
                    throw error
                }
            }
        }
        throw lastError
    }

    private func bestEffortWithFallback<Payload: Decodable & Sendable>(
        _ endpoints: [String],
        parameters: [String: String] = [:]
    ) async throws -> Payload? {
        do {
            return try await readWithFallback(endpoints, parameters: parameters)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if TransientServiceFailurePolicy.isAuthenticationFailure(error) {
                throw error
            }
            return nil
        }
    }

    @concurrent
    private static func decodeStatusEnvelope(_ data: Data) async throws -> StatusEnvelope {
        try Task.checkCancellation()
        return try JSONDecoder().decode(StatusEnvelope.self, from: data)
    }

    private func coalescedReadResponse(
        endpoint: String,
        queryItems: [URLQueryItem],
        key: ReadRequestKey,
        validators: ResponseBodyCache.Validators = .none
    ) async throws -> HTTPResponseData {
        try Task.checkCancellation()
        let waiter = UUID()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerReadWaiter(
                    continuation,
                    key: key,
                    waiter: waiter,
                    endpoint: endpoint,
                    queryItems: queryItems,
                    validators: validators
                )
            }
        } onCancel: {
            Task {
                await self.cancelReadWaiter(key: key, waiter: waiter)
            }
        }
        try Task.checkCancellation()
        return response
    }

    private func registerReadWaiter(
        _ continuation: CheckedContinuation<HTTPResponseData, Error>,
        key: ReadRequestKey,
        waiter: UUID,
        endpoint: String,
        queryItems: [URLQueryItem],
        validators: ResponseBodyCache.Validators
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if var existing = inFlightReadRequests[key] {
            existing.waiters[waiter] = continuation
            inFlightReadRequests[key] = existing
            return
        }

        let url: URL
        do {
            url = try endpointURL(endpoint, queryItems: queryItems)
        } catch {
            continuation.resume(throwing: error)
            return
        }

        var request = URLRequest(url: url)
        if let entityTag = validators.entityTag {
            request.setValue(entityTag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let token = UUID()
        let task = Task { [self] in
            do {
                let response = try await responseData(
                    from: request,
                    allowsRetry: true
                )
                finishReadRequest(
                    key: key,
                    token: token,
                    result: .success(response)
                )
            } catch {
                finishReadRequest(
                    key: key,
                    token: token,
                    result: .failure(error)
                )
            }
        }
        inFlightReadRequests[key] = InFlightReadRequest(
            token: token,
            task: task,
            waiters: [waiter: continuation]
        )
    }

    private func cancelReadWaiter(
        key: ReadRequestKey,
        waiter: UUID
    ) {
        guard var request = inFlightReadRequests[key],
              let continuation = request.waiters.removeValue(
                forKey: waiter
              ) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if request.waiters.isEmpty {
            request.task.cancel()
            inFlightReadRequests[key] = nil
        } else {
            inFlightReadRequests[key] = request
        }
    }

    private func finishReadRequest(
        key: ReadRequestKey,
        token: UUID,
        result: Result<HTTPResponseData, Error>
    ) {
        guard let request = inFlightReadRequests[key],
              request.token == token else {
            return
        }
        inFlightReadRequests[key] = nil
        for continuation in request.waiters.values {
            switch result {
            case .success(let response):
                continuation.resume(returning: response)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private func waitForRelevantMutations(
        affecting dependencies: Set<OpenSubsonicCacheDependency>
    ) async throws {
        try Task.checkCancellation()
        guard cacheRevisionState.hasMutation(affecting: dependencies) else {
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerMutationWaiter(
                    continuation,
                    id: waiterID,
                    dependencies: dependencies
                )
            }
        } onCancel: {
            Task {
                await self.cancelMutationWaiter(waiterID)
            }
        }
        try Task.checkCancellation()
    }

    private func registerMutationWaiter(
        _ continuation: CheckedContinuation<Void, Error>,
        id: UUID,
        dependencies: Set<OpenSubsonicCacheDependency>
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard cacheRevisionState.hasMutation(affecting: dependencies) else {
            continuation.resume(returning: ())
            return
        }
        mutationWaiters[id] = MutationWaiter(
            dependencies: dependencies,
            continuation: continuation
        )
    }

    private func cancelMutationWaiter(_ id: UUID) {
        guard let waiter = mutationWaiters.removeValue(forKey: id) else {
            return
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func finishMutation(_ impact: OpenSubsonicMutationImpact) {
        cacheRevisionState.finish(impact)
        guard !mutationWaiters.isEmpty else { return }

        let readyIDs = mutationWaiters.compactMap { id, waiter in
            cacheRevisionState.hasMutation(affecting: waiter.dependencies)
                ? nil
                : id
        }
        for id in readyIDs {
            mutationWaiters.removeValue(forKey: id)?
                .continuation
                .resume(returning: ())
        }
    }

    private func beginMutation(_ impact: OpenSubsonicMutationImpact) {
        cacheRevisionState.begin(impact)
        let dependencies = impact.invalidatedDependencies
        guard !dependencies.isEmpty else { return }
        responseCache.removeAll(affecting: dependencies)
        let invalidDecodedKeys = decodedResponseCache.compactMap { key, entry in
            entry.dependencies.isDisjoint(with: dependencies) ? nil : key
        }
        for key in invalidDecodedKeys {
            removeDecodedResponse(for: key)
        }
    }

    private func responseData(
        from url: URL,
        allowsRetry: Bool
    ) async throws -> HTTPResponseData {
        try await responseData(
            from: URLRequest(url: url),
            allowsRetry: allowsRetry
        )
    }

    private func responseData(
        from originalRequest: URLRequest,
        allowsRetry: Bool
    ) async throws -> HTTPResponseData {
        // Mutations avoid the zstd negotiation fallback because reissuing a
        // state-changing endpoint would itself be an unsafe retry.
        var acceptsZstandard = allowsRetry && allowsZstandardResponses
        var retryCount = 0

        while true {
            try Task.checkCancellation()
            do {
                let result = try await responseDataAttempt(
                    from: originalRequest,
                    acceptsZstandard: acceptsZstandard
                )
                guard allowsRetry,
                      retryCount < ReadRequestRetryPolicy.maximumRetryCount,
                      retryPolicy.shouldRetry(
                        statusCode: result.statusCode
                      ) else {
                    return result
                }

                if result.statusCode == 429, retryCount >= 1 {
                    return result
                }
                retryCount += 1
                guard let delay = retryPolicy.delay(
                    retryNumber: retryCount,
                    retryAfterHeader: result.retryAfter,
                    jitter: Double.random(in: 0.75...1.25)
                ) else {
                    return result
                }
                Self.logger.notice(
                    "Retrying read request after HTTP \(result.statusCode, privacy: .public); retry \(retryCount, privacy: .public)"
                )
                try await sleepBeforeRetry(delay)
            } catch {
                if acceptsZstandard,
                   error is ZstandardNegotiationError {
                    // Content negotiation fallback is not a retry. It existed
                    // before the bounded transient-failure policy and does not
                    // consume its budget.
                    allowsZstandardResponses = false
                    acceptsZstandard = false
                    continue
                }
                guard allowsRetry,
                      retryCount < ReadRequestRetryPolicy.maximumRetryCount,
                      retryPolicy.shouldRetry(error: error) else {
                    throw error
                }

                retryCount += 1
                guard let delay = retryPolicy.delay(
                    retryNumber: retryCount,
                    retryAfterHeader: nil,
                    jitter: Double.random(in: 0.75...1.25)
                ) else {
                    throw error
                }
                let code = (error as NSError).code
                Self.logger.notice(
                    "Retrying read request after network error \(code, privacy: .public); retry \(retryCount, privacy: .public)"
                )
                try await sleepBeforeRetry(delay)
            }
        }
    }

    private func sleepBeforeRetry(_ delay: TimeInterval) async throws {
        try Task.checkCancellation()
        let nanoseconds = UInt64(
            max(0, min(ReadRequestRetryPolicy.maximumServerDelay, delay))
                * 1_000_000_000
        )
        if nanoseconds > 0 {
            try await Task.sleep(nanoseconds: nanoseconds)
        }
        try Task.checkCancellation()
    }

    private func responseDataAttempt(
        from originalRequest: URLRequest,
        acceptsZstandard: Bool
    ) async throws -> HTTPResponseData {
        guard let url = originalRequest.url else {
            throw OpenSubsonicError.invalidServerURL
        }
        guard url.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        var request = originalRequest
        ModernNetworkPolicy.prepareAPIRequest(
            &request,
            acceptsZstandard: acceptsZstandard
        )

        let encodedData: Data
        let response: URLResponse
        do {
            (encodedData, response) = try await session.data(for: request)
        } catch let error as URLError
            where acceptsZstandard && error.code == .cannotDecodeContentData {
            throw ZstandardNegotiationError()
        }
        try Task.checkCancellation()
        guard encodedData.count <= Self.maximumResponseBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenSubsonicError.invalidResponse
        }
        guard http.url?.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        let validators = Self.responseValidators(from: http)
        let decodeIdentity = UUID()
        // Error response bodies are not decoded by callers. Returning the
        // status first ensures 408/429/5xx retry decisions do not depend on a
        // server's optional error-body content encoding.
        guard (200..<300).contains(http.statusCode) else {
            return HTTPResponseData(
                data: encodedData,
                statusCode: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                validators: validators,
                decodeIdentity: decodeIdentity
            )
        }
        let contentEncoding = http.value(forHTTPHeaderField: "Content-Encoding")
        do {
            let data: Data
            if HTTPContentDecoder.requiresManualDecoding(
                encodedData,
                contentEncoding: contentEncoding
            ) {
                data = try await HTTPContentDecoder.decodeAsync(
                    encodedData,
                    contentEncoding: contentEncoding
                )
            } else {
                data = encodedData
            }
            return HTTPResponseData(
                data: data,
                statusCode: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                validators: validators,
                decodeIdentity: decodeIdentity
            )
        } catch let error as URLError
            where acceptsZstandard
                && error.code == .cannotDecodeContentData {
            throw ZstandardNegotiationError()
        }
    }

    private nonisolated static func responseValidators(
        from response: HTTPURLResponse
    ) -> ResponseBodyCache.Validators {
        ResponseBodyCache.Validators(
            entityTag: boundedValidatorHeader(
                response.value(forHTTPHeaderField: "ETag")
            ),
            lastModified: boundedValidatorHeader(
                response.value(forHTTPHeaderField: "Last-Modified")
            )
        )
    }

    private nonisolated static func boundedValidatorHeader(
        _ value: String?
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 1_024 else { return nil }
        return trimmed
    }

    private func logFailure(_ error: Error, endpoint: String) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return
        }
        switch error {
        case OpenSubsonicError.http(let status):
            Self.logger.error(
                "Request failed at \(endpoint, privacy: .public) with HTTP \(status, privacy: .public)"
            )
        case OpenSubsonicError.server(let code, _):
            Self.logger.error(
                "Request failed at \(endpoint, privacy: .public) with server code \(code ?? -1, privacy: .public)"
            )
        case is DecodingError:
            Self.logger.error(
                "Request failed at \(endpoint, privacy: .public) while decoding"
            )
        case let error as URLError:
            Self.logger.error(
                "Request failed at \(endpoint, privacy: .public) with network code \(error.code.rawValue, privacy: .public)"
            )
        default:
            Self.logger.error(
                "Request failed at \(endpoint, privacy: .public)"
            )
        }
    }

    private func readResponse(
        endpoint: String,
        queryItems: [URLQueryItem],
        cacheKey: String,
        cachePolicy: OpenSubsonicResponseCachePolicy,
        requestRevision: OpenSubsonicCacheRevision,
        allowsCachedResponse: Bool
    ) async throws -> (HTTPResponseData, ReadResponseSource) {
        let cacheHit: ResponseBodyCache.Lookup
        if allowsCachedResponse,
           !cacheRevisionState.hasMutation(affecting: cachePolicy.dependencies),
           cachePolicy.lifetime > 0 {
            cacheHit = cachedResponse(
                for: cacheKey,
                lifetime: cachePolicy.lifetime,
                staleGrace: cachePolicy.staleGrace
            )
        } else {
            cacheHit = .miss
        }

        let staleValue: ResponseBodyCache.Value?
        if case .fresh(let cached) = cacheHit {
            return (
                HTTPResponseData(
                    data: cached.data,
                    statusCode: 200,
                    retryAfter: nil,
                    validators: cached.validators,
                    decodeIdentity: cached.identity
                ),
                .freshCache(storedAt: cached.storedAt)
            )
        } else if case .stale(let cached) = cacheHit {
            staleValue = cached
        } else {
            staleValue = nil
        }

        let validators: ResponseBodyCache.Validators
        if cachePolicy.revalidation == .conditionalValidators,
           let staleValue,
           !staleValue.validators.isEmpty {
            validators = staleValue.validators
        } else {
            validators = .none
        }

        do {
            let response = try await coalescedReadResponse(
                endpoint: endpoint,
                queryItems: queryItems,
                key: ReadRequestKey(
                    endpoint: endpoint,
                    queryItems: queryItems,
                    cacheRevision: requestRevision,
                    entityTag: validators.entityTag,
                    lastModified: validators.lastModified
                ),
                validators: validators
            )
            if response.statusCode == 304, let staleValue {
                return (
                    HTTPResponseData(
                        data: staleValue.data,
                        statusCode: 200,
                        retryAfter: nil,
                        validators: staleValue.validators.merging(
                            response.validators
                        ),
                        decodeIdentity: staleValue.identity
                    ),
                    .revalidatedCache
                )
            }
            if let staleValue,
               TransientServiceFailurePolicy.allowsCachedFallback(
                   OpenSubsonicError.http(response.statusCode)
               ) {
                return (
                    HTTPResponseData(
                        data: staleValue.data,
                        statusCode: 200,
                        retryAfter: nil,
                        validators: staleValue.validators,
                        decodeIdentity: staleValue.identity
                    ),
                    .staleFallback
                )
            }
            return (response, .network)
        } catch {
            if let staleValue,
               TransientServiceFailurePolicy.allowsCachedFallback(error) {
                return (
                    HTTPResponseData(
                        data: staleValue.data,
                        statusCode: 200,
                        retryAfter: nil,
                        validators: staleValue.validators,
                        decodeIdentity: staleValue.identity
                    ),
                    .staleFallback
                )
            }
            throw error
        }
    }

    private func cachedResponse(
        for key: String,
        lifetime: TimeInterval,
        staleGrace: TimeInterval = 0
    ) -> ResponseBodyCache.Lookup {
        responseCache.lookup(
            for: key,
            maximumAge: lifetime,
            staleGrace: staleGrace
        )
    }

    private func staleCachedResponse(
        for key: String,
        cachePolicy: OpenSubsonicResponseCachePolicy
    ) -> ResponseBodyCache.Value? {
        guard cachePolicy.lifetime > 0, cachePolicy.staleGrace > 0 else {
            return nil
        }
        let maximumFallbackAge = cachePolicy.lifetime
            + cachePolicy.staleGrace
        guard case .stale(let value) = responseCache.lookup(
            for: key,
            maximumAge: 0,
            staleGrace: maximumFallbackAge
        ) else {
            return nil
        }
        return value
    }

    private func storeResponse(
        _ response: HTTPResponseData,
        for key: String,
        dependencies: Set<OpenSubsonicCacheDependency>
    ) {
        responseCache.insert(
            response.data,
            for: key,
            validators: response.validators,
            identity: response.decodeIdentity,
            dependencies: dependencies
        )
    }

    private func cachedDecodedPayload<Payload: Sendable>(
        for key: String,
        maximumAge: TimeInterval
    ) -> Payload? {
        let key = Self.decodedResponseKey(
            responseKey: key,
            payloadType: Payload.self
        )
        guard maximumAge > 0,
              var entry = decodedResponseCache[key] else {
            return nil
        }
        let now = ContinuousClock().now
        guard entry.storedAt.duration(to: now) <= .seconds(maximumAge) else {
            removeDecodedResponse(for: key)
            return nil
        }
        guard let payload = entry.payload as? Payload else {
            removeDecodedResponse(for: key)
            return nil
        }
        decodedResponseAccessClock &+= 1
        entry.accessOrdinal = decodedResponseAccessClock
        decodedResponseCache[key] = entry
        return payload
    }

    private func storeDecodedPayload<Payload: Sendable>(
        _ payload: Payload,
        for key: String,
        byteCost: Int,
        storedAt: ContinuousClock.Instant,
        dependencies: Set<OpenSubsonicCacheDependency>
    ) {
        let key = Self.decodedResponseKey(
            responseKey: key,
            payloadType: Payload.self
        )
        removeDecodedResponse(for: key)
        guard byteCost > 0,
              byteCost <= Self.maximumCachedResponseBytes,
              byteCost <= Self.decodedResponseCacheByteLimit else {
            return
        }
        decodedResponseAccessClock &+= 1
        decodedResponseCache[key] = DecodedResponseCacheEntry(
            payload: payload,
            storedAt: storedAt,
            byteCost: byteCost,
            dependencies: dependencies,
            accessOrdinal: decodedResponseAccessClock
        )
        decodedResponseCacheByteCount += byteCost
        while decodedResponseCache.count > Self.decodedResponseCacheLimit
                || decodedResponseCacheByteCount
                    > Self.decodedResponseCacheByteLimit,
              let oldestKey = decodedResponseCache.min(by: {
                  $0.value.accessOrdinal < $1.value.accessOrdinal
              })?.key {
            removeDecodedResponse(for: oldestKey)
        }
    }

    private func removeDecodedResponse(for key: String) {
        guard let removed = decodedResponseCache.removeValue(forKey: key) else {
            return
        }
        decodedResponseCacheByteCount = max(
            0,
            decodedResponseCacheByteCount - removed.byteCost
        )
    }

    private static func decodedResponseKey<Payload>(
        responseKey: String,
        payloadType: Payload.Type
    ) -> String {
        responseKey + "\u{1c}" + String(reflecting: payloadType)
    }

    private func clearResponseCache() {
        responseCache.removeAll(keepingCapacity: false)
        decodedResponseCache.removeAll(keepingCapacity: false)
        decodedResponseCacheByteCount = 0
        decodedResponseAccessClock = 0
    }

    private static func responseCacheKey(
        endpoint: String,
        queryItems: [URLQueryItem],
        revision: OpenSubsonicCacheRevision
    ) -> String {
        var material = Data()
        appendCacheField(endpoint, to: &material)

        let orderedQueryItems = queryItems.sorted(by: cacheQueryItemSort)
        appendCacheInteger(UInt64(orderedQueryItems.count), to: &material)
        for item in orderedQueryItems {
            appendCacheField(item.name, to: &material)
            if let value = item.value {
                material.append(1)
                appendCacheField(value, to: &material)
            } else {
                material.append(0)
            }
        }

        appendCacheInteger(UInt64(revision.entries.count), to: &material)
        for entry in revision.entries {
            appendCacheField(entry.dependency.rawValue, to: &material)
            appendCacheInteger(entry.value, to: &material)
        }
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func cacheQueryItemSort(
        _ lhs: URLQueryItem,
        _ rhs: URLQueryItem
    ) -> Bool {
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        switch (lhs.value, rhs.value) {
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case (.some(let left), .some(let right)):
            return left < right
        case (nil, nil):
            return false
        }
    }

    private static func appendCacheField(
        _ value: String,
        to material: inout Data
    ) {
        appendCacheInteger(UInt64(value.utf8.count), to: &material)
        material.append(contentsOf: value.utf8)
    }

    private static func appendCacheInteger(
        _ value: UInt64,
        to material: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            material.append(contentsOf: bytes)
        }
    }

    private static func allowsIdempotentMutationRetry(_ endpoint: String) -> Bool {
        endpoint == "star"
            || endpoint == "unstar"
            || endpoint == "savePlayQueue"
    }

    func home(
        from previous: HomeSnapshot? = nil,
        refreshStableCatalog: Bool = true
    ) async throws -> HomeLoadResult {
        let fallback = previous ?? .empty
        let shouldRefreshStableCatalog = refreshStableCatalog
            || fallback.artists.isEmpty

        async let recent: AlbumListPayload? = albumList("newest", size: "16")
        async let recentlyPlayed: AlbumListPayload? = albumList("recent", size: "16")
        async let frequent: AlbumListPayload? = albumList("frequent", size: "16")
        async let randomAlbums: AlbumListPayload? = albumList("random", size: "16")
        async let starred: StarredPayload? = bestEffortWithFallback(
            SubsonicCompatibilityPolicy.starredEndpoints(for: apiFamily)
        )
        async let randomSongs: RandomSongsPayload? = bestEffortRequest(
            "getRandomSongs",
            parameters: ["size": "16"]
        )
        async let playlists: PlaylistsPayload? = bestEffortRequest("getPlaylists")
        async let artists: ArtistsPayload? = shouldRefreshStableCatalog
            ? bestEffortRequest("getArtists")
            : nil
        async let radioStations: InternetRadioStationsPayload? = shouldRefreshStableCatalog
            ? bestEffortRequest("getInternetRadioStations")
            : nil
        async let genres: GenresPayload? = shouldRefreshStableCatalog
            ? bestEffortRequest("getGenres")
            : nil

        let (
            recentValue,
            recentlyPlayedValue,
            frequentValue,
            randomAlbumsValue,
            starredValue,
            artistsValue,
            randomSongsValue,
            playlistsValue,
            radioStationsValue,
            genresValue
        ) = try await (
            recent,
            recentlyPlayed,
            frequent,
            randomAlbums,
            starred,
            artists,
            randomSongs,
            playlists,
            radioStations,
            genres
        )
        guard recentValue != nil || recentlyPlayedValue != nil ||
                frequentValue != nil || randomAlbumsValue != nil ||
                starredValue != nil || artistsValue != nil ||
                randomSongsValue != nil || playlistsValue != nil ||
                radioStationsValue != nil || genresValue != nil ||
                previous != nil else {
            throw OpenSubsonicError.invalidResponse
        }

        let starredAlbums: [Album]
        let starredSongs: [Song]
        let starredArtists: [Artist]
        if let value = starredValue?.container {
            starredAlbums = value.album ?? []
            starredSongs = value.song ?? []
            starredArtists = value.artist ?? []
        } else {
            starredAlbums = fallback.starredAlbums
            starredSongs = fallback.starredSongs
            starredArtists = fallback.starredArtists
        }

        let randomSongValues = randomSongsValue.map {
            $0.randomSongs?.song ?? []
        } ?? fallback.randomSongs
        let allArtists = artistsValue.map {
            $0.artists?.index?.flatMap { $0.artist ?? [] } ?? []
        } ?? fallback.artists
        let frequentAlbums = albums(from: frequentValue, fallback: fallback.frequentAlbums)
        let recentAlbums = albums(from: recentValue, fallback: fallback.recentAlbums)
        let playlistValues = playlistsValue.map {
            $0.playlists?.playlist ?? []
        } ?? fallback.playlists
        let serverGenreNames = (genresValue?.genres?.genre ?? [])
            .sorted {
                ($0.songCount ?? 0) > ($1.songCount ?? 0)
            }
            .map(\.value)
        let preferredGenres = Self.uniqueStrings(
            starredSongs.flatMap {
                [$0.genre].compactMap { $0 } + ($0.genres ?? []).map(\.name)
            }
            + (serverGenreNames.isEmpty
                ? fallback.genreRecommendedSongs.compactMap(\.genre)
                : serverGenreNames)
        )
        let enrichmentIdentity = HomeEnrichmentIdentity(
            starredSongs: starredSongs,
            randomSongs: randomSongValues,
            starredArtists: starredArtists,
            frequentAlbums: frequentAlbums,
            recentAlbums: recentAlbums,
            playlists: playlistValues,
            genres: preferredGenres
        )
        let canReuseEnrichment = previous != nil
            && enrichmentIdentity == HomeEnrichmentIdentity(snapshot: fallback)

        var snapshot = HomeSnapshot(
            recentAlbums: recentAlbums,
            recentlyPlayedAlbums: albums(
                from: recentlyPlayedValue,
                fallback: fallback.recentlyPlayedAlbums
            ),
            frequentAlbums: frequentAlbums,
            randomAlbums: albums(
                from: randomAlbumsValue,
                fallback: fallback.randomAlbums
            ),
            starredAlbums: starredAlbums,
            starredSongs: starredSongs,
            starredArtists: starredArtists,
            artists: allArtists,
            randomSongs: randomSongValues,
            lastFMRecommendedSongs: fallback.lastFMRecommendedSongs,
            listenBrainzRecommendedSongs: fallback.listenBrainzRecommendedSongs,
            playlists: playlistValues,
            radioStations: radioStationsValue.map {
                $0.internetRadioStations?.internetRadioStation ?? []
            } ?? fallback.radioStations
        )

        if canReuseEnrichment {
            snapshot.adoptServerEnrichment(from: fallback)
        } else {
            async let popularAlbumsRequest: AlbumListPayload? = albumList(
                "highest",
                size: "8"
            )
            let enrichmentLimiter = HomeEnrichmentRequestLimiter(
                limit: OpenSubsonicRequestPolicy.homeEnrichmentConcurrencyLimit
            )
            let resultLimit = OpenSubsonicRequestPolicy.homeEnrichmentResultLimit

            async let recommendationsRequest = recommendationSources(
                seeds: Array(
                    (starredSongs + randomSongValues).prefix(
                        OpenSubsonicRequestPolicy.homeRecommendationSeedLimit
                    )
                ),
                count: resultLimit,
                limiter: enrichmentLimiter
            )
            async let rankedSongsRequest = mostPlayedSongs(
                from: frequentAlbums,
                fallback: fallback.mostPlayedSongs,
                limiter: enrichmentLimiter
            )
            async let artistRecommendationsRequest = similarArtists(
                to: Array(
                    starredArtists.prefix(
                        OpenSubsonicRequestPolicy.homeSimilarArtistLimit
                    )
                ),
                fallback: fallback.recommendedArtists,
                limiter: enrichmentLimiter
            )
            async let genreSongsRequest = songsByGenres(
                Array(
                    preferredGenres.prefix(OpenSubsonicRequestPolicy.homeGenreLimit)
                ),
                fallback: fallback.genreRecommendedSongs,
                count: resultLimit,
                limiter: enrichmentLimiter
            )
            async let topArtistSongsRequest = topSongs(
                for: Array(
                    starredArtists.prefix(
                        OpenSubsonicRequestPolicy.homeTopArtistLimit
                    )
                ),
                fallback: fallback.topArtistSongs,
                count: resultLimit,
                limiter: enrichmentLimiter
            )
            async let recentlyAddedSongsRequest = songs(
                from: Array(
                    recentAlbums.prefix(
                        OpenSubsonicRequestPolicy.homeAlbumTrackLimit
                    )
                ),
                fallback: fallback.recentlyAddedSongs,
                count: resultLimit,
                limiter: enrichmentLimiter
            )
            let popularAlbumsValue = try await popularAlbumsRequest
            let popularAlbumValues = albums(from: popularAlbumsValue, fallback: [])
            async let popularSongsRequest = songs(
                from: Array(
                    popularAlbumValues.prefix(
                        OpenSubsonicRequestPolicy.homeAlbumTrackLimit
                    )
                ),
                fallback: fallback.popularSongs,
                count: resultLimit,
                limiter: enrichmentLimiter
            )
            async let playlistAffinityRequest = playlistAffinitySongs(
                from: Array(
                    playlistValues.prefix(
                        OpenSubsonicRequestPolicy.homePlaylistLimit
                    )
                ),
                fallback: fallback.playlistAffinitySongs,
                count: resultLimit,
                limiter: enrichmentLimiter
            )
            let (
                recommendationSources,
                rankedServerSongs,
                artistRecommendations,
                genreSongs,
                topArtistSongs,
                recentlyAddedSongs,
                popularSongs,
                playlistAffinitySongs
            ) = await (
                recommendationsRequest,
                rankedSongsRequest,
                artistRecommendationsRequest,
                genreSongsRequest,
                topArtistSongsRequest,
                recentlyAddedSongsRequest,
                popularSongsRequest,
                playlistAffinityRequest
            )
            let serverRecommendations = Self.uniqueSongs(
                recommendationSources.combined
                    + genreSongs
                    + topArtistSongs
                    + recentlyAddedSongs
                    + popularSongs
                    + playlistAffinitySongs
            )
            snapshot.sonicRecommendedSongs = recommendationSources.sonic
            snapshot.similarArtistSongs = recommendationSources.similarArtists
            snapshot.genreRecommendedSongs = genreSongs
            snapshot.topArtistSongs = topArtistSongs
            snapshot.recentlyAddedSongs = recentlyAddedSongs
            snapshot.popularSongs = popularSongs
            snapshot.playlistAffinitySongs = playlistAffinitySongs
            snapshot.serverRecommendedSongs = serverRecommendations
            snapshot.recommendedSongs = serverRecommendations
            snapshot.mostPlayedSongs = rankedServerSongs
            snapshot.recommendedArtists = artistRecommendations
        }
        snapshot.daylistSongs = DaylistBuilder.make(snapshot: snapshot)
        return HomeLoadResult(
            snapshot: snapshot,
            hasAuthoritativeStarredState: starredValue?.container != nil
        )
    }

    func incrementalHome(from previous: HomeSnapshot) async throws -> HomeLoadResult {
        async let recent: AlbumListPayload? = albumList("newest", size: "16")
        async let recentlyPlayed: AlbumListPayload? = albumList("recent", size: "16")
        async let frequent: AlbumListPayload? = albumList("frequent", size: "16")
        async let starred: StarredPayload? = bestEffortWithFallback(
            SubsonicCompatibilityPolicy.starredEndpoints(for: apiFamily)
        )
        async let playlists: PlaylistsPayload? = bestEffortRequest("getPlaylists")

        let values = try await (recent, recentlyPlayed, frequent, starred, playlists)
        guard values.0 != nil || values.1 != nil || values.2 != nil ||
                values.3 != nil || values.4 != nil else {
            throw OpenSubsonicError.invalidResponse
        }

        var snapshot = previous
        if let recent = values.0 {
            snapshot.recentAlbums = recent.albums
        }
        if let recent = values.1 {
            snapshot.recentlyPlayedAlbums = recent.albums
        }
        if let frequent = values.2 {
            let frequentAlbums = frequent.albums
            snapshot.frequentAlbums = frequentAlbums
            let previousIDs = previous.frequentAlbums
                .prefix(OpenSubsonicRequestPolicy.homeMostPlayedAlbumLimit)
                .map(\.id)
            let nextIDs = frequentAlbums
                .prefix(OpenSubsonicRequestPolicy.homeMostPlayedAlbumLimit)
                .map(\.id)
            if previous.mostPlayedSongs.isEmpty || previousIDs != nextIDs {
                snapshot.mostPlayedSongs = await mostPlayedSongs(
                    from: frequentAlbums,
                    fallback: previous.mostPlayedSongs
                )
            }
        }
        if let starred = values.3?.container {
            snapshot.starredAlbums = starred.album ?? []
            snapshot.starredSongs = starred.song ?? []
            snapshot.starredArtists = starred.artist ?? []
        }
        if let playlists = values.4 {
            snapshot.playlists = playlists.playlists?.playlist ?? []
        }
        return HomeLoadResult(
            snapshot: snapshot,
            hasAuthoritativeStarredState: values.3?.container != nil
        )
    }

    func radioQueue(seed: Song, count: Int = 30) async -> [Song] {
        await recommendationQueue(seeds: [seed], fallback: [], count: count)
    }

    func autoplayQueue(
        seed: Song,
        excluding excludedIDs: Set<String>,
        count: Int = 16
    ) async -> [Song] {
        let recommended = await recommendationQueue(
            seeds: [seed],
            fallback: [],
            count: max(count, 12)
        )
        var values = recommended.filter { !excludedIDs.contains($0.id) }
        if values.count < count {
            let parameters: [String: String]
            if let genre = seed.genre?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !genre.isEmpty {
                parameters = ["size": "\(max(count * 2, 24))", "genre": genre]
            } else {
                parameters = ["size": "\(max(count * 2, 24))"]
            }
            let random: RandomSongsPayload? = try? await readRequest(
                "getRandomSongs",
                parameters: parameters
            )
            values.append(contentsOf: random?.randomSongs?.song ?? [])
        }
        return Array(
            Self.uniqueSongs(values)
                .filter { $0.id != seed.id && !excludedIDs.contains($0.id) }
                .prefix(count)
        )
    }

    func matchExternalRecommendations(
        _ candidates: [ExternalRecommendationCandidate],
        library: [Song] = [],
        limit: Int = 10
    ) async -> [Song] {
        await LocalLibraryCatalog.shared.match(
            candidates,
            additionalSongs: library,
            limit: limit
        )
    }

    func expandLibraryCatalog(
        excluding excludedIDs: Set<String>,
        limit: Int = 400
    ) async -> [Song] {
        var collected: [Song] = []
        collected.reserveCapacity(min(limit, 160))
        for _ in 0..<2 {
            guard !Task.isCancelled, collected.count < limit else { break }
            let payload: RandomSongsPayload? = try? await readRequest(
                "getRandomSongs",
                parameters: ["size": "80"]
            )
            collected.append(contentsOf: payload?.randomSongs?.song ?? [])
        }
        return Array(
            Self.uniqueSongs(collected)
                .filter {
                    $0.externalStreamURL == nil
                        && !excludedIDs.contains($0.id)
                }
                .prefix(limit)
        )
    }

    private func recommendationQueue(
        seeds: [Song],
        fallback: [Song],
        count: Int = 24
    ) async -> [Song] {
        let sources = await recommendationSources(
            seeds: seeds,
            count: count
        )
        return sources.combined.isEmpty
            ? fallback
            : Array(sources.combined.prefix(count))
    }

    private func recommendationSources(
        seeds: [Song],
        count: Int = 24,
        limiter: HomeEnrichmentRequestLimiter? = nil
    ) async -> ServerRecommendationSources {
        let distinctSeeds = Self.uniqueSongs(seeds)
        guard !distinctSeeds.isEmpty else {
            return ServerRecommendationSources()
        }
        var sonicSongs: [Song] = []
        var similarArtistSongs: [Song] = []
        let similarEndpoints = SubsonicCompatibilityPolicy.similarSongEndpoints(
            for: apiFamily
        )
        let supportsSonicExtension = await supportsExtension(
            "sonicSimilarity",
            limiter: limiter
        )
        let supportsSonic = similarEndpoints.contains("getSonicSimilarTracks")
            && supportsSonicExtension

        for seed in distinctSeeds.prefix(
            OpenSubsonicRequestPolicy.homeRecommendationSeedLimit
        ) {
            guard !Task.isCancelled else { break }
            async let sonicResult = sonicRecommendations(
                for: seed,
                count: count,
                enabled: supportsSonic,
                limiter: limiter
            )
            async let similarResult = similarArtistRecommendations(
                for: seed,
                count: count,
                enabled: similarArtistSongs.count < count,
                limiter: limiter
            )
            let (sonic, similar) = await (sonicResult, similarResult)
            sonicSongs.append(contentsOf: sonic)
            similarArtistSongs.append(contentsOf: similar)
            if sonicSongs.count >= count,
               similarArtistSongs.count >= count {
                break
            }
        }

        let seedIDs = Set(distinctSeeds.map(\.id))
        return ServerRecommendationSources(
            sonic: Array(
                Self.uniqueSongs(sonicSongs)
                    .filter { !seedIDs.contains($0.id) }
                    .prefix(count)
            ),
            similarArtists: Array(
                Self.uniqueSongs(similarArtistSongs)
                    .filter { !seedIDs.contains($0.id) }
                    .prefix(count)
            )
        )
    }

    private func sonicRecommendations(
        for seed: Song,
        count: Int,
        enabled: Bool,
        limiter: HomeEnrichmentRequestLimiter?
    ) async -> [Song] {
        guard enabled, !Task.isCancelled else { return [] }
        let payload: SonicSimilarPayload? = try? await withEnrichmentPermit(
            limiter
        ) { [self] in
            try await readRequest(
                "getSonicSimilarTracks",
                parameters: ["id": seed.id, "count": "\(max(8, count))"]
            )
        }
        return (payload?.sonicMatch ?? [])
            .sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
            .map(\.entry)
    }

    private func similarArtistRecommendations(
        for seed: Song,
        count: Int,
        enabled: Bool,
        limiter: HomeEnrichmentRequestLimiter?
    ) async -> [Song] {
        guard enabled,
              !Task.isCancelled,
              let artistID = seed.artistId else {
            return []
        }
        let payload: SimilarSongsPayload? = try? await withEnrichmentPermit(
            limiter
        ) { [self] in
            try await readWithFallback(
                SubsonicCompatibilityPolicy.similarSongEndpoints(for: apiFamily)
                    .filter { $0 != "getSonicSimilarTracks" },
                parameters: ["id": artistID, "count": "\(max(8, count))"]
            )
        }
        return payload?.similarSongs2?.song
            ?? payload?.similarSongs?.song
            ?? []
    }

    private func supportsExtension(
        _ name: String,
        limiter: HomeEnrichmentRequestLimiter? = nil
    ) async -> Bool {
        if let supportedExtensions {
            return supportedExtensions.contains(name)
        }
        let payload: OpenSubsonicExtensionsPayload
        do {
            payload = try await withEnrichmentPermit(limiter) { [self] in
                try await readRequest("getOpenSubsonicExtensions")
            }
        } catch {
            // A transient/auth/cancellation failure is not an authoritative
            // statement that the server supports no extensions. Leave the
            // cache unresolved so a later healthy request can recover.
            return false
        }
        let names = Set(
            (payload.openSubsonicExtensions ?? []).compactMap { value in
                value.versions.isEmpty ? nil : value.name
            }
        )
        supportedExtensions = names
        return names.contains(name)
    }

    private func withEnrichmentPermit<Value: Sendable>(
        _ limiter: HomeEnrichmentRequestLimiter?,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let limiter else {
            return try await operation()
        }
        return try await limiter.withPermit(operation)
    }

    private func songsByGenres(
        _ genres: [String],
        fallback: [Song],
        count: Int = 24,
        limiter: HomeEnrichmentRequestLimiter? = nil
    ) async -> [Song] {
        guard !genres.isEmpty else { return fallback }
        let values = await withTaskGroup(
            of: (Int, [Song]).self,
            returning: [(Int, [Song])].self
        ) { group in
            for (index, genre) in genres
                .prefix(OpenSubsonicRequestPolicy.homeGenreLimit)
                .enumerated() {
                group.addTask { [self] in
                    let payload: SongsByGenrePayload? = try? await
                        withEnrichmentPermit(limiter) { [self] in
                            try await readRequest(
                                "getSongsByGenre",
                                parameters: [
                                    "genre": genre,
                                    "count": "\(count)",
                                    "offset": "0"
                                ]
                            )
                        }
                    return (index, payload?.songsByGenre?.song ?? [])
                }
            }
            var result: [(Int, [Song])] = []
            for await value in group { result.append(value) }
            return result
        }
        let songs = Self.uniqueSongs(
            values.sorted { $0.0 < $1.0 }.flatMap(\.1)
        )
        return songs.isEmpty ? fallback : Array(songs.prefix(count))
    }

    private func topSongs(
        for artists: [Artist],
        fallback: [Song],
        count: Int = 24,
        limiter: HomeEnrichmentRequestLimiter? = nil
    ) async -> [Song] {
        guard !artists.isEmpty else { return fallback }
        let usesArtistID = await supportsExtension(
            "topSongsByArtistId",
            limiter: limiter
        )
        let values = await withTaskGroup(
            of: (Int, [Song]).self,
            returning: [(Int, [Song])].self
        ) { group in
            for (index, artist) in artists
                .prefix(OpenSubsonicRequestPolicy.homeTopArtistLimit)
                .enumerated() {
                group.addTask { [self] in
                    var parameters = [
                        "artist": artist.name,
                        "count": "\(count)"
                    ]
                    if usesArtistID {
                        parameters["id"] = artist.id
                    }
                    let requestParameters = parameters
                    let payload: TopSongsPayload? = try? await
                        withEnrichmentPermit(limiter) { [self] in
                            try await readRequest(
                                "getTopSongs",
                                parameters: requestParameters
                            )
                        }
                    return (index, payload?.topSongs?.song ?? [])
                }
            }
            var result: [(Int, [Song])] = []
            for await value in group { result.append(value) }
            return result
        }
        let songs = Self.uniqueSongsByIdentity(
            values.sorted { $0.0 < $1.0 }.flatMap(\.1)
        )
        return songs.isEmpty ? fallback : Array(songs.prefix(count))
    }

    private func songs(
        from albums: [Album],
        fallback: [Song],
        count: Int = 30,
        limiter: HomeEnrichmentRequestLimiter? = nil
    ) async -> [Song] {
        guard !albums.isEmpty else { return fallback }
        let values = await withTaskGroup(
            of: (Int, [Song]).self,
            returning: [(Int, [Song])].self
        ) { group in
            for (index, album) in albums
                .prefix(OpenSubsonicRequestPolicy.homeAlbumTrackLimit)
                .enumerated() {
                group.addTask { [self] in
                    let detail = try? await withEnrichmentPermit(
                        limiter
                    ) { [self] in
                        try await self.album(id: album.id)
                    }
                    return (index, detail?.songs ?? [])
                }
            }
            var result: [(Int, [Song])] = []
            for await value in group { result.append(value) }
            return result
        }
        let songs = Self.uniqueSongs(
            values.sorted { $0.0 < $1.0 }.flatMap(\.1)
        )
        return songs.isEmpty ? fallback : Array(songs.prefix(count))
    }

    private func playlistAffinitySongs(
        from playlists: [Playlist],
        fallback: [Song],
        count: Int = 30,
        limiter: HomeEnrichmentRequestLimiter? = nil
    ) async -> [Song] {
        guard !playlists.isEmpty else { return fallback }
        let values = await withTaskGroup(
            of: (Int, [Song]).self,
            returning: [(Int, [Song])].self
        ) { group in
            for (index, playlist) in playlists
                .prefix(OpenSubsonicRequestPolicy.homePlaylistLimit)
                .enumerated() {
                group.addTask { [self] in
                    (
                        index,
                        (try? await withEnrichmentPermit(
                            limiter
                        ) { [self] in
                            try await self.playlist(id: playlist.id)
                        })?.songs ?? []
                    )
                }
            }
            var result: [(Int, [Song])] = []
            for await value in group { result.append(value) }
            return result
        }
        let songs = PlaylistAffinityRanking.rank(values, limit: count)
        return songs.isEmpty ? fallback : Array(songs.prefix(count))
    }

    private func mostPlayedSongs(
        from albums: [Album],
        fallback: [Song],
        limiter: HomeEnrichmentRequestLimiter? = nil
    ) async -> [Song] {
        let candidates = Array(
            albums.prefix(OpenSubsonicRequestPolicy.homeMostPlayedAlbumLimit)
        )
        guard !candidates.isEmpty else { return fallback }
        let songs = await withTaskGroup(
            of: (Int, [Song]).self,
            returning: [Song].self
        ) { group in
            for (index, album) in candidates.enumerated() {
                group.addTask { [self] in
                    let detail = try? await withEnrichmentPermit(
                        limiter
                    ) { [self] in
                        try await self.album(id: album.id)
                    }
                    return (index, detail?.songs ?? [])
                }
            }
            var values: [(Int, [Song])] = []
            for await value in group {
                values.append(value)
            }
            return values
                .sorted { $0.0 < $1.0 }
                .flatMap(\.1)
        }
        let ranked = Self.uniqueSongs(songs)
            .filter { ($0.playCount ?? 0) > 0 }
            .sorted { lhs, rhs in
                let lhsCount = lhs.playCount ?? 0
                let rhsCount = rhs.playCount ?? 0
                if lhsCount == rhsCount {
                    return (lhs.played ?? "") > (rhs.played ?? "")
                }
                return lhsCount > rhsCount
            }
        return ranked.isEmpty ? fallback : Array(ranked.prefix(30))
    }

    private func similarArtists(
        to seeds: [Artist],
        fallback: [Artist],
        limiter: HomeEnrichmentRequestLimiter? = nil
    ) async -> [Artist] {
        let candidates = Array(
            seeds.prefix(OpenSubsonicRequestPolicy.homeSimilarArtistLimit)
        )
        guard !candidates.isEmpty else { return fallback }
        let values = await withTaskGroup(
            of: [Artist].self,
            returning: [Artist].self
        ) { group in
            for artist in candidates {
                group.addTask { [self] in
                    let payload: ArtistInfoPayload? = try? await
                        withEnrichmentPermit(limiter) { [self] in
                            try await readRequest(
                                "getArtistInfo2",
                                parameters: [
                                    "id": artist.id,
                                    "count": "8",
                                    "includeNotPresent": "false"
                                ]
                            )
                        }
                    return payload?.artistInfo2?.similarArtist ?? []
                }
            }
            var artists: [Artist] = []
            for await result in group {
                artists.append(contentsOf: result)
            }
            return artists
        }
        let seedIDs = Set(candidates.map(\.id))
        let result = Self.uniqueArtists(values)
            .filter { !seedIDs.contains($0.id) }
        return result.isEmpty ? fallback : Array(result.prefix(12))
    }

    private func albumList(
        _ type: String,
        size: String
    ) async throws -> AlbumListPayload? {
        try await bestEffortWithFallback(
            SubsonicCompatibilityPolicy.albumListEndpoints(for: apiFamily),
            parameters: ["type": type, "size": size]
        )
    }

    private func albums(
        from payload: AlbumListPayload?,
        fallback: [Album]
    ) -> [Album] {
        payload.map(\.albums) ?? fallback
    }

    private static func uniqueSongs(_ songs: [Song]) -> [Song] {
        MediaIdentity.uniqueSongs(songs)
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var keys = Set<String>()
        return values.filter {
            let key = normalized($0)
            return !key.isEmpty && keys.insert(key).inserted
        }
    }

    private static func uniqueSongsByIdentity(_ songs: [Song]) -> [Song] {
        var ids = Set<String>()
        var mbids = Set<String>()
        var metadata = Set<String>()
        return songs.filter { song in
            guard !song.id.isEmpty, !ids.contains(song.id) else { return false }
            let mbid = normalized(song.musicBrainzId ?? "")
            let identity = [
                normalized(song.title),
                normalized(song.artist),
                normalized(song.album)
            ].joined(separator: "\u{1F}")
            if !mbid.isEmpty, mbids.contains(mbid) {
                return false
            }
            if metadata.contains(identity) {
                return false
            }
            ids.insert(song.id)
            if !mbid.isEmpty { mbids.insert(mbid) }
            metadata.insert(identity)
            return true
        }
    }

    private static func uniqueArtists(_ artists: [Artist]) -> [Artist] {
        MediaIdentity.uniqueArtists(artists)
    }

    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: normalizationLocale
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search(_ query: String) async throws -> SearchResults {
        let parameters = [
            "query": query,
            "artistCount": "8",
            "albumCount": "14",
            "songCount": "30"
        ]
        let payload: SearchPayload = try await readWithFallback(
            SubsonicCompatibilityPolicy.searchEndpoints(for: apiFamily),
            parameters: parameters
        )
        return Self.deduplicatedSearch(
            payload.searchResult3 ?? payload.searchResult2
        )
    }

    private static func deduplicatedSearch(_ result: SearchContainer?) -> SearchResults {
        func unique<T: Identifiable>(_ items: [T]) -> [T] where T.ID == String {
            var ids = Set<String>()
            return items.filter { ids.insert($0.id).inserted }
        }
        return SearchResults(
            artists: unique(result?.artist ?? []),
            albums: unique(result?.album ?? []),
            songs: unique(result?.song ?? [])
        )
    }

    func album(id: String) async throws -> AlbumDetail {
        let payload: AlbumPayload = try await readRequest("getAlbum", parameters: ["id": id])
        guard let value = payload.album else { throw OpenSubsonicError.invalidResponse }
        let albumID = value.id ?? id
        let songs = AlbumSongMetadataResolver.resolve(
            songs: value.song ?? [],
            albumID: albumID,
            coverArt: value.coverArt
        )
        let album = value.name.map {
            Album(
                id: albumID,
                name: $0,
                artist: value.artist ?? "",
                coverArt: value.coverArt,
                year: value.year,
                starred: value.starred,
                songCount: value.songCount ?? songs.count
            )
        }
        return AlbumDetail(songs: songs, album: album)
    }

    /// Returns the server's current canonical metadata for one song. List and
    /// recommendation responses can have different cache ages; resolving the
    /// selected item through getSong gives playback one authoritative source
    /// for song ID, cover-art ID, duration, and media format.
    func song(id: String, forceRefresh: Bool = false) async throws -> Song {
        let payload: SongPayload = try await readRequest(
            "getSong",
            parameters: ["id": id],
            allowsCachedResponse: !forceRefresh
        )
        guard let song = payload.song, song.id == id else {
            throw OpenSubsonicError.invalidResponse
        }
        return song
    }

    /// Canonical API boundary for an active playback occurrence. The caller's
    /// UUID survives metadata refresh, while all server-owned media fields are
    /// replaced together from one `getSong` response.
    func playbackMedia(
        for provisional: Song,
        queueEntryID: UUID,
        playbackGenerationID: UUID
    ) async throws -> PlaybackMediaItem {
        // getSong is already short-lived, mutation-aware, and conditionally
        // revalidated. Reusing its canonical response avoids an otherwise
        // unconditional API round trip whenever a cached queue item is played.
        let canonical = try await song(id: provisional.id)
        let resolved = PlaybackMetadataResolver.resolve(
            canonical: canonical,
            provisional: provisional
        )
        return PlaybackMediaItem(
            song: resolved,
            accountScope: accountScope,
            queueEntryID: queueEntryID,
            playbackGenerationID: playbackGenerationID
        )
    }

    func playlist(id: String) async throws -> PlaylistDetail {
        let payload: PlaylistPayload = try await readRequest("getPlaylist", parameters: ["id": id])
        guard let value = payload.playlist else { throw OpenSubsonicError.invalidResponse }
        let songs = value.entry ?? []
        let playlist = value.name.map {
            Playlist(
                id: value.id ?? id,
                name: $0,
                owner: value.owner,
                songCount: value.songCount ?? songs.count,
                coverArt: value.coverArt
            )
        }
        return PlaylistDetail(songs: songs, playlist: playlist)
    }

    func artist(id: String, name: String) async throws -> ArtistDetail {
        let usesArtistID = await supportsExtension("topSongsByArtistId")
        if usesArtistID {
            async let albumsPayload: ArtistAlbumsPayload = readRequest(
                "getArtist",
                parameters: ["id": id]
            )
            async let infoPayload: ArtistInfoPayload? = bestEffortRequest(
                "getArtistInfo2",
                parameters: ["id": id, "count": "8", "includeNotPresent": "false"]
            )
            async let topPayload: TopSongsPayload = readRequest(
                "getTopSongs",
                parameters: ["id": id, "artist": name, "count": "20"]
            )
            let (albums, info, top) = try await (
                albumsPayload,
                infoPayload,
                topPayload
            )
            guard let artist = albums.artist else {
                throw OpenSubsonicError.invalidResponse
            }
            return ArtistDetail(
                artist: artist.artistValue,
                albums: artist.album ?? [],
                topSongs: Self.uniqueSongsByIdentity(top.topSongs?.song ?? []),
                info: info?.artistInfo2
            )
        }

        async let albumsPayload: ArtistAlbumsPayload = readRequest(
            "getArtist",
            parameters: ["id": id]
        )
        async let infoPayload: ArtistInfoPayload? = bestEffortRequest(
            "getArtistInfo2",
            parameters: ["id": id, "count": "8", "includeNotPresent": "false"]
        )
        let albums = try await albumsPayload
        guard let artist = albums.artist else {
            throw OpenSubsonicError.invalidResponse
        }
        let top: TopSongsPayload = try await readRequest(
            "getTopSongs",
            parameters: ["artist": artist.name, "count": "20"]
        )
        let info = try await infoPayload
        return ArtistDetail(
            artist: artist.artistValue,
            albums: artist.album ?? [],
            topSongs: Self.uniqueSongsByIdentity(top.topSongs?.song ?? []),
            info: info?.artistInfo2
        )
    }

    func lyrics(
        songID: String,
        artist: String? = nil,
        title: String? = nil,
        forceRefresh: Bool = false
    ) async throws -> LyricsDocument {
        if !forceRefresh,
           let cached = lyricsCache.value(
               for: songID,
               maximumAge: 6 * 60 * 60,
               emptyMaximumAge: 30 * 60
           ) {
            return cached
        }
        if !forceRefresh,
           let persisted = await AppDatabase.shared.loadLyricsDocument(
               scope: accountScope,
               songID: songID,
               maximumAge: Self.persistedLyricsMaximumAge
           ) {
            lyricsCache.insert(persisted, for: songID)
            return persisted
        }
        let document: LyricsDocument
        let structuredRequestSucceeded: Bool
        let lyricsEndpoints = SubsonicCompatibilityPolicy.lyricsEndpoints(
            for: apiFamily
        )
        if lyricsEndpoints.contains("getLyricsBySongId") {
            do {
                let payload: LyricsPayload = try await readRequest(
                    "getLyricsBySongId",
                    parameters: ["id": songID]
                )
                document = LyricsDocumentParser.parse(payload)
                structuredRequestSucceeded = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                document = .empty
                structuredRequestSucceeded = false
            }
        } else {
            document = .empty
            structuredRequestSucceeded = false
        }
        if !document.lines.isEmpty {
            cachePositiveLyrics(document, songID: songID)
            return document
        }

        let normalizedArtist = artist?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        let normalizedTitle = title?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        guard !normalizedArtist.isEmpty, !normalizedTitle.isEmpty else {
            lyricsCache.insert(.empty, for: songID)
            return .empty
        }
        let legacyPayload: LegacyLyricsPayload
        do {
            legacyPayload = try await readRequest(
                "getLyrics",
                parameters: [
                    "artist": normalizedArtist,
                    "title": normalizedTitle
                ]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A successful structured response is authoritative even when the
            // optional legacy endpoint is unavailable on this server.
            if structuredRequestSucceeded {
                lyricsCache.insert(.empty, for: songID)
                return .empty
            }
            throw error
        }
        let legacyDocument = LyricsDocumentParser.parse(legacyPayload)
        if !legacyDocument.lines.isEmpty {
            cachePositiveLyrics(legacyDocument, songID: songID)
            return legacyDocument
        }
        lyricsCache.insert(.empty, for: songID)
        return legacyDocument
    }

    private func cachePositiveLyrics(
        _ document: LyricsDocument,
        songID: String
    ) {
        guard !document.lines.isEmpty else { return }
        lyricsCache.insert(document, for: songID)
        let scope = accountScope
        Task(priority: .utility) {
            _ = await AppDatabase.shared.saveLyricsDocument(
                document,
                scope: scope,
                songID: songID
            )
        }
    }

    /// Warms the same canonical getSong representation consumed by playback.
    /// Failures retain provisional queue metadata so speculative work can
    /// never make a playable queue entry unavailable.
    func prefetchPlaybackMetadata(songs: [Song]) async -> [Song] {
        var seen = Set<String>()
        let uniqueSongs = songs.prefix(3).filter {
            seen.insert($0.id).inserted
        }
        return await withTaskGroup(of: (Int, Song).self) { group in
            for (index, provisional) in uniqueSongs.enumerated() {
                group.addTask { [self] in
                    guard !Task.isCancelled,
                          let canonical = try? await song(id: provisional.id) else {
                        return (index, provisional)
                    }
                    return (
                        index,
                        PlaybackMetadataResolver.resolve(
                            canonical: canonical,
                            provisional: provisional
                        )
                    )
                }
            }
            var values: [(Int, Song)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    func prefetchLyrics(songs: [Song]) async {
        var seen = Set<String>()
        let uniqueSongs = songs.prefix(2).filter {
            seen.insert($0.id).inserted
        }
        await withTaskGroup(of: Void.self) { group in
            for song in uniqueSongs {
                group.addTask { [self] in
                    guard !Task.isCancelled else { return }
                    _ = try? await lyrics(
                        songID: song.id,
                        artist: song.artist,
                        title: song.title
                    )
                }
            }
            await group.waitForAll()
        }
    }

    func trimTransientNetworkCaches() {
        // Memory pressure should not turn a visible, awaited request into a
        // user-facing cancellation. Shared transfers are released naturally
        // when their last waiter goes away.
        clearResponseCache()
        lyricsCache.removeAll(keepingCapacity: true)
    }

    nonisolated func streamURL(
        songID: String,
        quality: StreamQuality,
        compatibilityFormat: String? = nil
    ) throws -> URL {
        let requestedFormat = compatibilityFormat ?? quality.parameters["format"]
        let requestedBitRate: Int?
        if let compatibilityFormat {
            requestedBitRate = Self.compatibilityBitRate(
                for: quality,
                format: compatibilityFormat
            )
        } else if let value = quality.parameters["maxBitRate"], let bitRate = Int(value), bitRate > 0 {
            requestedBitRate = bitRate
        } else {
            requestedBitRate = nil
        }
        guard let url = swiftSonic.streamURL(
            id: songID,
            maxBitRate: requestedBitRate,
            format: requestedFormat,
            estimateContentLength: true
        ), url.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        return url
    }

    func writeStreamSample(
        from url: URL,
        songID: String,
        maxBytes: Int = 1_600_000
    ) async -> URL? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 24
        ModernNetworkPolicy.prepareAnalysisMediaRequest(&request)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count > 8_000 else {
                return nil
            }
            return Self.writeTemporaryAudioSample(
                data,
                songID: songID,
                contentType: http.value(forHTTPHeaderField: "Content-Type")
            )
        } catch {
            return nil
        }
    }

    private static func writeTemporaryAudioSample(
        _ data: Data,
        songID: String,
        contentType: String?
    ) -> URL? {
        let type = (contentType ?? "").lowercased()
        let ext: String
        if type.contains("mpeg") || type.contains("mp3") {
            ext = "mp3"
        } else if type.contains("mp4") || type.contains("m4a") {
            ext = "m4a"
        } else if type.contains("aac") {
            ext = "aac"
        } else if type.contains("ogg") || type.contains("opus") {
            ext = "ogg"
        } else {
            ext = "m4a"
        }
        let name = String(
            songID.unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .prefix(48)
                .map(Character.init)
        )
        let fileName = name.isEmpty ? "sample" : name
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuFiSound", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let file = folder.appendingPathComponent("\(fileName).\(ext)")
        do {
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    static func compatibilityBitRate(
        for quality: StreamQuality,
        format: String
    ) -> Int? {
        let constrainedFallbackBitRate = quality == .opus160 ? 160 : 256
        return switch format.lowercased() {
        case "aac": quality == .aac320 ? 320 : constrainedFallbackBitRate
        case "opus": 160
        case "mp3": constrainedFallbackBitRate
        case "raw": nil
        default: constrainedFallbackBitRate
        }
    }

    nonisolated func coverURL(id: String, size: Int? = nil) throws -> URL {
        guard let url = swiftSonic.coverArtURL(id: id, size: size),
              url.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        return url
    }

    nonisolated func downloadURL(songID: String) throws -> URL {
        guard let url = swiftSonic.downloadURL(id: songID),
              url.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        return url
    }

    enum StarTarget: Sendable {
        case song
        case album
        case artist

        var parameterName: String {
            switch self {
            case .song: "id"
            case .album: "albumId"
            case .artist: "artistId"
            }
        }
    }

    func star(id: String, target: StarTarget = .song, enabled: Bool) async throws {
        let _: EmptyPayload = try await mutationRequest(
            enabled ? "star" : "unstar",
            parameters: [target.parameterName: id]
        )
    }

    func scrobble(id: String, submission: Bool) async throws {
        let _: EmptyPayload = try await mutationRequest(
            "scrobble",
            parameters: [
                "id": id,
                "submission": submission ? "true" : "false",
                "time": String(Int(Date().timeIntervalSince1970 * 1_000))
            ]
        )
    }

    func reportPlayback(
        id: String,
        position: TimeInterval,
        state: String
    ) async throws {
        let extensionNames: Set<String>
        if let supportedExtensions {
            extensionNames = supportedExtensions
        } else {
            let payload: OpenSubsonicExtensionsPayload = try await readRequest(
                "getOpenSubsonicExtensions"
            )
            extensionNames = Set(
                (payload.openSubsonicExtensions ?? []).compactMap { value in
                    value.versions.isEmpty ? nil : value.name
                }
            )
            supportedExtensions = extensionNames
        }
        guard extensionNames.contains("playbackReport") else { return }
        let allowedStates = ["starting", "playing", "paused", "stopped"]
        guard allowedStates.contains(state) else { return }
        let positionMs = Self.boundedMilliseconds(from: position)
        let _: EmptyPayload = try await mutationRequest(
            "reportPlayback",
            parameters: [
                "mediaId": id,
                "mediaType": "song",
                "positionMs": "\(positionMs)",
                "state": state,
                "playbackRate": "1.0",
                "ignoreScrobble": "false"
            ]
        )
    }

    func playQueue() async throws -> ServerPlayQueue {
        let payload: PlayQueuePayload = try await readRequest("getPlayQueue")
        let queue = payload.playQueue
        return ServerPlayQueue(
            songs: queue?.entry ?? [],
            currentID: queue?.current,
            position: TimeInterval(queue?.position ?? 0) / 1_000
        )
    }

    func savePlayQueue(songIDs: [String], current: String, position: TimeInterval) async throws {
        var queryItems = songIDs.map { URLQueryItem(name: "id", value: $0) }
        queryItems += [
            URLQueryItem(name: "current", value: current),
            URLQueryItem(
                name: "position",
                value: String(Self.boundedMilliseconds(from: position))
            )
        ]
        let _: EmptyPayload = try await formMutationRequest(
            "savePlayQueue",
            queryItems: queryItems
        )
    }

    private nonisolated static func boundedMilliseconds(
        from position: TimeInterval
    ) -> Int {
        guard position.isFinite, position > 0 else { return 0 }
        let maximumSeconds = Double(Int.max) / 1_000
        guard position < maximumSeconds else { return Int.max }
        return Int(position * 1_000)
    }
}
