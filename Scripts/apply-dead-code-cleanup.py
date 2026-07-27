from __future__ import annotations

from pathlib import Path
import re


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one match, found {count}: {old[:140]!r}")
    path.write_text(text.replace(old, new, 1))


def replace_all(path: Path, old: str, new: str, minimum: int = 1) -> None:
    text = path.read_text()
    count = text.count(old)
    if count < minimum:
        raise RuntimeError(f"{path}: expected at least {minimum} matches, found {count}: {old[:140]!r}")
    path.write_text(text.replace(old, new))


def sub_once(path: Path, pattern: str, replacement: str, flags: int = 0) -> None:
    text = path.read_text()
    updated, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        raise RuntimeError(f"{path}: expected one regex match, found {count}: {pattern[:160]!r}")
    path.write_text(updated)


# Models: retain only fields used by current behavior. Unknown JSON keys remain safely ignored.
models = Path("BuFi/Core/Models.swift")
replace_once(
    models,
    '''struct Song: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var artistId: String?
    var albumId: String?
    var coverArt: String?
    var duration: Double?
    var track: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var bitRate: Int?
    var suffix: String?
    var contentType: String?
    var starred: String?
    var playCount: Int?

    var isStarred: Bool { starred != nil }
    var safeDuration: Double { max(0, duration ?? 0) }
}
''',
    '''struct Song: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var artistId: String?
    var albumId: String?
    var coverArt: String?
    var duration: Double?
    var track: Int?
    var suffix: String?
    var contentType: String?
    var starred: String?

    var isStarred: Bool { starred != nil }
    var safeDuration: Double { max(0, duration ?? 0) }
}
''',
)
replace_once(
    models,
    '''struct Album: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var artist: String
    var artistId: String?
    var coverArt: String?
    var songCount: Int?
    var duration: Double?
    var year: Int?
    var genre: String?
    var starred: String?
    var playCount: Int?

    var title: String { name }
    var isStarred: Bool { starred != nil }
}
''',
    '''struct Album: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var artist: String
    var coverArt: String?
    var year: Int?
    var starred: String?

    var isStarred: Bool { starred != nil }
}
''',
)
replace_once(
    models,
    '''struct Artist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var coverArt: String?
    var artistImageUrl: String?
    var albumCount: Int?
    var starred: String?

    var isStarred: Bool { starred != nil }
}
''',
    '''struct Artist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var coverArt: String?
    var albumCount: Int?
    var starred: String?

    var isStarred: Bool { starred != nil }
}
''',
)
replace_once(
    models,
    '''struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var comment: String?
    var owner: String?
    var publicValue: Bool?
    var songCount: Int?
    var duration: Double?
    var coverArt: String?
    var changed: String?

    enum CodingKeys: String, CodingKey {
        case id, name, comment, owner, songCount, duration, coverArt, changed
        case publicValue = "public"
    }
}
''',
    '''struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var owner: String?
    var songCount: Int?
    var coverArt: String?
}
''',
)
replace_once(models, "struct HomeSnapshot: Sendable {", "struct HomeSnapshot: Equatable, Sendable {")
replace_once(
    models,
    '''struct AlbumDetail: Sendable {
    var album: Album
    var songs: [Song]
}

struct PlaylistDetail: Sendable {
    var playlist: Playlist
    var songs: [Song]
}
''',
    '''struct AlbumDetail: Sendable {
    var songs: [Song]
}

struct PlaylistDetail: Sendable {
    var songs: [Song]
}
''',
)
replace_once(
    models,
    '''struct LyricsDocument: Sendable {
    var displayTitle: String?
    var displayArtist: String?
    var language: String?
    var synced: Bool
    var lines: [LyricLine]

    static let empty = LyricsDocument(synced: false, lines: [])
}
''',
    '''struct LyricsDocument: Sendable {
    var synced: Bool
    var lines: [LyricLine]

    static let empty = LyricsDocument(synced: false, lines: [])
}
''',
)
replace_once(
    models,
    '''struct StatusBody: Decodable {
    let status: String
    let version: String?
    let type: String?
    let serverVersion: String?
    let openSubsonic: Bool?
    let error: APIErrorBody?
}
''',
    '''struct StatusBody: Decodable {
    let status: String
    let version: String?
    let serverVersion: String?
    let error: APIErrorBody?
}
''',
)
sub_once(
    models,
    r'''struct AlbumWithSongs: Decodable \{.*?\n\}\n\n(?=struct PlaylistPayload)''',
    '''struct AlbumWithSongs: Decodable {
    let song: [Song]?
}

''',
    flags=re.DOTALL,
)
sub_once(
    models,
    r'''struct PlaylistWithSongs: Decodable \{.*?\n\}\n\n(?=struct SearchPayload)''',
    '''struct PlaylistWithSongs: Decodable {
    let entry: [Song]?
}

''',
    flags=re.DOTALL,
)
sub_once(
    models,
    r'''\nstruct ArtistPayload: Decodable \{.*?\n\}\n''',
    "\n",
    flags=re.DOTALL,
)
replace_once(
    models,
    '''struct ArtistInfo: Decodable, Sendable {
    let biography: String?
    let musicBrainzId: String?
    let lastFmUrl: String?
    let smallImageUrl: String?
    let mediumImageUrl: String?
    let largeImageUrl: String?
}
''',
    '''struct ArtistInfo: Decodable, Sendable {
    let biography: String?
}
''',
)
replace_once(
    models,
    '''struct ArtistIndex: Decodable {
    let name: String?
    let artist: [Artist]?
}
''',
    '''struct ArtistIndex: Decodable {
    let artist: [Artist]?
}
''',
)
replace_once(
    models,
    '''struct ArtistWithAlbums: Decodable {
    let id: String
    let name: String
    let coverArt: String?
    let artistImageUrl: String?
    let albumCount: Int?
    let starred: String?
    let album: [Album]?

    var artistValue: Artist {
        Artist(
            id: id,
            name: name,
            coverArt: coverArt,
            artistImageUrl: artistImageUrl,
            albumCount: albumCount,
            starred: starred
        )
    }
}
''',
    '''struct ArtistWithAlbums: Decodable {
    let id: String
    let name: String
    let coverArt: String?
    let albumCount: Int?
    let starred: String?
    let album: [Album]?

    var artistValue: Artist {
        Artist(
            id: id,
            name: name,
            coverArt: coverArt,
            albumCount: albumCount,
            starred: starred
        )
    }
}
''',
)
replace_once(
    models,
    '''struct StructuredLyrics: Decodable {
    let displayArtist: String?
    let displayTitle: String?
    let lang: String?
    let offset: Int?
    let synced: Bool?
    let line: [StructuredLyricLine]?
}
''',
    '''struct StructuredLyrics: Decodable {
    let offset: Int?
    let synced: Bool?
    let line: [StructuredLyricLine]?
}
''',
)
replace_once(
    models,
    '''struct PlayQueueContainer: Decodable {
    let current: String?
    let position: Int?
    let username: String?
    let changed: String?
    let changedBy: String?
    let entry: [Song]?
}
''',
    '''struct PlayQueueContainer: Decodable {
    let current: String?
    let position: Int?
    let entry: [Song]?
}
''',
)

