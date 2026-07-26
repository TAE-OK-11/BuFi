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
        sessionState = .signedOut
        serverVersion = ""
        AudioEngine.shared.configure(client: nil)
    }

    func refresh() async {
        guard let client, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            home = try await client.home()
        } catch {
            errorMessage = error.localizedDescription
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
        do {
            try await client.star(id: song.id, enabled: !song.isStarred)
            await refresh()
        } catch {
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

    private func connect(_ credentials: ServerCredentials, persist: Bool) async {
        sessionState = .connecting
        errorMessage = nil
        do {
            let client = try OpenSubsonicClient(credentials: credentials)
            let status = try await client.ping()
            let snapshot = try await client.home()
            self.client = client
            self.home = snapshot
            self.serverVersion = status.serverVersion ?? status.version ?? ""
            self.sessionState = .ready
            AudioEngine.shared.configure(client: client)
            if persist { try secureStore.save(credentials) }
        } catch {
            client = nil
            sessionState = .signedOut
            errorMessage = error.localizedDescription
            AudioEngine.shared.configure(client: nil)
        }
    }
}
