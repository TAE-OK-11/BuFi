import Combine
import Foundation

struct ArtworkContextIdentity: Hashable, Sendable {
    let sessionGeneration: Int
    let accountScope: String?
}

enum FavoriteOverrideApplicationPolicy {
    static func canReuseSnapshot(
        hasOverrides: Bool,
        hasPendingMutations: Bool
    ) -> Bool {
        !hasOverrides && !hasPendingMutations
    }
}

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
    struct Presentation: Equatable, Sendable {
        let snapshot: HomeSnapshot
        let revision: HomeSnapshotRevision
    }

    @Published private(set) var presentation: Presentation

    var snapshot: HomeSnapshot { presentation.snapshot }
    var revision: HomeSnapshotRevision { presentation.revision }

    init() {
        presentation = Presentation(
            snapshot: .empty,
            revision: HomeSnapshotRevision()
        )
    }

    @discardableResult
    func setSnapshot(_ value: HomeSnapshot) -> Bool {
        guard snapshot != value else { return false }
        presentation = Presentation(
            snapshot: value,
            revision: revision.advanced()
        )
        return true
    }
}

@MainActor
final class SearchContentState: ObservableObject {
    struct Presentation: Equatable, Sendable {
        let query: String
        let results: SearchResults
        let isSearching: Bool
        let isLocalFallback: Bool

        static let empty = Presentation(
            query: "",
            results: .empty,
            isSearching: false,
            isLocalFallback: false
        )
    }

    @Published fileprivate(set) var presentation = Presentation.empty

    var results: SearchResults { presentation.results }
    var isSearching: Bool { presentation.isSearching }
    var query: String { presentation.query }
    var isLocalFallback: Bool { presentation.isLocalFallback }

    fileprivate func setResults(_ value: SearchResults) {
        publish(
            query: query,
            results: value,
            isSearching: isSearching,
            isLocalFallback: isLocalFallback
        )
    }

    fileprivate func setSearching(_ value: Bool) {
        publish(
            query: query,
            results: results,
            isSearching: value,
            isLocalFallback: isLocalFallback
        )
    }

    fileprivate func publish(
        query: String,
        results: SearchResults,
        isSearching: Bool,
        isLocalFallback: Bool = false
    ) {
        let next = Presentation(
            query: query,
            results: results,
            isSearching: isSearching,
            isLocalFallback: isLocalFallback && !results.isEmpty
        )
        guard presentation != next else { return }
        presentation = next
    }
}

@MainActor
final class FavoriteOverrideValueState: ObservableObject {
    @Published fileprivate(set) var value: Bool?

    fileprivate init(value: Bool?) {
        self.value = value
    }

    fileprivate func setValue(_ value: Bool?) {
        guard self.value != value else { return }
        self.value = value
    }
}

@MainActor
private final class WeakFavoriteOverrideValueState {
    weak var value: FavoriteOverrideValueState?

    init(_ value: FavoriteOverrideValueState) {
        self.value = value
    }
}

@MainActor
final class FavoriteOverrideState: ObservableObject {
    fileprivate(set) var values: [String: Bool] = [:]
    private var valueStates: [String: WeakFavoriteOverrideValueState] = [:]

    fileprivate func setValues(_ value: [String: Bool]) {
        guard values != value else { return }
        let previous = values
        values = value
        let changedKeys = Set(previous.keys).union(value.keys).filter {
            previous[$0] != value[$0]
        }
        for key in changedKeys {
            valueStates[key]?.value?.setValue(value[key])
        }
    }

    func setValue(_ value: Bool, for key: String) {
        guard values[key] != value else { return }
        values[key] = value
        valueStates[key]?.value?.setValue(value)
    }

    fileprivate func removeAll() {
        guard !values.isEmpty else { return }
        let previousKeys = Array(values.keys)
        values.removeAll(keepingCapacity: false)
        for key in previousKeys {
            valueStates[key]?.value?.setValue(nil)
        }
        valueStates = valueStates.filter { $0.value.value != nil }
    }

    func valueState(for key: String) -> FavoriteOverrideValueState {
        if let state = valueStates[key]?.value {
            return state
        }
        if valueStates.count >= 512 {
            valueStates = valueStates.filter { $0.value.value != nil }
        }
        let state = FavoriteOverrideValueState(value: values[key])
        valueStates[key] = WeakFavoriteOverrideValueState(state)
        return state
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
        let expiresAt: ContinuousClock.Instant
        let staleUntil: ContinuousClock.Instant
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

    private struct StoreActivationLeases: Sendable {
        var offline: AccountSessionToken?
        var artwork: AccountSessionToken?
        var history: AccountSessionToken?
        var catalog: AccountSessionToken?
    }

    let session = AppSessionState()
    let library = HomeLibraryState()
    let searchContent = SearchContentState()
    let favorites = FavoriteOverrideState()

    private(set) var sessionState: SessionState {
        get { session.phase }
        set { session.setPhase(newValue) }
    }

    var home: HomeSnapshot { library.snapshot }

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
    private var offlineSessionToken: AccountSessionToken?
    private var artworkSessionToken: AccountSessionToken?
    private var historySessionToken: AccountSessionToken?
    private var catalogSessionToken: AccountSessionToken?
    private let secureStore = SecureStore()
    private var searchTask: Task<Void, Never>?
    private var recommendationTask: Task<Void, Never>?
    private var automaticRefreshTask: Task<Void, Never>?
    private var automaticRefreshToken: UUID?
    private var recommendationGeneration: UInt64 = 0
    private var lastFMKeyOperationGeneration: UInt64 = 0
    private var listenBrainzOperationGeneration: UInt64 = 0
    private var bootstrapState = BootstrapState.idle
    private var loginInFlight = false
    private var refreshInFlight = false
    private let runtimeClock = ContinuousClock()
    private var lastFullRefresh: ContinuousClock.Instant?
    private var lastHomeSnapshotSave: ContinuousClock.Instant?
    private var lastExternalRecommendationIdentity:
        ExternalRecommendationRefreshIdentity?
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
        let normalizedURL: URL
        do {
            normalizedURL = try ServerURLNormalization.resolvedURL(from: serverURL)
        } catch {
            sessionState = .signedOut
            errorMessage = error.localizedDescription
            return
        }
        let credentials = ServerCredentials(
            serverURL: ServerURLNormalization.persistedServerURL(from: normalizedURL),
            username: username,
            password: password
        )
        await connect(credentials, persist: true)
    }

