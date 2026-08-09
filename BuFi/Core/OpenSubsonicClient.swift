import CryptoKit
import Foundation
import OSLog
import SwiftSonic

enum OpenSubsonicError: LocalizedError, Equatable, Sendable {
    case invalidServerURL
    case insecureServerURL
    case invalidResponse
    case server(code: Int?, message: String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            String(localized: "서버 주소가 올바르지 않습니다.")
        case .insecureServerURL:
            String(localized: "보안을 위해 HTTPS 서버 주소만 사용할 수 있습니다.")
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

/// A structural key for OpenSubsonic requests. Keeping query names and values
/// as separate fields avoids collisions such as `a=b&c=d` being interpreted as
/// either one value or two query items.
struct OpenSubsonicRequestKey: Hashable, Sendable {
    struct QueryItem: Hashable, Sendable {
        let name: String
        let value: String?
    }

    let endpoint: String
    let queryItems: [QueryItem]

    init(endpoint: String, queryItems: [URLQueryItem]) {
        self.endpoint = endpoint
        self.queryItems = queryItems
            .map { QueryItem(name: $0.name, value: $0.value) }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                switch (lhs.value, rhs.value) {
                case (nil, nil):
                    return false
                case (nil, _):
                    return true
                case (_, nil):
                    return false
                case (.some(let lhsValue), .some(let rhsValue)):
                    return lhsValue < rhsValue
                }
            }
    }

    func containsQueryItem(name: String, value: String) -> Bool {
        queryItems.contains { $0.name == name && $0.value == value }
    }
}

/// Defines the read-cache dependencies of the mutations BuFi currently sends.
/// Unknown mutations retain the conservative clear-all behavior so a future
/// endpoint cannot silently leave unrelated model data stale.
enum OpenSubsonicCacheInvalidationPolicy {
    static func shouldInvalidate(
        _ key: OpenSubsonicRequestKey,
        afterMutation mutationEndpoint: String
    ) -> Bool {
        switch mutationEndpoint {
        case "star", "unstar":
            return key.endpoint == "getStarred"
                || key.endpoint == "getStarred2"
                || ((key.endpoint == "getAlbumList"
                        || key.endpoint == "getAlbumList2")
                    && key.containsQueryItem(name: "type", value: "starred"))
        case "savePlayQueue":
            return key.endpoint == "getPlayQueue"
        case "reportPlayback", "scrobble":
            return key.endpoint == "getNowPlaying"
                || key.endpoint == "getNowPlaying2"
                || ((key.endpoint == "getAlbumList"
                        || key.endpoint == "getAlbumList2")
                    && ["recent", "frequent", "highest"].contains { type in
                        key.containsQueryItem(name: "type", value: type)
                    })
        default:
            return true
        }
    }
}

/// A successful mutation advances this generation. Each coalesced read is
/// stamped when its underlying transfer starts, so a response that completes
/// after a mutation can still be returned to existing callers without being
/// written back into the in-memory cache as stale data.
struct OpenSubsonicCacheEpoch: Equatable, Sendable {
    private(set) var currentValue: UInt64 = 0

    mutating func advance() {
        currentValue &+= 1
    }

    func permitsStorage(capturedValue: UInt64) -> Bool {
        capturedValue == currentValue
    }
}

/// Session-scoped capability memory for servers that expose `search2` but not
/// `search3`. A new client starts optimistic; one authoritative unsupported
/// response removes the extra failed request from every later search.
struct OpenSubsonicSearchCapability: Equatable, Sendable {
    private(set) var search3IsUnsupported = false

    var shouldTrySearch3: Bool {
        !search3IsUnsupported
    }

    mutating func recordSearch3Unsupported() {
        search3IsUnsupported = true
    }

    static func isAuthoritativeUnsupported(_ error: Error) -> Bool {
        guard let error = error as? OpenSubsonicError else { return false }
        switch error {
        case .http(let status):
            return status == 404 || status == 405
        case .server(_, let message):
            let mentionsSearch3 = message.localizedCaseInsensitiveContains(
                "search3"
            )
            let describesUnsupported = message.localizedCaseInsensitiveContains(
                "unknown endpoint"
            ) || message.localizedCaseInsensitiveContains("not found")
                || message.localizedCaseInsensitiveContains("unsupported")
                || message.localizedCaseInsensitiveContains("not implemented")
            return mentionsSearch3 && describesUnsupported
        default:
            return false
        }
    }
}

/// Session-local discovery state for optional OpenSubsonic extensions.
/// Authoritative endpoint absence is remembered for the client lifetime,
/// whereas network and server failures suppress repeated discovery only for a
/// short interval. The Sonic fallback preserves compatibility with older
/// servers that implement the feature without advertising it.
struct OpenSubsonicExtensionCapabilityState: Equatable, Sendable {
    enum LookupDecision: Equatable, Sendable {
        case discover
        case resolved(Bool)
    }

    static let transientFailureBackoff: TimeInterval = 15

    private var discoveredExtensions: Set<String>?
    private var discoveryIsUnsupported = false
    private var retryAfter: Date?

    func decision(for name: String, now: Date) -> LookupDecision {
        if let discoveredExtensions {
            return .resolved(discoveredExtensions.contains(name))
        }
        if discoveryIsUnsupported {
            return .resolved(Self.compatibilityFallback(for: name))
        }
        if let retryAfter, now < retryAfter {
            return .resolved(Self.compatibilityFallback(for: name))
        }
        return .discover
    }

    mutating func recordSuccess(_ names: Set<String>) {
        discoveredExtensions = names
        discoveryIsUnsupported = false
        retryAfter = nil
    }

    mutating func recordFailure(_ error: Error, now: Date) {
        discoveredExtensions = nil
        if Self.isAuthoritativeUnsupported(error) {
            discoveryIsUnsupported = true
            retryAfter = nil
        } else {
            discoveryIsUnsupported = false
            retryAfter = now.addingTimeInterval(Self.transientFailureBackoff)
        }
    }

    static func compatibilityFallback(for name: String) -> Bool {
        name == "sonicSimilarity"
    }

    static func isAuthoritativeUnsupported(_ error: Error) -> Bool {
        guard let error = error as? OpenSubsonicError else { return false }
        switch error {
        case .http(let status):
            return status == 404 || status == 405
        case .server(_, let message):
            let mentionsEndpoint = message.localizedCaseInsensitiveContains(
                "endpoint"
            ) || message.localizedCaseInsensitiveContains(
                "getOpenSubsonicExtensions"
            ) || message.localizedCaseInsensitiveContains(
                "OpenSubsonic extension"
            )
            let describesUnsupported = message.localizedCaseInsensitiveContains(
                "unknown"
            ) || message.localizedCaseInsensitiveContains("unsupported")
                || message.localizedCaseInsensitiveContains("not supported")
                || message.localizedCaseInsensitiveContains("not implemented")
                || message.localizedCaseInsensitiveContains("not found")
            return mentionsEndpoint && describesUnsupported
        default:
            return false
        }
    }
}

struct ExternalRecommendationMatchQuery: Hashable, Sendable {
    let title: String
    let artist: String
    let album: String?
    let recordingMBID: String?

