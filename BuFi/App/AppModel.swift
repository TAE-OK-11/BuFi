import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum SessionState: Equatable {
        case signedOut
        case connecting
        case ready
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
        searchTask?.cancel()
        refreshTask?.cancel()
        secureStore.delete()
        client = nil
        home = .empty
        searchResults = .empty
        refreshInFlight = false
        lastFullRefresh = .distantPast
        sessionState = .signedOut
        serverVersion = ""
        AudioEngine.shared.configure(client: nil)
    }

    func refresh(forceFull: Bool = false, silent: Bool = false) async {
        guard let client, !refreshInFlight else { return }
        refreshInFlight = true
        if !silent { isRefreshing = true }
        defer {
            refreshInFlight = false
            if !silent { isRefreshing = false }
        }

        do {
            let needsFullRefresh = forceFull ||
                Date().timeIntervalSince(lastFullRefresh) >= 300 ||
                isHomeEmpty
            let snapshot: HomeSnapshot
            if needsFullRefresh {
                snapshot = try await client.home()
                lastFullRefresh = Date()
            } else {
                snapshot = try await client.incrementalHome(from: home)
            }
            if homeChanged(snapshot) {
                home = snapshot
            }
        } catch {
            if !silent { errorMessage = error.localizedDescription }
        }
    }

    func search(_ rawQuery: String) {
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
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            do {
                let value = try await client.search(query)
                guard !Task.isCancelled else { return }
                self?.searchResults = value
                self?.isSearching = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.isSearching = false
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func searchImmediately(_ rawQuery: String) async {
        searchTask?.cancel()
        let query = rawQuery
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let client else {
            searchResults = .empty
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await client.search(query)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        isSearching = false
        searchResults = .empty
    }

    func album(id: String) async throws -> AlbumDetail {
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        return try await client.album(id: id)
    }

    func playlist(id: String) async throws -> PlaylistDetail {
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        return try await client.playlist(id: id)
    }

    func artist(id: String, name: String) async throws -> ArtistDetail {
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        return try await client.artist(id: id, name: name)
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
            updateStarredSong(song, enabled: !enabled)
            AudioEngine.shared.updateStarred(songID: song.id, enabled: !enabled)
            errorMessage = error.localizedDescription
        }
    }

    func toggleStar(album: Album) async {
        guard let client else { return }
        let enabled = !album.isStarred
        updateStarredAlbum(album, enabled: enabled)
        do {
            try await client.star(id: album.id, target: .album, enabled: enabled)
        } catch {
            updateStarredAlbum(album, enabled: !enabled)
            errorMessage = error.localizedDescription
        }
    }

    func toggleStar(artist: Artist) async {
        guard let client else { return }
        let enabled = !artist.isStarred
        updateStarredArtist(artist, enabled: enabled)
        do {
            try await client.star(id: artist.id, target: .artist, enabled: enabled)
        } catch {
            updateStarredArtist(artist, enabled: !enabled)
            errorMessage = error.localizedDescription
        }
    }

    func download(_ song: Song) async {
        guard let client else { return }
        do {
            _ = try await OfflineStore.shared.download(song: song, client: client)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateStarredSong(_ song: Song, enabled: Bool) {
        var updated = song
        updated.starred = enabled ? Self.starDateFormatter.string(from: Date()) : nil
        home.starredSongs.removeAll { $0.id == song.id }
        if enabled { home.starredSongs.insert(updated, at: 0) }
        home.randomSongs = home.randomSongs.map { $0.id == song.id ? updated : $0 }
    }

    private func updateStarredAlbum(_ album: Album, enabled: Bool) {
        var updated = album
        updated.starred = enabled ? Self.starDateFormatter.string(from: Date()) : nil
        home.starredAlbums.removeAll { $0.id == album.id }
        if enabled { home.starredAlbums.insert(updated, at: 0) }
        home.recentAlbums = home.recentAlbums.map { $0.id == album.id ? updated : $0 }
        home.randomAlbums = home.randomAlbums.map { $0.id == album.id ? updated : $0 }
    }

    private func updateStarredArtist(_ artist: Artist, enabled: Bool) {
        var updated = artist
        updated.starred = enabled ? Self.starDateFormatter.string(from: Date()) : nil
        home.starredArtists.removeAll { $0.id == artist.id }
        if enabled { home.starredArtists.insert(updated, at: 0) }
        home.artists = home.artists.map { $0.id == artist.id ? updated : $0 }
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
        sessionState = .connecting
        errorMessage = nil
        do {
            let client = try OpenSubsonicClient(credentials: credentials)
            let status = try await client.ping()
            let snapshot = try await client.home()
            let accountScope = AccountScope.identifier(for: credentials)
            await OfflineStore.shared.activate(accountScope: accountScope)
            await ArtworkStore.shared.activate(accountScope: accountScope)
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
            if persist { try secureStore.save(credentials) }
        } catch {
            client = nil
            sessionState = .signedOut
            errorMessage = error.localizedDescription
            AudioEngine.shared.configure(client: nil)
        }
    }
}