# Client mappings after leaner response models.
client = Path("BuFi/Core/OpenSubsonicClient.swift")
replace_once(
    client,
    "        return AlbumDetail(album: value.albumValue, songs: value.song ?? [])\n",
    "        return AlbumDetail(songs: value.song ?? [])\n",
)
replace_once(
    client,
    "        return PlaylistDetail(playlist: value.playlistValue, songs: value.entry ?? [])\n",
    "        return PlaylistDetail(songs: value.entry ?? [])\n",
)
replace_once(
    client,
    '''        return LyricsDocument(
            displayTitle: source.displayTitle,
            displayArtist: source.displayArtist,
            language: source.lang,
            synced: source.synced ?? !lines.isEmpty,
            lines: lines.sorted { $0.start < $1.start }
        )
''',
    '''        return LyricsDocument(
            synced: source.synced ?? !lines.isEmpty,
            lines: lines.sorted { $0.start < $1.start }
        )
''',
)

# App model: remove unused state and centralize repeated query normalization.
app = Path("BuFi/App/AppModel.swift")
replace_once(app, "    private var refreshTask: Task<Void, Never>?\n", "")
replace_all(app, "        refreshTask?.cancel()\n", "", minimum=2)
sub_once(
    app,
    r'''\n    var allSongs: \[Song\] \{.*?\n    \}\n''',
    "\n",
    flags=re.DOTALL,
)
normalization = '''        let query = rawQuery
            .precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
'''
replace_all(app, normalization, "        let query = Self.normalizedSearchQuery(rawQuery)\n", minimum=2)
replace_once(
    app,
    '''    func clearSearch() {
''',
    '''    private static func normalizedSearchQuery(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearSearch() {
''',
)
sub_once(
    app,
    r'''    private var isHomeEmpty: Bool \{.*?\n    \}\n\n    private func homeChanged\(_ next: HomeSnapshot\) -> Bool \{.*?\n    \}\n''',
    '''    private var isHomeEmpty: Bool { home == .empty }

    private func homeChanged(_ next: HomeSnapshot) -> Bool { home != next }
''',
    flags=re.DOTALL,
)

