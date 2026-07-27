from pathlib import Path


def replace_all_exact(path: Path, old: str, new: str, expected: int) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != expected:
        raise RuntimeError(f"{path}: expected {expected} matches, found {count}: {old[:120]!r}")
    path.write_text(text.replace(old, new))


def replace_once(path: Path, old: str, new: str) -> None:
    replace_all_exact(path, old, new, 1)


app = Path("BuFi/App/AppModel.swift")
replace_all_exact(
    app,
    '''        guard generation == sessionGeneration, self.client === client else {
            throw CancellationError()
        }
        if ''',
    '''        guard generation == sessionGeneration, self.client === client else {
            throw CancellationError()
        }
        guard ''',
    3,
)
replace_once(
    app,
    '''        guard albumDetailTasks[id]?.token == request.token {
            albumDetailTasks[id] = nil
        }
        albumDetailCache[id] = CachedValue(
''',
    '''        guard albumDetailTasks[id]?.token == request.token else {
            throw CancellationError()
        }
        albumDetailTasks[id] = nil
        albumDetailCache[id] = CachedValue(
''',
)
replace_once(
    app,
    '''        guard playlistDetailTasks[id]?.token == request.token {
            playlistDetailTasks[id] = nil
        }
        playlistDetailCache[id] = CachedValue(
''',
    '''        guard playlistDetailTasks[id]?.token == request.token else {
            throw CancellationError()
        }
        playlistDetailTasks[id] = nil
        playlistDetailCache[id] = CachedValue(
''',
)
replace_once(
    app,
    '''        guard artistDetailTasks[id]?.token == request.token {
            artistDetailTasks[id] = nil
        }
        artistDetailCache[id] = CachedValue(
''',
    '''        guard artistDetailTasks[id]?.token == request.token else {
            throw CancellationError()
        }
        artistDetailTasks[id] = nil
        artistDetailCache[id] = CachedValue(
''',
)

offline = Path("BuFi/Core/OfflineStore.swift")
replace_once(
    offline,
    '''                clearInFlight(
                    taskKey: taskKey,
                    scopeGeneration: existingTask.scopeGeneration,
                    songGeneration: existingTask.songGeneration
                )
                return result.url
''',
    '''                clearInFlight(
                    taskKey: taskKey,
                    scopeGeneration: existingTask.scopeGeneration,
                    songGeneration: existingTask.songGeneration
                )
                guard activeScope == scope,
                      scopeGeneration == existingTask.scopeGeneration,
                      songGenerations[song.id, default: 0] == existingTask.songGeneration,
                      FileManager.default.fileExists(atPath: result.url.path) else {
                    throw CancellationError()
                }
                return result.url
''',
)

for path in (app, offline):
    path.write_text(path.read_text().rstrip() + "\n")