    init?(
        title: String,
        artist: String,
        album: String?,
        recordingMBID: String?
    ) {
        let normalizedTitle = ExternalRecommendationSongIndex.normalized(title)
        guard !normalizedTitle.isEmpty else { return nil }
        self.title = normalizedTitle
        self.artist = ExternalRecommendationSongIndex.normalized(artist)
        self.album = album.map(ExternalRecommendationSongIndex.normalized)
        self.recordingMBID = recordingMBID.map {
            ExternalRecommendationSongIndex.mbidKey($0)
        }
    }
}

/// Immutable, order-aware lookup tables for matching external metadata to a
/// song collection. Each library field is normalized once during construction.
/// Exact composite indexes provide the common fast path, while title buckets
/// retain the original fuzzy artist-containment behavior and library ordering.
struct ExternalRecommendationSongIndex: Sendable {
    struct ArtistTitleKey: Hashable, Sendable {
        let artist: String
        let title: String
    }

    struct ArtistAlbumTitleKey: Hashable, Sendable {
        let artist: String
        let album: String
        let title: String
    }

    private struct Entry: Sendable {
        let position: Int
        let song: Song
        let title: String
        let artist: String
        let album: String
    }

    private let mbidIndex: [String: Entry]
    private let artistTitleIndex: [ArtistTitleKey: Entry]
    private let artistAlbumTitleIndex: [ArtistAlbumTitleKey: Entry]
    private let titleIndex: [String: [Entry]]
    private let orderedEntries: [Entry]

    init(_ songs: [Song]) {
        var mbidIndex: [String: Entry] = [:]
        var artistTitleIndex: [ArtistTitleKey: Entry] = [:]
        var artistAlbumTitleIndex: [ArtistAlbumTitleKey: Entry] = [:]
        var titleIndex: [String: [Entry]] = [:]
        var orderedEntries: [Entry] = []
        mbidIndex.reserveCapacity(songs.count)
        artistTitleIndex.reserveCapacity(songs.count)
        artistAlbumTitleIndex.reserveCapacity(songs.count)
        titleIndex.reserveCapacity(songs.count)
        orderedEntries.reserveCapacity(songs.count)

        for (position, song) in songs.enumerated() {
            let entry = Entry(
                position: position,
                song: song,
                title: Self.normalized(song.title),
                artist: Self.normalized(song.artist),
                album: Self.normalized(song.album)
            )
            orderedEntries.append(entry)
            titleIndex[entry.title, default: []].append(entry)

            let artistTitleKey = ArtistTitleKey(
                artist: entry.artist,
                title: entry.title
            )
            if artistTitleIndex[artistTitleKey] == nil {
                artistTitleIndex[artistTitleKey] = entry
            }

            let artistAlbumTitleKey = ArtistAlbumTitleKey(
                artist: entry.artist,
                album: entry.album,
                title: entry.title
            )
            if artistAlbumTitleIndex[artistAlbumTitleKey] == nil {
                artistAlbumTitleIndex[artistAlbumTitleKey] = entry
            }

            if let value = song.musicBrainzId {
                let key = Self.mbidKey(value)
                if mbidIndex[key] == nil { mbidIndex[key] = entry }
            }
        }

        self.mbidIndex = mbidIndex
        self.artistTitleIndex = artistTitleIndex
        self.artistAlbumTitleIndex = artistAlbumTitleIndex
        self.titleIndex = titleIndex
        self.orderedEntries = orderedEntries
    }

    func match(
        _ query: ExternalRecommendationMatchQuery,
        allowsTitleContainmentFallback: Bool = false
    ) -> Song? {
        if let song = firstSong(
            normalizedTitle: query.title,
            normalizedArtist: query.artist,
            normalizedAlbum: query.album
        ) {
            return song
        }
        if let recordingMBID = query.recordingMBID,
           let song = mbidIndex[recordingMBID]?.song {
            return song
        }
        if let song = firstSong(
            normalizedTitle: query.title,
            normalizedArtist: query.artist,
            normalizedAlbum: nil
        ) {
            return song
        }
        guard allowsTitleContainmentFallback else { return nil }
        return orderedEntries.first {
            $0.title.contains(query.title)
        }?.song
    }

    func firstSong(recordingMBID: String) -> Song? {
        mbidIndex[Self.mbidKey(recordingMBID)]?.song
    }

    func firstSong(title: String, artist: String) -> Song? {
        firstSong(
            normalizedTitle: Self.normalized(title),
            normalizedArtist: Self.normalized(artist),
            normalizedAlbum: nil
        )
    }

    func firstSong(title: String, artist: String, album: String) -> Song? {
        firstSong(
            normalizedTitle: Self.normalized(title),
            normalizedArtist: Self.normalized(artist),
            normalizedAlbum: Self.normalized(album)
        )
    }

    static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func mbidKey(_ value: String) -> String {
        value.lowercased()
    }

    private func firstSong(
        normalizedTitle title: String,
        normalizedArtist artist: String,
        normalizedAlbum album: String?
    ) -> Song? {
        guard !artist.isEmpty, let entries = titleIndex[title] else {
            return nil
        }

        let constrainsAlbum = album.map { !$0.isEmpty } ?? false
        let exact: Entry?
        if constrainsAlbum, let album {
            exact = artistAlbumTitleIndex[
                ArtistAlbumTitleKey(
                    artist: artist,
                    album: album,
                    title: title
                )
            ]
        } else {
            exact = artistTitleIndex[
                ArtistTitleKey(artist: artist, title: title)
            ]
        }

        // An earlier fuzzy artist match must win over a later exact-index hit
        // because the previous implementation used `library.first(where:)`.
        for entry in entries {
            if let exact, entry.position >= exact.position {
                return exact.song
            }
            guard Self.artistsMatch(entry.artist, artist) else { continue }
            if constrainsAlbum, let album, entry.album != album { continue }
            return entry.song
        }
        return exact?.song
    }

    private static func artistsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs)
    }
}

struct ExternalRecommendationResolvedSong: Sendable {
    let candidateIndex: Int
    let song: Song
}

enum ExternalRecommendationMatchOrdering {
    static func orderedUniqueSongs(
        _ values: [ExternalRecommendationResolvedSong]
    ) -> [Song] {
        var ids = Set<String>()
        return values
            .sorted { $0.candidateIndex < $1.candidateIndex }
            .compactMap { value in
                ids.insert(value.song.id).inserted ? value.song : nil
            }
    }
}

