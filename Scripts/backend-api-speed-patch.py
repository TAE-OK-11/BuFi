from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"{path}: expected one match, got {count}: {old[:100]!r}"
        )
    file.write_text(text.replace(old, new, 1))


def replace_region(path: str, start: str, end: str, replacement: str) -> None:
    file = Path(path)
    text = file.read_text()
    begin = text.find(start)
    if begin < 0:
        raise SystemExit(f"{path}: start marker not found: {start!r}")
    finish = text.find(end, begin + len(start))
    if finish < 0:
        raise SystemExit(f"{path}: end marker not found: {end!r}")
    file.write_text(text[:begin] + replacement + text[finish:])


# 1) Most API bodies are already expanded by CFNetwork. Avoid an async
# decoder hop unless the bytes are actually a zstd frame that BuFi owns.
replace_once(
    "BuFi/Core/HTTPContentDecoder.swift",
    '''    static func decode(_ data: Data, contentEncoding: String?) throws -> Data {
        try Task.checkCancellation()
        guard isZstandardFrame(data) else {
            // URLSession expands gzip and Brotli, and newer CFNetwork versions
            // may also expand zstd before returning the body.
            return data
        }
        guard declaresZstandard(contentEncoding) != false else {
            return data
        }
        return try decompressZstandard(data)
    }
''',
    '''    static func requiresManualDecoding(
        _ data: Data,
        contentEncoding: String?
    ) -> Bool {
        isZstandardFrame(data)
            && declaresZstandard(contentEncoding) != false
    }

    static func decode(_ data: Data, contentEncoding: String?) throws -> Data {
        try Task.checkCancellation()
        guard requiresManualDecoding(
            data,
            contentEncoding: contentEncoding
        ) else {
            // URLSession expands gzip and Brotli, and newer CFNetwork versions
            // may also expand zstd before returning the body.
            return data
        }
        return try decompressZstandard(data)
    }
''',
)

osc = "BuFi/Core/OpenSubsonicClient.swift"

# 2) Subsonic token auth supports a reusable random salt/token pair. SwiftSonic
# is already configured with reusesSalt=true, so mirror that in BuFi's native
# request path and remove random/MD5/hex work from every request.
replace_once(
    osc,
    '''    private let swiftSonic: SwiftSonicClient
    private let retryPolicy = ReadRequestRetryPolicy()
    private var supportedExtensions: Set<String>?
''',
    '''    private let swiftSonic: SwiftSonicClient
    private let retryPolicy = ReadRequestRetryPolicy()
    private let authenticationQueryItems: [URLQueryItem]
    private var supportedExtensions: Set<String>?
''',
)
replace_once(
    osc,
    '''        self.credentials = normalizedCredentials
        self.accountScope = AccountScope.identifier(for: normalizedCredentials)
        self.swiftSonic = SwiftSonicClient(
''',
    '''        self.credentials = normalizedCredentials
        self.accountScope = AccountScope.identifier(for: normalizedCredentials)
        self.authenticationQueryItems = Self.makeAuthenticationItems(
            for: normalizedCredentials
        )
        self.swiftSonic = SwiftSonicClient(
''',
)
replace_once(
    osc,
    '''    private func authenticationItems() -> [URLQueryItem] {
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
''',
    '''    private static func makeAuthenticationItems(
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
''',
)