# Offline store: keep only metadata required for lookup, accounting and LRU eviction.
offline = Path("BuFi/Core/OfflineStore.swift")
replace_once(
    offline,
    '''    private struct Entry: Codable, Sendable {
        var song: Song
        var fileName: String
        var byteCount: Int64
        var downloadedAt: Date
        var lastAccessedAt: Date
    }

    private struct DownloadResult: Sendable {
        let url: URL
        let byteCount: Int64
    }

    private struct InFlightDownload {
        let scopeGeneration: UInt64
        let songGeneration: UInt64
        let task: Task<DownloadResult, Error>
    }
''',
    '''    private struct Entry: Codable, Sendable {
        var fileName: String
        var byteCount: Int64
        var lastAccessedAt: Date
    }

    private struct InFlightDownload {
        let token: UUID
        let scopeGeneration: UInt64
        let task: Task<URL, Error>
    }
''',
)
replace_once(offline, "    private var songGenerations: [String: UInt64] = [:]\n", "")
replace_all(offline, "        songGenerations.removeAll(keepingCapacity: false)\n", "", minimum=2)
sub_once(
    offline,
    r'''    func isDownloaded\(songID: String\) -> Bool \{.*?\n    \}\n\n    func downloadedSongs\(\) -> \[Song\] \{.*?\n    \}\n\n    func download\(song: Song, client: OpenSubsonicClient\) async throws -> URL \{.*?\n    \}\n\n    private func commitDownload\(.*?\n    \}\n\n    func remove\(songID: String\) throws \{.*?\n    \}\n\n(?=    func removeAll)''',
    '''    func download(song: Song, client: OpenSubsonicClient) async throws -> URL {
        guard let scope = activeScope, let directory else {
            throw OpenSubsonicError.invalidResponse
        }
        if let existing = localURL(for: song.id) { return existing }

        let generation = scopeGeneration
        let taskKey = scope + ":" + song.id
        if let existing = inFlight[taskKey] {
            do {
                let url = try await existing.task.value
                clearInFlight(taskKey: taskKey, token: existing.token)
                guard activeScope == scope,
                      scopeGeneration == existing.scopeGeneration,
                      FileManager.default.fileExists(atPath: url.path) else {
                    throw CancellationError()
                }
                return url
            } catch {
                clearInFlight(taskKey: taskKey, token: existing.token)
                throw error
            }
        }

        let remote = try await client.downloadURL(songID: song.id)
        guard remote.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        guard activeScope == scope, scopeGeneration == generation else {
            throw CancellationError()
        }

        let fileName = Self.fileName(for: song)
        let destination = directory.appendingPathComponent(fileName)
        let wifiOnly = UserDefaults.standard.object(forKey: "offline-wifi-only") as? Bool ?? true
        let session = wifiOnly ? wifiOnlySession : unrestrictedSession
        let token = UUID()
        let task = Task<URL, Error>(priority: .utility) { [weak self] in
            let (temporary, response) = try await session.download(from: remote)
            guard let http = response as? HTTPURLResponse else {
                throw OpenSubsonicError.invalidResponse
            }
            guard http.url?.scheme?.lowercased() == "https" else {
                throw OpenSubsonicError.insecureServerURL
            }
            guard (200..<300).contains(http.statusCode) else {
                throw OpenSubsonicError.http(http.statusCode)
            }

            let values = try temporary.resourceValues(forKeys: [.fileSizeKey])
            let bytes = Int64(values.fileSize ?? 0)
            guard bytes > 0 else { throw URLError(.zeroByteResource) }

            let staging = directory.appendingPathComponent(
                fileName + "." + UUID().uuidString + ".partial"
            )
            try FileManager.default.moveItem(at: temporary, to: staging)
            guard let self else {
                try? FileManager.default.removeItem(at: staging)
                throw CancellationError()
            }
            return try await self.commitDownload(
                staging: staging,
                destination: destination,
                byteCount: bytes,
                songID: song.id,
                scope: scope,
                scopeGeneration: generation
            )
        }
        inFlight[taskKey] = InFlightDownload(
            token: token,
            scopeGeneration: generation,
            task: task
        )

        do {
            let url = try await task.value
            clearInFlight(taskKey: taskKey, token: token)
            return url
        } catch {
            clearInFlight(taskKey: taskKey, token: token)
            throw error
        }
    }

    private func commitDownload(
        staging: URL,
        destination: URL,
        byteCount: Int64,
        songID: String,
        scope: String,
        scopeGeneration generation: UInt64
    ) throws -> URL {
        guard activeScope == scope, scopeGeneration == generation else {
            try? FileManager.default.removeItem(at: staging)
            throw CancellationError()
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            entries[songID] = Entry(
                fileName: destination.lastPathComponent,
                byteCount: byteCount,
                lastAccessedAt: Date()
            )
            try enforceStorageLimit(keeping: songID)
            scheduleIndexPersistence()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

''',
    flags=re.DOTALL,
)
sub_once(
    offline,
    r'''    private func invalidateDownload\(songID: String\) \{.*?\n    \}\n\n    private func clearInFlight\(.*?\n    \}\n''',
    '''    private func clearInFlight(taskKey: String, token: UUID) {
        guard inFlight[taskKey]?.token == token else { return }
        inFlight[taskKey] = nil
    }
''',
    flags=re.DOTALL,
)

