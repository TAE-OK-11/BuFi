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


app = Path("BuFi/App/AppModel.swift")
replace_once(
    app,
    '''    private struct CachedValue<Value> {
        let value: Value
        let expiresAt: Date
    }
''',
    '''    private struct CachedValue<Value> {
        let value: Value
        let expiresAt: Date
    }

    private struct DetailRequest<Value> {
        let token: UUID
        let task: Task<Value, Error>
    }
''',
)
replace_once(
    app,
    '''    private var sessionGeneration = 0
    private var searchGeneration = 0
''',
    '''    private var sessionGeneration = 0
    private var searchGeneration = 0
    private var homeRevision = 0
''',
)
replace_once(
    app,
    '''    private var albumDetailTasks: [String: Task<AlbumDetail, Error>] = [:]
    private var playlistDetailTasks: [String: Task<PlaylistDetail, Error>] = [:]
    private var artistDetailTasks: [String: Task<ArtistDetail, Error>] = [:]
''',
    '''    private var albumDetailTasks: [String: DetailRequest<AlbumDetail>] = [:]
    private var playlistDetailTasks: [String: DetailRequest<PlaylistDetail>] = [:]
    private var artistDetailTasks: [String: DetailRequest<ArtistDetail>] = [:]
''',
)
replace_once(
    app,
    '''        let generation = sessionGeneration
        refreshInFlight = true
''',
    '''        let generation = sessionGeneration
        let revision = homeRevision
        let previousHome = home
        refreshInFlight = true
''',
)
replace_once(
    app,
    '''                snapshot = try await client.home(from: isHomeEmpty ? nil : home)
            } else {
                snapshot = try await client.incrementalHome(from: home)
            }
            guard generation == sessionGeneration, self.client === client else { return }
''',
    '''                snapshot = try await client.home(from: isHomeEmpty ? nil : previousHome)
            } else {
                snapshot = try await client.incrementalHome(from: previousHome)
            }
            guard generation == sessionGeneration, self.client === client else { return }
            guard revision == homeRevision else { return }
''',
)
sub_once(
    app,
    r'''        let task: Task<AlbumDetail, Error>\n        if let existing = albumDetailTasks\[id\] \{.*?\n        albumDetailTasks\[id\] = nil\n''',
    '''        let request: DetailRequest<AlbumDetail>
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
''',
    flags=re.DOTALL,
)
sub_once(
    app,
    r'''        let task: Task<PlaylistDetail, Error>\n        if let existing = playlistDetailTasks\[id\] \{.*?\n        playlistDetailTasks\[id\] = nil\n''',
    '''        let request: DetailRequest<PlaylistDetail>
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
''',
    flags=re.DOTALL,
)
sub_once(
    app,
    r'''        let task: Task<ArtistDetail, Error>\n        if let existing = artistDetailTasks\[id\] \{.*?\n        artistDetailTasks\[id\] = nil\n''',
    '''        let request: DetailRequest<ArtistDetail>
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
''',
    flags=re.DOTALL,
)
replace_once(
    app,
    '''        albumDetailTasks.removeValue(forKey: album.id)?.cancel()
''',
    '''        albumDetailTasks.removeValue(forKey: album.id)?.task.cancel()
''',
)
replace_once(
    app,
    '''        artistDetailTasks.removeValue(forKey: artist.id)?.cancel()
''',
    '''        artistDetailTasks.removeValue(forKey: artist.id)?.task.cancel()
''',
)
replace_once(
    app,
    '''        albumDetailTasks.values.forEach { $0.cancel() }
        playlistDetailTasks.values.forEach { $0.cancel() }
        artistDetailTasks.values.forEach { $0.cancel() }
''',
    '''        albumDetailTasks.values.forEach { $0.task.cancel() }
        playlistDetailTasks.values.forEach { $0.task.cancel() }
        artistDetailTasks.values.forEach { $0.task.cancel() }
''',
)
replace_once(
    app,
    '''        snapshot.randomSongs = snapshot.randomSongs.map { $0.id == song.id ? updated : $0 }
        home = snapshot
''',
    '''        snapshot.randomSongs = snapshot.randomSongs.map { $0.id == song.id ? updated : $0 }
        homeRevision &+= 1
        home = snapshot
''',
)
replace_once(
    app,
    '''        snapshot.randomAlbums = snapshot.randomAlbums.map { $0.id == album.id ? updated : $0 }
        home = snapshot
''',
    '''        snapshot.randomAlbums = snapshot.randomAlbums.map { $0.id == album.id ? updated : $0 }
        homeRevision &+= 1
        home = snapshot
''',
)
replace_once(
    app,
    '''        snapshot.artists = snapshot.artists.map { $0.id == artist.id ? updated : $0 }
        home = snapshot
''',
    '''        snapshot.artists = snapshot.artists.map { $0.id == artist.id ? updated : $0 }
        homeRevision &+= 1
        home = snapshot
''',
)