# 3) Add a tiny typed/decoded cache on top of the existing revision-aware body
# cache. Fresh repeated reads can now skip URL construction, transport and JSON
# decoding while retaining the exact same TTL and mutation invalidation model.
replace_once(
    osc,
    '''    private static let responseCacheLimit = 128
    private static let responseCacheByteLimit = 16 * 1_024 * 1_024
    private static let maximumCachedResponseBytes = 2 * 1_024 * 1_024
    private static let coverURLCacheLimit = 512
    private var responseCache = ResponseBodyCache(
        countLimit: OpenSubsonicClient.responseCacheLimit,
        byteLimit: OpenSubsonicClient.responseCacheByteLimit,
        maximumEntryBytes: OpenSubsonicClient.maximumCachedResponseBytes
    )
    private var lyricsCache = LyricsDocumentCache(countLimit: 64)
''',
    '''    private enum ReadResponseSource {
        case network
        case freshCache
        case staleFallback
    }

    private struct DecodedResponseCacheEntry {
        let payload: any Sendable
        let storedAt: ContinuousClock.Instant
        var accessOrdinal: UInt64
    }

    private static let responseCacheLimit = 128
    private static let responseCacheByteLimit = 16 * 1_024 * 1_024
    private static let maximumCachedResponseBytes = 2 * 1_024 * 1_024
    private static let decodedResponseCacheLimit = 32
    private static let coverURLCacheLimit = 512
    private var responseCache = ResponseBodyCache(
        countLimit: OpenSubsonicClient.responseCacheLimit,
        byteLimit: OpenSubsonicClient.responseCacheByteLimit,
        maximumEntryBytes: OpenSubsonicClient.maximumCachedResponseBytes
    )
    private var decodedResponseCache: [String: DecodedResponseCacheEntry] = [:]
    private var decodedResponseAccessClock: UInt64 = 0
    private var lyricsCache = LyricsDocumentCache(countLimit: 64)
''',
)
replace_once(
    osc,
    '''        mutationWaiters.removeAll(keepingCapacity: false)
        coverURLCache.removeAll(keepingCapacity: false)
        session.invalidateAndCancel()
''',
    '''        mutationWaiters.removeAll(keepingCapacity: false)
        decodedResponseCache.removeAll(keepingCapacity: false)
        decodedResponseAccessClock = 0
        coverURLCache.removeAll(keepingCapacity: false)
        session.invalidateAndCancel()
''',
)

# Playlist headers and playlist details are the same library-list dependency.
# This makes the new parsed cache just as mutation-safe as the existing body
# cache when a playlist changes.
replace_once(
    osc,
    '''        case "getPlaylists":
            return OpenSubsonicResponseCachePolicy(
                lifetime: 5 * 60,
                staleGrace: 20 * 60
            )
''',
    '''        case "getPlaylists":
            return OpenSubsonicResponseCachePolicy(
                lifetime: 5 * 60,
                staleGrace: 20 * 60,
                dependencies: [.libraryLists]
            )
''',
)

perform_request = '''    private func performRequest<Payload: Decodable & Sendable>(
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
                cacheRevisionState.begin(impact)
                let url = try endpointURL(endpoint, queryItems: queryItems)
                response = try await responseData(
                    from: url,
                    allowsRetry: Self.allowsIdempotentMutationRetry(endpoint)
                )
                responseSource = .network
            }
            let payload: Payload = try await decodeResponse(response)
            switch semantics {
            case .readOnly where !cacheRevisionState.hasMutation(
                    affecting: cachePolicy.dependencies
                )
                    && cacheRevisionState.revision(
                        for: cachePolicy.dependencies
                    ) == requestRevision:
                if cachePolicy.lifetime > 0 {
                    switch responseSource {
                    case .network:
                        // Store only a body that decoded into the endpoint's
                        // expected payload, never an HTTP/schema error body.
                        storeResponse(response.data, for: cacheKey)
                        if response.data.count <= Self.maximumCachedResponseBytes {
                            storeDecodedPayload(payload, for: cacheKey)
                        }
                    case .freshCache:
                        if response.data.count <= Self.maximumCachedResponseBytes {
                            storeDecodedPayload(payload, for: cacheKey)
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
        } catch {
            if case .mutation(let impact) = semantics {
                finishMutation(impact)
            }
            logFailure(error, endpoint: endpoint)
            throw error
        }
    }

'''
replace_region(
    osc,
    "    private func performRequest<Payload: Decodable & Sendable>(\n",
    "    private func bestEffortRequest<Payload: Decodable & Sendable>(\n",
    perform_request,
)

