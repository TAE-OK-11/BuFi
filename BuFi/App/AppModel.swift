import Combine
import Foundation

@MainActor
final class AppSessionState: ObservableObject {
    @Published fileprivate(set) var phase: AppModel.SessionState = .signedOut
    @Published fileprivate(set) var connectedServerAddress = ""
    @Published fileprivate(set) var serverVersion = ""
    @Published fileprivate(set) var subsonicAPIVersion = ""
    @Published fileprivate(set) var hasLastFMAPIKey = false
    @Published fileprivate(set) var hasListenBrainzToken = false
    @Published fileprivate(set) var listenBrainzUsername = ""
    @Published var errorMessage: String?

    fileprivate func setPhase(_ value: AppModel.SessionState) {
        guard phase != value else { return }
        phase = value
    }

    fileprivate func setServerVersion(_ value: String) {
        guard serverVersion != value else { return }
        serverVersion = value
    }

    fileprivate func setConnectedServerAddress(_ value: String) {
        guard connectedServerAddress != value else { return }
        connectedServerAddress = value
    }

    fileprivate func setSubsonicAPIVersion(_ value: String) {
        guard subsonicAPIVersion != value else { return }
        subsonicAPIVersion = value
    }

    fileprivate func setHasLastFMAPIKey(_ value: Bool) {
        guard hasLastFMAPIKey != value else { return }
        hasLastFMAPIKey = value
    }

    fileprivate func setHasListenBrainzToken(_ value: Bool) {
        guard hasListenBrainzToken != value else { return }
        hasListenBrainzToken = value
    }

    fileprivate func setListenBrainzUsername(_ value: String) {
        guard listenBrainzUsername != value else { return }
        listenBrainzUsername = value
    }

    fileprivate func setErrorMessage(_ value: String?) {
        guard errorMessage != value else { return }
        errorMessage = value
    }
}

@MainActor
final class HomeLibraryState: ObservableObject {
    @Published fileprivate(set) var snapshot = HomeSnapshot.empty

    fileprivate func setSnapshot(_ value: HomeSnapshot) {
        guard snapshot != value else { return }
        snapshot = value
    }
}

@MainActor
final class SearchContentState: ObservableObject {
    @Published fileprivate(set) var results = SearchResults.empty
    @Published fileprivate(set) var isSearching = false

    fileprivate func setResults(_ value: SearchResults) {
        guard results != value else { return }
        results = value
    }

    fileprivate func setSearching(_ value: Bool) {
        guard isSearching != value else { return }
        isSearching = value
    }
}

@MainActor
final class FavoriteOverrideState: ObservableObject {
    @Published fileprivate(set) var values: [String: Bool] = [:]