/// Runs at most `maximumConcurrentTasks` operations while returning values in
/// input order. Structured child-task cancellation is allowed to throw through
/// the helper so callers can terminate the whole batch immediately.
enum OrderedBoundedTaskGroup {
    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maximumConcurrentTasks: Int,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        guard !inputs.isEmpty else { return [] }
        try Task.checkCancellation()
        let width = min(max(1, maximumConcurrentTasks), inputs.count)

        return try await withThrowingTaskGroup(
            of: (Int, Output).self,
            returning: [Output].self
        ) { group in
            var nextIndex = width
            var completed: [(Int, Output)] = []
            completed.reserveCapacity(inputs.count)

            for index in 0..<width {
                let input = inputs[index]
                group.addTask {
                    try Task.checkCancellation()
                    return (index, try await operation(input))
                }
            }

            do {
                while let value = try await group.next() {
                    completed.append(value)
                    if nextIndex < inputs.count {
                        let index = nextIndex
                        let input = inputs[index]
                        group.addTask {
                            try Task.checkCancellation()
                            return (index, try await operation(input))
                        }
                        nextIndex += 1
                    }
                }
            } catch {
                group.cancelAll()
                throw error
            }
            try Task.checkCancellation()
            return completed
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }
}

private struct ExternalRecommendationSearchWork: Sendable {
    let candidateIndex: Int
    let candidate: ExternalRecommendationCandidate
    let query: ExternalRecommendationMatchQuery
}