# Coalesce identical reads before building authenticated URLs. Second and later
# waiters now avoid auth array copying, URLComponents and percent encoding.
coalesced_read = '''    private func coalescedReadResponse(
        endpoint: String,
        queryItems: [URLQueryItem],
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
                    endpoint: endpoint,
                    queryItems: queryItems
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
        queryItems: [URLQueryItem]
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

'''
replace_region(
    osc,
    "    private func coalescedReadResponse(\n",
    "    private func cancelReadWaiter(\n",
    coalesced_read,
)

replace_once(
    osc,
    '''        let endpoint = "ping"
        let url = try endpointURL(endpoint)
        do {
            let response = try await coalescedReadResponse(
                from: url,
                key: ReadRequestKey(
                    endpoint: endpoint,
                    queryItems: [],
                    cacheRevision: OpenSubsonicCacheRevision(entries: [])
                )
            )
''',
    '''        let endpoint = "ping"
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
''',
)

read_response = '''    private func readResponse(
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

        if case .fresh(let cached) = cacheHit {
            return (
                HTTPResponseData(data: cached, statusCode: 200, retryAfter: nil),
                .freshCache
            )
        }

        do {
            let response = try await coalescedReadResponse(
                endpoint: endpoint,
                queryItems: queryItems,
                key: ReadRequestKey(
                    endpoint: endpoint,
                    queryItems: queryItems,
                    cacheRevision: requestRevision
                )
            )
            return (response, .network)
        } catch {
            if case .stale(let cached) = cacheHit,
               TransientServiceFailurePolicy.allowsCachedFallback(error) {
                return (
                    HTTPResponseData(
                        data: cached,
                        statusCode: 200,
                        retryAfter: nil
                    ),
                    .staleFallback
                )
            }
            throw error
        }
    }

'''
replace_region(
    osc,
    "    private func readResponse(\n",
    "    private func cachedResponse(\n",
    read_response,
)

replace_once(
    osc,
    '''    private func storeResponse(_ data: Data, for key: String) {
        responseCache.insert(data, for: key)
    }

    private func clearResponseCache() {
        responseCache.removeAll(keepingCapacity: false)
    }
''',
    '''    private func storeResponse(_ data: Data, for key: String) {
        responseCache.insert(data, for: key)
    }

    private func cachedDecodedPayload<Payload: Sendable>(
        for key: String,
        maximumAge: TimeInterval
    ) -> Payload? {
        guard maximumAge > 0,
              var entry = decodedResponseCache[key] else {
            return nil
        }
        let now = ContinuousClock().now
        guard entry.storedAt.duration(to: now) <= .seconds(maximumAge) else {
            decodedResponseCache[key] = nil
            return nil
        }
        guard let payload = entry.payload as? Payload else {
            decodedResponseCache[key] = nil
            return nil
        }
        decodedResponseAccessClock &+= 1
        entry.accessOrdinal = decodedResponseAccessClock
        decodedResponseCache[key] = entry
        return payload
    }

    private func storeDecodedPayload<Payload: Sendable>(
        _ payload: Payload,
        for key: String
    ) {
        decodedResponseAccessClock &+= 1
        decodedResponseCache[key] = DecodedResponseCacheEntry(
            payload: payload,
            storedAt: ContinuousClock().now,
            accessOrdinal: decodedResponseAccessClock
        )
        while decodedResponseCache.count > Self.decodedResponseCacheLimit,
              let oldestKey = decodedResponseCache.min(by: {
                  $0.value.accessOrdinal < $1.value.accessOrdinal
              })?.key {
            decodedResponseCache[oldestKey] = nil
        }
    }

    private func clearResponseCache() {
        responseCache.removeAll(keepingCapacity: false)
        decodedResponseCache.removeAll(keepingCapacity: false)
        decodedResponseAccessClock = 0
    }
''',
)