    func logout() async {
        sessionGeneration += 1
        let logoutGeneration = sessionGeneration
        lastFMKeyOperationGeneration &+= 1
        listenBrainzOperationGeneration &+= 1
        let accountScope = client.map {
            AccountScope.identifier(for: $0.credentials)
        }
        let leases = StoreActivationLeases(
            offline: offlineSessionToken,
            artwork: artworkSessionToken,
            history: historySessionToken,
            catalog: catalogSessionToken
        )
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        recommendationTask?.cancel()
        recommendationTask = nil
        cancelAutomaticRefresh()
        clearFavoriteState()
        clearDetailCaches()
        errorMessage = nil
        sessionState = .signingOut

        // Stop playback before detaching the history scope so the final
        // completion/skip sample and queue deletion are durable.
        await AudioEngine.shared.shutdownForSessionEnd()
        guard sessionGeneration == logoutGeneration else {
            await deactivateStores(leases)
            return
        }
        await OfflineStore.shared.flushPendingWrites()
        guard sessionGeneration == logoutGeneration else {
            await deactivateStores(leases)
            return
        }
        await ListeningHistoryStore.shared.flushPendingWrites()
        guard sessionGeneration == logoutGeneration else {
            await deactivateStores(leases)
            return
        }

        client = nil
        offlineSessionToken = nil
        artworkSessionToken = nil
        historySessionToken = nil
        catalogSessionToken = nil
        publishHome(.empty)
        searchResults = .empty
        isSearching = false
        refreshInFlight = false
        lastFullRefresh = nil
        lastHomeSnapshotSave = nil
        lastExternalRecommendationIdentity = nil
        connectedServerAddress = ""
        serverVersion = ""
        subsonicAPIVersion = ""

        if let artworkSession = leases.artwork {
            await ArtworkStore.shared.clearAll(session: artworkSession)
            guard sessionGeneration == logoutGeneration else {
                await deactivateStores(leases)
                return
            }
        }
        await deactivateStores(leases)
        guard sessionGeneration == logoutGeneration else { return }

        if let accountScope {
            await HomeSnapshotStore.shared.remove(accountScope: accountScope)
            guard sessionGeneration == logoutGeneration else { return }
        }

        do {
            try await secureStore.delete()
        } catch {
            guard sessionGeneration == logoutGeneration else { return }
            errorMessage = error.localizedDescription
        }
        guard sessionGeneration == logoutGeneration else { return }

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
            let refreshNow = runtimeClock.now
            let needsFullRefresh = forceFull
                || lastFullRefresh.map {
                    $0.duration(to: refreshNow) >= .seconds(300)
                } ?? true
                || isHomeEmpty
            let loadResult: HomeLoadResult
            if needsFullRefresh {
                loadResult = try await client.home(
                    from: isHomeEmpty ? nil : previousHome,
                    refreshStableCatalog: forceFull || isHomeEmpty
                )
            } else {
                loadResult = try await client.incrementalHome(from: previousHome)
            }
            let snapshot = await preparedHomeSnapshot(loadResult.snapshot)
            guard generation == sessionGeneration, self.client === client else { return }
            guard revision == homeRevision else { return }
            guard starRequests.isEmpty else { return }
            if needsFullRefresh { lastFullRefresh = runtimeClock.now }
            reconcileFavoriteStates(
                in: snapshot,
                authoritative: loadResult.hasAuthoritativeStarredState
            )
            let resolvedSnapshot = applyingFavoriteOverrides(to: snapshot)
            let snapshotChanged = publishHome(resolvedSnapshot)
            let saveNow = runtimeClock.now
            let snapshotSaveIsDue = lastHomeSnapshotSave.map {
                $0.duration(to: saveNow) >= .seconds(3_600)
            } ?? true
            if snapshotChanged || snapshotSaveIsDue {
                let accountScope = AccountScope.identifier(for: client.credentials)
                await HomeSnapshotStore.shared.save(
                    resolvedSnapshot,
                    accountScope: accountScope
                )
                guard generation == sessionGeneration,
                      self.client === client else { return }
                lastHomeSnapshotSave = saveNow
            }
            scheduleLibraryCatalogRefresh(snapshot: resolvedSnapshot)
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
        startSearch(rawQuery, debounce: .milliseconds(260))
    }

