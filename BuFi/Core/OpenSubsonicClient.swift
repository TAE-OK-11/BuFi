import CryptoKit
import Foundation
import OSLog
import SwiftSonic

enum OpenSubsonicError: LocalizedError, Equatable {
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
    private let decoder: JSONDecoder
    private let swiftSonic: SwiftSonicClient
    private let retryPolicy = ReadRequestRetryPolicy()
    private var supportedExtensions: Set<String>?
    private var inFlightReadRequests: [ReadRequestKey: InFlightReadRequest] = [:]
    private var mutationEpoch: UInt64 = 0
    private var mutationsInFlight = 0

    private enum RequestSemantics {
        case readOnly
        case mutation
    }

    private struct ReadRequestKey: Hashable, Sendable {
        let endpoint: String
        let queryItems: [String]
        let mutationEpoch: UInt64

        init(
            endpoint: String,
            queryItems: [URLQueryItem],
            mutationEpoch: UInt64
        ) {
            self.endpoint = endpoint
            self.mutationEpoch = mutationEpoch
            self.queryItems = queryItems
                .map { "\($0.name)=\($0.value ?? "")" }
                .sorted()
        }
    }

    /// Sendable transport value used by coalesced requests. Foundation's
    /// HTTPURLResponse is a reference type, so extract only the immutable
    /// fields needed after the URLSession boundary.
    private struct HTTPResponseData: Sendable {
        let data: Data
        let statusCode: Int
        let retryAfter: String?
    }

    private struct ZstandardNegotiationError: Error, Sendable {}