# Artwork cache: remove a prefetch API that has no caller.
artwork = Path("BuFi/Core/ArtworkStore.swift")
sub_once(
    artwork,
    r'''\n    func prefetch\(urls: \[URL\], pixelSize: CGFloat\) async \{.*?\n    \}\n''',
    "\n",
    flags=re.DOTALL,
)
sub_once(
    artwork,
    r'''\n    private static var allowsDiscretionaryWork: Bool \{.*?\n    \}\n''',
    "\n",
    flags=re.DOTALL,
)

# Playback engine: delete superseded APIs and remove a meaningless parameter.
audio = Path("BuFi/Playback/AudioEngine.swift")
replace_once(
    audio,
    "            guard oldValue != quality, let song = currentSong else { return }\n            restartPlaybackPlan(for: song, resumeFrom: elapsed)\n",
    "            guard oldValue != quality, currentSong != nil else { return }\n            restartPlaybackPlan(resumeFrom: elapsed)\n",
)
sub_once(
    audio,
    r'''\n    func localOrRemoteURL\(for song: Song, compatibilityFormat: String\? = nil\) async throws -> URL \{.*?\n    \}\n''',
    "\n",
    flags=re.DOTALL,
)
sub_once(
    audio,
    r'''\n    func downloadCurrent\(\) async throws -> URL \{.*?\n    \}\n''',
    "\n",
    flags=re.DOTALL,
)
audio_text = audio.read_text()
audio_text, replacements = re.subn(
    r'restartPlaybackPlan\(for: [^,\n]+, resumeFrom:',
    'restartPlaybackPlan(resumeFrom:',
    audio_text,
)
if replacements < 3:
    raise RuntimeError(f"{audio}: expected at least 3 restart call replacements, found {replacements}")
audio_text = audio_text.replace(
    "    private func restartPlaybackPlan(for song: Song, resumeFrom: TimeInterval) {",
    "    private func restartPlaybackPlan(resumeFrom: TimeInterval) {",
)
audio.write_text(audio_text)

