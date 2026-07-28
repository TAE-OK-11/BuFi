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

    private struct DetailRequest<Value: Sendable> {
        let token: UUID
        let task: Task<Value, Error>
    }

    private struct StarRequest {
        let token: UUID
        let desiredState: Bool
        let task: Task<Void, Error>
    }

    private struct StarMutationOutcome {
        let succeeded: Bool
        let rollbackState: Bool?
    }

    @Published private(set) var sessionState: SessionState = .signedOut
    @Published private(set) var home = HomeSnapshot.empty
    @Published private(set) var searchResults = SearchResults.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSearching = false
    @Published private(set) var serverVersion = ""
    @Published private(set) var favoriteOverrides: [String: Bool] = [:]
    @Published private(set) var hasLastFMAPIKey = false
    @Published private(set) var hasListenBrainzToken = false
    @Published private(set) var listenBrainzUsername = ""
    @Published var errorMessage: String?

    private(set) var client: OpenSubsonicClient?
    private let secureStore = SecureStore()
    private var searchTask: Task<Void, Never>?
    private var recommendationTask: Task<Void, Never>?
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
    private var starRequests: [String: StarRequest] = [:]
    private var confirmedStarStates: [String: Bool] = [:]
    private var awaitingStarConfirmations: [String: Bool] = [:]
    private static let starDateFormatter = ISO8601DateFormatter()
    private static let albumDetailCacheLimit = 48
    private static let playlistDetailCacheLimit = 24
    private static let artistDetailCacheLimit = 32
    private static let lastFMKeyAccount = "lastfm-api-key"
    private static let listenBrainzTokenAccount = "listenbrainz-token"
    private static let listenBrainzUsernameKey = "listenbrainz-username"

    init() {
        hasLastFMAPIKey = secureStore.loadSecret(
            account: Self.lastFMKeyAccount
        )?.isEmpty == false
        hasListenBrainzToken = secureStore.loadSecret(
            account: Self.listenBrainzTokenAccount
        )?.isEmpty == false
        listenBrainzUsername = UserDefaults.standard.string(
            forKey: Self.listenBrainzUsernameKey
        ) ?? ""
        if let credentials = secureStore.load() {
            Task { await connect(credentials, persist: false) }
        }
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
        let accountScope = client.map {
            AccountScope.identifier(for: $0.credentials)
        }
        searchGeneration += 1
        searchTask?.cancel()
        recommendationTask?.cancel()
        clearFavoriteState()
        secureStore.delete()
        if let accountScope {
            Task {
                await ListeningHistoryStore.shared.deactivate(
                    accountScope: accountScope
                )
            }
        }
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
            let loadResult: HomeLoadResult
            if needsFullRefresh {
                loadResult = try await client.home(from: isHomeEmpty ? nil : previousHome)
            } else {
                loadResult = try await client.incrementalHome(from: previousHome)
            }
            var snapshot = await mergingListeningHistory(into: loadResult.snapshot)
            snapshot.recommendedSongs = RecommendationMixer.mix(
                snapshot: snapshot,
                weights: .current()
            )
            guard generation == sessionGeneration, self.client === client else { return }
            guard revision == homeRevision else { return }
            guard starRequests.isEmpty else { return }
            if needsFullRefresh { lastFullRefresh = Date() }
            reconcileFavoriteStates(
                in: snapshot,
                authoritative: loadResult.hasAuthoritativeStarredState
            )
            let resolvedSnapshot = applyingFavoriteOverrides(to: snapshot)
            if home != resolvedSnapshot { home = resolvedSnapshot }
            if needsFullRefresh {
                scheduleExternalRecommendationRefresh(
                    client: client,
                    generation: generation
                )
            }
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
        let query = Self.normalizedSearchQuery(rawQuery)
        guard !query.isEmpty, let client else {
            searchResults = .empty
            isSearching = false
            return
        }

        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(260))
                try Task.checkCancellation()
                guard let self, generation == self.searchGeneration, self.client === client else { return }
                self.isSearching = true
                let value = try await client.search(query)
                try Task.checkCancellation()
                guard generation == self.searchGeneration, self.client === client else { return }
                self.reconcileFavoriteStates(in: value)
                self.searchResults = self.applyingFavoriteOverrides(to: value)
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
        let query = Self.normalizedSearchQuery(rawQuery)
        guard !query.isEmpty, let client else {
            searchResults = .empty
            isSearching = false
            return
        }
        isSearching = true
        do {
            let value = try await client.search(query)
            guard generation == searchGeneration, self.client === client else { return }
            reconcileFavoriteStates(in: value)
            searchResults = applyingFavoriteOverrides(to: value)
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            guard generation == searchGeneration, self.client === client else { return }
            isSearching = false
            errorMessage = error.localizedDescription
        }
    }

    private static func normalizedSearchQuery(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearSearch() {
        searchGeneration += 1
        searchTask?.cancel()
        isSearching = false
        searchResults = .empty
    }

    func playRadio(from seed: Song) async {
        guard let client else { return }
        let values = await client.radioQueue(seed: seed)
        guard !values.isEmpty else {
            errorMessage = String(localized: "이 곡과 비슷한 음악을 서버에서 찾지 못했습니다.")
            return
        }
        AudioEngine.shared.play(values[0], in: values)
    }

    func playInternetRadio(_ station: InternetRadioStation) {
        guard let url = URL(string: station.streamUrl),
              url.scheme?.lowercased() == "https" else {
            errorMessage = String(localized: "HTTPS 인터넷 라디오만 안전하게 재생할 수 있습니다.")
            return
        }
        let song = station.playableSong
        AudioEngine.shared.play(song, in: [song])
    }

    func saveLastFMAPIKey(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if key.isEmpty {
                secureStore.deleteSecret(account: Self.lastFMKeyAccount)
                hasLastFMAPIKey = false
                var snapshot = home
                snapshot.lastFMRecommendedSongs = []
                snapshot.recommendedSongs = RecommendationMixer.mix(
                    snapshot: snapshot,
                    weights: .current()
                )
                home = snapshot
            } else {
                try secureStore.saveSecret(key, account: Self.lastFMKeyAccount)
                hasLastFMAPIKey = true
                var snapshot = home
                snapshot.lastFMRecommendedSongs = []
                snapshot.recommendedSongs = RecommendationMixer.mix(
                    snapshot: snapshot,
                    weights: .current()
                )
                home = snapshot
            }
            if let client {
                scheduleExternalRecommendationRefresh(
                    client: client,
                    generation: sessionGeneration
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveListenBrainz(username: String, token: String) {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(name, forKey: Self.listenBrainzUsernameKey)
        listenBrainzUsername = name
        do {
            if secret.isEmpty {
                if name.isEmpty {
                    secureStore.deleteSecret(account: Self.listenBrainzTokenAccount)
                    hasListenBrainzToken = false
                }
            } else {
                try secureStore.saveSecret(
                    secret,
                    account: Self.listenBrainzTokenAccount
                )
                hasListenBrainzToken = true
            }
            var snapshot = home
            snapshot.listenBrainzRecommendedSongs = []
            snapshot.recommendedSongs = RecommendationMixer.mix(
                snapshot: snapshot,
                weights: .current()
            )
            home = snapshot
            if let client {
                scheduleExternalRecommendationRefresh(
                    client: client,
                    generation: sessionGeneration
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeListenBrainz() {
        secureStore.deleteSecret(account: Self.listenBrainzTokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.listenBrainzUsernameKey)
        hasListenBrainzToken = false
        listenBrainzUsername = ""
        var snapshot = home
        snapshot.listenBrainzRecommendedSongs = []
        snapshot.recommendedSongs = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: .current()
        )
        home = snapshot
        if let client {
            scheduleExternalRecommendationRefresh(
                client: client,
                generation: sessionGeneration
            )
        } else {
            recommendationTask?.cancel()
        }
    }

    func rebuildRecommendations() {
        var snapshot = home
        snapshot.recommendedSongs = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: .current()
        )
        if snapshot != home { home = snapshot }
    }

    func album(id: String) async throws -> AlbumDetail {
        if let cached = Self.cachedDetail(id: id, cache: &albumDetailCache) {
            return cached
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
        if let activeRequest = albumDetailTasks[id],
           activeRequest.token != request.token {
            throw CancellationError()
        }
        let resolvedValue: AlbumDetail
        if albumDetailTasks[id]?.token == request.token {
            albumDetailTasks[id] = nil
            reconcileFavoriteStates(songs: value.songs)
            resolvedValue = AlbumDetail(
                songs: value.songs.map(applyingFavoriteOverride)
            )
            Self.storeDetail(
                resolvedValue,
                id: id,
                lifetime: 5 * 60,
                limit: Self.albumDetailCacheLimit,
                cache: &albumDetailCache
            )
        } else if let cached = albumDetailCache[id] {
            resolvedValue = cached.value
        } else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        return resolvedValue
    }

    func playlist(id: String) async throws -> PlaylistDetail {
        if let cached = Self.cachedDetail(id: id, cache: &playlistDetailCache) {
            return cached
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
        if let activeRequest = playlistDetailTasks[id],
           activeRequest.token != request.token {
            throw CancellationError()
        }
        let resolvedValue: PlaylistDetail
        if playlistDetailTasks[id]?.token == request.token {
            playlistDetailTasks[id] = nil
            reconcileFavoriteStates(songs: value.songs)
            resolvedValue = PlaylistDetail(
                songs: value.songs.map(applyingFavoriteOverride)
            )
            Self.storeDetail(
                resolvedValue,
                id: id,
                lifetime: 5 * 60,
                limit: Self.playlistDetailCacheLimit,
                cache: &playlistDetailCache
            )
        } else if let cached = playlistDetailCache[id] {
            resolvedValue = cached.value
        } else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        return resolvedValue
    }

    func artist(id: String, name: String) async throws -> ArtistDetail {
        if let cached = Self.cachedDetail(id: id, cache: &artistDetailCache) {
            return cached
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
        if let activeRequest = artistDetailTasks[id],
           activeRequest.token != request.token {
            throw CancellationError()
        }
        let resolvedValue: ArtistDetail
        if artistDetailTasks[id]?.token == request.token {
            artistDetailTasks[id] = nil
            reconcileFavoriteStates(
                songs: value.topSongs,
                albums: value.albums,
                artists: [value.artist]
            )
            resolvedValue = ArtistDetail(
                artist: applyingFavoriteOverride(value.artist),
                albums: value.albums.map(applyingFavoriteOverride),
                topSongs: value.topSongs.map(applyingFavoriteOverride),
                info: value.info
            )
            Self.storeDetail(
                resolvedValue,
                id: id,
                lifetime: 15 * 60,
                limit: Self.artistDetailCacheLimit,
                cache: &artistDetailCache
            )
        } else if let cached = artistDetailCache[id] {
            resolvedValue = cached.value
        } else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        return resolvedValue
    }

    func artworkURL(id: String?, size: Int = 600) async -> URL? {
        guard let id, !id.isEmpty, let client else { return nil }
        return try? await client.coverURL(id: id, size: size)
    }

    func isStarred(_ song: Song) -> Bool {
        favoriteOverrides[starKey(id: song.id, target: .song)] ?? song.isStarred
    }

    func isStarred(_ album: Album) -> Bool {
        favoriteOverrides[starKey(id: album.id, target: .album)] ?? album.isStarred
    }

    func isStarred(_ artist: Artist) -> Bool {
        favoriteOverrides[starKey(id: artist.id, target: .artist)] ?? artist.isStarred
    }

    func toggleStar(song: Song) async {
        _ = await setStar(song: song, enabled: !isStarred(song))
    }

    @discardableResult
    func setStar(song: Song, enabled: Bool) async -> Bool {
        guard let client else { return false }
        let generation = sessionGeneration
        let previous = isStarred(song)
        updateStarredSong(song, enabled: enabled)
        AudioEngine.shared.updateStarred(songID: song.id, enabled: enabled)
        let outcome = await performStarMutation(
            id: song.id,
            target: .song,
            enabled: enabled,
            client: client,
            generation: generation,
            initialState: previous
        )
        guard !outcome.succeeded,
              generation == sessionGeneration,
              self.client === client else {
            return outcome.succeeded
        }
        let rollbackState = outcome.rollbackState ?? previous
        updateStarredSong(song, enabled: rollbackState)
        AudioEngine.shared.updateStarred(songID: song.id, enabled: rollbackState)
        return false
    }

    func toggleStar(album: Album) async {
        _ = await setStar(album: album, enabled: !isStarred(album))
    }

    @discardableResult
    func setStar(album: Album, enabled: Bool) async -> Bool {
        guard let client else { return false }
        let generation = sessionGeneration
        let previous = isStarred(album)
        albumDetailCache[album.id] = nil
        albumDetailTasks.removeValue(forKey: album.id)?.task.cancel()
        updateStarredAlbum(album, enabled: enabled)
        let outcome = await performStarMutation(
            id: album.id,
            target: .album,
            enabled: enabled,
            client: client,
            generation: generation,
            initialState: previous
        )
        guard !outcome.succeeded,
              generation == sessionGeneration,
              self.client === client else {
            return outcome.succeeded
        }
        updateStarredAlbum(album, enabled: outcome.rollbackState ?? previous)
        return false
    }

    func toggleStar(artist: Artist) async {
        _ = await setStar(artist: artist, enabled: !isStarred(artist))
    }

    @discardableResult
    func setStar(artist: Artist, enabled: Bool) async -> Bool {
        guard let client else { return false }
        let generation = sessionGeneration
        let previous = isStarred(artist)
        artistDetailCache[artist.id] = nil
        artistDetailTasks.removeValue(forKey: artist.id)?.task.cancel()
        updateStarredArtist(artist, enabled: enabled)
        let outcome = await performStarMutation(
            id: artist.id,
            target: .artist,
            enabled: enabled,
            client: client,
            generation: generation,
            initialState: previous
        )
        guard !outcome.succeeded,
              generation == sessionGeneration,
              self.client === client else {
            return outcome.succeeded
        }
        updateStarredArtist(artist, enabled: outcome.rollbackState ?? previous)
        return false
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

    private func performStarMutation(
        id: String,
        target: OpenSubsonicClient.StarTarget,
        enabled: Bool,
        client: OpenSubsonicClient,
        generation: Int,
        initialState: Bool
    ) async -> StarMutationOutcome {
        let key = starKey(id: id, target: target)
        if starRequests[key] == nil {
            confirmedStarStates[key] = initialState
        }
        let previousTask = starRequests[key]?.task
        let token = UUID()
        let task = Task { [weak self] in
            if let previousTask {
                await withTaskCancellationHandler {
                    _ = try? await previousTask.value
                } onCancel: {
                    previousTask.cancel()
                }
            }
            try Task.checkCancellation()
            try await client.star(id: id, target: target, enabled: enabled)
            guard let self,
                  generation == self.sessionGeneration,
                  self.client === client else {
                return
            }
            self.confirmedStarStates[key] = enabled
            // Preserve every successful mutation until a later server payload
            // confirms it. This also covers A-success/B-failure chains.
            self.awaitingStarConfirmations[key] = enabled
        }
        starRequests[key] = StarRequest(
            token: token,
            desiredState: enabled,
            task: task
        )

        do {
            try await task.value
            if starRequests[key]?.token == token {
                starRequests[key] = nil
                confirmedStarStates[key] = nil
                awaitingStarConfirmations[key] = enabled
                // Invalidate a home request that may have started while this
                // mutation was pending and captured a stale starred list.
                homeRevision &+= 1
            }
            return StarMutationOutcome(succeeded: true, rollbackState: nil)
        } catch {
            let isLatestRequest = starRequests[key]?.token == token
            if isLatestRequest {
                starRequests[key] = nil
            }
            guard isLatestRequest,
                  generation == sessionGeneration,
                  self.client === client else {
                // A newer request owns the final state, or the account changed.
                // In both cases this older failure must not roll the UI back.
                return StarMutationOutcome(succeeded: true, rollbackState: nil)
            }
            let rollbackState = confirmedStarStates.removeValue(forKey: key) ?? initialState
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
            return StarMutationOutcome(
                succeeded: false,
                rollbackState: rollbackState
            )
        }
    }

    private func starKey(
        id: String,
        target: OpenSubsonicClient.StarTarget
    ) -> String {
        "\(starKeyPrefix(for: target)):\(id)"
    }

    private func starKeyPrefix(
        for target: OpenSubsonicClient.StarTarget
    ) -> String {
        switch target {
        case .song: "song"
        case .album: "album"
        case .artist: "artist"
        }
    }

    private func applyingFavoriteOverride(_ song: Song) -> Song {
        guard let enabled = favoriteOverrides[starKey(id: song.id, target: .song)] else {
            return song
        }
        var value = song
        value.starred = enabled ? (song.starred ?? Self.starDateFormatter.string(from: Date())) : nil
        return value
    }

    private func applyingFavoriteOverride(_ album: Album) -> Album {
        guard let enabled = favoriteOverrides[starKey(id: album.id, target: .album)] else {
            return album
        }
        var value = album
        value.starred = enabled ? (album.starred ?? Self.starDateFormatter.string(from: Date())) : nil
        return value
    }

    private func applyingFavoriteOverride(_ artist: Artist) -> Artist {
        guard let enabled = favoriteOverrides[starKey(id: artist.id, target: .artist)] else {
            return artist
        }
        var value = artist
        value.starred = enabled ? (artist.starred ?? Self.starDateFormatter.string(from: Date())) : nil
        return value
    }

    private func applyingFavoriteOverrides(to snapshot: HomeSnapshot) -> HomeSnapshot {
        var value = snapshot
        value.recentAlbums = value.recentAlbums.map(applyingFavoriteOverride)
        value.recentlyPlayedAlbums = value.recentlyPlayedAlbums.map(applyingFavoriteOverride)
        value.frequentAlbums = value.frequentAlbums.map(applyingFavoriteOverride)
        value.randomAlbums = value.randomAlbums.map(applyingFavoriteOverride)
        let resolvedAlbums = value.starredAlbums
            .map(applyingFavoriteOverride)
            .filter(\.isStarred)
        let resolvedAlbumIDs = Set(resolvedAlbums.map(\.id))
        let retainedAlbums = home.starredAlbums
            .map(applyingFavoriteOverride)
            .filter(\.isStarred)
            .filter {
                shouldRetainMissingFavorite(id: $0.id, target: .album)
            }
            .filter { !resolvedAlbumIDs.contains($0.id) }
        value.starredAlbums = resolvedAlbums + retainedAlbums

        let resolvedSongs = value.starredSongs
            .map(applyingFavoriteOverride)
            .filter(\.isStarred)
        let resolvedSongIDs = Set(resolvedSongs.map(\.id))
        let retainedSongs = home.starredSongs
            .map(applyingFavoriteOverride)
            .filter(\.isStarred)
            .filter {
                shouldRetainMissingFavorite(id: $0.id, target: .song)
            }
            .filter { !resolvedSongIDs.contains($0.id) }
        value.starredSongs = resolvedSongs + retainedSongs

        let resolvedArtists = value.starredArtists
            .map(applyingFavoriteOverride)
            .filter(\.isStarred)
        let resolvedArtistIDs = Set(resolvedArtists.map(\.id))
        let retainedArtists = home.starredArtists
            .map(applyingFavoriteOverride)
            .filter(\.isStarred)
            .filter {
                shouldRetainMissingFavorite(id: $0.id, target: .artist)
            }
            .filter { !resolvedArtistIDs.contains($0.id) }
        value.starredArtists = resolvedArtists + retainedArtists

        value.artists = value.artists.map(applyingFavoriteOverride)
        value.randomSongs = value.randomSongs.map(applyingFavoriteOverride)
        value.serverRecommendedSongs = value.serverRecommendedSongs.map(applyingFavoriteOverride)
        value.lastFMRecommendedSongs = value.lastFMRecommendedSongs.map(applyingFavoriteOverride)
        value.listenBrainzRecommendedSongs = value.listenBrainzRecommendedSongs.map(
            applyingFavoriteOverride
        )
        value.recommendedSongs = value.recommendedSongs.map(applyingFavoriteOverride)
        value.mostPlayedSongs = value.mostPlayedSongs.map(applyingFavoriteOverride)
        return value
    }

    private func shouldRetainMissingFavorite(
        id: String,
        target: OpenSubsonicClient.StarTarget
    ) -> Bool {
        let key = starKey(id: id, target: target)
        if let request = starRequests[key] {
            return request.desiredState
        }
        return awaitingStarConfirmations[key] == true
    }

    private func applyingFavoriteOverrides(to results: SearchResults) -> SearchResults {
        var value = results
        value.artists = value.artists.map(applyingFavoriteOverride)
        value.albums = value.albums.map(applyingFavoriteOverride)
        value.songs = value.songs.map(applyingFavoriteOverride)
        return value
    }

    private func reconcileFavoriteStates(
        in snapshot: HomeSnapshot,
        authoritative: Bool
    ) {
        guard authoritative else { return }

        reconcileFavoriteStates(
            songs: snapshot.starredSongs,
            albums: snapshot.starredAlbums,
            artists: snapshot.starredArtists,
            authoritative: true
        )

        // getStarred2 is the authoritative list. OpenSubsonicClient keeps the
        // previous arrays when that endpoint fails, so a genuinely missing
        // prior item represents a confirmed unstar rather than a partial read.
        let songIDs = Set(snapshot.starredSongs.map(\.id))
        let albumIDs = Set(snapshot.starredAlbums.map(\.id))
        let artistIDs = Set(snapshot.starredArtists.map(\.id))
        var states = favoriteOverrides
        reconcileMissingFavorites(
            knownStarredIDs(for: .song, including: snapshot),
            presentIDs: songIDs,
            target: .song,
            states: &states
        )
        reconcileMissingFavorites(
            knownStarredIDs(for: .album, including: snapshot),
            presentIDs: albumIDs,
            target: .album,
            states: &states
        )
        reconcileMissingFavorites(
            knownStarredIDs(for: .artist, including: snapshot),
            presentIDs: artistIDs,
            target: .artist,
            states: &states
        )
        if states != favoriteOverrides {
            favoriteOverrides = states
        }

        var playbackStates: [String: Bool] = [:]
        let playbackSongs = AudioEngine.shared.queue +
            (AudioEngine.shared.currentSong.map { [$0] } ?? [])
        for song in playbackSongs {
            if let enabled = states[starKey(id: song.id, target: .song)] {
                playbackStates[song.id] = enabled
            }
        }
        AudioEngine.shared.synchronizeStarredStates(playbackStates)
    }

    private func knownStarredIDs(
        for target: OpenSubsonicClient.StarTarget,
        including snapshot: HomeSnapshot
    ) -> [String] {
        var ids = Set<String>()
        switch target {
        case .song:
            let visibleSongs =
                home.starredSongs + home.randomSongs + home.recommendedSongs +
                home.serverRecommendedSongs + home.lastFMRecommendedSongs +
                home.listenBrainzRecommendedSongs + home.mostPlayedSongs +
                snapshot.starredSongs + snapshot.randomSongs +
                snapshot.serverRecommendedSongs + snapshot.lastFMRecommendedSongs +
                snapshot.listenBrainzRecommendedSongs + snapshot.recommendedSongs +
                snapshot.mostPlayedSongs +
                searchResults.songs
            ids.formUnion(visibleSongs.lazy.filter(\.isStarred).map(\.id))
            ids.formUnion(
                AudioEngine.shared.queue.lazy.filter(\.isStarred).map(\.id)
            )
            if let song = AudioEngine.shared.currentSong, song.isStarred {
                ids.insert(song.id)
            }
            for cached in albumDetailCache.values {
                ids.formUnion(
                    cached.value.songs.lazy.filter(\.isStarred).map(\.id)
                )
            }
            for cached in playlistDetailCache.values {
                ids.formUnion(
                    cached.value.songs.lazy.filter(\.isStarred).map(\.id)
                )
            }
            for cached in artistDetailCache.values {
                ids.formUnion(
                    cached.value.topSongs.lazy.filter(\.isStarred).map(\.id)
                )
            }
        case .album:
            let visibleAlbums =
                home.starredAlbums + home.recentAlbums + home.recentlyPlayedAlbums +
                home.frequentAlbums + home.randomAlbums +
                snapshot.starredAlbums + snapshot.recentAlbums +
                snapshot.recentlyPlayedAlbums + snapshot.frequentAlbums +
                snapshot.randomAlbums +
                searchResults.albums
            ids.formUnion(visibleAlbums.lazy.filter(\.isStarred).map(\.id))
            for cached in artistDetailCache.values {
                ids.formUnion(
                    cached.value.albums.lazy.filter(\.isStarred).map(\.id)
                )
            }
        case .artist:
            let visibleArtists =
                home.starredArtists + home.artists +
                snapshot.starredArtists + snapshot.artists +
                searchResults.artists
            ids.formUnion(visibleArtists.lazy.filter(\.isStarred).map(\.id))
            for cached in artistDetailCache.values where cached.value.artist.isStarred {
                ids.insert(cached.value.artist.id)
            }
        }

        let prefix = starKeyPrefix(for: target) + ":"
        for (key, enabled) in favoriteOverrides
            where enabled && key.hasPrefix(prefix) {
            ids.insert(String(key.dropFirst(prefix.count)))
        }
        return Array(ids)
    }

    private func reconcileFavoriteStates(in results: SearchResults) {
        reconcileFavoriteStates(
            songs: results.songs,
            albums: results.albums,
            artists: results.artists
        )
    }

    private func reconcileFavoriteStates(
        songs: [Song] = [],
        albums: [Album] = [],
        artists: [Artist] = [],
        authoritative: Bool = false
    ) {
        var observed: [String: Bool] = [:]
        for song in songs {
            let key = starKey(id: song.id, target: .song)
            observed[key] = authoritative || (observed[key] ?? false) || song.isStarred
        }
        for album in albums {
            let key = starKey(id: album.id, target: .album)
            observed[key] = authoritative || (observed[key] ?? false) || album.isStarred
        }
        for artist in artists {
            let key = starKey(id: artist.id, target: .artist)
            observed[key] = authoritative || (observed[key] ?? false) || artist.isStarred
        }

        var states = favoriteOverrides
        for (key, serverState) in observed {
            guard starRequests[key] == nil else { continue }
            if let expected = awaitingStarConfirmations[key] {
                states[key] = expected
                if serverState == expected {
                    awaitingStarConfirmations[key] = nil
                }
            } else if authoritative {
                states[key] = serverState
            }
        }
        if states != favoriteOverrides {
            favoriteOverrides = states
        }
    }

    private func reconcileMissingFavorites(
        _ previousIDs: [String],
        presentIDs: Set<String>,
        target: OpenSubsonicClient.StarTarget,
        states: inout [String: Bool]
    ) {
        for id in previousIDs {
            let key = starKey(id: id, target: target)
            guard !presentIDs.contains(id), starRequests[key] == nil else {
                continue
            }
            if let expected = awaitingStarConfirmations[key] {
                states[key] = expected
                if !expected {
                    awaitingStarConfirmations[key] = nil
                }
            } else {
                states[key] = false
            }
        }

        let targetPrefix = starKeyPrefix(for: target) + ":"
        let confirmedUnstarKeys = awaitingStarConfirmations.compactMap { entry -> String? in
            let (key, expected) = entry
            guard !expected, key.hasPrefix(targetPrefix) else { return nil }
            return key
        }
        for key in confirmedUnstarKeys where starRequests[key] == nil {
            let id = String(key.dropFirst(targetPrefix.count))
            guard !presentIDs.contains(id) else { continue }
            states[key] = false
            awaitingStarConfirmations[key] = nil
        }
    }

    private func updateStarredSong(_ song: Song, enabled: Bool) {
        favoriteOverrides[starKey(id: song.id, target: .song)] = enabled
        var updated = song
        updated.starred = enabled ? Self.starDateFormatter.string(from: Date()) : nil
        var snapshot = home
        snapshot.starredSongs.removeAll { $0.id == song.id }
        if enabled { snapshot.starredSongs.insert(updated, at: 0) }
        snapshot.randomSongs = snapshot.randomSongs.map { $0.id == song.id ? updated : $0 }
        snapshot.recommendedSongs = snapshot.recommendedSongs.map {
            $0.id == song.id ? updated : $0
        }
        snapshot.serverRecommendedSongs = snapshot.serverRecommendedSongs.map {
            $0.id == song.id ? updated : $0
        }
        snapshot.lastFMRecommendedSongs = snapshot.lastFMRecommendedSongs.map {
            $0.id == song.id ? updated : $0
        }
        snapshot.listenBrainzRecommendedSongs = snapshot.listenBrainzRecommendedSongs.map {
            $0.id == song.id ? updated : $0
        }
        snapshot.mostPlayedSongs = snapshot.mostPlayedSongs.map {
            $0.id == song.id ? updated : $0
        }
        homeRevision &+= 1
        home = snapshot

        if searchResults.songs.contains(where: { $0.id == song.id }) {
            var results = searchResults
            results.songs = results.songs.map { $0.id == song.id ? updated : $0 }
            searchResults = results
        }

        for key in Array(albumDetailCache.keys) {
            guard let cached = albumDetailCache[key] else { continue }
            let songs = cached.value.songs.map { $0.id == song.id ? updated : $0 }
            albumDetailCache[key] = CachedValue(
                value: AlbumDetail(songs: songs),
                expiresAt: cached.expiresAt
            )
        }
        for key in Array(playlistDetailCache.keys) {
            guard let cached = playlistDetailCache[key] else { continue }
            let songs = cached.value.songs.map { $0.id == song.id ? updated : $0 }
            playlistDetailCache[key] = CachedValue(
                value: PlaylistDetail(songs: songs),
                expiresAt: cached.expiresAt
            )
        }
        for key in Array(artistDetailCache.keys) {
            guard let cached = artistDetailCache[key] else { continue }
            var detail = cached.value
            detail.topSongs = detail.topSongs.map { $0.id == song.id ? updated : $0 }
            artistDetailCache[key] = CachedValue(
                value: detail,
                expiresAt: cached.expiresAt
            )
        }
    }

    private func updateStarredAlbum(_ album: Album, enabled: Bool) {
        favoriteOverrides[starKey(id: album.id, target: .album)] = enabled
        var updated = album
        updated.starred = enabled ? Self.starDateFormatter.string(from: Date()) : nil
        var snapshot = home
        snapshot.starredAlbums.removeAll { $0.id == album.id }
        if enabled { snapshot.starredAlbums.insert(updated, at: 0) }
        snapshot.recentAlbums = snapshot.recentAlbums.map { $0.id == album.id ? updated : $0 }
        snapshot.recentlyPlayedAlbums = snapshot.recentlyPlayedAlbums.map {
            $0.id == album.id ? updated : $0
        }
        snapshot.frequentAlbums = snapshot.frequentAlbums.map {
            $0.id == album.id ? updated : $0
        }
        snapshot.randomAlbums = snapshot.randomAlbums.map { $0.id == album.id ? updated : $0 }
        homeRevision &+= 1
        home = snapshot

        if searchResults.albums.contains(where: { $0.id == album.id }) {
            var results = searchResults
            results.albums = results.albums.map { $0.id == album.id ? updated : $0 }
            searchResults = results
        }
        for key in Array(artistDetailCache.keys) {
            guard let cached = artistDetailCache[key] else { continue }
            var detail = cached.value
            detail.albums = detail.albums.map { $0.id == album.id ? updated : $0 }
            artistDetailCache[key] = CachedValue(
                value: detail,
                expiresAt: cached.expiresAt
            )
        }
    }

    private func updateStarredArtist(_ artist: Artist, enabled: Bool) {
        favoriteOverrides[starKey(id: artist.id, target: .artist)] = enabled
        var updated = artist
        updated.starred = enabled ? Self.starDateFormatter.string(from: Date()) : nil
        var snapshot = home
        snapshot.starredArtists.removeAll { $0.id == artist.id }
        if enabled { snapshot.starredArtists.insert(updated, at: 0) }
        snapshot.artists = snapshot.artists.map { $0.id == artist.id ? updated : $0 }
        homeRevision &+= 1
        home = snapshot

        if searchResults.artists.contains(where: { $0.id == artist.id }) {
            var results = searchResults
            results.artists = results.artists.map { $0.id == artist.id ? updated : $0 }
            searchResults = results
        }
        if let cached = artistDetailCache[artist.id] {
            var detail = cached.value
            detail.artist = updated
            artistDetailCache[artist.id] = CachedValue(
                value: detail,
                expiresAt: cached.expiresAt
            )
        }
    }

    private func clearFavoriteState() {
        starRequests.values.forEach { $0.task.cancel() }
        starRequests.removeAll(keepingCapacity: false)
        confirmedStarStates.removeAll(keepingCapacity: false)
        awaitingStarConfirmations.removeAll(keepingCapacity: false)
        favoriteOverrides.removeAll(keepingCapacity: false)
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

    private static func cachedDetail<Value>(
        id: String,
        cache: inout [String: CachedValue<Value>]
    ) -> Value? {
        guard let cached = cache[id] else { return nil }
        guard cached.expiresAt > Date() else {
            cache[id] = nil
            return nil
        }
        return cached.value
    }

    private static func storeDetail<Value>(
        _ value: Value,
        id: String,
        lifetime: TimeInterval,
        limit: Int,
        cache: inout [String: CachedValue<Value>]
    ) {
        let now = Date()
        cache = cache.filter { $0.value.expiresAt > now }
        cache[id] = CachedValue(
            value: value,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        while cache.count > limit,
              let oldest = cache.min(by: {
                  $0.value.expiresAt < $1.value.expiresAt
              }) {
            cache[oldest.key] = nil
        }
    }

    private var isHomeEmpty: Bool { home == .empty }

    private func mergingListeningHistory(
        into snapshot: HomeSnapshot
    ) async -> HomeSnapshot {
        let history = await ListeningHistoryStore.shared.snapshot()
        var value = snapshot
        value.mostPlayedSongs = Self.uniqueSongs(
            history.mostPlayedSongs + snapshot.mostPlayedSongs
        )

        let albums = snapshot.recentlyPlayedAlbums +
            snapshot.frequentAlbums +
            snapshot.recentAlbums +
            snapshot.randomAlbums +
            snapshot.starredAlbums
        var albumsByID: [String: Album] = [:]
        for album in albums where albumsByID[album.id] == nil {
            albumsByID[album.id] = album
        }
        var localRecentAlbums: [Album] = []
        var seenAlbumIDs = Set<String>()
        for song in history.recentlyPlayedSongs {
            guard let albumID = song.albumId,
                  seenAlbumIDs.insert(albumID).inserted else {
                continue
            }
            if let album = albumsByID[albumID] {
                localRecentAlbums.append(album)
            } else if !song.album.isEmpty {
                localRecentAlbums.append(
                    Album(
                        id: albumID,
                        name: song.album,
                        artist: song.artist,
                        coverArt: song.coverArt,
                        year: nil,
                        starred: nil
                    )
                )
                albumsByID[albumID] = localRecentAlbums.last
            }
        }
        value.recentlyPlayedAlbums = Self.uniqueAlbums(
            localRecentAlbums + snapshot.recentlyPlayedAlbums
        )
        return value
    }

    private static func uniqueSongs(_ values: [Song]) -> [Song] {
        var ids = Set<String>()
        return values.filter { ids.insert($0.id).inserted }
    }

    private static func uniqueAlbums(_ values: [Album]) -> [Album] {
        var ids = Set<String>()
        return values.filter { ids.insert($0.id).inserted }
    }

    private func enrichingExternalRecommendations(
        in snapshot: HomeSnapshot,
        client: OpenSubsonicClient
    ) async -> HomeSnapshot {
        let lastFMKey = secureStore.loadSecret(account: Self.lastFMKeyAccount) ?? ""
        let listenBrainzToken = secureStore.loadSecret(
            account: Self.listenBrainzTokenAccount
        )
        let seed = snapshot.mostPlayedSongs.first
            ?? snapshot.starredSongs.first
            ?? snapshot.randomSongs.first

        async let lastFMCandidates = Self.lastFMCandidates(
            seed: seed,
            apiKey: lastFMKey
        )
        async let listenBrainzCandidates =
            ExternalRecommendationClient.shared.listenBrainz(
                username: listenBrainzUsername,
                token: listenBrainzToken
            )

        let candidates = await (lastFMCandidates, listenBrainzCandidates)
        async let lastFMSongs = client.matchExternalRecommendations(
            candidates.0,
            limit: 8
        )
        async let listenBrainzSongs = client.matchExternalRecommendations(
            candidates.1,
            limit: 8
        )

        var value = snapshot
        let matches = await (lastFMSongs, listenBrainzSongs)
        if !matches.0.isEmpty {
            value.lastFMRecommendedSongs = matches.0
        }
        if !matches.1.isEmpty {
            value.listenBrainzRecommendedSongs = matches.1
        }
        return value
    }

    private nonisolated static func lastFMCandidates(
        seed: Song?,
        apiKey: String
    ) async -> [ExternalRecommendationCandidate] {
        guard let seed, !apiKey.isEmpty else { return [] }
        return await ExternalRecommendationClient.shared.lastFM(
            seed: seed,
            apiKey: apiKey
        )
    }

    private func scheduleExternalRecommendationRefresh(
        client: OpenSubsonicClient,
        generation: Int
    ) {
        recommendationTask?.cancel()
        guard hasLastFMAPIKey || !listenBrainzUsername.isEmpty,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState.rawValue <
                ProcessInfo.ThermalState.serious.rawValue else {
            return
        }
        let source = home
        recommendationTask = Task { [weak self] in
            guard let self else { return }
            let enriched = await self.enrichingExternalRecommendations(
                in: source,
                client: client
            )
            guard !Task.isCancelled,
                  generation == self.sessionGeneration,
                  self.client === client else {
                return
            }
            var value = self.home
            if !enriched.lastFMRecommendedSongs.isEmpty {
                value.lastFMRecommendedSongs = enriched.lastFMRecommendedSongs
            }
            if !enriched.listenBrainzRecommendedSongs.isEmpty {
                value.listenBrainzRecommendedSongs =
                    enriched.listenBrainzRecommendedSongs
            }
            value.recommendedSongs = RecommendationMixer.mix(
                snapshot: value,
                weights: .current()
            )
            value = self.applyingFavoriteOverrides(to: value)
            if value != self.home {
                self.home = value
            }
        }
    }

    private func connect(_ credentials: ServerCredentials, persist: Bool) async {
        sessionGeneration += 1
        let generation = sessionGeneration
        searchGeneration += 1
        searchTask?.cancel()
        recommendationTask?.cancel()
        let isReplacingActiveSession = client != nil
        client = nil
        if isReplacingActiveSession {
            AudioEngine.shared.configure(client: nil)
        }
        home = .empty
        searchResults = .empty
        serverVersion = ""
        refreshInFlight = false
        isRefreshing = false
        isSearching = false
        clearFavoriteState()
        clearDetailCaches()
        sessionState = .connecting
        errorMessage = nil
        do {
            let client = try OpenSubsonicClient(credentials: credentials)
            async let statusRequest = client.ping()
            async let homeRequest = client.home()
            let (status, loadResult) = try await (statusRequest, homeRequest)
            try Task.checkCancellation()
            guard generation == sessionGeneration else { return }

            let accountScope = AccountScope.identifier(for: credentials)
            await OfflineStore.shared.activate(accountScope: accountScope)
            await ArtworkStore.shared.activate(accountScope: accountScope)
            await ListeningHistoryStore.shared.activate(accountScope: accountScope)
            guard generation == sessionGeneration else { return }
            var snapshot = await mergingListeningHistory(into: loadResult.snapshot)
            snapshot.recommendedSongs = RecommendationMixer.mix(
                snapshot: snapshot,
                weights: .current()
            )
            guard generation == sessionGeneration else { return }
            if persist { try secureStore.save(credentials) }

            reconcileFavoriteStates(
                in: snapshot,
                authoritative: loadResult.hasAuthoritativeStarredState
            )
            self.client = client
            self.home = applyingFavoriteOverrides(to: snapshot)
            self.lastFullRefresh = Date()
            self.serverVersion = status.serverVersion ?? status.version ?? ""
            self.sessionState = .ready
            AudioEngine.shared.configure(
                client: client,
                songFavoriteMutationHandler: { [weak self] song in
                    guard let self else { return false }
                    return await self.setStar(
                        song: song,
                        enabled: !self.isStarred(song)
                    )
                }
            )
            scheduleExternalRecommendationRefresh(
                client: client,
                generation: generation
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
        }
    }
}
