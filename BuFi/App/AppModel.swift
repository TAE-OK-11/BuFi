import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum SessionState: Equatable {
        case signedOut
        case connecting
        case ready
    }

    private struct CachedValue<Value> {
        let value: Value
        let expiresAt: Date
    }

    private struct DetailRequest<Value> {
        let token: UUID
        let task: Task<Value, Error>
    }

    @Published private(set) var sessionState: SessionState = .signedOut
    @Published private(set) var home = HomeSnapshot.empty
    @Published private(set) var searchResults = SearchResults.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSearching = false
    @Published private(set) var serverVersion = ""
    @Published var errorMessage: String?

    private(set) var client: OpenSubsonicClient?
    private let secureStore = SecureStore()
    private var searchTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var lastFullRefresh = Date.distantPast
    private var sessionGeneration = 0
    private var searchGeneration = 0
    private var homeRevision = 0
    private var albumDetailCache: [String: CachedValue<AlbumDetail>] = [:]
    private var playlistDetailCache: [String: CachedValue<PlaylistDetail>] = [:]
    private var artistDetailCache: [String: CachedValue<ArtistDetail>] = [:]
    private var albumDetailTasks: [String: DetailRequest<AlbumDetail>] = [:]
    private var playlistDetailTasks: [String: DetailRequest<PlaylistDetail>] = [:]
    private var artistDetailTasks: [String: DetailRequest<ArtistDetail>] = [:]
    private static let starDateFormatter = ISO8601DateFormatter()

    init() {
        if let credentials = secureStore.load() {
            Task { await connect(credentials, persist: false) }
        }
    }

    var allSongs: [Song] {
        var ids = Set<String>()
        return (home.randomSongs + home.starredSongs).filter { ids.insert($0.id).inserted }
    }

    func login(serverURL: String, username: String, password: String) async {
        let credentials = ServerCredentials(
            serverURL: serverURL,
            username: username,
            password: password
        )
        await connect(credentials, persist: true)
    }

    func logout() {
        sessionGeneration += 1
        searchGeneration += 1
        searchTask?.cancel()
        refreshTask?.cancel()
        secureStore.delete()
        client = nil
        home = .empty
        searchResults = .empty
        isSearching = false
        isRefreshing = false
        refreshInFlight = false
        lastFullRefresh = .distantPast
        clearDetailCaches()
        sessionState = .signedOut
        serverVersion = ""
        AudioEngine.shared.configure(client: nil)
    }

    func refresh(forceFull: Bool = false, silent: Bool = false) async {
        guard let client, !refreshInFlight else { return }
        let generation = sessionGeneration
        let revision = homeRevision
        let previousHome = home
        refreshInFlight = true
        if !silent { isRefreshing = true }
        defer {
            if generation == sessionGeneration {
                refreshInFlight = false
                if !silent { isRefreshing = false }
            }
        }

        do {
            let needsFullRefresh = forceFull ||
                Date().timeIntervalSince(lastFullRefresh) >= 300 ||
                isHomeEmpty
            let snapshot: HomeSnapshot
            if needsFullRefresh {
                snapshot = try await client.home(from: isHomeEmpty ? nil : previousHome)
            } else {
                snapshot = try await client.incrementalHome(from: previousHome)
            }
            guard generation == sessionGeneration, self.client === client else { return }
            guard revision == homeRevision else { return }
            if needsFullRefresh { lastFullRefresh = Date() }
            if homeChanged(snapshot) { home = snapshot }
        } catch is CancellationError {
            return
        } catch {
            guard generation == sessionGeneration else { return }
            if !silent { errorMessage = error.localizedDescription }
        }
    }

    func search(_ rawQuery: String) {
        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()
        let query = rawQuery
            .precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let client else {
            searchResults = .empty
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(260))
                try Task.checkCancellation()
                let value = try await client.search(query)
                try Task.checkCancellation()
                guard let self, generation == self.searchGeneration, self.client === client else { return }
                self.searchResults = value
                self.isSearching = false
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.searchGeneration, self.client === client else { return }
                self.isSearching = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func searchImmediately(_ rawQuery: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()
        let query = rawQuery
            .precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let client else {
            searchResults = .empty
            isSearching = false
            return
        }
        isSearching = true
        do {
            let value = try await client.search(query)
            guard generation == searchGeneration, self.client === client else { return }
            searchResults = value
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            guard generation == searchGeneration, self.client === client else { return }
            isSearching = false
            errorMessage = error.localizedDescription
        }
    }

    func clearSearch() {
        searchGeneration += 1
        searchTask?.cancel()
        isSearching = false
        searchResults = .empty
    }

    func album(id: String) async throws -> AlbumDetail {
        if let cached = albumDetailCache[id], cached.expiresAt > Date() {
            return cached.value
        }
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        let generation = sessionGeneration
        let request: DetailRequest<AlbumDetail>
        if let existing = albumDetailTasks[id] {
            request = existing
        } else {
            let created = DetailRequest(
                token: UUID(),
                task: Task { try await client.album(id: id) }
            )
            albumDetailTasks[id] = created
            request = created
        }
        let value: AlbumDetail
        do {
            value = try await request.task.value
        } catch {
            if generation == sessionGeneration,
               albumDetailTasks[id]?.token == request.token {
                albumDetailTasks[id] = nil
            }
            throw error
        }
        guard generation == sessionGeneration, self.client === client else {
            throw CancellationError()
        }
        if albumDetailTasks[id]?.token == request.token {
            albumDetailTasks[id] = nil
        }
        albumDetailCache[id] = CachedValue(
            value: value,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        return value
    }

    func playlist(id: String) async throws -> PlaylistDetail {
        if let cached = playlistDetailCache[id], cached.expiresAt > Date() {
            return cached.value
        }
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        let generation = sessionGeneration
        let request: DetailRequest<PlaylistDetail>
        if let existing = playlistDetailTasks[id] {
            request = existing
        } else {
            let created = DetailRequest(
                token: UUID(),
                task: Task { try await client.playlist(id: id) }
            )
            playlistDetailTasks[id] = created
            request = created
        }
        let value: PlaylistDetail
        do {
            value = try await request.task.value
        } catch {
            if generation == sessionGeneration,
               playlistDetailTasks[id]?.token == request.token {
                playlistDetailTasks[id] = nil
            }
            throw error
        }
        guard generation == sessionGeneration, self.client === client else {
            throw CancellationError()
        }
        if playlistDetailTasks[id]?.token == request.token {
            playlistDetailTasks[id] = nil
        }
        playlistDetailCache[id] = CachedValue(
            value: value,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
        return value
    }

    func artist(id: String, name: String) async throws -> ArtistDetail {
        if let cached = artistDetailCache[id], cached.expiresAt > Date() {
            return cached.value
        }
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        let generation = sessionGeneration
        let request: DetailRequest<ArtistDetail>
        if let existing = artistDetailTasks[id] {
            request = existing
        } else {
            let created = DetailRequest(
                token: UUID(),
                task: Task { try await client.artist(id: id, name: name) }
            )
            artistDetailTasks[id] = created
            request = created
        }
        let value: ArtistDetail
        do {
            value = try await request.task.value
        } catch {
            if generation == sessionGeneration,
               artistDetailTasks[id]?.token == request.token {
                artistDetailTasks[id] = nil
            }
            throw error
        }
        guard generation == sessionGeneration, self.client === client else {
            throw CancellationError()
        }
        if artistDetailTasks[id]?.token == request.token {
            artistDetailTasks[id] = nil
        }
        artistDetailCache[id] = CachedValue(
            value: value,
            expiresAt: Date().addingTimeInterval(15 * 60)
        )
        return value
    }

    func artworkURL(id: String?, size: Int = 600) async -> URL? {
        guard let id, !id.isEmpty, let client else { return nil }
        return try? await client.coverURL(id: id, size: size)
    }

    func toggleStar(song: Song) async {
        guard let client else { return }
        let enabled = !song.isStarred
        updateStarredSong(song, enabled: enabled)
        AudioEngine.shared.updateStarred(songID: song.id, enabled: enabled)
        do {
            try await client.star(id: song.id, target: .song, enabled: enabled)
        } catch {
            guard self.client === client else { return }
            updateStarredSong(song, enabled: !enabled)
            AudioEngine.shared.updateStarred(songID: song.id, enabled: !enabled)
            errorMessage = error.localizedDescription
        }
    }

    func toggleStar(album: Album) async {
        guard let client else { return }
        let enabled = !album.isStarred
        albumDetailCache[album.id] = nil
        albumDetailTasks.removeValue(forKey: album.id)?.task.cancel()
        updateStarredAlbum(album, enabled: enabled)
        do {
            try await client.star(id: album.id, target: .album, enabled: enabled)
        } catch {
            guard self.client === client else { return }
            updateStarredAlbum(album, enabled: !enabled)
            errorMessage = error.localizedDescription
        }
    }

    func toggleStar(artist: Artist) async {
        guard let client else { return }
        let enabled = !artist.isStarred
        artistDetailCache[artist.id] = nil
        artistDetailTasks.removeValue(forKey: artist.id)?.task.cancel()
        updateStarredArtist(artist, enabled: enabled)
        do {
            try await client.star(id: artist.id, target: .artist, enabled: enabled)
        } catch {
            guard self.client === client else { return }
            updateStarredArtist(artist, enabled: !enabled)
            errorMessage = error.localizedDescription
        }
    }

    func download(_ song: Song) async {
        guard let client else { return }
        do {
            _ = try await OfflineStore.shared.download(song: song, client: client)
        } catch is CancellationError {
            return
        } catch {
            guard self.client === client else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func updateStarredSong(_ song: Song, enabled: Bool) {
        var updated = song
        updated.starred = enabled ? Self.starDateFormatter.string(from: Date()) : nil
        var snapshot = home
        snapshot.starredSongs.removeAll { $0.id == song.id }
        if enabled { snapshot.starredSongs.insert(updated, at: 0) }
        snapshot.randomSongs = snapshot.randomSongs.map { $0.id == song.id ? updated : $0 }
        homeRevision &+= 1
        home = snapshot
    }

    private func updateStarredAlbum(_ album: Album, enabled: Bool) {
        var updated = album
        updated.starred = enabled ? Self.starDateFormatter.string(from: Date()) : nil
        var snapshot = home
        snapshot.starredAlbums.removeAll { $0.id == album.id }
        if enabled { snapshot.starredAlbums.insert(updated, at: 0) }
        snapshot.recentAlbums = snapshot.recentAlbums.map { $0.id == album.id ? updated : $0 }
        snapshot.randomAlbums = snapshot.randomAlbums.map { $0.id == album.id ? updated : $0 }
        homeRevision &+= 1
        home = snapshot
    }

    private func updateStarredArtist(_ artist: Artist, enabled: Bool) {
        var updated = artist
        updated.starred = enabled ? Self.starDateFormatter.string(from: Date()) : nil
        var snapshot = home
        snapshot.starredArtists.removeAll { $0.id == artist.id }
        if enabled { snapshot.starredArtists.insert(updated, at: 0) }
        snapshot.artists = snapshot.artists.map { $0.id == artist.id ? updated : $0 }
        homeRevision &+= 1
        home = snapshot
    }

    private func clearDetailCaches() {
        albumDetailTasks.values.forEach { $0.task.cancel() }
        playlistDetailTasks.values.forEach { $0.task.cancel() }
        artistDetailTasks.values.forEach { $0.task.cancel() }
        albumDetailTasks.removeAll(keepingCapacity: false)
        playlistDetailTasks.removeAll(keepingCapacity: false)
        artistDetailTasks.removeAll(keepingCapacity: false)
        albumDetailCache.removeAll(keepingCapacity: false)
        playlistDetailCache.removeAll(keepingCapacity: false)
        artistDetailCache.removeAll(keepingCapacity: false)
    }

    private var isHomeEmpty: Bool {
        home.recentAlbums.isEmpty &&
            home.randomAlbums.isEmpty &&
            home.starredAlbums.isEmpty &&
            home.starredSongs.isEmpty &&
            home.starredArtists.isEmpty &&
            home.artists.isEmpty &&
            home.randomSongs.isEmpty &&
            home.playlists.isEmpty
    }

    private func homeChanged(_ next: HomeSnapshot) -> Bool {
        home.recentAlbums != next.recentAlbums ||
            home.randomAlbums != next.randomAlbums ||
            home.starredAlbums != next.starredAlbums ||
            home.starredSongs != next.starredSongs ||
            home.starredArtists != next.starredArtists ||
            home.artists != next.artists ||
            home.randomSongs != next.randomSongs ||
            home.playlists != next.playlists
    }

    private func connect(_ credentials: ServerCredentials, persist: Bool) async {
        sessionGeneration += 1
        let generation = sessionGeneration
        searchGeneration += 1
        searchTask?.cancel()
        refreshTask?.cancel()
        refreshInFlight = false
        isRefreshing = false
        isSearching = false
        clearDetailCaches()
        sessionState = .connecting
        errorMessage = nil
        do {
            let client = try OpenSubsonicClient(credentials: credentials)
            async let statusRequest = client.ping()
            async let snapshotRequest = client.home()
            let (status, snapshot) = try await (statusRequest, snapshotRequest)
            try Task.checkCancellation()
            guard generation == sessionGeneration else { return }

            let accountScope = AccountScope.identifier(for: credentials)
            await OfflineStore.shared.activate(accountScope: accountScope)
            await ArtworkStore.shared.activate(accountScope: accountScope)
            guard generation == sessionGeneration else { return }
            if persist { try secureStore.save(credentials) }

            self.client = client
            self.home = snapshot
            self.lastFullRefresh = Date()
            self.serverVersion = status.serverVersion ?? status.version ?? ""
            self.sessionState = .ready
            AudioEngine.shared.configure(
                client: client,
                songFavoriteChangeHandler: { [weak self] song, enabled in
                    self?.updateStarredSong(song, enabled: enabled)
                }
            )
        } catch is CancellationError {
            return
        } catch {
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
    }
}