    func searchImmediately(_ rawQuery: String) async {
        guard let task = startSearch(rawQuery, debounce: nil) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult
    private func startSearch(
        _ rawQuery: String,
        debounce: Duration?
    ) -> Task<Void, Never>? {
        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()
        searchTask = nil
        let query = Self.normalizedSearchQuery(rawQuery)
        guard !query.isEmpty, let client else {
            searchContent.publish(
                query: query,
                results: .empty,
                isSearching: false
            )
            return nil
        }
        let retained = SearchPresentationPolicy.retainedResults(
            previousQuery: searchContent.query,
            previousResults: searchContent.results,
            nextQuery: query
        )
        searchContent.publish(
            query: query,
            results: retained,
            isSearching: true,
            isLocalFallback: searchContent.isLocalFallback && !retained.isEmpty
        )

        let task = Task { [weak self] in
            do {
                if let debounce {
                    try await Task.sleep(for: debounce)
                }
                try Task.checkCancellation()
                guard let self, generation == self.searchGeneration, self.client === client else { return }
                let value = try await client.search(query)
                try Task.checkCancellation()
                guard generation == self.searchGeneration, self.client === client else { return }
                self.reconcileFavoriteStates(in: value)
                self.searchContent.publish(
                    query: query,
                    results: self.applyingFavoriteOverrides(to: value),
                    isSearching: false
                )
                self.searchTask = nil
            } catch is CancellationError {
                guard let self,
                      generation == self.searchGeneration,
                      self.client === client else { return }
                self.searchContent.publish(
                    query: query,
                    results: self.searchContent.results,
                    isSearching: false,
                    isLocalFallback: self.searchContent.isLocalFallback
                )
                self.searchTask = nil
            } catch {
                guard let self, generation == self.searchGeneration, self.client === client else { return }
                let fallback = self.localSearchFallback(for: query)
                self.searchContent.publish(
                    query: query,
                    results: fallback.results,
                    isSearching: false,
                    isLocalFallback: fallback.isLocal
                )
                if fallback.results.isEmpty {
                    self.errorMessage = error.localizedDescription
                }
                self.searchTask = nil
            }
        }
        searchTask = task
        return task
    }

    private static func normalizedSearchQuery(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func localSearchFallback(
        for query: String
    ) -> (results: SearchResults, isLocal: Bool) {
        let retained = SearchPresentationPolicy.retainedResults(
            previousQuery: searchContent.query,
            previousResults: searchContent.results,
            nextQuery: query
        )
        let local = applyingFavoriteOverrides(
            to: LocalLibrarySearch.results(for: query, in: home)
        )
        if !local.isEmpty {
            return (local, true)
        }
        if !retained.isEmpty {
            return (retained, searchContent.isLocalFallback)
        }
        return (.empty, false)
    }

    func clearSearch() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        searchContent.presentation = .empty
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
            seed: seed,
            limit: 40
        )
        return Self.uniqueSongs(ranked + serverValues)
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
        lastFMKeyOperationGeneration &+= 1
        let operationGeneration = lastFMKeyOperationGeneration
        let generation = sessionGeneration
        do {
            if key.isEmpty {
                try await secureStore.deleteSecret(account: Self.lastFMKeyAccount)
            } else {
                try await secureStore.saveSecret(key, account: Self.lastFMKeyAccount)
            }
            guard !Task.isCancelled,
                  generation == sessionGeneration,
                  operationGeneration == lastFMKeyOperationGeneration else {
                return
            }
            hasLastFMAPIKey = !key.isEmpty
            var snapshot = home
            snapshot.lastFMRecommendedSongs = []
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
            guard generation == sessionGeneration,
                  operationGeneration == lastFMKeyOperationGeneration else {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func saveListenBrainz(username: String, token: String) async -> Bool {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        listenBrainzOperationGeneration &+= 1
        let operationGeneration = listenBrainzOperationGeneration
        let generation = sessionGeneration
        let retainedTokenState = hasListenBrainzToken
        do {
            if secret.isEmpty {
                if name.isEmpty {
                    try await secureStore.deleteSecret(
                        account: Self.listenBrainzTokenAccount
                    )
                }
            } else {
                try await secureStore.saveSecret(
                    secret,
                    account: Self.listenBrainzTokenAccount
                )
            }
            guard !Task.isCancelled,
                  generation == sessionGeneration,
                  operationGeneration == listenBrainzOperationGeneration else {
                return false
            }
            UserDefaults.standard.set(name, forKey: Self.listenBrainzUsernameKey)
            listenBrainzUsername = name
            hasListenBrainzToken = secret.isEmpty
                ? (name.isEmpty ? false : retainedTokenState)
                : true
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
            return true
        } catch {
            guard generation == sessionGeneration,
                  operationGeneration == listenBrainzOperationGeneration else {
                return false
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeListenBrainz() async -> Bool {
        listenBrainzOperationGeneration &+= 1
        let operationGeneration = listenBrainzOperationGeneration
        let generation = sessionGeneration
        do {
            try await secureStore.deleteSecret(
                account: Self.listenBrainzTokenAccount
            )
            guard !Task.isCancelled,
                  generation == sessionGeneration,
                  operationGeneration == listenBrainzOperationGeneration else {
                return false
            }
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
            return true
        } catch {
            guard generation == sessionGeneration,
                  operationGeneration == listenBrainzOperationGeneration else {
                return false
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func rebuildRecommendations() {
        recommendationTask?.cancel()
        recommendationGeneration &+= 1
        let requestGeneration = recommendationGeneration
        let session = sessionGeneration
        let source = home
        let sourceRevision = library.revision
        let weights = RecommendationWeights.current()
        recommendationTask = Task { [weak self] in
            guard let self else { return }
            let behavior = await ListeningHistoryStore.shared
                .recommendationSnapshot()
            guard !Task.isCancelled,
                  requestGeneration == self.recommendationGeneration,
                  session == self.sessionGeneration,
                  sourceRevision == self.library.revision else { return }
            var snapshot = source
            let sections = await Self.recommendationSections(
                snapshot: snapshot,
                snapshotRevision: sourceRevision,
                weights: weights,
                behavior: behavior
            )
            let latestBehaviorRevision = await ListeningHistoryStore.shared
                .recommendationRevision()
            snapshot.recommendedSongs = sections.recommended
            snapshot.daylistSongs = sections.daylist
            guard !Task.isCancelled,
                  requestGeneration == self.recommendationGeneration,
                  session == self.sessionGeneration,
                  behavior.revision == latestBehaviorRevision,
                  sourceRevision == self.library.revision else { return }
            if snapshot.recommendedSongs != source.recommendedSongs
                || snapshot.daylistSongs != source.daylistSongs {
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
            if TransientServiceFailurePolicy.allowsCachedFallback(error),
               let stale = Self.staleDetail(id: id, cache: &albumDetailCache) {
                return AlbumDetail(
                    songs: stale.songs.map(applyingFavoriteOverride),
                    album: stale.album.map(applyingFavoriteOverride)
                )
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
            if TransientServiceFailurePolicy.allowsCachedFallback(error),
               let stale = Self.staleDetail(id: id, cache: &playlistDetailCache) {
                return PlaylistDetail(
                    songs: stale.songs.map(applyingFavoriteOverride),
                    playlist: stale.playlist
                )
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
            if TransientServiceFailurePolicy.allowsCachedFallback(error),
               let stale = Self.staleDetail(id: id, cache: &artistDetailCache) {
                return ArtistDetail(
                    artist: applyingFavoriteOverride(stale.artist),
                    albums: stale.albums.map(applyingFavoriteOverride),
                    topSongs: stale.topSongs.map(applyingFavoriteOverride),
                    info: stale.info
                )
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

    var artworkContextID: ArtworkContextIdentity {
        ArtworkContextIdentity(
            sessionGeneration: sessionGeneration,
            accountScope: client?.accountScope
        )
    }

    func isStarred(_ song: Song) -> Bool {
        favoriteOverrides[starKey(id: song.id, target: .song)] ?? song.isStarred
    }

    func favoriteOverrideState(for song: Song) -> FavoriteOverrideValueState {
        favorites.valueState(for: starKey(id: song.id, target: .song))
    }

    func isStarred(_ album: Album) -> Bool {
        favoriteOverrides[starKey(id: album.id, target: .album)] ?? album.isStarred
    }

    func favoriteOverrideState(for album: Album) -> FavoriteOverrideValueState {
        favorites.valueState(for: starKey(id: album.id, target: .album))
    }

    func isStarred(_ artist: Artist) -> Bool {
        favoriteOverrides[starKey(id: artist.id, target: .artist)] ?? artist.isStarred
    }

    func favoriteOverrideState(for artist: Artist) -> FavoriteOverrideValueState {
        favorites.valueState(for: starKey(id: artist.id, target: .artist))
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
           self.client === client {
            if let historySession {
                Task {
                    await ListeningHistoryStore.shared.recordFavorite(
                        song,
                        enabled: enabled,
                        session: historySession
                    )
                }
            }
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
        // The common refresh path has no optimistic star mutations. Skip
        // walking every library artist and recommendation list in that case.
        guard !FavoriteOverrideApplicationPolicy.canReuseSnapshot(
            hasOverrides: !favoriteOverrides.isEmpty,
            hasPendingMutations: !starRequests.isEmpty
                || !awaitingStarConfirmations.isEmpty
        ) else {
            return snapshot
        }
        var value = snapshot
        value.mapSongs(applyingFavoriteOverride)
        value.mapAlbums(applyingFavoriteOverride)
        value.mapArtists(applyingFavoriteOverride)
        value.starredSongs = retainingOptimisticFavorites(
            incoming: value.starredSongs,
            previous: home.starredSongs,
            isStarred: \.isStarred,
            apply: applyingFavoriteOverride,
            target: .song
        )
        value.starredAlbums = retainingOptimisticFavorites(
            incoming: value.starredAlbums,
            previous: home.starredAlbums,
            isStarred: \.isStarred,
            apply: applyingFavoriteOverride,
            target: .album
        )
        value.starredArtists = retainingOptimisticFavorites(
            incoming: value.starredArtists,
            previous: home.starredArtists,
            isStarred: \.isStarred,
            apply: applyingFavoriteOverride,
            target: .artist
        )
        return value
    }

    private func retainingOptimisticFavorites<Item: Identifiable>(
        incoming: [Item],
        previous: [Item],
        isStarred: (Item) -> Bool,
        apply: (Item) -> Item,
        target: OpenSubsonicClient.StarTarget
    ) -> [Item] where Item.ID == String {
        let resolved = incoming.filter(isStarred)
        var ids = Set(resolved.map(\.id))
        let retained = previous.map(apply).filter { item in
            isStarred(item)
                && shouldRetainMissingFavorite(id: item.id, target: target)
                && ids.insert(item.id).inserted
        }
        return resolved + retained
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
        favorites.setValue(enabled, for: starKey(id: song.id, target: .song))
        let starredValue = enabled
            ? Self.starDateFormatter.string(from: Date())
            : nil
        var snapshot = home
        snapshot.mapSongs { item in
            guard item.id == song.id else { return item }
            var updated = item
            updated.starred = starredValue
            return updated
        }
        let freshestKnownSong = searchResults.songs.first { $0.id == song.id }
            ?? snapshot.randomSongs.first { $0.id == song.id }
            ?? snapshot.serverRecommendedSongs.first { $0.id == song.id }
            ?? snapshot.starredSongs.first { $0.id == song.id }
            ?? song
        var updated = freshestKnownSong
        updated.starred = starredValue
        snapshot.starredSongs.removeAll { $0.id == song.id }
        if enabled { snapshot.starredSongs.insert(updated, at: 0) }
        publishHome(snapshot)
        stampSearchSong(id: song.id, starred: starredValue)
    }

    private func updateStarredAlbum(_ album: Album, enabled: Bool) {
        favorites.setValue(enabled, for: starKey(id: album.id, target: .album))
        let starredValue = enabled
            ? Self.starDateFormatter.string(from: Date())
            : nil
        var snapshot = home
        snapshot.mapAlbums { item in
            guard item.id == album.id else { return item }
            var updated = item
            updated.starred = starredValue
            return updated
        }
        let freshestKnownAlbum = searchResults.albums.first { $0.id == album.id }
            ?? snapshot.recentAlbums.first { $0.id == album.id }
            ?? snapshot.randomAlbums.first { $0.id == album.id }
            ?? snapshot.starredAlbums.first { $0.id == album.id }
            ?? album
        var updated = freshestKnownAlbum
        updated.starred = starredValue
        snapshot.starredAlbums.removeAll { $0.id == album.id }
        if enabled { snapshot.starredAlbums.insert(updated, at: 0) }
        publishHome(snapshot)
        if searchResults.albums.contains(where: { $0.id == album.id }) {
            var results = searchResults
            results.albums = results.albums.map { item in
                guard item.id == album.id else { return item }
                var value = item
                value.starred = starredValue
                return value
            }
            searchResults = results
        }
    }

    private func updateStarredArtist(_ artist: Artist, enabled: Bool) {
        favorites.setValue(enabled, for: starKey(id: artist.id, target: .artist))
        let starredValue = enabled
            ? Self.starDateFormatter.string(from: Date())
            : nil
        var snapshot = home
        snapshot.mapArtists { item in
            guard item.id == artist.id else { return item }
            var updated = item
            updated.starred = starredValue
            return updated
        }
        let freshestKnownArtist = searchResults.artists.first { $0.id == artist.id }
            ?? snapshot.artists.first { $0.id == artist.id }
            ?? snapshot.starredArtists.first { $0.id == artist.id }
            ?? artist
        var updated = freshestKnownArtist
        updated.starred = starredValue
        snapshot.starredArtists.removeAll { $0.id == artist.id }
        if enabled { snapshot.starredArtists.insert(updated, at: 0) }
        publishHome(snapshot)
        if searchResults.artists.contains(where: { $0.id == artist.id }) {
            var results = searchResults
            results.artists = results.artists.map { item in
                guard item.id == artist.id else { return item }
                var value = item
                value.starred = starredValue
                return value
            }
            searchResults = results
        }
    }

    private func stampSearchSong(id: String, starred: String?) {
        guard searchResults.songs.contains(where: { $0.id == id }) else { return }
        var results = searchResults
        results.songs = results.songs.map { item in
            guard item.id == id else { return item }
            var value = item
            value.starred = starred
            return value
        }
        searchResults = results
    }

    private func clearFavoriteState() {
        starRequests.values.forEach { $0.task.cancel() }
        starRequests.removeAll(keepingCapacity: false)
        confirmedStarStates.removeAll(keepingCapacity: false)
        awaitingStarConfirmations.removeAll(keepingCapacity: false)
        favorites.removeAll()
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
        guard cached.expiresAt > ContinuousClock().now else {
            return nil
        }
        return cached.value
    }

    private static func staleDetail<Value>(
        id: String,
        cache: inout [String: CachedValue<Value>]
    ) -> Value? {
        guard let cached = cache[id] else { return nil }
        guard cached.staleUntil > ContinuousClock().now else {
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
        cache: inout [String: CachedValue<Value>],
        staleGrace: TimeInterval = 15 * 60
    ) {
        let clock = ContinuousClock()
        let now = clock.now
        cache[id] = CachedValue(
            value: value,
            expiresAt: now.advanced(by: .seconds(lifetime)),
            staleUntil: now.advanced(by: .seconds(lifetime + max(0, staleGrace)))
        )
        guard limit > 0 else {
            cache.removeAll(keepingCapacity: false)
            return
        }
        guard cache.count > limit else { return }

        let expiredKeys = cache.compactMap { key, cached in
            cached.expiresAt <= now ? key : nil
        }
        for key in expiredKeys {
            cache[key] = nil
        }
        while cache.count > limit,
              let oldest = cache.min(by: {
                  $0.value.expiresAt < $1.value.expiresAt
              }) {
            cache[oldest.key] = nil
        }
    }

    private var isHomeEmpty: Bool { home == .empty }

    @discardableResult
    private func publishHome(_ snapshot: HomeSnapshot) -> Bool {
        guard library.setSnapshot(snapshot) else { return false }
        homeRevision &+= 1
        return true
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
        snapshotRevision: HomeSnapshotRevision? = nil,
        weights: RecommendationWeights,
        purpose: RecommendationPurpose = .home,
        behavior: RecommendationBehaviorSnapshot = .empty,
        seed: Song? = nil,
        limit: Int = 40
    ) async -> [Song] {
        await RecommendationMixer.mixConcurrently(
            snapshot: snapshot,
            snapshotRevision: snapshotRevision,
            weights: weights,
            purpose: purpose,
            behavior: behavior,
            seed: seed,
            limit: limit
        )
    }

    nonisolated private static func recommendationSections(
        snapshot: HomeSnapshot,
        snapshotRevision: HomeSnapshotRevision? = nil,
        weights: RecommendationWeights,
        behavior: RecommendationBehaviorSnapshot
    ) async -> (recommended: [Song], daylist: [Song]) {
        await RecommendationMixer.sectionsConcurrently(
            snapshot: snapshot,
            snapshotRevision: snapshotRevision,
            weights: weights,
            behavior: behavior
        )
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
        MediaIdentity.uniqueSongs(values)
    }

    private static func uniqueArtists(_ values: [Artist]) -> [Artist] {
        MediaIdentity.uniqueArtists(values)
    }

    private func enrichingExternalRecommendations(
        in snapshot: HomeSnapshot
    ) async -> HomeSnapshot {
        let lastFMKey = await secureStore.loadSecret(account: Self.lastFMKeyAccount) ?? ""
        let listenBrainzToken = await secureStore.loadSecret(
            account: Self.listenBrainzTokenAccount
        )
        let recent = await ListeningHistoryStore.shared.recommendationSnapshot()
        let seed = recent.recentSongs.first
            ?? snapshot.starredSongs.first
            ?? snapshot.mostPlayedSongs.first
            ?? snapshot.randomSongs.first

        let knownSongs = Self.uniqueSongs(
            snapshot.serverRecommendedSongs +
            snapshot.recommendedSongs +
            snapshot.randomSongs +
            snapshot.starredSongs +
            snapshot.mostPlayedSongs
        )
        async let lastFMSongs = Self.resolvedLastFMSongs(
            seed: seed,
            apiKey: lastFMKey,
            knownSongs: knownSongs
        )
        async let listenBrainzSongs = Self.resolvedListenBrainzSongs(
            username: listenBrainzUsername,
            token: listenBrainzToken,
            knownSongs: knownSongs
        )

        var value = snapshot
        let matches = await (lastFMSongs, listenBrainzSongs)
        if !matches.0.isEmpty {
            value.lastFMRecommendedSongs = matches.0
        }
        if !matches.1.isEmpty {
            value.listenBrainzRecommendedSongs = Self.songsRankedNearSeed(
                matches.1,
                seed: seed
            )
        }
        return value
    }

    private nonisolated static func songsRankedNearSeed(
        _ songs: [Song],
        seed: Song?
    ) -> [Song] {
        guard let seed else { return songs }
        return songs.sorted { lhs, rhs in
            let left = RecommendationSeedAffinity.score(
                candidate: lhs,
                seed: seed,
                seedCompleted: true
            )
            let right = RecommendationSeedAffinity.score(
                candidate: rhs,
                seed: seed,
                seedCompleted: true
            )
            if left == right { return lhs.id < rhs.id }
            return left > right
        }
    }

    private nonisolated static func resolvedLastFMSongs(
        seed: Song?,
        apiKey: String,
        knownSongs: [Song]
    ) async -> [Song] {
        let cacheKey = seed?.id ?? ""
        let cached = await LocalLibraryCatalog.shared.cachedMatches(
            source: "lastfm",
            key: cacheKey,
            maximumAge: 3 * 60 * 60
        )
        if !cached.isEmpty { return cached }
        guard let seed, !apiKey.isEmpty else { return [] }
        let candidates = await ExternalRecommendationClient.shared.lastFM(
            seed: seed,
            apiKey: apiKey,
            limit: 20
        )
        let songs = await LocalLibraryCatalog.shared.match(
            candidates,
            additionalSongs: knownSongs,
            limit: 12
        )
        if !songs.isEmpty {
            await LocalLibraryCatalog.shared.storeCachedMatches(
                songs,
                source: "lastfm",
                key: cacheKey
            )
        }
        return songs
    }

    private nonisolated static func resolvedListenBrainzSongs(
        username: String,
        token: String?,
        knownSongs: [Song]
    ) async -> [Song] {
        let cacheKey = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cached = await LocalLibraryCatalog.shared.cachedMatches(
            source: "listenbrainz",
            key: cacheKey,
            maximumAge: 24 * 60 * 60
        )
        if !cached.isEmpty { return cached }
        guard !cacheKey.isEmpty else { return [] }
        let candidates = await ExternalRecommendationClient.shared.listenBrainz(
            username: cacheKey,
            token: token,
            limit: 16
        )
        let songs = await LocalLibraryCatalog.shared.match(
            candidates,
            additionalSongs: knownSongs,
            limit: 12
        )
        if !songs.isEmpty {
            await LocalLibraryCatalog.shared.storeCachedMatches(
                songs,
                source: "listenbrainz",
                key: cacheKey
            )
        }
        return songs
    }

    private func scheduleExternalRecommendationRefresh(
        client: OpenSubsonicClient,
        generation: Int
    ) {
        guard hasLastFMAPIKey || !listenBrainzUsername.isEmpty,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState.rawValue <
                ProcessInfo.ThermalState.serious.rawValue else {
            lastExternalRecommendationIdentity = nil
            return
        }
        let nextIdentity = ExternalRecommendationRefreshIdentity(
            sessionGeneration: generation,
            snapshotRevision: library.revision,
            seedSongID: AudioEngine.shared.currentSong?.id
                ?? home.starredSongs.first?.id
                ?? home.mostPlayedSongs.first?.id
                ?? home.randomSongs.first?.id,
            includesLastFM: hasLastFMAPIKey,
            includesListenBrainz: !listenBrainzUsername.isEmpty
        )
        guard ExternalRecommendationRefreshPolicy.shouldRefresh(
            previous: lastExternalRecommendationIdentity,
            next: nextIdentity
        ) else {
            return
        }
        recommendationTask?.cancel()
        recommendationGeneration &+= 1
        let requestGeneration = recommendationGeneration
        let source = home
        let sourceRevision = library.revision
        recommendationTask = Task { [weak self] in
            guard let self else { return }
            let enriched = await self.enrichingExternalRecommendations(
                in: source
            )
            guard !Task.isCancelled,
                  requestGeneration == self.recommendationGeneration,
                  generation == self.sessionGeneration,
                  self.client === client,
                  sourceRevision == self.library.revision else {
                return
            }
            let publicationSource = self.home
            let publicationRevision = self.library.revision
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
                  publicationRevision == self.library.revision else {
                return
            }
            let weights = RecommendationWeights.current()
            let sections = await Self.recommendationSections(
                snapshot: value,
                snapshotRevision:
                    value.lastFMRecommendedSongs
                        == publicationSource.lastFMRecommendedSongs
                    && value.listenBrainzRecommendedSongs
                        == publicationSource.listenBrainzRecommendedSongs
                    ? publicationRevision
                    : nil,
                weights: weights,
                behavior: behavior
            )
            let latestBehaviorRevision = await ListeningHistoryStore.shared
                .recommendationRevision()
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
                  publicationRevision == self.library.revision else {
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
                self.lastExternalRecommendationIdentity =
                    ExternalRecommendationRefreshIdentity(
                        sessionGeneration: generation,
                        snapshotRevision: self.library.revision,
                        seedSongID: nextIdentity.seedSongID,
                        includesLastFM: nextIdentity.includesLastFM,
                        includesListenBrainz: nextIdentity.includesListenBrainz
                    )
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
        lastFMKeyOperationGeneration &+= 1
        listenBrainzOperationGeneration &+= 1
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        recommendationTask?.cancel()
        recommendationTask = nil
        lastExternalRecommendationIdentity = nil
        cancelAutomaticRefresh()
        let previousLeases = StoreActivationLeases(
            offline: offlineSessionToken,
            artwork: artworkSessionToken,
            history: historySessionToken,
            catalog: catalogSessionToken
        )
        let isReplacingActiveSession = client != nil
        client = nil
        offlineSessionToken = nil
        artworkSessionToken = nil
        historySessionToken = nil
        catalogSessionToken = nil
        if isReplacingActiveSession {
            await AudioEngine.shared.shutdownForSessionEnd()
            guard generation == sessionGeneration else {
                await deactivateStores(previousLeases)
                return
            }
        }
        await deactivateStores(previousLeases)
        guard generation == sessionGeneration else { return }

        publishHome(.empty)
        searchResults = .empty
        connectedServerAddress = ""
        serverVersion = ""
        subsonicAPIVersion = ""
        refreshInFlight = false
        lastHomeSnapshotSave = nil
        isSearching = false
        clearFavoriteState()
        clearDetailCaches()
        sessionState = .connecting
        errorMessage = nil
        var activatedLeases = StoreActivationLeases(
            offline: nil,
            artwork: nil,
            history: nil,
            catalog: nil
        )
        do {
            let client = try OpenSubsonicClient(credentials: credentials)
            let accountScope = AccountScope.identifier(for: client.credentials)
            async let statusRequest = Self.pingResult(client)
            async let cachedSnapshotRequest = HomeSnapshotStore.shared.load(
                accountScope: accountScope
            )
            async let offlineRequest = OfflineStore.shared.activate(
                accountScope: accountScope
            )
            async let artworkRequest = ArtworkStore.shared.activate(
                accountScope: accountScope
            )
            async let historyRequest = ListeningHistoryStore.shared.activate(
                accountScope: accountScope
            )
            async let catalogRequest = LocalLibraryCatalog.shared.activate(
                accountScope: accountScope
            )

            let cachedSnapshot = await cachedSnapshotRequest
            let offlineSession = await offlineRequest
            let artworkSession = await artworkRequest
            let historySession = await historyRequest
            let catalogSession = await catalogRequest
            let ping = await statusRequest
            try Task.checkCancellation()
            guard generation == sessionGeneration else {
                await deactivateStores(
                    StoreActivationLeases(
                        offline: offlineSession,
                        artwork: artworkSession,
                        history: historySession,
                        catalog: catalogSession
                    )
                )
                return
            }

            guard let offlineSession, let historySession else {
                throw CancellationError()
            }
            activatedLeases = StoreActivationLeases(
                offline: offlineSession,
                artwork: artworkSession,
                history: historySession,
                catalog: catalogSession
            )

            if ping.isCancelled {
                throw CancellationError()
            }
            let status = ping.status
            if status == nil {
                if cachedSnapshot == nil || !ping.allowsCachedFallback {
                    throw OpenSubsonicError.server(
                        code: nil,
                        message: ping.failureDescription
                            ?? String(localized: "서버 연결에 실패했습니다.")
                    )
                }
                errorMessage = String(
                    localized: "서버에 연결할 수 없어 저장된 라이브러리를 엽니다."
                )
            }

            if persist, status != nil {
                try await secureStore.save(client.credentials)
                guard generation == sessionGeneration else {
                    await deactivateStores(activatedLeases)
                    return
                }
            }

            try Task.checkCancellation()
            guard generation == sessionGeneration else {
                await deactivateStores(activatedLeases)
                return
            }

            let snapshot = cachedSnapshot ?? .empty
            reconcileFavoriteStates(
                in: snapshot,
                authoritative: false
            )
            self.client = client
            self.offlineSessionToken = offlineSession
            self.artworkSessionToken = artworkSession
            self.historySessionToken = historySession
            self.catalogSessionToken = catalogSession
            self.publishHome(applyingFavoriteOverrides(to: snapshot))
            self.scheduleLibraryCatalogRefresh(snapshot: snapshot)
            self.lastFullRefresh = nil
            self.lastHomeSnapshotSave = nil
            self.connectedServerAddress = Self.serverDisplayAddress(
                from: client.credentials.serverURL
            )
            self.serverVersion = Self.sanitizedVersion(status?.serverVersion)
            self.subsonicAPIVersion = Self.sanitizedVersion(status?.version)
            self.sessionState = .ready
            activatedLeases = StoreActivationLeases(
                offline: nil,
                artwork: nil,
                history: nil,
                catalog: nil
            )
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
            if cachedSnapshot != nil {
                scheduleCachedHomePreparation(
                    snapshot,
                    generation: generation
                )
            }
            if status != nil {
                scheduleAutomaticRefresh(
                    silent: cachedSnapshot != nil,
                    generation: generation
                )
            }
        } catch is CancellationError {
            await deactivateStores(activatedLeases)
            return
        } catch {
            await deactivateStores(activatedLeases)
            guard generation == sessionGeneration else { return }
            client = nil
            offlineSessionToken = nil
            artworkSessionToken = nil
            historySessionToken = nil
            publishHome(.empty)
            searchResults = .empty
            connectedServerAddress = ""
            serverVersion = ""
            subsonicAPIVersion = ""
            refreshInFlight = false
            lastHomeSnapshotSave = nil
            isSearching = false
            sessionState = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    private struct ConnectPingResult: Sendable {
        var status: StatusBody?
        var failureDescription: String?
        var allowsCachedFallback: Bool
        var isCancelled: Bool
    }

    private static func pingResult(
        _ client: OpenSubsonicClient
    ) async -> ConnectPingResult {
        do {
            return ConnectPingResult(
                status: try await client.ping(),
                failureDescription: nil,
                allowsCachedFallback: false,
                isCancelled: false
            )
        } catch is CancellationError {
            return ConnectPingResult(
                status: nil,
                failureDescription: nil,
                allowsCachedFallback: false,
                isCancelled: true
            )
        } catch {
            return ConnectPingResult(
                status: nil,
                failureDescription: error.localizedDescription,
                allowsCachedFallback: TransientServiceFailurePolicy
                    .allowsCachedFallback(error),
                isCancelled: false
            )
        }
    }

    private func scheduleCachedHomePreparation(
        _ snapshot: HomeSnapshot,
        generation: Int
    ) {
        Task { [weak self] in
            guard let self else { return }
            let prepared = await self.preparedHomeSnapshot(snapshot)
            guard generation == self.sessionGeneration,
                  self.lastFullRefresh == nil else {
                return
            }
            self.reconcileFavoriteStates(
                in: prepared,
                authoritative: false
            )
            _ = self.publishHome(self.applyingFavoriteOverrides(to: prepared))
        }
    }

    private func scheduleAutomaticRefresh(silent: Bool, generation: Int) {
        cancelAutomaticRefresh()
        let token = UUID()
        automaticRefreshToken = token
        automaticRefreshTask = Task { [weak self] in
            guard let self else { return }
            guard generation == self.sessionGeneration else { return }
            await self.refresh(forceFull: true, silent: silent)
            guard token == self.automaticRefreshToken else { return }
            self.automaticRefreshTask = nil
            self.automaticRefreshToken = nil
        }
    }

    private func cancelAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        automaticRefreshToken = nil
    }

    private func deactivateStores(_ leases: StoreActivationLeases) async {
        if let offline = leases.offline {
            await OfflineStore.shared.deactivate(session: offline)
        }
        if let artwork = leases.artwork {
            await ArtworkStore.shared.deactivate(session: artwork)
        }
        if let history = leases.history {
            await ListeningHistoryStore.shared.deactivate(session: history)
        }
        if let catalog = leases.catalog {
            await LocalLibraryCatalog.shared.deactivate(session: catalog)
        }
    }

    private func scheduleLibraryCatalogRefresh(snapshot: HomeSnapshot) {
        let seedSongs = snapshot.knownSongs()
        Task(priority: .utility) {
            await LocalLibraryCatalog.shared.ingest(seedSongs)
            let historySongs = await ListeningHistoryStore.shared.catalogSongs()
            await LocalLibraryCatalog.shared.ingest(historySongs)
            await LocalLibraryCatalog.shared.persistNow()
        }
    }
}