/// Cancellation-safe FIFO limiter for independent metadata transfers.
///
/// The permit is released from `defer`, including when the operation throws or
/// is cancelled. A cancelled queued waiter is removed without consuming a
/// permit, while a cancellation racing with a grant is handled by the post-
/// acquisition cancellation check and the same deferred release.
actor MetadataRequestLimiter {
    struct Snapshot: Equatable, Sendable {
        let limit: Int
        let activeCount: Int
        let waitingCount: Int
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }

    private let limit: Int
    private var activePermits: Set<UUID> = []
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func withPermit<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let permit = try await acquire()
        defer { release(permit) }
        try Task.checkCancellation()
        return try await operation()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            limit: limit,
            activeCount: activePermits.count,
            waitingCount: waiters.count
        )
    }

    private func acquire() async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if activePermits.count < limit {
                    activePermits.insert(id)
                    continuation.resume(returning: id)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ id: UUID) {
        guard activePermits.remove(id) != nil else { return }
        guard !waiters.isEmpty else { return }
        let waiter = waiters.removeFirst()
        activePermits.insert(waiter.id)
        waiter.continuation.resume(returning: waiter.id)
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
    private let session: URLSession
    private let decoder: JSONDecoder
    private let swiftSonic: SwiftSonicClient
    private let retryPolicy = ReadRequestRetryPolicy()
    private let metadataRequestLimiter = MetadataRequestLimiter(limit: 6)
    private var extensionCapability = OpenSubsonicExtensionCapabilityState()
    private var searchCapability = OpenSubsonicSearchCapability()
    private var inFlightReadRequests: [OpenSubsonicRequestKey: InFlightReadRequest] = [:]

    private enum RequestSemantics {
        case readOnly
        case mutation
    }

    private struct HTTPResponseData: @unchecked Sendable {
        let data: Data
        let response: HTTPURLResponse
    }

    private struct InFlightReadResponse: Sendable {
        let response: HTTPResponseData
        let cacheEpoch: UInt64
    }

    private struct ZstandardNegotiationError: Error, Sendable {}

    private struct InFlightReadRequest {
        let token: UUID
        let task: Task<Void, Never>
        let cacheEpoch: UInt64
        var waiters: [UUID: CheckedContinuation<InFlightReadResponse, Error>]
    }

    private struct CachedAPIResponse: Sendable {
        let data: Data
        let storedAt: Date
    }

    private static let responseCacheLimit = 128
    private static let responseCacheByteLimit = 16 * 1_024 * 1_024
    private static let maximumCachedResponseBytes = 2 * 1_024 * 1_024
    private var responseCache: [OpenSubsonicRequestKey: CachedAPIResponse] = [:]
    private var responseCacheOrder: [OpenSubsonicRequestKey] = []
    private var responseCacheBytes = 0
    private var responseCacheEpoch = OpenSubsonicCacheEpoch()

    private struct ServerRecommendationSources: Sendable {
        var sonic: [Song] = []
        var similarArtists: [Song] = []

        var combined: [Song] {
            OpenSubsonicClient.uniqueSongs(sonic + similarArtists)
        }
    }

    init(credentials: ServerCredentials) throws {
        guard let normalized = Self.normalizedBaseURL(credentials.serverURL) else {
            throw OpenSubsonicError.invalidServerURL
        }
        guard normalized.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        let username = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.credentials = ServerCredentials(
            serverURL: normalized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            username: username,
            password: credentials.password
        )
        self.swiftSonic = SwiftSonicClient(
            configuration: ServerConfiguration(
                serverURL: normalized,
                username: username,
                password: credentials.password,
                reusesSalt: false,
                clientName: Self.clientName,
                apiVersion: Self.apiVersion,
                requestTimeout: 18,
                resourceTimeout: 60
            )
        )

        let configuration = ModernNetworkPolicy.makeEphemeralConfiguration(
            requestTimeout: 18,
            resourceTimeout: 60,
            maximumConnectionsPerHost: 6,
            allowsExpensiveNetworkAccess: true,
            allowsConstrainedNetworkAccess: true
        )
        self.session = URLSession(
            configuration: configuration,
            delegate: HTTPSOnlyURLSessionDelegate(),
            delegateQueue: nil
        )
        self.decoder = JSONDecoder()
    }

    private static func normalizedBaseURL(_ value: String) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("https://") && !text.lowercased().hasPrefix("http://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.user == nil,
              components.password == nil,
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func authenticationItems() -> [URLQueryItem] {
        let salt = (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let tokenData = Data((credentials.password + salt).utf8)
        let token = Insecure.MD5.hash(data: tokenData).map { String(format: "%02hhx", $0) }.joined()
        return [
            URLQueryItem(name: "u", value: credentials.username),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName)
        ]
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

    private func readRequest<Payload: Decodable>(
        _ endpoint: String,
        parameters: [String: String] = [:]
    ) async throws -> Payload {
        let queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await performRequest(
            endpoint,
            queryItems: queryItems,
            semantics: .readOnly
        )
    }

    private func mutationRequest<Payload: Decodable>(
        _ endpoint: String,
        parameters: [String: String]
    ) async throws -> Payload {
        try await performRequest(
            endpoint,
            queryItems: parameters
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) },
            semantics: .mutation
        )
    }

    private func mutationRequest<Payload: Decodable>(
        _ endpoint: String,
        queryItems: [URLQueryItem]
    ) async throws -> Payload {
        try await performRequest(
            endpoint,
            queryItems: queryItems,
            semantics: .mutation
        )
    }

    private func performRequest<Payload: Decodable>(
        _ endpoint: String,
        queryItems: [URLQueryItem],
        semantics: RequestSemantics
    ) async throws -> Payload {
        let url = try endpointURL(endpoint, queryItems: queryItems)
        let cacheKey = OpenSubsonicRequestKey(
            endpoint: endpoint,
            queryItems: queryItems
        )
        let cacheLifetime = Self.responseCacheLifetime(for: endpoint)
        do {
            let response: HTTPResponseData
            var readCacheEpoch: UInt64? = nil
            switch semantics {
            case .readOnly:
                if cacheLifetime > 0,
                   let cached = cachedResponse(
                    for: cacheKey,
                    lifetime: cacheLifetime
                   ) {
                    return try decodeResponseData(cached)
                }
                let readResponse = try await coalescedReadResponse(
                    from: url,
                    key: cacheKey,
                    usesMetadataPermit: true
                )
                response = readResponse.response
                readCacheEpoch = readResponse.cacheEpoch
            case .mutation:
                response = try await responseData(
                    from: url,
                    allowsRetry: false
                )
            }
            let payload: Payload = try decodeResponse(response)
            switch semantics {
            case .readOnly where cacheLifetime > 0:
                // Store only a body that decoded into the endpoint's expected
                // payload, never an HTTP or schema error response. A response
                // stamped before a successful mutation may still satisfy its
                // original caller, but must not repopulate stale cache state.
                if let readCacheEpoch,
                   responseCacheEpoch.permitsStorage(
                    capturedValue: readCacheEpoch
                   ) {
                    storeResponse(response.data, for: cacheKey)
                }
            case .mutation:
                invalidateResponseCache(afterMutation: endpoint)
            default:
                break
            }
            return payload
        } catch {
            logFailure(error, endpoint: endpoint)
            throw error
        }
    }

    private func bestEffortRequest<Payload: Decodable>(
        _ endpoint: String,
        parameters: [String: String] = [:]
    ) async throws -> Payload? {
        do {
            return try await readRequest(endpoint, parameters: parameters)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return nil
        }
    }

    private struct DecoderCapture: Decodable {
        let decoder: Decoder
        init(from decoder: Decoder) throws {
            self.decoder = decoder
        }
    }

    private func decodeResponse<Payload: Decodable>(
        _ response: HTTPResponseData
    ) throws -> Payload {
        guard (200..<300).contains(response.response.statusCode) else {
            throw OpenSubsonicError.http(response.response.statusCode)
        }
        return try decodeResponseData(response.data)
    }

    private func decodeResponseData<Payload: Decodable>(
        _ data: Data
    ) throws -> Payload {
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
        let url = try endpointURL(endpoint)
        do {
            let readResponse = try await coalescedReadResponse(
                from: url,
                key: OpenSubsonicRequestKey(endpoint: endpoint, queryItems: []),
                usesMetadataPermit: false
            )
            let response = readResponse.response
            guard (200..<300).contains(response.response.statusCode) else {
                throw OpenSubsonicError.http(response.response.statusCode)
            }
            let envelope = try decoder.decode(
                StatusEnvelope.self,
                from: response.data
            )
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

    private func coalescedReadResponse(
        from url: URL,
        key: OpenSubsonicRequestKey,
        usesMetadataPermit: Bool
    ) async throws -> InFlightReadResponse {
        try Task.checkCancellation()
        let waiter = UUID()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerReadWaiter(
                    continuation,
                    key: key,
                    waiter: waiter,
                    url: url,
                    usesMetadataPermit: usesMetadataPermit
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
        _ continuation: CheckedContinuation<InFlightReadResponse, Error>,
        key: OpenSubsonicRequestKey,
        waiter: UUID,
        url: URL,
        usesMetadataPermit: Bool
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

        let token = UUID()
        let task = Task { [self] in
            do {
                let response: HTTPResponseData
                if usesMetadataPermit {
                    response = try await metadataRequestLimiter.withPermit {
                        try await self.responseData(
                            from: url,
                            allowsRetry: true
                        )
                    }
                } else {
                    response = try await responseData(
                        from: url,
                        allowsRetry: true
                    )
                }
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
            cacheEpoch: responseCacheEpoch.currentValue,
            waiters: [waiter: continuation]
        )
    }

    private func cancelReadWaiter(
        key: OpenSubsonicRequestKey,
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
        key: OpenSubsonicRequestKey,
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
                continuation.resume(
                    returning: InFlightReadResponse(
                        response: response,
                        cacheEpoch: request.cacheEpoch
                    )
                )
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private func responseData(
        from url: URL,
        allowsRetry: Bool
    ) async throws -> HTTPResponseData {
        // Mutations avoid the zstd negotiation fallback because reissuing a
        // state-changing endpoint would itself be an unsafe retry.
        var acceptsZstandard = allowsRetry
        var retryCount = 0

        while true {
            try Task.checkCancellation()
            do {
                let result = try await responseDataAttempt(
                    from: url,
                    acceptsZstandard: acceptsZstandard
                )
                guard allowsRetry,
                      retryCount < ReadRequestRetryPolicy.maximumRetryCount,
                      retryPolicy.shouldRetry(
                        statusCode: result.response.statusCode
                      ) else {
                    return result
                }

                retryCount += 1
                guard let delay = retryPolicy.delay(
                    retryNumber: retryCount,
                    retryAfterHeader: result.response.value(
                        forHTTPHeaderField: "Retry-After"
                    ),
                    jitter: Double.random(in: 0.75...1.25)
                ) else {
                    return result
                }
                Self.logger.notice(
                    "Retrying read request after HTTP \(result.response.statusCode, privacy: .public); retry \(retryCount, privacy: .public)"
                )
                try await sleepBeforeRetry(delay)
            } catch {
                if acceptsZstandard,
                   error is ZstandardNegotiationError {
                    // Content negotiation fallback is not a retry. It existed
                    // before the bounded transient-failure policy and does not
                    // consume its budget.
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
        from url: URL,
        acceptsZstandard: Bool
    ) async throws -> HTTPResponseData {
        guard url.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        var request = URLRequest(url: url)
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
        // Error response bodies are not decoded by callers. Returning the
        // status first ensures 408/429/5xx retry decisions do not depend on a
        // server's optional error-body content encoding.
        guard (200..<300).contains(http.statusCode) else {
            return HTTPResponseData(data: encodedData, response: http)
        }
        let contentEncoding = http.value(forHTTPHeaderField: "Content-Encoding")
        do {
            let data = try HTTPContentDecoder.decode(
                encodedData,
                contentEncoding: contentEncoding
            )
            return HTTPResponseData(data: data, response: http)
        } catch let error as URLError
            where acceptsZstandard
                && error.code == .cannotDecodeContentData {
            throw ZstandardNegotiationError()
        }
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

    private func cachedResponse(
        for key: OpenSubsonicRequestKey,
        lifetime: TimeInterval
    ) -> Data? {
        guard let value = responseCache[key] else { return nil }
        guard Date().timeIntervalSince(value.storedAt) <= lifetime else {
            responseCache[key] = nil
            responseCacheBytes = max(0, responseCacheBytes - value.data.count)
            responseCacheOrder.removeAll { $0 == key }
            return nil
        }
        responseCacheOrder.removeAll { $0 == key }
        responseCacheOrder.append(key)
        return value.data
    }

    private func storeResponse(
        _ data: Data,
        for key: OpenSubsonicRequestKey
    ) {
        guard data.count <= Self.maximumCachedResponseBytes else { return }
        if let existing = responseCache[key] {
            responseCacheBytes = max(0, responseCacheBytes - existing.data.count)
        }
        responseCache[key] = CachedAPIResponse(data: data, storedAt: Date())
        responseCacheBytes += data.count
        responseCacheOrder.removeAll { $0 == key }
        responseCacheOrder.append(key)
        while responseCacheOrder.count > Self.responseCacheLimit
                || responseCacheBytes > Self.responseCacheByteLimit {
            let evicted = responseCacheOrder.removeFirst()
            if let removed = responseCache.removeValue(forKey: evicted) {
                responseCacheBytes = max(0, responseCacheBytes - removed.data.count)
            }
        }
    }

    private func clearResponseCache() {
        responseCache.removeAll(keepingCapacity: false)
        responseCacheOrder.removeAll(keepingCapacity: false)
        responseCacheBytes = 0
    }

    private func invalidateResponseCache(afterMutation endpoint: String) {
        responseCacheEpoch.advance()
        let keys = Set(
            responseCache.keys.filter {
                OpenSubsonicCacheInvalidationPolicy.shouldInvalidate(
                    $0,
                    afterMutation: endpoint
                )
            }
        )
        guard !keys.isEmpty else { return }
        for key in keys {
            if let removed = responseCache.removeValue(forKey: key) {
                responseCacheBytes = max(
                    0,
                    responseCacheBytes - removed.data.count
                )
            }
        }
        responseCacheOrder.removeAll { keys.contains($0) }
    }

    private static func responseCacheLifetime(for endpoint: String) -> TimeInterval {
        switch endpoint {
        case "ping", "star", "unstar", "scrobble",
             "reportPlayback", "savePlayQueue":
            return 0
        case "getOpenSubsonicExtensions":
            return 60 * 60
        case "getLyricsBySongId":
            return 6 * 60 * 60
        case "getGenres":
            return 10 * 60
        case "getArtistInfo2":
            return 5 * 60
        default:
            // Coalesce bursts from overlapping views and recommendation
            // providers without making library state visibly stale. Unknown
            // mutation endpoints remain uncached by default.
            return endpoint.hasPrefix("get") || endpoint.hasPrefix("search")
                ? 2
                : 0
        }
    }

    func home(from previous: HomeSnapshot? = nil) async throws -> HomeLoadResult {
        async let recent: AlbumListPayload? = bestEffortRequest(
            "getAlbumList2",
            parameters: ["type": "newest", "size": "16"]
        )
        async let recentlyPlayed: AlbumListPayload? = bestEffortRequest(
            "getAlbumList2",
            parameters: ["type": "recent", "size": "16"]
        )
        async let frequent: AlbumListPayload? = bestEffortRequest(
            "getAlbumList2",
            parameters: ["type": "frequent", "size": "16"]
        )
        async let randomAlbums: AlbumListPayload? = bestEffortRequest(
            "getAlbumList2",
            parameters: ["type": "random", "size": "16"]
        )
        async let popularAlbumsRequest: AlbumListPayload? = bestEffortRequest(
            "getAlbumList2",
            parameters: ["type": "highest", "size": "12"]
        )
        async let starred: StarredPayload? = bestEffortRequest("getStarred2")
        async let artists: ArtistsPayload? = bestEffortRequest("getArtists")
        async let randomSongs: RandomSongsPayload? = bestEffortRequest(
            "getRandomSongs",
            parameters: ["size": "24"]
        )
        async let playlists: PlaylistsPayload? = bestEffortRequest("getPlaylists")
        async let radioStations: InternetRadioStationsPayload? = bestEffortRequest(
            "getInternetRadioStations"
        )
        async let genres: GenresPayload? = bestEffortRequest("getGenres")

        let (
            recentValue,
            recentlyPlayedValue,
            frequentValue,
            randomAlbumsValue,
            popularAlbumsValue,
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
            popularAlbumsRequest,
            starred,
            artists,
            randomSongs,
            playlists,
            radioStations,
            genres
        )
        guard recentValue != nil || recentlyPlayedValue != nil ||
                frequentValue != nil || randomAlbumsValue != nil ||
                popularAlbumsValue != nil || starredValue != nil ||
                artistsValue != nil || randomSongsValue != nil ||
                playlistsValue != nil || radioStationsValue != nil ||
                genresValue != nil else {
            throw OpenSubsonicError.invalidResponse
        }

        let fallback = previous ?? .empty
        let starredAlbums: [Album]
        let starredSongs: [Song]
        let starredArtists: [Artist]
        if let value = starredValue?.starred2 {
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
        }
            ?? fallback.randomSongs
        let allArtists =
            artistsValue.map {
                $0.artists?.index?.flatMap { $0.artist ?? [] } ?? []
            }
            ?? fallback.artists
        let frequentAlbums = frequentValue.map { $0.albumList2?.album ?? [] }
            ?? fallback.frequentAlbums
        let recentAlbums = recentValue.map { $0.albumList2?.album ?? [] }
            ?? fallback.recentAlbums
        let popularAlbumValues = popularAlbumsValue.map {
            $0.albumList2?.album ?? []
        } ?? []
        let playlistValues = playlistsValue.map {
            $0.playlists?.playlist ?? []
        } ?? fallback.playlists
        let preferredGenres = Self.uniqueStrings(
            starredSongs.flatMap {
                [$0.genre].compactMap { $0 } + ($0.genres ?? []).map(\.name)
            }
            + (genresValue?.genres?.genre ?? [])
                .sorted {
                    ($0.songCount ?? 0) > ($1.songCount ?? 0)
                }
                .map(\.value)
        )

        async let recommendationsRequest = recommendationSources(
            seeds: starredSongs + randomSongValues
        )
        async let rankedSongsRequest = mostPlayedSongs(
            from: frequentAlbums,
            fallback: fallback.mostPlayedSongs
        )
        async let artistRecommendationsRequest = similarArtists(
            to: starredArtists,
            fallback: fallback.recommendedArtists
        )
        async let genreSongsRequest = songsByGenres(
            Array(preferredGenres.prefix(2)),
            fallback: fallback.genreRecommendedSongs
        )
        async let topArtistSongsRequest = topSongs(
            for: Array(starredArtists.prefix(2)),
            fallback: fallback.topArtistSongs
        )
        async let recentlyAddedSongsRequest = songs(
            from: Array(recentAlbums.prefix(3)),
            fallback: fallback.recentlyAddedSongs
        )
        async let popularSongsRequest = songs(
            from: Array(popularAlbumValues.prefix(3)),
            fallback: fallback.popularSongs
        )
        async let playlistAffinityRequest = playlistAffinitySongs(
            from: Array(playlistValues.prefix(3)),
            fallback: fallback.playlistAffinitySongs
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
        var combinedRecommendations = recommendationSources.combined
        combinedRecommendations.append(contentsOf: genreSongs)
        combinedRecommendations.append(contentsOf: topArtistSongs)
        combinedRecommendations.append(contentsOf: recentlyAddedSongs)
        combinedRecommendations.append(contentsOf: popularSongs)
        combinedRecommendations.append(contentsOf: playlistAffinitySongs)
        let serverRecommendations = Self.uniqueSongs(combinedRecommendations)

        var snapshot = HomeSnapshot(
            recentAlbums: recentAlbums,
            recentlyPlayedAlbums: recentlyPlayedValue.map {
                $0.albumList2?.album ?? []
            }
                ?? fallback.recentlyPlayedAlbums,
            frequentAlbums: frequentAlbums,
            randomAlbums: randomAlbumsValue.map {
                $0.albumList2?.album ?? []
            }
                ?? fallback.randomAlbums,
            starredAlbums: starredAlbums,
            starredSongs: starredSongs,
            starredArtists: starredArtists,
            artists: allArtists,
            randomSongs: randomSongValues,
            sonicRecommendedSongs: recommendationSources.sonic,
            similarArtistSongs: recommendationSources.similarArtists,
            genreRecommendedSongs: genreSongs,
            topArtistSongs: topArtistSongs,
            recentlyAddedSongs: recentlyAddedSongs,
            popularSongs: popularSongs,
            playlistAffinitySongs: playlistAffinitySongs,
            serverRecommendedSongs: serverRecommendations,
            lastFMRecommendedSongs: fallback.lastFMRecommendedSongs,
            listenBrainzRecommendedSongs: fallback.listenBrainzRecommendedSongs,
            recommendedSongs: serverRecommendations,
            mostPlayedSongs: rankedServerSongs,
            recommendedArtists: artistRecommendations,
            playlists: playlistValues,
            radioStations: radioStationsValue.map {
                $0.internetRadioStations?.internetRadioStation ?? []
            } ?? fallback.radioStations
        )
        snapshot.daylistSongs = DaylistBuilder.make(snapshot: snapshot)
        return HomeLoadResult(
            snapshot: snapshot,
            hasAuthoritativeStarredState: starredValue?.starred2 != nil
        )
    }

    func incrementalHome(from previous: HomeSnapshot) async throws -> HomeLoadResult {
        async let recent: AlbumListPayload? = bestEffortRequest(
            "getAlbumList2",
            parameters: ["type": "newest", "size": "16"]
        )
        async let recentlyPlayed: AlbumListPayload? = bestEffortRequest(
            "getAlbumList2",
            parameters: ["type": "recent", "size": "16"]
        )
        async let frequent: AlbumListPayload? = bestEffortRequest(
            "getAlbumList2",
            parameters: ["type": "frequent", "size": "16"]
        )
        async let starred: StarredPayload? = bestEffortRequest("getStarred2")
        async let playlists: PlaylistsPayload? = bestEffortRequest("getPlaylists")

        let values = try await (recent, recentlyPlayed, frequent, starred, playlists)
        guard values.0 != nil || values.1 != nil || values.2 != nil ||
                values.3 != nil || values.4 != nil else {
            throw OpenSubsonicError.invalidResponse
        }

        var snapshot = previous
        if let recent = values.0 {
            snapshot.recentAlbums = recent.albumList2?.album ?? []
        }
        if let recent = values.1 {
            snapshot.recentlyPlayedAlbums = recent.albumList2?.album ?? []
        }
        if let frequent = values.2 {
            let frequentAlbums = frequent.albumList2?.album ?? []
            snapshot.frequentAlbums = frequentAlbums
            snapshot.mostPlayedSongs = await mostPlayedSongs(
                from: frequentAlbums,
                fallback: previous.mostPlayedSongs
            )
        }
        if let starred = values.3?.starred2 {
            snapshot.starredAlbums = starred.album ?? []
            snapshot.starredSongs = starred.song ?? []
            snapshot.starredArtists = starred.artist ?? []
        }
        if let playlists = values.4 {
            snapshot.playlists = playlists.playlists?.playlist ?? []
        }
        return HomeLoadResult(
            snapshot: snapshot,
            hasAuthoritativeStarredState: values.3?.starred2 != nil
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
        guard limit > 0, !Task.isCancelled else { return [] }
        let libraryIndex = ExternalRecommendationSongIndex(library)
        var resolved: [ExternalRecommendationResolvedSong] = []
        var serverSearches: [ExternalRecommendationSearchWork] = []
        let candidateCount = min(limit, candidates.count)
        resolved.reserveCapacity(candidateCount)
        serverSearches.reserveCapacity(candidateCount)

        for (candidateIndex, candidate) in candidates.prefix(limit).enumerated() {
            guard !Task.isCancelled else { return [] }
            guard let query = ExternalRecommendationMatchQuery(
                title: candidate.title,
                artist: candidate.artist,
                album: candidate.album,
                recordingMBID: candidate.recordingMBID
            ) else {
                continue
            }
            if let song = libraryIndex.match(query) {
                resolved.append(
                    ExternalRecommendationResolvedSong(
                        candidateIndex: candidateIndex,
                        song: song
                    )
                )
            } else {
                serverSearches.append(
                    ExternalRecommendationSearchWork(
                        candidateIndex: candidateIndex,
                        candidate: candidate,
                        query: query
                    )
                )
            }
        }

        do {
            let serverMatches = try await OrderedBoundedTaskGroup.map(
                serverSearches,
                maximumConcurrentTasks: 3
            ) { [self] work -> ExternalRecommendationResolvedSong? in
                try Task.checkCancellation()
                let results: SearchResults
                do {
                    results = try await self.search(
                        "\(work.candidate.artist) \(work.candidate.title)"
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    return nil
                }
                try Task.checkCancellation()
                let resultIndex = ExternalRecommendationSongIndex(results.songs)
                guard let song = resultIndex.match(
                    work.query,
                    allowsTitleContainmentFallback: true
                ) else {
                    return nil
                }
                return ExternalRecommendationResolvedSong(
                    candidateIndex: work.candidateIndex,
                    song: song
                )
            }
            try Task.checkCancellation()
            resolved.append(contentsOf: serverMatches.compactMap { $0 })
            return ExternalRecommendationMatchOrdering.orderedUniqueSongs(
                resolved
            )
        } catch {
            // The public API intentionally remains non-throwing. Returning no
            // batch on cancellation prevents a partially completed concurrent
            // search from being published by its caller.
            return []
        }
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
        count: Int = 24
    ) async -> ServerRecommendationSources {
        let distinctSeeds = Self.uniqueSongs(seeds)
        guard !distinctSeeds.isEmpty else {
            return ServerRecommendationSources()
        }
        var sonicSongs: [Song] = []
        var similarArtistSongs: [Song] = []
        let supportsSonic = await supportsExtension("sonicSimilarity")

        for seed in distinctSeeds.prefix(3) {
            guard !Task.isCancelled else { break }
            async let sonicResult = sonicRecommendations(
                for: seed,
                count: count,
                enabled: supportsSonic
            )
            async let similarResult = similarArtistRecommendations(
                for: seed,
                count: count,
                enabled: similarArtistSongs.count < count
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
        enabled: Bool
    ) async -> [Song] {
        guard enabled, !Task.isCancelled else { return [] }
        let payload: SonicSimilarPayload? = try? await readRequest(
            "getSonicSimilarTracks",
            parameters: ["id": seed.id, "count": "\(max(8, count))"]
        )
        return (payload?.sonicMatch ?? [])
            .sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
            .map(\.entry)
    }

    private func similarArtistRecommendations(
        for seed: Song,
        count: Int,
        enabled: Bool
    ) async -> [Song] {
        guard enabled,
              !Task.isCancelled,
              let artistID = seed.artistId else {
            return []
        }
        let payload: SimilarSongsPayload? = try? await readRequest(
            "getSimilarSongs2",
            parameters: ["id": artistID, "count": "\(max(8, count))"]
        )
        return payload?.similarSongs2?.song
            ?? payload?.similarSongs?.song
            ?? []
    }

    private func supportsExtension(_ name: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        switch extensionCapability.decision(for: name, now: Date()) {
        case .resolved(let supported):
            return supported
        case .discover:
            break
        }

        do {
            let payload: OpenSubsonicExtensionsPayload = try await readRequest(
                "getOpenSubsonicExtensions"
            )
            let names = Set(
                (payload.openSubsonicExtensions ?? []).compactMap { value in
                    value.versions.isEmpty ? nil : value.name
                }
            )
            extensionCapability.recordSuccess(names)
            return names.contains(name)
        } catch {
            guard !Task.isCancelled else { return false }
            extensionCapability.recordFailure(error, now: Date())
            // Older Navidrome-compatible servers may implement the endpoint
            // without advertising extensions. Keep the existing best-effort
            // Sonic request in that compatibility case.
            return OpenSubsonicExtensionCapabilityState
                .compatibilityFallback(for: name)
        }
    }

    private func songsByGenres(
        _ genres: [String],
        fallback: [Song],
        count: Int = 24
    ) async -> [Song] {
        guard !genres.isEmpty else { return fallback }
        let values = await withTaskGroup(
            of: (Int, [Song]).self,
            returning: [(Int, [Song])].self
        ) { group in
            for (index, genre) in genres.prefix(2).enumerated() {
                group.addTask { [self] in
                    let payload: SongsByGenrePayload? = try? await readRequest(
                        "getSongsByGenre",
                        parameters: [
                            "genre": genre,
                            "count": "\(count)",
                            "offset": "0"
                        ]
                    )
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
        count: Int = 24
    ) async -> [Song] {
        guard !artists.isEmpty else { return fallback }
        let usesArtistID = await supportsExtension("topSongsByArtistId")
        let values = await withTaskGroup(
            of: (Int, [Song]).self,
            returning: [(Int, [Song])].self
        ) { group in
            for (index, artist) in artists.prefix(2).enumerated() {
                group.addTask { [self] in
                    var parameters = [
                        "artist": artist.name,
                        "count": "\(count)"
                    ]
                    if usesArtistID {
                        parameters["id"] = artist.id
                    }
                    let payload: TopSongsPayload? = try? await readRequest(
                        "getTopSongs",
                        parameters: parameters
                    )
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
        count: Int = 30
    ) async -> [Song] {
        guard !albums.isEmpty else { return fallback }
        let values = await withTaskGroup(
            of: (Int, [Song]).self,
            returning: [(Int, [Song])].self
        ) { group in
            for (index, album) in albums.prefix(3).enumerated() {
                group.addTask { [self] in
                    let detail = try? await self.album(id: album.id)
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
        count: Int = 30
    ) async -> [Song] {
        guard !playlists.isEmpty else { return fallback }
        let values = await withTaskGroup(
            of: [Song].self,
            returning: [[Song]].self
        ) { group in
            for playlist in playlists.prefix(3) {
                group.addTask { [self] in
                    (try? await self.playlist(id: playlist.id))?.songs ?? []
                }
            }
            var result: [[Song]] = []
            for await value in group { result.append(value) }
            return result
        }
        var appearances: [String: Int] = [:]
        var songsByID: [String: Song] = [:]
        for playlistSongs in values {
            var seenInPlaylist = Set<String>()
            for song in playlistSongs
                where seenInPlaylist.insert(song.id).inserted {
                appearances[song.id, default: 0] += 1
                songsByID[song.id] = song
            }
        }
        let songs = songsByID.values.sorted {
            let left = appearances[$0.id, default: 0]
            let right = appearances[$1.id, default: 0]
            if left == right {
                return ($0.playCount ?? 0) > ($1.playCount ?? 0)
            }
            return left > right
        }
        return songs.isEmpty ? fallback : Array(songs.prefix(count))
    }

    private func mostPlayedSongs(
        from albums: [Album],
        fallback: [Song]
    ) async -> [Song] {
        let candidates = Array(albums.prefix(8))
        guard !candidates.isEmpty else { return fallback }
        let songs = await withTaskGroup(
            of: (Int, [Song]).self,
            returning: [Song].self
        ) { group in
            for (index, album) in candidates.enumerated() {
                group.addTask { [self] in
                    let detail = try? await self.album(id: album.id)
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
        fallback: [Artist]
    ) async -> [Artist] {
        let candidates = Array(seeds.prefix(3))
        guard !candidates.isEmpty else { return fallback }
        let values = await withTaskGroup(
            of: [Artist].self,
            returning: [Artist].self
        ) { group in
            for artist in candidates {
                group.addTask { [self] in
                    let payload: ArtistInfoPayload? = try? await self.readRequest(
                        "getArtistInfo2",
                        parameters: [
                            "id": artist.id,
                            "count": "8",
                            "includeNotPresent": "false"
                        ]
                    )
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

    private static func uniqueSongs(_ songs: [Song]) -> [Song] {
        var ids = Set<String>()
        return songs.filter { ids.insert($0.id).inserted }
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
            guard ids.insert(song.id).inserted else { return false }
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
            if !mbid.isEmpty { mbids.insert(mbid) }
            metadata.insert(identity)
            return true
        }
    }

    private static func uniqueArtists(_ artists: [Artist]) -> [Artist] {
        var ids = Set<String>()
        return artists.filter { ids.insert($0.id).inserted }
    }

    private static func normalized(_ value: String) -> String {
        ExternalRecommendationSongIndex.normalized(value)
    }

    func search(_ query: String) async throws -> SearchResults {
        let parameters = [
            "query": query,
            "artistCount": "8",
            "albumCount": "14",
            "songCount": "30"
        ]
        guard searchCapability.shouldTrySearch3 else {
            return try await search2(parameters: parameters)
        }
        do {
            let payload: SearchPayload = try await readRequest("search3", parameters: parameters)
            let result = payload.searchResult3 ?? payload.searchResult2
            return Self.deduplicatedSearch(result)
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            guard Self.shouldFallbackToSearch2(error) else { throw error }
            if OpenSubsonicSearchCapability.isAuthoritativeUnsupported(error) {
                searchCapability.recordSearch3Unsupported()
            }
            return try await search2(parameters: parameters)
        }
    }

    private func search2(
        parameters: [String: String]
    ) async throws -> SearchResults {
        let payload: SearchPayload = try await readRequest(
            "search2",
            parameters: parameters
        )
        return Self.deduplicatedSearch(
            payload.searchResult2 ?? payload.searchResult3
        )
    }

    private static func shouldFallbackToSearch2(_ error: Error) -> Bool {
        guard let error = error as? OpenSubsonicError else { return false }
        switch error {
        case .http(let status):
            return status == 404 || status == 405
        case .server(let code, let message):
            return code == 70 ||
                message.localizedCaseInsensitiveContains("search3") ||
                message.localizedCaseInsensitiveContains("not found") ||
                message.localizedCaseInsensitiveContains("unknown endpoint")
        default:
            return false
        }
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
        return AlbumDetail(songs: value.song ?? [])
    }

    func playlist(id: String) async throws -> PlaylistDetail {
        let payload: PlaylistPayload = try await readRequest("getPlaylist", parameters: ["id": id])
        guard let value = payload.playlist else { throw OpenSubsonicError.invalidResponse }
        return PlaylistDetail(songs: value.entry ?? [])
    }

    func artist(id: String, name: String) async throws -> ArtistDetail {
        let usesArtistID = await supportsExtension("topSongsByArtistId")
        async let albumsPayload: ArtistAlbumsPayload = readRequest("getArtist", parameters: ["id": id])
        async let topPayload: TopSongsPayload = readRequest(
            "getTopSongs",
            parameters: usesArtistID
                ? ["id": id, "artist": name, "count": "20"]
                : ["artist": name, "count": "20"]
        )
        async let infoPayload: ArtistInfoPayload? = bestEffortRequest(
            "getArtistInfo2",
            parameters: ["id": id, "count": "8", "includeNotPresent": "false"]
        )
        let (albums, top, info) = try await (albumsPayload, topPayload, infoPayload)
        guard let artist = albums.artist else { throw OpenSubsonicError.invalidResponse }
        return ArtistDetail(
            artist: artist.artistValue,
            albums: artist.album ?? [],
            topSongs: Self.uniqueSongsByIdentity(top.topSongs?.song ?? []),
            info: info?.artistInfo2
        )
    }

    func lyrics(songID: String) async throws -> LyricsDocument {
        let payload: LyricsPayload = try await readRequest(
            "getLyricsBySongId",
            parameters: ["id": songID]
        )
        guard let source = payload.lyricsList?.structuredLyrics?.first else {
            return .empty
        }
        let offset = TimeInterval(source.offset ?? 0) / 1_000
        let lines = (source.line ?? []).enumerated().compactMap { index, item -> LyricLine? in
            guard let text = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return nil
            }
            let start = max(0, TimeInterval(item.start ?? 0) / 1_000 + offset)
            return LyricLine(id: index, start: start, text: text)
        }
        return LyricsDocument(
            synced: source.synced ?? !lines.isEmpty,
            lines: lines.sorted { $0.start < $1.start }
        )
    }

    func prefetchLyrics(songIDs: [String]) async {
        var seen = Set<String>()
        for songID in songIDs.prefix(2) where seen.insert(songID).inserted {
            guard !Task.isCancelled else { return }
            _ = try? await lyrics(songID: songID)
        }
    }

    func trimTransientNetworkCaches() {
        for request in inFlightReadRequests.values {
            request.task.cancel()
            request.waiters.values.forEach {
                $0.resume(throwing: CancellationError())
            }
        }
        inFlightReadRequests.removeAll(keepingCapacity: false)
        clearResponseCache()
    }

    func streamURL(
        songID: String,
        quality: StreamQuality,
        compatibilityFormat: String? = nil
    ) throws -> URL {
        let requestedFormat = compatibilityFormat ?? quality.parameters["format"]
        let requestedBitRate: Int?
        if let compatibilityFormat {
            switch compatibilityFormat.lowercased() {
            case "aac":
                requestedBitRate = quality == .aac320 ? 320 : 256
            case "opus":
                requestedBitRate = 160
            case "mp3":
                requestedBitRate = 256
            case "raw":
                requestedBitRate = nil
            default:
                requestedBitRate = 256
            }
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

    func coverURL(id: String, size: Int = 600) throws -> URL {
        guard let url = swiftSonic.coverArtURL(id: id, size: size),
              url.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        return url
    }

    func downloadURL(songID: String) throws -> URL {
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
    ) async {
        guard await supportsExtension("playbackReport") else { return }
        let allowedStates = ["starting", "playing", "paused", "stopped"]
        guard allowedStates.contains(state) else { return }
        let positionMs = Int(max(0, position) * 1_000)
        let _: EmptyPayload? = try? await mutationRequest(
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
            URLQueryItem(name: "position", value: String(Int(position * 1_000)))
        ]
        let _: EmptyPayload = try await mutationRequest(
            "savePlayQueue",
            queryItems: queryItems
        )
    }
}
