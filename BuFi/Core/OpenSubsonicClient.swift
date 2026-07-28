import CryptoKit
import Foundation
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

actor OpenSubsonicClient {
    static let apiVersion = "1.16.1"
    static let clientName = "BuFi"
    private static let maximumResponseBytes = 64 * 1_024 * 1_024

    let credentials: ServerCredentials
    private let session: URLSession
    private let decoder: JSONDecoder
    private let swiftSonic: SwiftSonicClient

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

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = true
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

    func request<Payload: Decodable>(
        _ endpoint: String,
        parameters: [String: String] = [:]
    ) async throws -> Payload {
        let url = try endpointURL(endpoint, parameters: parameters)
        return try await decodeResponse(from: url)
    }

    private func request<Payload: Decodable>(
        _ endpoint: String,
        queryItems: [URLQueryItem]
    ) async throws -> Payload {
        let url = try endpointURL(endpoint, queryItems: queryItems)
        return try await decodeResponse(from: url)
    }

    private func bestEffortRequest<Payload: Decodable>(
        _ endpoint: String,
        parameters: [String: String] = [:]
    ) async throws -> Payload? {
        do {
            return try await request(endpoint, parameters: parameters)
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

    private func decodeResponse<Payload: Decodable>(from url: URL) async throws -> Payload {
        let (data, http) = try await responseData(from: url, acceptsZstandard: true)
        guard (200..<300).contains(http.statusCode) else {
            throw OpenSubsonicError.http(http.statusCode)
        }

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
        let url = try endpointURL("ping")
        let (data, http) = try await responseData(from: url, acceptsZstandard: true)

        guard (200..<300).contains(http.statusCode) else {
            throw OpenSubsonicError.http(http.statusCode)
        }
        let envelope = try decoder.decode(StatusEnvelope.self, from: data)
        guard envelope.response.status == "ok" else {
            throw OpenSubsonicError.server(
                code: envelope.response.error?.code,
                message: envelope.response.error?.message
                    ?? String(localized: "서버 연결에 실패했습니다.")
            )
        }
        return envelope.response
    }

    private func responseData(
        from url: URL,
        acceptsZstandard: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            acceptsZstandard ? "zstd, br, gzip" : "br, gzip",
            forHTTPHeaderField: "Accept-Encoding"
        )
        request.assumesHTTP3Capable = true

        let (encodedData, response) = try await session.data(for: request)
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
        do {
            let data = try HTTPContentDecoder.decode(
                encodedData,
                contentEncoding: http.value(forHTTPHeaderField: "Content-Encoding")
            )
            return (data, http)
        } catch let error as URLError
            where acceptsZstandard && error.code == .cannotDecodeContentData {
            try Task.checkCancellation()
            return try await responseData(from: url, acceptsZstandard: false)
        }
    }

    func home(from previous: HomeSnapshot? = nil) async throws -> HomeLoadResult {
        async let recent: AlbumListPayload? = bestEffortRequest(
            "getAlbumList2",
            parameters: ["type": "newest", "size": "16"]
        )
        async let randomAlbums: AlbumListPayload? = bestEffortRequest(
            "getAlbumList2",
            parameters: ["type": "random", "size": "16"]
        )
        async let starred: StarredPayload? = bestEffortRequest("getStarred2")
        async let artists: ArtistsPayload? = bestEffortRequest("getArtists")
        async let randomSongs: RandomSongsPayload? = bestEffortRequest(
            "getRandomSongs",
            parameters: ["size": "24"]
        )
        async let playlists: PlaylistsPayload? = bestEffortRequest("getPlaylists")

        let values = try await (recent, randomAlbums, starred, artists, randomSongs, playlists)
        guard values.0 != nil || values.1 != nil || values.2 != nil ||
                values.3 != nil || values.4 != nil || values.5 != nil else {
            throw OpenSubsonicError.invalidResponse
        }

        let fallback = previous ?? .empty
        let starredAlbums: [Album]
        let starredSongs: [Song]
        let starredArtists: [Artist]
        if let value = values.2?.starred2 {
            starredAlbums = value.album ?? []
            starredSongs = value.song ?? []
            starredArtists = value.artist ?? []
        } else {
            starredAlbums = fallback.starredAlbums
            starredSongs = fallback.starredSongs
            starredArtists = fallback.starredArtists
        }

        return HomeLoadResult(
            snapshot: HomeSnapshot(
                recentAlbums: values.0.map { $0.albumList2?.album ?? [] }
                    ?? fallback.recentAlbums,
                randomAlbums: values.1.map { $0.albumList2?.album ?? [] }
                    ?? fallback.randomAlbums,
                starredAlbums: starredAlbums,
                starredSongs: starredSongs,
                starredArtists: starredArtists,
                artists: values.3.map { $0.artists?.index?.flatMap { $0.artist ?? [] } ?? [] }
                    ?? fallback.artists,
                randomSongs: values.4.map { $0.randomSongs?.song ?? [] }
                    ?? fallback.randomSongs,
                playlists: values.5.map { $0.playlists?.playlist ?? [] }
                    ?? fallback.playlists
            ),
            hasAuthoritativeStarredState: values.2?.starred2 != nil
        )
    }

    func incrementalHome(from previous: HomeSnapshot) async throws -> HomeLoadResult {
        async let recent: AlbumListPayload? = bestEffortRequest(
            "getAlbumList2",
            parameters: ["type": "newest", "size": "16"]
        )
        async let starred: StarredPayload? = bestEffortRequest("getStarred2")
        async let playlists: PlaylistsPayload? = bestEffortRequest("getPlaylists")

        let values = try await (recent, starred, playlists)
        guard values.0 != nil || values.1 != nil || values.2 != nil else {
            throw OpenSubsonicError.invalidResponse
        }

        var snapshot = previous
        if let recent = values.0 {
            snapshot.recentAlbums = recent.albumList2?.album ?? []
        }
        if let starred = values.1?.starred2 {
            snapshot.starredAlbums = starred.album ?? []
            snapshot.starredSongs = starred.song ?? []
            snapshot.starredArtists = starred.artist ?? []
        }
        if let playlists = values.2 {
            snapshot.playlists = playlists.playlists?.playlist ?? []
        }
        return HomeLoadResult(
            snapshot: snapshot,
            hasAuthoritativeStarredState: values.1?.starred2 != nil
        )
    }

    func search(_ query: String) async throws -> SearchResults {
        let parameters = [
            "query": query,
            "artistCount": "8",
            "albumCount": "14",
            "songCount": "30"
        ]
        do {
            let payload: SearchPayload = try await request("search3", parameters: parameters)
            let result = payload.searchResult3 ?? payload.searchResult2
            return Self.deduplicatedSearch(result)
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            guard Self.shouldFallbackToSearch2(error) else { throw error }
            let payload: SearchPayload = try await request("search2", parameters: parameters)
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
        let payload: AlbumPayload = try await request("getAlbum", parameters: ["id": id])
        guard let value = payload.album else { throw OpenSubsonicError.invalidResponse }
        return AlbumDetail(songs: value.song ?? [])
    }

    func playlist(id: String) async throws -> PlaylistDetail {
        let payload: PlaylistPayload = try await request("getPlaylist", parameters: ["id": id])
        guard let value = payload.playlist else { throw OpenSubsonicError.invalidResponse }
        return PlaylistDetail(songs: value.entry ?? [])
    }

    func artist(id: String, name: String) async throws -> ArtistDetail {
        async let albumsPayload: ArtistAlbumsPayload = request("getArtist", parameters: ["id": id])
        async let topPayload: TopSongsPayload = request(
            "getTopSongs",
            parameters: ["artist": name, "count": "20"]
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
            topSongs: top.topSongs?.song ?? [],
            info: info?.artistInfo2
        )
    }

    func lyrics(songID: String) async throws -> LyricsDocument {
        let payload: LyricsPayload = try await request(
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
        let _: EmptyPayload = try await request(
            enabled ? "star" : "unstar",
            parameters: [target.parameterName: id]
        )
    }

    func scrobble(id: String, submission: Bool) async throws {
        let _: EmptyPayload = try await request(
            "scrobble",
            parameters: [
                "id": id,
                "submission": submission ? "true" : "false",
                "time": String(Int(Date().timeIntervalSince1970 * 1_000))
            ]
        )
    }

    func playQueue() async throws -> ServerPlayQueue {
        let payload: PlayQueuePayload = try await request("getPlayQueue")
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
        let _: EmptyPayload = try await request("savePlayQueue", queryItems: queryItems)
    }
}