    fileprivate func setValues(_ value: [String: Bool]) {
        guard values != value else { return }
        values = value
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum SessionState: Equatable {
        case signedOut
        case connecting
        case signingOut
        case ready
    }

    private enum BootstrapState {
        case idle
        case running
        case completed
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

    let session = AppSessionState()
    let library = HomeLibraryState()
    let searchContent = SearchContentState()
    let favorites = FavoriteOverrideState()

    private(set) var sessionState: SessionState {
        get { session.phase }
        set { session.setPhase(newValue) }
    }

    private(set) var home: HomeSnapshot {
        get { library.snapshot }
        set { library.setSnapshot(newValue) }
    }

    private(set) var searchResults: SearchResults {
        get { searchContent.results }
        set { searchContent.setResults(newValue) }
    }

    private(set) var isSearching: Bool {
        get { searchContent.isSearching }
        set { searchContent.setSearching(newValue) }
    }

    private(set) var serverVersion: String {
        get { session.serverVersion }
        set { session.setServerVersion(newValue) }
    }

    private(set) var connectedServerAddress: String {
        get { session.connectedServerAddress }
        set { session.setConnectedServerAddress(newValue) }
    }

    private(set) var subsonicAPIVersion: String {
        get { session.subsonicAPIVersion }
        set { session.setSubsonicAPIVersion(newValue) }
    }

    private(set) var hasLastFMAPIKey: Bool {
        get { session.hasLastFMAPIKey }
        set { session.setHasLastFMAPIKey(newValue) }
    }

    private(set) var hasListenBrainzToken: Bool {
        get { session.hasListenBrainzToken }
        set { session.setHasListenBrainzToken(newValue) }
    }

    private(set) var listenBrainzUsername: String {
        get { session.listenBrainzUsername }
        set { session.setListenBrainzUsername(newValue) }
    }

    var errorMessage: String? {
        get { session.errorMessage }
        set { session.setErrorMessage(newValue) }
    }

    private var favoriteOverrides: [String: Bool] {
        get { favorites.values }
        set { favorites.setValues(newValue) }
    }

    private(set) var client: OpenSubsonicClient?
    private var historySessionToken: AccountSessionToken?
    private let secureStore = SecureStore()
    private var searchTask: Task<Void, Never>?
    private var recommendationTask: Task<Void, Never>?
    private var recommendationGeneration: UInt64 = 0
    private var bootstrapState = BootstrapState.idle
    private var loginInFlight = false
    private var refreshInFlight = false
    private var lastFullRefresh = Date.distantPast
    private var lastHomeSnapshotSave = Date.distantPast
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
        sessionState = .connecting
        listenBrainzUsername = UserDefaults.standard.string(
            forKey: Self.listenBrainzUsernameKey
        ) ?? ""
    }

    /// Starts credential and session restoration after the first scene has
    /// mounted. Security.framework IPC and automatic-login networking are not
    /// part of `StateObject` construction or the pre-first-frame launch path.
    func bootstrapIfNeeded() async {
        guard bootstrapState == .idle else { return }
        bootstrapState = .running
        LaunchDiagnostics.mark("credential-bootstrap-starting")
        let stored = await secureStore.loadBootstrapState(
            lastFMAccount: Self.lastFMKeyAccount,
            listenBrainzAccount: Self.listenBrainzTokenAccount
        )
        guard !Task.isCancelled else {
            bootstrapState = .idle
            return
        }
        hasLastFMAPIKey = stored.hasLastFMKey
        hasListenBrainzToken = stored.hasListenBrainzToken
        LaunchDiagnostics.mark("credential-bootstrap-loaded")
        if let credentials = stored.credentials {
            await connect(credentials, persist: false)
        } else {
            sessionState = .signedOut
        }
        guard !Task.isCancelled else {
            bootstrapState = sessionState == .ready ? .completed : .idle
            return
        }
        bootstrapState = .completed
        LaunchDiagnostics.mark("application-bootstrap-ready")
    }


    func login(serverURL: String, username: String, password: String) async {
        guard !loginInFlight else { return }
        loginInFlight = true
        defer { loginInFlight = false }
        let credentials = ServerCredentials(
            serverURL: serverURL,
            username: username,
            password: password
        )
        await connect(credentials, persist: true)
    }

    func logout() async {
        sessionGeneration += 1
        let logoutGeneration = sessionGeneration
        let accountScope = client.map {
            AccountScope.identifier(for: $0.credentials)
        }
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        recommendationTask?.cancel()
        recommendationTask = nil
        clearFavoriteState()
        clearDetailCaches()
        await secureStore.delete()
        client = nil
        historySessionToken = nil
        publishHome(.empty)
        searchResults = .empty
        isSearching = false
        refreshInFlight = false
        lastFullRefresh = .distantPast
        lastHomeSnapshotSave = .distantPast
        connectedServerAddress = ""
        serverVersion = ""
        subsonicAPIVersion = ""
        errorMessage = nil
        sessionState = .signingOut

        // Stop playback before detaching the history scope so the final
        // completion/skip sample and queue deletion are durable.
        await AudioEngine.shared.shutdownForSessionEnd()
        guard sessionGeneration == logoutGeneration else { return }
        await OfflineStore.shared.flushPendingWrites()
        guard sessionGeneration == logoutGeneration else { return }
        await ListeningHistoryStore.shared.flushPendingWrites()
        guard sessionGeneration == logoutGeneration else { return }

        if let accountScope {
            await ArtworkStore.shared.clearAll()
            guard sessionGeneration == logoutGeneration else { return }
            await deactivateStores(accountScope: accountScope)
            guard sessionGeneration == logoutGeneration else { return }
            await HomeSnapshotStore.shared.remove(accountScope: accountScope)
            guard sessionGeneration == logoutGeneration else { return }
        }

        sessionState = .signedOut
    }

    func refresh(forceFull: Bool = false, silent: Bool = false) async {
        guard let client, !refreshInFlight else { return }
        let generation = sessionGeneration
        let revision = homeRevision
        let previousHome = home
        refreshInFlight = true
        defer {
            if generation == sessionGeneration {
                refreshInFlight = false
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
            let snapshot = await preparedHomeSnapshot(loadResult.snapshot)
            guard generation == sessionGeneration, self.client === client else { return }
            guard revision == homeRevision else { return }
            guard starRequests.isEmpty else { return }
            if needsFullRefresh { lastFullRefresh = Date() }
            reconcileFavoriteStates(
                in: snapshot,
                authoritative: loadResult.hasAuthoritativeStarredState
            )
            let resolvedSnapshot = applyingFavoriteOverrides(to: snapshot)
            let snapshotChanged = home != resolvedSnapshot
            if snapshotChanged { publishHome(resolvedSnapshot) }
            let now = Date()
            if snapshotChanged
                || now.timeIntervalSince(lastHomeSnapshotSave) >= 3_600 {
                let accountScope = AccountScope.identifier(for: client.credentials)
                await HomeSnapshotStore.shared.save(
                    resolvedSnapshot,
                    accountScope: accountScope
                )
                guard generation == sessionGeneration,
                      self.client === client else { return }
                lastHomeSnapshotSave = now
            }
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
                self.searchResults = .empty
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
            searchResults = .empty
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
        let generation = sessionGeneration
        let accountScope = client.accountScope
        let radioSongs = await client.radioQueue(seed: seed)
        guard generation == sessionGeneration,
              self.client === client,
              client.accountScope == accountScope else {
            return
        }
        let values = radioSongs.map(applyingFavoriteOverride)
        guard !values.isEmpty else {
            errorMessage = String(localized: "이 곡과 비슷한 음악을 서버에서 찾지 못했습니다.")
            return
        }
        AudioEngine.shared.play(values[0], in: values)
    }

    private func autoplayContinuation(
        after seed: Song,
        excluding excludedIDs: Set<String>,
        client: OpenSubsonicClient
    ) async -> [Song] {
        let serverValues = await client.autoplayQueue(
            seed: seed,
            excluding: excludedIDs
        )
        guard self.client === client else { return [] }
        let behavior = await ListeningHistoryStore.shared.recommendationSnapshot()
        guard self.client === client else { return [] }
        var snapshot = home
        snapshot.serverRecommendedSongs = Self.uniqueSongs(
            serverValues + snapshot.serverRecommendedSongs
        )
        let ranked = await Self.recommendations(
            snapshot: snapshot,
            weights: .current(),
            purpose: .autoplay,
            behavior: behavior,
            limit: 32
        )
        return Self.uniqueSongs(ranked + serverValues + home.randomSongs)
            .filter {
                !excludedIDs.contains($0.id) &&
                    $0.id != seed.id &&
                    $0.externalStreamURL == nil
            }
            .prefix(16)
            .map(applyingFavoriteOverride)
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

    func saveLastFMAPIKey(_ value: String) async {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            var snapshot = home
            snapshot.lastFMRecommendedSongs = []
            if key.isEmpty {
                await secureStore.deleteSecret(account: Self.lastFMKeyAccount)
                hasLastFMAPIKey = false
            } else {
                try await secureStore.saveSecret(key, account: Self.lastFMKeyAccount)
                hasLastFMAPIKey = true
            }
            publishHome(snapshot)
            if let client {
                scheduleExternalRecommendationRefresh(
                    client: client,
                    generation: sessionGeneration
                )
            } else {
                rebuildRecommendations()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveListenBrainz(username: String, token: String) async {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(name, forKey: Self.listenBrainzUsernameKey)
        listenBrainzUsername = name
        do {
            if secret.isEmpty {
                if name.isEmpty {
                    await secureStore.deleteSecret(account: Self.listenBrainzTokenAccount)
                    hasListenBrainzToken = false
                }
            } else {
                try await secureStore.saveSecret(
                    secret,
                    account: Self.listenBrainzTokenAccount
                )
                hasListenBrainzToken = true
            }
            var snapshot = home
            snapshot.listenBrainzRecommendedSongs = []
            publishHome(snapshot)
            if let client {
                scheduleExternalRecommendationRefresh(
                    client: client,
                    generation: sessionGeneration
                )
            } else {
                rebuildRecommendations()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeListenBrainz() async {
        await secureStore.deleteSecret(account: Self.listenBrainzTokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.listenBrainzUsernameKey)
        hasListenBrainzToken = false
        listenBrainzUsername = ""
        var snapshot = home
        snapshot.listenBrainzRecommendedSongs = []
        publishHome(snapshot)
        if let client {
            scheduleExternalRecommendationRefresh(
                client: client,
                generation: sessionGeneration
            )
        } else {
            recommendationTask?.cancel()
            rebuildRecommendations()
        }
    }

    func rebuildRecommendations() {
        recommendationTask?.cancel()
        recommendationGeneration &+= 1
        let requestGeneration = recommendationGeneration
        let session = sessionGeneration
        let source = home
        let weights = RecommendationWeights.current()
        recommendationTask = Task { [weak self] in
            guard let self else { return }
            let behavior = await ListeningHistoryStore.shared
                .recommendationSnapshot()
            guard !Task.isCancelled,
                  requestGeneration == self.recommendationGeneration,
                  session == self.sessionGeneration,
                  source == self.home else { return }
            var snapshot = source
            let sections = await Self.recommendationSections(
                snapshot: snapshot,
                weights: weights,
                behavior: behavior
            )
            let latestBehaviorRevision = await ListeningHistoryStore.shared
                .recommendationSnapshot().revision
            snapshot.recommendedSongs = sections.recommended
            snapshot.daylistSongs = sections.daylist
            guard !Task.isCancelled,
                  requestGeneration == self.recommendationGeneration,
                  session == self.sessionGeneration,
                  behavior.revision == latestBehaviorRevision,
                  source == self.home else { return }
            if snapshot != self.home {
                self.publishHome(snapshot)
            }
            self.recommendationTask = nil
        }
    }

    func handleMemoryPressure() {
        // In-flight detail requests belong to visible screens and are allowed
        // to finish. Only reusable snapshots are discarded.
        albumDetailCache.removeAll(keepingCapacity: false)
        playlistDetailCache.removeAll(keepingCapacity: false)
        artistDetailCache.removeAll(keepingCapacity: false)
    }

    func handleEnergyConstraints(
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) {
        guard lowPowerMode
                || thermalState == .serious
                || thermalState == .critical else {
            return
        }
        recommendationTask?.cancel()
        recommendationTask = nil
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
                songs: value.songs.map(applyingFavoriteOverride),
                album: value.album
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
                songs: value.songs.map(applyingFavoriteOverride),
                playlist: value.playlist
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
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty,
              let client else {
            return nil
        }
        let generation = sessionGeneration
        let url = try? await client.coverURL(id: id, size: size)
        guard generation == sessionGeneration, self.client === client else {
            return nil
        }
        return url
    }

    var artworkContextID: String {
        "\(sessionGeneration):\(client?.accountScope ?? "signed-out")"
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
        let historySession = historySessionToken
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
        if outcome.succeeded,
           generation == sessionGeneration,
           self.client === client,
           let historySession {
            await ListeningHistoryStore.shared.recordFavorite(
                song,
                enabled: enabled,
                session: historySession
            )
            return true
        }
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
        value.sonicRecommendedSongs = value.sonicRecommendedSongs.map(
            applyingFavoriteOverride
        )
        value.similarArtistSongs = value.similarArtistSongs.map(
            applyingFavoriteOverride
        )
        value.genreRecommendedSongs = value.genreRecommendedSongs.map(
            applyingFavoriteOverride
        )
        value.topArtistSongs = value.topArtistSongs.map(applyingFavoriteOverride)
        value.recentlyAddedSongs = value.recentlyAddedSongs.map(
            applyingFavoriteOverride
        )
        value.popularSongs = value.popularSongs.map(applyingFavoriteOverride)
        value.playlistAffinitySongs = value.playlistAffinitySongs.map(
            applyingFavoriteOverride
        )
        value.serverRecommendedSongs = value.serverRecommendedSongs.map(applyingFavoriteOverride)
        value.lastFMRecommendedSongs = value.lastFMRecommendedSongs.map(applyingFavoriteOverride)
        value.listenBrainzRecommendedSongs = value.listenBrainzRecommendedSongs.map(
            applyingFavoriteOverride
        )
        value.recommendedSongs = value.recommendedSongs.map(applyingFavoriteOverride)
        value.daylistSongs = value.daylistSongs.map(applyingFavoriteOverride)
        value.offlineBackupSongs = value.offlineBackupSongs.map(
            applyingFavoriteOverride
        )
        value.mostPlayedSongs = value.mostPlayedSongs.map(applyingFavoriteOverride)
        value.recommendedArtists = value.recommendedArtists.map(
            applyingFavoriteOverride
        )
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
            let visibleSongs = [
                home.starredSongs,
                home.randomSongs,
                home.recommendedSongs,
                home.sonicRecommendedSongs,
                home.similarArtistSongs,
                home.genreRecommendedSongs,
                home.topArtistSongs,
                home.recentlyAddedSongs,
                home.popularSongs,
                home.playlistAffinitySongs,
                home.serverRecommendedSongs,
                home.lastFMRecommendedSongs,
                home.listenBrainzRecommendedSongs,
                home.mostPlayedSongs,
                home.daylistSongs,
                home.offlineBackupSongs,
                snapshot.starredSongs,
                snapshot.randomSongs,
                snapshot.sonicRecommendedSongs,
                snapshot.similarArtistSongs,
                snapshot.genreRecommendedSongs,
                snapshot.topArtistSongs,
                snapshot.recentlyAddedSongs,
                snapshot.popularSongs,
                snapshot.playlistAffinitySongs,
                snapshot.serverRecommendedSongs,
                snapshot.lastFMRecommendedSongs,
                snapshot.listenBrainzRecommendedSongs,
                snapshot.recommendedSongs,
                snapshot.mostPlayedSongs,
                snapshot.daylistSongs,
                snapshot.offlineBackupSongs,
                searchResults.songs
            ].flatMap { $0 }
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
                home.starredArtists + home.artists + home.recommendedArtists +
                snapshot.starredArtists + snapshot.artists +
                snapshot.recommendedArtists +
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
        let starredValue = enabled
            ? Self.starDateFormatter.string(from: Date())
            : nil
        func updatingFavorite(_ value: Song) -> Song {
            guard value.id == song.id else { return value }
            var result = value
            result.starred = starredValue
            return result
        }
        var snapshot = home
        let freshestKnownSong = searchResults.songs.first { $0.id == song.id }
            ?? snapshot.randomSongs.first { $0.id == song.id }
            ?? snapshot.serverRecommendedSongs.first { $0.id == song.id }
            ?? snapshot.starredSongs.first { $0.id == song.id }
            ?? song
        let updated = updatingFavorite(freshestKnownSong)
        snapshot.starredSongs.removeAll { $0.id == song.id }
        if enabled { snapshot.starredSongs.insert(updated, at: 0) }
        snapshot.randomSongs = snapshot.randomSongs.map(updatingFavorite)
        snapshot.sonicRecommendedSongs = snapshot.sonicRecommendedSongs.map {
            updatingFavorite($0)
        }
        snapshot.similarArtistSongs = snapshot.similarArtistSongs.map {
            updatingFavorite($0)
        }
        snapshot.genreRecommendedSongs = snapshot.genreRecommendedSongs.map {
            updatingFavorite($0)
        }
        snapshot.topArtistSongs = snapshot.topArtistSongs.map {
            updatingFavorite($0)
        }
        snapshot.recentlyAddedSongs = snapshot.recentlyAddedSongs.map {
            updatingFavorite($0)
        }
        snapshot.popularSongs = snapshot.popularSongs.map {
            updatingFavorite($0)
        }
        snapshot.playlistAffinitySongs = snapshot.playlistAffinitySongs.map {
            updatingFavorite($0)
        }
        snapshot.recommendedSongs = snapshot.recommendedSongs.map {
            updatingFavorite($0)
        }
        snapshot.serverRecommendedSongs = snapshot.serverRecommendedSongs.map {
            updatingFavorite($0)
        }
        snapshot.lastFMRecommendedSongs = snapshot.lastFMRecommendedSongs.map {
            updatingFavorite($0)
        }
        snapshot.listenBrainzRecommendedSongs = snapshot.listenBrainzRecommendedSongs.map {
            updatingFavorite($0)
        }
        snapshot.daylistSongs = snapshot.daylistSongs.map {
            updatingFavorite($0)
        }
        snapshot.offlineBackupSongs = snapshot.offlineBackupSongs.map {
            updatingFavorite($0)
        }
        snapshot.mostPlayedSongs = snapshot.mostPlayedSongs.map {
            updatingFavorite($0)
        }
        publishHome(snapshot)

        if searchResults.songs.contains(where: { $0.id == song.id }) {
            var results = searchResults
            results.songs = results.songs.map(updatingFavorite)
            searchResults = results
        }

        for key in Array(albumDetailCache.keys) {
            guard let cached = albumDetailCache[key] else { continue }
            let songs = cached.value.songs.map(updatingFavorite)
            albumDetailCache[key] = CachedValue(
                value: AlbumDetail(songs: songs, album: cached.value.album),
                expiresAt: cached.expiresAt
            )
        }
        for key in Array(playlistDetailCache.keys) {
            guard let cached = playlistDetailCache[key] else { continue }
            let songs = cached.value.songs.map(updatingFavorite)
            playlistDetailCache[key] = CachedValue(
                value: PlaylistDetail(
                    songs: songs,
                    playlist: cached.value.playlist
                ),
                expiresAt: cached.expiresAt
            )
        }
        for key in Array(artistDetailCache.keys) {
            guard let cached = artistDetailCache[key] else { continue }
            var detail = cached.value
            detail.topSongs = detail.topSongs.map(updatingFavorite)
            artistDetailCache[key] = CachedValue(
                value: detail,
                expiresAt: cached.expiresAt
            )
        }
    }

    private func updateStarredAlbum(_ album: Album, enabled: Bool) {
        favoriteOverrides[starKey(id: album.id, target: .album)] = enabled
        let starredValue = enabled
            ? Self.starDateFormatter.string(from: Date())
            : nil
        func updatingFavorite(_ value: Album) -> Album {
            guard value.id == album.id else { return value }
            var result = value
            result.starred = starredValue
            return result
        }
        var snapshot = home
        let freshestKnownAlbum = searchResults.albums.first { $0.id == album.id }
            ?? snapshot.recentAlbums.first { $0.id == album.id }
            ?? snapshot.randomAlbums.first { $0.id == album.id }
            ?? snapshot.starredAlbums.first { $0.id == album.id }
            ?? album
        let updated = updatingFavorite(freshestKnownAlbum)
        snapshot.starredAlbums.removeAll { $0.id == album.id }
        if enabled { snapshot.starredAlbums.insert(updated, at: 0) }
        snapshot.recentAlbums = snapshot.recentAlbums.map(updatingFavorite)
        snapshot.recentlyPlayedAlbums = snapshot.recentlyPlayedAlbums.map {
            updatingFavorite($0)
        }
        snapshot.frequentAlbums = snapshot.frequentAlbums.map {
            updatingFavorite($0)
        }
        snapshot.randomAlbums = snapshot.randomAlbums.map(updatingFavorite)
        publishHome(snapshot)

        if searchResults.albums.contains(where: { $0.id == album.id }) {
            var results = searchResults
            results.albums = results.albums.map(updatingFavorite)
            searchResults = results
        }
        for key in Array(artistDetailCache.keys) {
            guard let cached = artistDetailCache[key] else { continue }
            var detail = cached.value
            detail.albums = detail.albums.map(updatingFavorite)
            artistDetailCache[key] = CachedValue(
                value: detail,
                expiresAt: cached.expiresAt
            )
        }
    }

    private func updateStarredArtist(_ artist: Artist, enabled: Bool) {
        favoriteOverrides[starKey(id: artist.id, target: .artist)] = enabled
        let starredValue = enabled
            ? Self.starDateFormatter.string(from: Date())
            : nil
        func updatingFavorite(_ value: Artist) -> Artist {
            guard value.id == artist.id else { return value }
            var result = value
            result.starred = starredValue
            return result
        }
        var snapshot = home
        let freshestKnownArtist = searchResults.artists.first { $0.id == artist.id }
            ?? snapshot.artists.first { $0.id == artist.id }
            ?? snapshot.starredArtists.first { $0.id == artist.id }
            ?? artist
        let updated = updatingFavorite(freshestKnownArtist)
        snapshot.starredArtists.removeAll { $0.id == artist.id }
        if enabled { snapshot.starredArtists.insert(updated, at: 0) }
        snapshot.artists = snapshot.artists.map(updatingFavorite)
        snapshot.recommendedArtists = snapshot.recommendedArtists.map {
            updatingFavorite($0)
        }
        publishHome(snapshot)

        if searchResults.artists.contains(where: { $0.id == artist.id }) {
            var results = searchResults
            results.artists = results.artists.map(updatingFavorite)
            searchResults = results
        }
        if let cached = artistDetailCache[artist.id] {
            var detail = cached.value
            detail.artist = updatingFavorite(detail.artist)
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

    private func publishHome(_ snapshot: HomeSnapshot) {
        guard snapshot != home else { return }
        homeRevision &+= 1
        home = snapshot
    }

    private func mergingListeningHistory(
        into snapshot: HomeSnapshot
    ) async -> HomeSnapshot {
        let history = await ListeningHistoryStore.shared.snapshot()
        let offlineSongIDs = await OfflineStore.shared.availableSongIDs()
        var value = snapshot
        if value.mostPlayedSongs.isEmpty {
            value.mostPlayedSongs = history.mostPlayedSongs
        }

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
        if value.recentlyPlayedAlbums.isEmpty {
            value.recentlyPlayedAlbums = localRecentAlbums
        }
        value.offlineBackupSongs = history.recentlyPlayedSongs.filter {
            offlineSongIDs.contains($0.id)
        }
        return value
    }

    private func preparedHomeSnapshot(
        _ snapshot: HomeSnapshot
    ) async -> HomeSnapshot {
        var value = await mergingListeningHistory(into: snapshot)
        let behavior = await ListeningHistoryStore.shared.recommendationSnapshot()
        let weights = RecommendationWeights.current()
        let sections = await Self.recommendationSections(
            snapshot: value,
            weights: weights,
            behavior: behavior
        )
        value.recommendedSongs = sections.recommended
        value.recommendedArtists = resolvedRecommendedArtists(in: value)
        value.daylistSongs = sections.daylist
        return value
    }

    nonisolated private static func recommendations(
        snapshot: HomeSnapshot,
        weights: RecommendationWeights,
        purpose: RecommendationPurpose = .home,
        behavior: RecommendationBehaviorSnapshot = .empty,
        limit: Int = 30
    ) async -> [Song] {
        let task = Task.detached(priority: .userInitiated) {
            RecommendationMixer.mix(
                snapshot: snapshot,
                weights: weights,
                purpose: purpose,
                behavior: behavior,
                limit: limit
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func recommendationSections(
        snapshot: HomeSnapshot,
        weights: RecommendationWeights,
        behavior: RecommendationBehaviorSnapshot
    ) async -> (recommended: [Song], daylist: [Song]) {
        let task = Task.detached(priority: .userInitiated) { () -> (recommended: [Song], daylist: [Song]) in
            let recommended = RecommendationMixer.mix(
                snapshot: snapshot,
                weights: weights,
                behavior: behavior
            )
            guard !Task.isCancelled else { return (recommended, []) }
            let daylist = RecommendationMixer.mix(
                snapshot: snapshot,
                weights: weights,
                purpose: .daylist,
                behavior: behavior,
                limit: 24
            )
            return (recommended, daylist)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func resolvedRecommendedArtists(
        in snapshot: HomeSnapshot
    ) -> [Artist] {
        var result = Self.uniqueArtists(snapshot.recommendedArtists)
        var ids = Set(result.map(\.id))
        let starredIDs = Set(snapshot.starredArtists.map(\.id))
        let artistsByName = Dictionary(
            snapshot.artists.map {
                (Self.normalizedName($0.name), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let signals =
            snapshot.recommendedSongs +
            snapshot.serverRecommendedSongs +
            snapshot.lastFMRecommendedSongs +
            snapshot.listenBrainzRecommendedSongs +
            snapshot.mostPlayedSongs +
            snapshot.starredSongs
        for song in signals {
            guard result.count < 12,
                  let artist = artistsByName[
                    Self.normalizedName(song.artist)
                  ],
                  !starredIDs.contains(artist.id),
                  ids.insert(artist.id).inserted else {
                continue
            }
            result.append(artist)
        }
        return Array(result.filter { !starredIDs.contains($0.id) }.prefix(12))
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueSongs(_ values: [Song]) -> [Song] {
        var ids = Set<String>()
        return values.filter { ids.insert($0.id).inserted }
    }

    private static func uniqueArtists(_ values: [Artist]) -> [Artist] {
        var ids = Set<String>()
        return values.filter { ids.insert($0.id).inserted }
    }

    private func enrichingExternalRecommendations(
        in snapshot: HomeSnapshot,
        client: OpenSubsonicClient
    ) async -> HomeSnapshot {
        let lastFMKey = await secureStore.loadSecret(account: Self.lastFMKeyAccount) ?? ""
        let listenBrainzToken = await secureStore.loadSecret(
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
        let knownSongs = Self.uniqueSongs(
            snapshot.serverRecommendedSongs +
            snapshot.recommendedSongs +
            snapshot.randomSongs +
            snapshot.starredSongs +
            snapshot.mostPlayedSongs
        )
        async let lastFMSongs = client.matchExternalRecommendations(
            candidates.0,
            library: knownSongs,
            limit: 8
        )
        async let listenBrainzSongs = client.matchExternalRecommendations(
            candidates.1,
            library: knownSongs,
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
        recommendationGeneration &+= 1
        let requestGeneration = recommendationGeneration
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
                  requestGeneration == self.recommendationGeneration,
                  generation == self.sessionGeneration,
                  self.client === client,
                  source == self.home else {
                return
            }
            let publicationSource = self.home
            var value = publicationSource
            if !enriched.lastFMRecommendedSongs.isEmpty {
                value.lastFMRecommendedSongs = enriched.lastFMRecommendedSongs
            }
            if !enriched.listenBrainzRecommendedSongs.isEmpty {
                value.listenBrainzRecommendedSongs =
                    enriched.listenBrainzRecommendedSongs
            }
            let behavior = await ListeningHistoryStore.shared
                .recommendationSnapshot()
            guard !Task.isCancelled,
                  requestGeneration == self.recommendationGeneration,
                  generation == self.sessionGeneration,
                  self.client === client,
                  publicationSource == self.home else {
                return
            }
            let weights = RecommendationWeights.current()
            let sections = await Self.recommendationSections(
                snapshot: value,
                weights: weights,
                behavior: behavior
            )
            let latestBehaviorRevision = await ListeningHistoryStore.shared
                .recommendationSnapshot().revision
            value.recommendedSongs = sections.recommended
            value.recommendedArtists = self.resolvedRecommendedArtists(
                in: value
            )
            value.daylistSongs = sections.daylist
            guard !Task.isCancelled,
                  requestGeneration == self.recommendationGeneration,
                  generation == self.sessionGeneration,
                  self.client === client,
                  behavior.revision == latestBehaviorRevision,
                  publicationSource == self.home else {
                return
            }
            value = self.applyingFavoriteOverrides(to: value)
            if value != self.home {
                self.publishHome(value)
                let accountScope = AccountScope.identifier(
                    for: client.credentials
                )
                await HomeSnapshotStore.shared.save(
                    value,
                    accountScope: accountScope
                )
            }
            if requestGeneration == self.recommendationGeneration {
                self.recommendationTask = nil
            }
        }
    }

    nonisolated static func serverDisplayAddress(from value: String) -> String {
        guard let components = URLComponents(string: value),
              let rawHost = components.host?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              !rawHost.isEmpty else {
            return ""
        }

        let lowercasedHost = rawHost.lowercased()
        let host = lowercasedHost.contains(":")
            && !lowercasedHost.hasPrefix("[")
            ? "[\(lowercasedHost)]"
            : lowercasedHost
        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.percentEncodedPath.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return path.isEmpty
            ? host + port
            : host + port + "/" + path
    }

    private static func sanitizedVersion(_ value: String?) -> String {
        guard let value else { return "" }
        let flattened = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(flattened.prefix(80))
    }

    private func connect(_ credentials: ServerCredentials, persist: Bool) async {
        sessionGeneration += 1
        let generation = sessionGeneration
        searchGeneration += 1
        searchTask?.cancel()
        recommendationTask?.cancel()
        let previousAccountScope = client.map {
            AccountScope.identifier(for: $0.credentials)
        }
        let isReplacingActiveSession = client != nil
        client = nil
        historySessionToken = nil
        if isReplacingActiveSession {
            await AudioEngine.shared.shutdownForSessionEnd()
            guard generation == sessionGeneration else { return }
        }
        if let previousAccountScope {
            await deactivateStores(accountScope: previousAccountScope)
        }
        guard generation == sessionGeneration else { return }
        publishHome(.empty)
        searchResults = .empty
        connectedServerAddress = ""
        serverVersion = ""
        subsonicAPIVersion = ""
        refreshInFlight = false
        lastHomeSnapshotSave = .distantPast
        isSearching = false
        clearFavoriteState()
        clearDetailCaches()
        sessionState = .connecting
        errorMessage = nil
        var activatedAccountScope: String?
        do {
            let client = try OpenSubsonicClient(credentials: credentials)
            let accountScope = AccountScope.identifier(for: client.credentials)
            async let statusRequest = client.ping()
            async let cachedSnapshotRequest = HomeSnapshotStore.shared.load(
                accountScope: accountScope
            )
            let status = try await statusRequest
            let cachedSnapshot = await cachedSnapshotRequest
            try Task.checkCancellation()
            guard generation == sessionGeneration else { return }

            activatedAccountScope = accountScope
            await OfflineStore.shared.activate(accountScope: accountScope)
            guard generation == sessionGeneration else {
                await deactivateStores(accountScope: accountScope)
                return
            }
            await ArtworkStore.shared.activate(accountScope: accountScope)
            guard generation == sessionGeneration else {
                await deactivateStores(accountScope: accountScope)
                return
            }
            guard let historySession = await ListeningHistoryStore.shared.activate(
                accountScope: accountScope
            ), generation == sessionGeneration else {
                await deactivateStores(accountScope: accountScope)
                return
            }
            let snapshot = await preparedHomeSnapshot(
                cachedSnapshot ?? .empty
            )
            guard generation == sessionGeneration else {
                await deactivateStores(accountScope: accountScope)
                return
            }
            if persist { try await secureStore.save(client.credentials) }

            reconcileFavoriteStates(
                in: snapshot,
                authoritative: false
            )
            self.client = client
            self.historySessionToken = historySession
            self.publishHome(applyingFavoriteOverrides(to: snapshot))
            self.lastFullRefresh = .distantPast
            self.lastHomeSnapshotSave = .distantPast
            self.connectedServerAddress = Self.serverDisplayAddress(
                from: client.credentials.serverURL
            )
            self.serverVersion = Self.sanitizedVersion(status.serverVersion)
            self.subsonicAPIVersion = Self.sanitizedVersion(status.version)
            self.sessionState = .ready
            activatedAccountScope = nil
            AudioEngine.shared.configure(
                client: client,
                historySession: historySession,
                songFavoriteMutationHandler: { [weak self] song in
                    guard let self else { return false }
                    return await self.setStar(
                        song: song,
                        enabled: !self.isStarred(song)
                    )
                },
                autoplayContinuationProvider: { [weak self] seed, excludedIDs in
                    guard let self else { return [] }
                    return await self.autoplayContinuation(
                        after: seed,
                        excluding: excludedIDs,
                        client: client
                    )
                }
            )
            Task { [weak self] in
                await self?.refresh(
                    forceFull: true,
                    silent: cachedSnapshot != nil
                )
            }
        } catch is CancellationError {
            if let activatedAccountScope {
                await deactivateStores(accountScope: activatedAccountScope)
            }
            return
        } catch {
            if let activatedAccountScope {
                await deactivateStores(accountScope: activatedAccountScope)
            }
            guard generation == sessionGeneration else { return }
            client = nil
            historySessionToken = nil
            publishHome(.empty)
            searchResults = .empty
            connectedServerAddress = ""
            serverVersion = ""
            subsonicAPIVersion = ""
            refreshInFlight = false
            lastHomeSnapshotSave = .distantPast
            isSearching = false
            sessionState = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    private func deactivateStores(accountScope: String) async {
        await OfflineStore.shared.deactivate(accountScope: accountScope)
        await ArtworkStore.shared.deactivate(accountScope: accountScope)
        await ListeningHistoryStore.shared.deactivate(accountScope: accountScope)
    }
}
