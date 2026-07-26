import CryptoKit
import Foundation

enum OpenSubsonicError: LocalizedError, Equatable {
    case invalidServerURL
    case invalidResponse
    case server(code: Int?, message: String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            String(localized: "서버 주소가 올바르지 않습니다.")
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

    let credentials: ServerCredentials
    private let session: URLSession
    private let decoder: JSONDecoder

    init(credentials: ServerCredentials) throws {
        guard let normalized = Self.normalizedBaseURL(credentials.serverURL) else {
            throw OpenSubsonicError.invalidServerURL
        }
        self.credentials = ServerCredentials(
            serverURL: normalized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            username: credentials.username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: credentials.password
        )

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = URLCache(
            memoryCapacity: 24 * 1_024 * 1_024,
            diskCapacity: 128 * 1_024 * 1_024,
            diskPath: "BuFiAPI"
        )
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = true
        configuration.multipathServiceType = .handover
        self.session = URLSession(configuration: configuration)
        self.decoder = JSONDecoder()
    }

    private static func normalizedBaseURL(_ value: String) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("https://") && !text.lowercased().hasPrefix("http://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
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
            queryItems: parameters.map { URLQueryItem(name: $0.key, value: $0.value) },
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

    private func decodeResponse<Payload: Decodable>(from url: URL) async throws -> Payload {
        let (data, http) = try await responseData(from: url, acceptsZstandard: true)
        guard (200..<300).contains(http.statusCode) else {
            throw OpenSubsonicError.http(http.statusCode)
        }

        let statusEnvelope = try decoder.decode(StatusEnvelope.self, from: data)
        guard statusEnvelope.response.status == "ok" else {
            throw OpenSubsonicError.server(
                code: statusEnvelope.response.error?.code,
                message: statusEnvelope.response.error?.message
                    ?? String(localized: "서버 요청이 실패했습니다.")
            )
        }
        return try decoder.decode(APIEnvelope<Payload>.self, from: data).response
    }

    func ping() async throws -> StatusBody {
        let url = try endpointURL("ping")
        let (data, http) = try await responseData(from: url, acceptsZstandard: true)
        guard (200..<300).contains(http.statusCode) else {
            throw OpenSubsonicError.invalidResponse
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
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            acceptsZstandard ? "zstd, br, gzip" : "br, gzip",
            forHTTPHeaderField: "Accept-Encoding"
        )
        if url.scheme?.lowercased() == "https" {
            request.assumesHTTP3Capable = true
        }

        let (encodedData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenSubsonicError.invalidResponse
        }
        do {
            let data = try HTTPContentDecoder.decode(
                encodedData,
                contentEncoding: http.value(forHTTPHeaderField: "Content-Encoding")
            )
            return (data, http)
        } catch where acceptsZstandard {
            // A server can negotiate zstd with an older CFNetwork build.
            // Retrying with Brotli/gzip keeps login and library sync reliable.
            return try await responseData(from: url, acceptsZstandard: false)
        }
    }

    func home() async throws -> HomeSnapshot {
        async let recent: AlbumListPayload? = try? request(
            "getAlbumList2",
            parameters: ["type": "newest", "size": "20"]
        )
        async let randomAlbums: AlbumListPayload? = try? request(
            "getAlbumList2",
            parameters: ["type": "random", "size": "20"]
        )
        async let starred: StarredPayload? = try? request("getStarred2")
        async let artists: ArtistsPayload? = try? request("getArtists")
        async let randomSongs: RandomSongsPayload? = try? request(
            "getRandomSongs",
            parameters: ["size": "40"]
        )
        async let playlists: PlaylistsPayload? = try? request("getPlaylists")

        let values = await (recent, randomAlbums, starred, artists, randomSongs, playlists)
        return HomeSnapshot(
            recentAlbums: values.0?.albumList2?.album ?? [],
            randomAlbums: values.1?.albumList2?.album ?? [],
            starredAlbums: values.2?.starred2?.album ?? [],
            starredSongs: values.2?.starred2?.song ?? [],
            starredArtists: values.2?.starred2?.artist ?? [],
            artists: values.3?.artists?.index?.flatMap { $0.artist ?? [] } ?? [],
            randomSongs: values.4?.randomSongs?.song ?? [],
            playlists: values.5?.playlists?.playlist ?? []
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
            let payload: SearchPayload = try await request("search2", parameters: parameters)
            return Self.deduplicatedSearch(payload.searchResult2 ?? payload.searchResult3)
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
        return AlbumDetail(album: value.albumValue, songs: value.song ?? [])
    }

    func playlist(id: String) async throws -> PlaylistDetail {
        let payload: PlaylistPayload = try await request("getPlaylist", parameters: ["id": id])
        guard let value = payload.playlist else { throw OpenSubsonicError.invalidResponse }
        return PlaylistDetail(playlist: value.playlistValue, songs: value.entry ?? [])
    }

    func artist(id: String, name: String) async throws -> ArtistDetail {
        async let albumsPayload: ArtistAlbumsPayload = request("getArtist", parameters: ["id": id])
        async let topPayload: TopSongsPayload = request(
            "getTopSongs",
            parameters: ["artist": name, "count": "20"]
        )
        async let infoPayload: ArtistInfoPayload? = try? request(
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
            displayTitle: source.displayTitle,
            displayArtist: source.displayArtist,
            language: source.lang,
            synced: source.synced ?? !lines.isEmpty,
            lines: lines.sorted { $0.start < $1.start }
        )
    }

    func streamURL(
        songID: String,
        quality: StreamQuality,
        compatibilityFormat: String? = nil
    ) throws -> URL {
        var parameters = quality.parameters
        parameters["id"] = songID
        parameters["estimateContentLength"] = "true"
        if let compatibilityFormat {
            parameters["format"] = compatibilityFormat
            parameters["maxBitRate"] = "320"
        }
        return try endpointURL("stream", parameters: parameters, json: false)
    }

    func coverURL(id: String, size: Int = 600) throws -> URL {
        try endpointURL(
            "getCoverArt",
            parameters: ["id": id, "size": String(size)],
            json: false
        )
    }

    func downloadURL(songID: String) throws -> URL {
        try endpointURL("download", parameters: ["id": songID], json: false)
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
