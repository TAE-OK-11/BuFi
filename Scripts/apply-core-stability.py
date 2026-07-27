from __future__ import annotations

from pathlib import Path
import re


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one literal match, found {count}: {old[:120]!r}")
    path.write_text(text.replace(old, new, 1))


def sub_once(path: Path, pattern: str, replacement: str, flags: int = 0) -> None:
    text = path.read_text()
    updated, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        raise RuntimeError(f"{path}: expected one regex match, found {count}: {pattern[:140]!r}")
    path.write_text(updated)


# OfflineStore: invalidate stale downloads, retry metadata writes, and make eviction honest.
offline = Path("BuFi/Core/OfflineStore.swift")
replace_once(
    offline,
    '''    private struct DownloadResult: Sendable {
        let url: URL
        let byteCount: Int64
    }
''',
    '''    private struct DownloadResult: Sendable {
        let url: URL
        let byteCount: Int64
    }

    private struct InFlightDownload {
        let scopeGeneration: UInt64
        let songGeneration: UInt64
        let task: Task<DownloadResult, Error>
    }
''',
)
replace_once(
    offline,
    '''    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<DownloadResult, Error>] = [:]
    private var indexSaveTask: Task<Void, Never>?
    private var indexIsDirty = false
''',
    '''    private var entries: [String: Entry] = [:]
    private var inFlight: [String: InFlightDownload] = [:]
    private var scopeGeneration: UInt64 = 0
    private var songGenerations: [String: UInt64] = [:]
    private var indexSaveTask: Task<Void, Never>?
    private var indexIsDirty = false
    private var indexRetryCount = 0
''',
)
replace_once(
    offline,
    '''        flushPendingWrites()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
''',
    '''        flushPendingWrites(retryOnFailure: false)
        scopeGeneration &+= 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        songGenerations.removeAll(keepingCapacity: false)
        indexRetryCount = 0
''',
)
replace_once(
    offline,
    '''    func downloadedSongs() -> [Song] {
        entries.values
            .sorted { $0.downloadedAt > $1.downloadedAt }
            .map(\.song)
    }
''',
    '''    func downloadedSongs() -> [Song] {
        guard let directory else { return [] }
        let valid = entries.filter { _, entry in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(entry.fileName).path
            )
        }
        if valid.count != entries.count {
            entries = valid
            scheduleIndexPersistence()
        }
        return valid.values
            .sorted { $0.downloadedAt > $1.downloadedAt }
            .map(\.song)
    }
''',
)
replace_once(
    offline,
    '''        if let existing = localURL(for: song.id) { return existing }

        let taskKey = scope + ":" + song.id
        if let existingTask = inFlight[taskKey] {
            return try await existingTask.value.url
        }
''',
    '''        if let existing = localURL(for: song.id) { return existing }

        let generation = scopeGeneration
        let songGeneration = songGenerations[song.id, default: 0]
        let taskKey = scope + ":" + song.id
        if let existingTask = inFlight[taskKey] {
            return try await existingTask.task.value.url
        }
''',
)
replace_once(
    offline,
    '''        inFlight[taskKey] = task

        do {
            let result = try await task.value
            inFlight[taskKey] = nil
            guard activeScope == scope else {
                try? FileManager.default.removeItem(at: result.url)
                throw CancellationError()
            }
''',
    '''        inFlight[taskKey] = InFlightDownload(
            scopeGeneration: generation,
            songGeneration: songGeneration,
            task: task
        )

        do {
            let result = try await task.value
            clearInFlight(
                taskKey: taskKey,
                scopeGeneration: generation,
                songGeneration: songGeneration
            )
            guard activeScope == scope,
                  scopeGeneration == generation,
                  songGenerations[song.id, default: 0] == songGeneration else {
                try? FileManager.default.removeItem(at: result.url)
                throw CancellationError()
            }
''',
)
replace_once(
    offline,
    '''        } catch {
            inFlight[taskKey] = nil
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("partial"))
            throw error
        }
''',
    '''        } catch {
            clearInFlight(
                taskKey: taskKey,
                scopeGeneration: generation,
                songGeneration: songGeneration
            )
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("partial"))
            throw error
        }
''',
)
replace_once(
    offline,
    '''    func remove(songID: String) throws {
        guard let directory else { return }
''',
    '''    func remove(songID: String) throws {
        guard let directory else { return }
        invalidateDownload(songID: songID)
''',
)
replace_once(
    offline,
    '''    func removeAll() throws {
        guard let directory else { return }
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
''',
    '''    func removeAll() throws {
        guard let directory else { return }
        scopeGeneration &+= 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        songGenerations.removeAll(keepingCapacity: false)
''',
)
sub_once(
    offline,
    r'''    func flushPendingWrites\(\) \{.*?\n    \}\n\n(?=    private func enforceStorageLimit)''',
    '''    func flushPendingWrites() {
        flushPendingWrites(retryOnFailure: true)
    }

    private func flushPendingWrites(retryOnFailure: Bool) {
        indexSaveTask?.cancel()
        indexSaveTask = nil
        persistIndexIfNeeded(retryOnFailure: retryOnFailure)
    }

    private func persistIndexIfNeeded(retryOnFailure: Bool) {
        guard indexIsDirty else { return }
        do {
            try persistIndex()
            indexIsDirty = false
            indexRetryCount = 0
        } catch {
            guard retryOnFailure else { return }
            indexRetryCount += 1
            guard indexRetryCount <= 3 else { return }
            let delay: Duration
            switch indexRetryCount {
            case 1: delay = .seconds(1)
            case 2: delay = .seconds(2)
            default: delay = .seconds(4)
            }
            scheduleIndexPersistence(retryDelay: delay, resetRetry: false)
        }
    }

''',
    flags=re.DOTALL,
)
replace_once(
    offline,
    '''        for (id, entry) in candidates where total > limit {
            let url = directory.appendingPathComponent(entry.fileName)
            try? FileManager.default.removeItem(at: url)
            entries[id] = nil
            total -= entry.byteCount
        }
''',
    '''        for (id, entry) in candidates where total > limit {
            let url = directory.appendingPathComponent(entry.fileName)
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                entries[id] = nil
                total -= entry.byteCount
            } catch {
                // Keep the index entry when deletion fails so storage accounting
                // remains truthful and a later cleanup can retry.
            }
        }
''',
)
sub_once(
    offline,
    r'''    private func scheduleIndexPersistence\(immediate: Bool = false\) \{.*?\n    \}\n\n(?=    private func persistIndex)''',
    '''    private func scheduleIndexPersistence(
        immediate: Bool = false,
        retryDelay: Duration? = nil,
        resetRetry: Bool = true
    ) {
        indexIsDirty = true
        if resetRetry { indexRetryCount = 0 }
        indexSaveTask?.cancel()
        let generation = scopeGeneration
        let delay: Duration = retryDelay ?? (immediate ? .zero : .milliseconds(500))
        indexSaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flushScheduledIndex(for: generation)
        }
    }

    private func flushScheduledIndex(for generation: UInt64) {
        guard generation == scopeGeneration else { return }
        indexSaveTask = nil
        persistIndexIfNeeded(retryOnFailure: true)
    }

    private func invalidateDownload(songID: String) {
        songGenerations[songID, default: 0] &+= 1
        guard let activeScope else { return }
        let taskKey = activeScope + ":" + songID
        inFlight.removeValue(forKey: taskKey)?.task.cancel()
    }

    private func clearInFlight(
        taskKey: String,
        scopeGeneration: UInt64,
        songGeneration: UInt64
    ) {
        guard let current = inFlight[taskKey],
              current.scopeGeneration == scopeGeneration,
              current.songGeneration == songGeneration else {
            return
        }
        inFlight[taskKey] = nil
    }

''',
    flags=re.DOTALL,
)
replace_once(
    offline,
    '''        return URLSession(
            configuration: configuration,
            delegate: HTTPSOnlyDownloadDelegate(),
            delegateQueue: nil
        )
''',
    '''        return URLSession(
            configuration: configuration,
            delegate: HTTPSOnlyURLSessionDelegate(),
            delegateQueue: nil
        )
''',
)
sub_once(
    offline,
    r'''\nprivate final class HTTPSOnlyDownloadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable \{.*?\n\}\n?\Z''',
    '''\n''',
    flags=re.DOTALL,
)