    private struct InFlightReadRequest {
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<HTTPResponseData, Error>]
    }

    private static let responseCacheLimit = 128
    private static let responseCacheByteLimit = 16 * 1_024 * 1_024
    private static let maximumCachedResponseBytes = 2 * 1_024 * 1_024
    private var responseCache = ResponseBodyCache(
        countLimit: OpenSubsonicClient.responseCacheLimit,
        byteLimit: OpenSubsonicClient.responseCacheByteLimit,
        maximumEntryBytes: OpenSubsonicClient.maximumCachedResponseBytes
    )

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
        let normalizedCredentials = ServerCredentials(
            serverURL: normalized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            username: username,
            password: credentials.password
        )
        self.credentials = normalizedCredentials
        self.accountScope = AccountScope.identifier(for: normalizedCredentials)
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

    private func readRequest<Payload: Decodable & Sendable>(
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

    private func mutationRequest<Payload: Decodable & Sendable>(
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

    private func mutationRequest<Payload: Decodable & Sendable>(
        _ endpoint: String,
        queryItems: [URLQueryItem]
    ) async throws -> Payload {
        try await performRequest(
            endpoint,
            queryItems: queryItems,
            semantics: .mutation
        )
    }

    private func performRequest<Payload: Decodable & Sendable>(
        _ endpoint: String,
        queryItems: [URLQueryItem],
        semantics: RequestSemantics
    ) async throws -> Payload {
        let url = try endpointURL(endpoint, queryItems: queryItems)
        let cacheKey = Self.responseCacheKey(
            endpoint: endpoint,
            queryItems: queryItems
        )
        let cacheLifetime = Self.responseCacheLifetime(for: endpoint)
        do {
            let response: HTTPResponseData
            let requestEpoch: UInt64
            switch semantics {
            case .readOnly:
                requestEpoch = mutationEpoch
                if mutationsInFlight == 0,
                   cacheLifetime > 0,
                   let cached = cachedResponse(
                    for: cacheKey,
                    lifetime: cacheLifetime
                   ) {
                    return try decodeResponseData(cached)
                }
                response = try await coalescedReadResponse(
                    from: url,
                    key: ReadRequestKey(
                        endpoint: endpoint,
                        queryItems: queryItems,
                        mutationEpoch: requestEpoch
                    )
                )
            case .mutation:
                mutationsInFlight += 1
                mutationEpoch &+= 1
                requestEpoch = mutationEpoch
                clearResponseCache()
                response = try await responseData(
                    from: url,
                    allowsRetry: false
                )
            }
            let payload: Payload = try decodeResponse(response)
            switch semantics {
            case .readOnly where mutationsInFlight == 0
                    && cacheLifetime > 0
                    && mutationEpoch == requestEpoch:
                // Store only a body that decoded into the endpoint's expected
                // payload, never an HTTP or schema error response.
                storeResponse(response.data, for: cacheKey)
            case .mutation:
                mutationsInFlight = max(0, mutationsInFlight - 1)
                mutationEpoch &+= 1
                clearResponseCache()
            default:
                break
            }
            return payload
        } catch {
            if case .mutation = semantics {
                mutationsInFlight = max(0, mutationsInFlight - 1)
                mutationEpoch &+= 1
                clearResponseCache()
            }
            logFailure(error, endpoint: endpoint)
            throw error
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
    ) throws -> Payload {
        guard (200..<300).contains(response.statusCode) else {
            throw OpenSubsonicError.http(response.statusCode)
        }
        return try decodeResponseData(response.data)
    }

    private func decodeResponseData<Payload: Decodable & Sendable>(
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
            let response = try await coalescedReadResponse(
                from: url,
                key: ReadRequestKey(
                    endpoint: endpoint,
                    queryItems: [],
                    mutationEpoch: mutationEpoch
                )
            )
            guard (200..<300).contains(response.statusCode) else {
                throw OpenSubsonicError.http(response.statusCode)
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
        key: ReadRequestKey
    ) async throws -> HTTPResponseData {
        try Task.checkCancellation()
        let waiter = UUID()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerReadWaiter(
                    continuation,
                    key: key,
                    waiter: waiter,
                    url: url
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
        url: URL
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
                let response = try await responseData(
                    from: url,
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
                        statusCode: result.statusCode
                      ) else {
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
            return HTTPResponseData(
                data: encodedData,
                statusCode: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        let contentEncoding = http.value(forHTTPHeaderField: "Content-Encoding")
        do {
            let data = try HTTPContentDecoder.decode(
                encodedData,
                contentEncoding: contentEncoding
            )
            return HTTPResponseData(
                data: data,
                statusCode: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
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
        for key: String,
        lifetime: TimeInterval
    ) -> Data? {
        responseCache.value(for: key, maximumAge: lifetime)
    }

    private func storeResponse(_ data: Data, for key: String) {
        responseCache.insert(data, for: key)
    }

    private func clearResponseCache() {
        responseCache.removeAll(keepingCapacity: false)
    }

    private static func responseCacheKey(
        endpoint: String,
        queryItems: [URLQueryItem]
    ) -> String {
        var parameters: [String] = []
        parameters.reserveCapacity(queryItems.count)
        for item in queryItems {
            parameters.append(item.name + "=" + (item.value ?? ""))
        }
        parameters.sort()
        return endpoint + "?" + parameters.joined(separator: "&")
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
        var matches: [Song] = []
        var ids = Set<String>()
        for candidate in candidates.prefix(limit) {
            guard !Task.isCancelled else { break }
            let normalizedTitle = Self.normalized(candidate.title)
            let normalizedArtist = Self.normalized(candidate.artist)
            let normalizedAlbum = candidate.album.map(Self.normalized)
            guard !normalizedTitle.isEmpty else { continue }
            let localMatch = library.first { song in
                guard let recordingMBID = candidate.recordingMBID else {
                    return false
                }
                return song.musicBrainzId?.caseInsensitiveCompare(recordingMBID)
                    == .orderedSame
            } ?? library.first { song in
                Self.matchesExternalMetadata(
                    song,
                    title: normalizedTitle,
                    artist: normalizedArtist,
                    album: normalizedAlbum
                )
            } ?? library.first { song in
                Self.matchesExternalMetadata(
                    song,
                    title: normalizedTitle,
                    artist: normalizedArtist,
                    album: nil
                )
            }
            let match: Song?
            if let localMatch {
                match = localMatch
            } else {
                let query = "\(candidate.artist) \(candidate.title)"
                guard let results = try? await search(query) else { continue }
                match = results.songs.first { song in
                    guard let recordingMBID = candidate.recordingMBID else {
                        return false
                    }
                    return song.musicBrainzId?.caseInsensitiveCompare(recordingMBID)
                        == .orderedSame
                } ?? results.songs.first { song in
                    Self.matchesExternalMetadata(
                        song,
                        title: normalizedTitle,
                        artist: normalizedArtist,
                        album: normalizedAlbum
                    )
                } ?? results.songs.first { song in
                    Self.matchesExternalMetadata(
                        song,
                        title: normalizedTitle,
                        artist: normalizedArtist,
                        album: nil
                    )
                }
            }
            if let match, ids.insert(match.id).inserted {
                matches.append(match)
            }
        }
        return matches
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
        if let supportedExtensions {
            return supportedExtensions.contains(name)
        }
        guard let payload: OpenSubsonicExtensionsPayload =
                try? await readRequest("getOpenSubsonicExtensions") else {
            // Older Navidrome-compatible servers may implement the endpoint
            // without advertising extensions. Keep the existing best-effort
            // Sonic request in that compatibility case.
            return name == "sonicSimilarity"
        }
        let names = Set(
            (payload.openSubsonicExtensions ?? []).compactMap { value in
                value.versions.isEmpty ? nil : value.name
            }
        )
        supportedExtensions = names
        return names.contains(name)
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
            of: (Int, [Song]).self,
            returning: [(Int, [Song])].self
        ) { group in
            for (index, playlist) in playlists.prefix(3).enumerated() {
                group.addTask { [self] in
                    (
                        index,
                        (try? await self.playlist(id: playlist.id))?.songs ?? []
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

    private static func matchesExternalMetadata(
        _ song: Song,
        title: String,
        artist: String,
        album: String?
    ) -> Bool {
        guard normalized(song.title) == title, !artist.isEmpty else {
            return false
        }
        let songArtist = normalized(song.artist)
        guard songArtist == artist ||
                songArtist.contains(artist) ||
                artist.contains(songArtist) else {
            return false
        }
        guard let album, !album.isEmpty else { return true }
        return normalized(song.album) == album
    }

    private static func uniqueArtists(_ artists: [Artist]) -> [Artist] {
        var ids = Set<String>()
        return artists.filter { ids.insert($0.id).inserted }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
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
        do {
            let payload: SearchPayload = try await readRequest("search3", parameters: parameters)
            let result = payload.searchResult3 ?? payload.searchResult2
            return Self.deduplicatedSearch(result)
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            guard Self.shouldFallbackToSearch2(error) else { throw error }
            let payload: SearchPayload = try await readRequest("search2", parameters: parameters)
            return Self.deduplicatedSearch(payload.searchResult2 ?? payload.searchResult3)
        }
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
    func song(id: String) async throws -> Song {
        let payload: SongPayload = try await readRequest(
            "getSong",
            parameters: ["id": id]
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
        occurrenceID: UUID
    ) async throws -> PlaybackMediaItem {
        var canonical = try await song(id: provisional.id)
        canonical.starred = provisional.starred
        if canonical.artworkID == nil,
           provisional.artworkID != nil,
           let albumID = canonical.albumId,
           albumID == provisional.albumId {
            canonical.coverArt = provisional.artworkID
        }
        return PlaybackMediaItem(
            song: canonical,
            accountScope: accountScope,
            occurrenceID: occurrenceID
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
        // Servers without topSongsByArtistId use the artist name as identity.
        // Use getArtist's authoritative name rather than a stale route label.
        let top: TopSongsPayload = try await readRequest(
            "getTopSongs",
            parameters: usesArtistID
                ? ["id": id, "artist": artist.name, "count": "20"]
                : ["artist": artist.name, "count": "20"]
        )
        let info = try await infoPayload
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
        // Memory pressure should not turn a visible, awaited request into a
        // user-facing cancellation. Shared transfers are released naturally
        // when their last waiter goes away.
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