# Avoid creating a concurrent decoder task for identity/gzip/brotli-expanded
# bytes. Large zstd decompression still remains off the actor.
replace_once(
    osc,
    '''        let contentEncoding = http.value(forHTTPHeaderField: "Content-Encoding")
        do {
            let data = try await HTTPContentDecoder.decodeAsync(
                encodedData,
                contentEncoding: contentEncoding
            )
            return HTTPResponseData(
''',
    '''        let contentEncoding = http.value(forHTTPHeaderField: "Content-Encoding")
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
''',
)

# Start independent home enrichment while the popular-album request is still
# in flight; only the popular-song task actually depends on that result.
replace_once(
    osc,
    '''            let popularAlbumsValue: AlbumListPayload? = try await albumList(
                "highest",
                size: "8"
            )
            let popularAlbumValues = albums(from: popularAlbumsValue, fallback: [])
            let enrichmentLimiter = HomeEnrichmentRequestLimiter(
''',
    '''            async let popularAlbumsRequest: AlbumListPayload? = albumList(
                "highest",
                size: "8"
            )
            let enrichmentLimiter = HomeEnrichmentRequestLimiter(
''',
)
replace_once(
    osc,
    '''            async let recentlyAddedSongsRequest = songs(
                from: Array(
                    recentAlbums.prefix(
                        OpenSubsonicRequestPolicy.homeAlbumTrackLimit
                    )
                ),
                fallback: fallback.recentlyAddedSongs,
                count: resultLimit,
                limiter: enrichmentLimiter
            )
            async let popularSongsRequest = songs(
''',
    '''            async let recentlyAddedSongsRequest = songs(
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
''',
)

# topSongsByArtistId removes the dependency on getArtist's name. On capable
# servers, fetch artist/biography/top-songs in parallel. Older servers retain
# the existing authoritative-name sequence unchanged.
artist_detail = '''    func artist(id: String, name: String) async throws -> ArtistDetail {
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

'''
replace_region(
    osc,
    "    func artist(id: String, name: String) async throws -> ArtistDetail {\n",
    "    func lyrics(\n",
    artist_detail,
)

# 4) These stores are independent. Waiting for them serially adds local actor
# latency after every API refresh without improving consistency.
app = "BuFi/App/AppModel.swift"
replace_once(
    app,
    '''        let history = await ListeningHistoryStore.shared.snapshot()
        let offlineSongIDs = await OfflineStore.shared.availableSongIDs()
        var value = snapshot
''',
    '''        async let historyRequest = ListeningHistoryStore.shared.snapshot()
        async let offlineSongIDsRequest = OfflineStore.shared.availableSongIDs()
        let (history, offlineSongIDs) = await (
            historyRequest,
            offlineSongIDsRequest
        )
        var value = snapshot
''',
)

# 5) External API requests reuse policy state and take the same no-hop path for
# non-zstd bodies. Last.fm/ListenBrainz result semantics and retry limits stay
# unchanged.
rec = "BuFi/Core/RecommendationEngine.swift"
replace_once(
    rec,
    '''    private let publicSession: URLSession
    private let privateSession: URLSession
    private let decoder = JSONDecoder()
''',
    '''    private let publicSession: URLSession
    private let privateSession: URLSession
    private let decoder = JSONDecoder()
    private let retryPolicy = ReadRequestRetryPolicy()
''',
)
replace_once(
    rec,
    '''        let session = allowsCaching ? publicSession : privateSession
        let retryPolicy = ReadRequestRetryPolicy()
        var retryCount = 0
''',
    '''        let session = allowsCaching ? publicSession : privateSession
        var retryCount = 0
''',
)
replace_once(
    rec,
    '''            let decoded = try await HTTPContentDecoder.decodeAsync(
                data,
                contentEncoding: http.value(forHTTPHeaderField: "Content-Encoding")
            )
''',
    '''            let contentEncoding = http.value(
                forHTTPHeaderField: "Content-Encoding"
            )
            let decoded: Data
            if HTTPContentDecoder.requiresManualDecoding(
                data,
                contentEncoding: contentEncoding
            ) {
                decoded = try await HTTPContentDecoder.decodeAsync(
                    data,
                    contentEncoding: contentEncoding
                )
            } else {
                decoded = data
            }
''',
)