# OpenSubsonicClient: cancellation-safe best effort requests and fewer redundant calls.
client = Path("BuFi/Core/OpenSubsonicClient.swift")
replace_once(
    client,
    '''    static let apiVersion = "1.16.1"
    static let clientName = "BuFi"
''',
    '''    static let apiVersion = "1.16.1"
    static let clientName = "BuFi"
    private static let maximumResponseBytes = 64 * 1_024 * 1_024
''',
)
replace_once(
    client,
    '''        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
''',
    '''        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = true
        self.session = URLSession(
            configuration: configuration,
            delegate: HTTPSOnlyURLSessionDelegate(),
            delegateQueue: nil
        )
''',
)
replace_once(
    client,
    '''            queryItems: parameters.map { URLQueryItem(name: $0.key, value: $0.value) },
''',
    '''            queryItems: parameters
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) },
''',
)
replace_once(
    client,
    '''    private struct DecoderCapture: Decodable {
''',
    '''    private func bestEffortRequest<Payload: Decodable>(
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
''',
)
sub_once(
    client,
    r'''    func ping\(\) async throws -> StatusBody \{.*?\n    \}\n\n(?=    private func responseData)''',
    '''    func ping() async throws -> StatusBody {
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

''',
    flags=re.DOTALL,
)
replace_once(
    client,
    '''        let (encodedData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
''',
    '''        let (encodedData, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard encodedData.count <= Self.maximumResponseBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        guard let http = response as? HTTPURLResponse else {
''',
)
replace_once(
    client,
    '''        } catch where acceptsZstandard {
            return try await responseData(from: url, acceptsZstandard: false)
        }
''',
    '''        } catch let error as URLError
            where acceptsZstandard && error.code == .cannotDecodeContentData {
            try Task.checkCancellation()
            return try await responseData(from: url, acceptsZstandard: false)
        }
''',
)
sub_once(
    client,
    r'''    func home\(\) async throws -> HomeSnapshot \{.*?\n    \}\n\n(?=    func incrementalHome)''',
    '''    func home(from previous: HomeSnapshot? = nil) async throws -> HomeSnapshot {
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

        return HomeSnapshot(
            recentAlbums: values.0?.albumList2?.album ?? fallback.recentAlbums,
            randomAlbums: values.1?.albumList2?.album ?? fallback.randomAlbums,
            starredAlbums: starredAlbums,
            starredSongs: starredSongs,
            starredArtists: starredArtists,
            artists: values.3.map { $0.artists?.index?.flatMap { $0.artist ?? [] } ?? [] }
                ?? fallback.artists,
            randomSongs: values.4?.randomSongs?.song ?? fallback.randomSongs,
            playlists: values.5?.playlists?.playlist ?? fallback.playlists
        )
    }

''',
    flags=re.DOTALL,
)
sub_once(
    client,
    r'''    func incrementalHome\(from previous: HomeSnapshot\) async throws -> HomeSnapshot \{.*?\n    \}\n\n(?=    func search)''',
    '''    func incrementalHome(from previous: HomeSnapshot) async throws -> HomeSnapshot {
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
        if let albums = values.0?.albumList2?.album {
            snapshot.recentAlbums = albums
        }
        if let starred = values.1?.starred2 {
            snapshot.starredAlbums = starred.album ?? []
            snapshot.starredSongs = starred.song ?? []
            snapshot.starredArtists = starred.artist ?? []
        }
        if let playlists = values.2?.playlists?.playlist {
            snapshot.playlists = playlists
        }
        return snapshot
    }

''',
    flags=re.DOTALL,
)
replace_once(
    client,
    '''        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            let payload: SearchPayload = try await request("search2", parameters: parameters)
            return Self.deduplicatedSearch(payload.searchResult2 ?? payload.searchResult3)
        }
    }

    private static func deduplicatedSearch(_ result: SearchContainer?) -> SearchResults {
''',
    '''        } catch {
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
''',
)
replace_once(
    client,
    '''        async let infoPayload: ArtistInfoPayload? = try? request(
            "getArtistInfo2",
            parameters: ["id": id, "count": "8", "includeNotPresent": "false"]
        )
        let (albums, top, info) = try await (albumsPayload, topPayload, infoPayload)
''',
    '''        async let infoPayload: ArtistInfoPayload? = bestEffortRequest(
            "getArtistInfo2",
            parameters: ["id": id, "count": "8", "includeNotPresent": "false"]
        )
        let (albums, top, info) = try await (albumsPayload, topPayload, infoPayload)
''',
)