offline = Path("BuFi/Core/OfflineStore.swift")
replace_once(
    offline,
    '''        if let existingTask = inFlight[taskKey] {
            return try await existingTask.task.value.url
        }

        let remote = try await client.downloadURL(songID: song.id)
''',
    '''        if let existingTask = inFlight[taskKey] {
            let result = try await existingTask.task.value
            guard activeScope == scope,
                  scopeGeneration == existingTask.scopeGeneration,
                  songGenerations[song.id, default: 0] == existingTask.songGeneration else {
                throw CancellationError()
            }
            return result.url
        }

        let remote = try await client.downloadURL(songID: song.id)
''',
)
replace_once(
    offline,
    '''        guard remote.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        let fileName = Self.fileName(for: song)
''',
    '''        guard remote.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        guard activeScope == scope,
              scopeGeneration == generation,
              songGenerations[song.id, default: 0] == songGeneration else {
            throw CancellationError()
        }
        let fileName = Self.fileName(for: song)
''',
)
sub_once(
    offline,
    r'''    func remove\(songID: String\) throws \{.*?\n    \}\n\n(?=    func removeAll)''',
    '''    func remove(songID: String) throws {
        guard let directory else { return }
        invalidateDownload(songID: songID)
        defer { scheduleIndexPersistence(immediate: true) }
        if let entry = entries[songID] {
            let url = directory.appendingPathComponent(entry.fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            entries[songID] = nil
        }
        let legacy = legacyFileURL(songID: songID, directory: directory)
        if FileManager.default.fileExists(atPath: legacy.path) {
            try FileManager.default.removeItem(at: legacy)
        }
    }

''',
    flags=re.DOTALL,
)
sub_once(
    offline,
    r'''    func removeAll\(\) throws \{.*?\n    \}\n\n(?=    func totalBytes)''',
    '''    func removeAll() throws {
        guard let directory else { return }
        scopeGeneration &+= 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        songGenerations.removeAll(keepingCapacity: false)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var firstError: Error?
        for file in files {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        entries = entries.reduce(into: [:]) { result, pair in
            let url = directory.appendingPathComponent(pair.value.fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                result[pair.key] = pair.value
            }
        }
        scheduleIndexPersistence(immediate: true)
        if let firstError { throw firstError }
    }

''',
    flags=re.DOTALL,
)


client = Path("BuFi/Core/OpenSubsonicClient.swift")
replace_once(
    client,
    '''            recentAlbums: values.0?.albumList2?.album ?? fallback.recentAlbums,
            randomAlbums: values.1?.albumList2?.album ?? fallback.randomAlbums,
''',
    '''            recentAlbums: values.0.map { $0.albumList2?.album ?? [] }
                ?? fallback.recentAlbums,
            randomAlbums: values.1.map { $0.albumList2?.album ?? [] }
                ?? fallback.randomAlbums,
''',
)
replace_once(
    client,
    '''            randomSongs: values.4?.randomSongs?.song ?? fallback.randomSongs,
            playlists: values.5?.playlists?.playlist ?? fallback.playlists
''',
    '''            randomSongs: values.4.map { $0.randomSongs?.song ?? [] }
                ?? fallback.randomSongs,
            playlists: values.5.map { $0.playlists?.playlist ?? [] }
                ?? fallback.playlists
''',
)
replace_once(
    client,
    '''        if let albums = values.0?.albumList2?.album {
            snapshot.recentAlbums = albums
        }
''',
    '''        if let recent = values.0 {
            snapshot.recentAlbums = recent.albumList2?.album ?? []
        }
''',
)
replace_once(
    client,
    '''        if let playlists = values.2?.playlists?.playlist {
            snapshot.playlists = playlists
        }
''',
    '''        if let playlists = values.2 {
            snapshot.playlists = playlists.playlists?.playlist ?? []
        }
''',
)

for name in [
    "BuFi/App/AppModel.swift",
    "BuFi/Core/OfflineStore.swift",
    "BuFi/Core/OpenSubsonicClient.swift",
]:
    path = Path(name)
    path.write_text(path.read_text().rstrip() + "\n")