# Reusable filter control replaces duplicated Home/Library implementations.
components = Path("BuFi/UI/Components.swift")
replace_once(components, "    static let tertiary = Color(uiColor: .tertiarySystemBackground)\n", "")
replace_once(
    components,
    '''struct BuFiPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.972 : 1)
            .brightness(configuration.isPressed ? -0.018 : 0)
            .animation(BuFiMotion.tap, value: configuration.isPressed)
    }
}
''',
    '''struct BuFiPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.972 : 1)
            .brightness(configuration.isPressed ? -0.018 : 0)
            .animation(BuFiMotion.tap, value: configuration.isPressed)
    }
}

struct BuFiFilterBar<Item: Identifiable & Equatable>: View {
    let items: [Item]
    @Binding var selection: Item
    var fontSize: CGFloat = 14
    let title: (Item) -> LocalizedStringKey

    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                Button {
                    withAnimation(
                        .interactiveSpring(
                            response: 0.34,
                            dampingFraction: 0.80,
                            blendDuration: 0.08
                        )
                    ) {
                        selection = item
                    }
                } label: {
                    Text(title(item))
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(
                            selection == item
                                ? Color.white
                                : Color.white.opacity(0.62)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background {
                            if selection == item {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.14))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Color.white.opacity(0.13), lineWidth: 0.7)
                                    }
                                    .matchedGeometryEffect(
                                        id: "filter-selection",
                                        in: selectionNamespace
                                    )
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(BuFiPressStyle())
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(height: 50)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.58))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.26)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 0.7)
        }
        .buFiGlass(cornerRadius: 16, interactive: true)
        .padding(.horizontal, 16)
    }
}
''',
)

home = Path("BuFi/UI/HomeView.swift")
replace_once(home, "    @Namespace private var filterSelection\n", "")
sub_once(
    home,
    r'''    private var filterBar: some View \{.*?\n    \}\n\n(?=    @ViewBuilder)''',
    '''    private var filterBar: some View {
        BuFiFilterBar(
            items: HomeFilter.allCases,
            selection: $filter,
            fontSize: 14,
            title: { $0.title }
        )
    }

''',
    flags=re.DOTALL,
)

library = Path("BuFi/UI/LibraryView.swift")
replace_once(library, "    @Namespace private var filterSelection\n", "")
sub_once(
    library,
    r'''    private var filters: some View \{.*?\n    \}\n\n(?=    @ViewBuilder)''',
    '''    private var filters: some View {
        BuFiFilterBar(
            items: LibraryFilter.allCases,
            selection: $filter,
            fontSize: 13,
            title: { $0.title }
        )
    }

''',
    flags=re.DOTALL,
)
sub_once(
    library,
    r'''\n    var icon: String \{.*?\n    \}\n''',
    "\n",
    flags=re.DOTALL,
)

motion = Path("BuFi/UI/BuFiMotion.swift")
for name in ("selection", "entrance", "list"):
    sub_once(
        motion,
        rf'''    static let {name} = Animation\.interactiveSpring\(.*?\n    \)\n''',
        "",
        flags=re.DOTALL,
    )

artist_art = Path("BuFi/UI/ArtistHeroArtwork.swift")
replace_once(artist_art, "    let remoteURL: String?\n", "")

music_detail = Path("BuFi/UI/MusicDetailView.swift")
replace_once(music_detail, "    @State private var artistImageURL: String?\n", "")
replace_once(music_detail, "                remoteURL: artistImageURL,\n", "")
replace_once(music_detail, "        artistImageURL = nil\n", "")
replace_once(music_detail, "                artistImageURL = artist.artistImageUrl\n", "")
sub_once(
    music_detail,
    r'''                artistImageURL =\n                    detail\.artist\.artistImageUrl\n                    \?\? detail\.info\?\.largeImageUrl\n                    \?\? detail\.info\?\.mediumImageUrl\n                    \?\? artistImageURL\n''',
    "",
)

# The active root uses LegacyMiniPlayerView; this superseded implementation is unreachable.
mini_player = Path("BuFi/UI/MiniPlayerView.swift")
if not mini_player.exists():
    raise RuntimeError(f"{mini_player}: expected dead file to exist")
mini_player.unlink()