# AppModel: coalesce detail reads and prevent state flags from sticking across sessions.
app = Path("BuFi/App/AppModel.swift")
replace_once(
    app,
    '''    private var albumDetailCache: [String: CachedValue<AlbumDetail>] = [:]
    private var playlistDetailCache: [String: CachedValue<PlaylistDetail>] = [:]
    private var artistDetailCache: [String: CachedValue<ArtistDetail>] = [:]
''',
    '''    private var albumDetailCache: [String: CachedValue<AlbumDetail>] = [:]
    private var playlistDetailCache: [String: CachedValue<PlaylistDetail>] = [:]
    private var artistDetailCache: [String: CachedValue<ArtistDetail>] = [:]
    private var albumDetailTasks: [String: Task<AlbumDetail, Error>] = [:]
    private var playlistDetailTasks: [String: Task<PlaylistDetail, Error>] = [:]
    private var artistDetailTasks: [String: Task<ArtistDetail, Error>] = [:]
''',
)
replace_once(
    app,
    '''                snapshot = try await client.home()
''',
    '''                snapshot = try await client.home(from: isHomeEmpty ? nil : home)
''',
)
sub_once(
    app,
    r'''    func album\(id: String\) async throws -> AlbumDetail \{.*?\n    \}\n\n(?=    func playlist)''',
    '''    func album(id: String) async throws -> AlbumDetail {
        if let cached = albumDetailCache[id], cached.expiresAt > Date() {
            return cached.value
        }
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        let generation = sessionGeneration
        let task: Task<AlbumDetail, Error>
        if let existing = albumDetailTasks[id] {
            task = existing
        } else {
            let created = Task { try await client.album(id: id) }
            albumDetailTasks[id] = created
            task = created
        }
        let value: AlbumDetail
        do {
            value = try await task.value
        } catch {
            if generation == sessionGeneration { albumDetailTasks[id] = nil }
            throw error
        }
        guard generation == sessionGeneration, self.client === client else {
            throw CancellationError()
        }
        albumDetailTasks[id] = nil
        albumDetailCache[id] = CachedValue(
            value: value,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        return value
    }

''',
    flags=re.DOTALL,
)
sub_once(
    app,
    r'''    func playlist\(id: String\) async throws -> PlaylistDetail \{.*?\n    \}\n\n(?=    func artist)''',
    '''    func playlist(id: String) async throws -> PlaylistDetail {
        if let cached = playlistDetailCache[id], cached.expiresAt > Date() {
            return cached.value
        }
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        let generation = sessionGeneration
        let task: Task<PlaylistDetail, Error>
        if let existing = playlistDetailTasks[id] {
            task = existing
        } else {
            let created = Task { try await client.playlist(id: id) }
            playlistDetailTasks[id] = created
            task = created
        }
        let value: PlaylistDetail
        do {
            value = try await task.value
        } catch {
            if generation == sessionGeneration { playlistDetailTasks[id] = nil }
            throw error
        }
        guard generation == sessionGeneration, self.client === client else {
            throw CancellationError()
        }
        playlistDetailTasks[id] = nil
        playlistDetailCache[id] = CachedValue(
            value: value,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        return value
    }

''',
    flags=re.DOTALL,
)
sub_once(
    app,
    r'''    func artist\(id: String, name: String\) async throws -> ArtistDetail \{.*?\n    \}\n\n(?=    func artworkURL)''',
    '''    func artist(id: String, name: String) async throws -> ArtistDetail {
        if let cached = artistDetailCache[id], cached.expiresAt > Date() {
            return cached.value
        }
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        let generation = sessionGeneration
        let task: Task<ArtistDetail, Error>
        if let existing = artistDetailTasks[id] {
            task = existing
        } else {
            let created = Task { try await client.artist(id: id, name: name) }
            artistDetailTasks[id] = created
            task = created
        }
        let value: ArtistDetail
        do {
            value = try await task.value
        } catch {
            if generation == sessionGeneration { artistDetailTasks[id] = nil }
            throw error
        }
        guard generation == sessionGeneration, self.client === client else {
            throw CancellationError()
        }
        artistDetailTasks[id] = nil
        artistDetailCache[id] = CachedValue(
            value: value,
            expiresAt: Date().addingTimeInterval(15 * 60)
        )
        return value
    }

''',
    flags=re.DOTALL,
)
replace_once(
    app,
    '''        albumDetailCache[album.id] = nil
        updateStarredAlbum(album, enabled: enabled)
''',
    '''        albumDetailCache[album.id] = nil
        albumDetailTasks.removeValue(forKey: album.id)?.cancel()
        updateStarredAlbum(album, enabled: enabled)
''',
)
replace_once(
    app,
    '''        artistDetailCache[artist.id] = nil
        updateStarredArtist(artist, enabled: enabled)
''',
    '''        artistDetailCache[artist.id] = nil
        artistDetailTasks.removeValue(forKey: artist.id)?.cancel()
        updateStarredArtist(artist, enabled: enabled)
''',
)
replace_once(
    app,
    '''    private func clearDetailCaches() {
        albumDetailCache.removeAll(keepingCapacity: false)
        playlistDetailCache.removeAll(keepingCapacity: false)
        artistDetailCache.removeAll(keepingCapacity: false)
    }
''',
    '''    private func clearDetailCaches() {
        albumDetailTasks.values.forEach { $0.cancel() }
        playlistDetailTasks.values.forEach { $0.cancel() }
        artistDetailTasks.values.forEach { $0.cancel() }
        albumDetailTasks.removeAll(keepingCapacity: false)
        playlistDetailTasks.removeAll(keepingCapacity: false)
        artistDetailTasks.removeAll(keepingCapacity: false)
        albumDetailCache.removeAll(keepingCapacity: false)
        playlistDetailCache.removeAll(keepingCapacity: false)
        artistDetailCache.removeAll(keepingCapacity: false)
    }
''',
)
replace_once(
    app,
    '''        searchTask?.cancel()
        refreshTask?.cancel()
        clearDetailCaches()
        sessionState = .connecting
''',
    '''        searchTask?.cancel()
        refreshTask?.cancel()
        refreshInFlight = false
        isRefreshing = false
        isSearching = false
        clearDetailCaches()
        sessionState = .connecting
''',
)
replace_once(
    app,
    '''            await ArtworkStore.shared.activate(accountScope: accountScope)
            guard generation == sessionGeneration else { return }

            self.client = client
''',
    '''            await ArtworkStore.shared.activate(accountScope: accountScope)
            guard generation == sessionGeneration else { return }
            if persist { try secureStore.save(credentials) }

            self.client = client
''',
)
replace_once(
    app,
    '''            )
            if persist { try secureStore.save(credentials) }
        } catch is CancellationError {
''',
    '''            )
        } catch is CancellationError {
''',
)
replace_once(
    app,
    '''        } catch {
            guard generation == sessionGeneration else { return }
            client = nil
            sessionState = .signedOut
            errorMessage = error.localizedDescription
            AudioEngine.shared.configure(client: nil)
        }
''',
    '''        } catch {
            guard generation == sessionGeneration else { return }
            client = nil
            home = .empty
            searchResults = .empty
            serverVersion = ""
            refreshInFlight = false
            isRefreshing = false
            isSearching = false
            sessionState = .signedOut
            errorMessage = error.localizedDescription
            AudioEngine.shared.configure(client: nil)
        }
''',
)


# HTTP decoder: remove a small allocation and reject non-progressing corrupt streams.
decoder = Path("BuFi/Core/HTTPContentDecoder.swift")
replace_once(
    decoder,
    '''        guard data.count >= zstandardMagic.count,
              Array(data.prefix(zstandardMagic.count)) == zstandardMagic else {
''',
    '''        guard data.count >= zstandardMagic.count,
              data.starts(with: zstandardMagic) else {
''',
)
replace_once(
    decoder,
    '''        var output = Data()
        var chunk = [UInt8](repeating: 0, count: outputCapacity)
''',
    '''        var output = Data()
        let estimatedCapacity = data.count > maximumDecodedBytes / 3
            ? maximumDecodedBytes
            : data.count * 3
        output.reserveCapacity(max(outputCapacity, estimatedCapacity))
        var chunk = [UInt8](repeating: 0, count: outputCapacity)
''',
)
replace_once(
    decoder,
    '''            while input.pos < input.size {
                var produced = 0
''',
    '''            while input.pos < input.size {
                let previousInputPosition = input.pos
                var produced = 0
''',
)
replace_once(
    decoder,
    '''                guard ZSTD_isError(result) == 0 else {
                    throw URLError(.cannotDecodeContentData)
                }
                if produced > 0 {
''',
    '''                guard ZSTD_isError(result) == 0 else {
                    throw URLError(.cannotDecodeContentData)
                }
                guard produced > 0 || input.pos > previousInputPosition || result == 0 else {
                    throw URLError(.cannotDecodeContentData)
                }
                if produced > 0 {
''',
)


# Artwork prefetch: avoid spending work twice on equivalent authenticated URLs.
artwork = Path("BuFi/Core/ArtworkStore.swift")
replace_once(
    artwork,
    '''        await withTaskGroup(of: Void.self) { group in
            for url in urls.prefix(2) {
''',
    '''        var seen = Set<String>()
        let candidates = urls.filter { url in
            seen.insert(ArtworkPipelineDelegate.normalizedCacheKey(for: url)).inserted
        }.prefix(2)
        await withTaskGroup(of: Void.self) { group in
            for url in candidates {
''',
)
