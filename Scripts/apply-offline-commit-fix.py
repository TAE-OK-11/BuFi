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
    '''    private struct DetailRequest<Value> {
''',
    '''    private struct DetailRequest<Value: Sendable> {
''',
)

offline = Path("BuFi/Core/OfflineStore.swift")
sub_once(
    offline,
    r'''        if let existingTask = inFlight\[taskKey\] \{.*?\n        \}\n\n        let remote = try await client\.downloadURL''',
    '''        if let existingTask = inFlight[taskKey] {
            do {
                let result = try await existingTask.task.value
                clearInFlight(
                    taskKey: taskKey,
                    scopeGeneration: existingTask.scopeGeneration,
                    songGeneration: existingTask.songGeneration
                )
                return result.url
            } catch {
                clearInFlight(
                    taskKey: taskKey,
                    scopeGeneration: existingTask.scopeGeneration,
                    songGeneration: existingTask.songGeneration
                )
                throw error
            }
        }

        let remote = try await client.downloadURL''',
    flags=re.DOTALL,
)
sub_once(
    offline,
    r'''        let task = Task<DownloadResult, Error>\(priority: \.utility\) \{.*?\n        \}\n    \}\n\n(?=    func remove\(songID:)''',
    '''        let task = Task<DownloadResult, Error>(priority: .utility) { [weak self] in
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
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: temporary, to: staging)
            guard let self else {
                try? FileManager.default.removeItem(at: staging)
                throw CancellationError()
            }
            return try await self.commitDownload(
                staging: staging,
                destination: destination,
                byteCount: bytes,
                song: song,
                scope: scope,
                scopeGeneration: generation,
                songGeneration: songGeneration
            )
        }
        inFlight[taskKey] = InFlightDownload(
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
            return result.url
        } catch {
            clearInFlight(
                taskKey: taskKey,
                scopeGeneration: generation,
                songGeneration: songGeneration
            )
            throw error
        }
    }

    private func commitDownload(
        staging: URL,
        destination: URL,
        byteCount: Int64,
        song: Song,
        scope: String,
        scopeGeneration generation: UInt64,
        songGeneration: UInt64
    ) throws -> DownloadResult {
        guard activeScope == scope,
              scopeGeneration == generation,
              songGenerations[song.id, default: 0] == songGeneration else {
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
            let now = Date()
            entries[song.id] = Entry(
                song: song,
                fileName: destination.lastPathComponent,
                byteCount: byteCount,
                downloadedAt: now,
                lastAccessedAt: now
            )
            try enforceStorageLimit(keeping: song.id)
            scheduleIndexPersistence()
            return DownloadResult(url: destination, byteCount: byteCount)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

''',
    flags=re.DOTALL,
)

for name in ["BuFi/App/AppModel.swift", "BuFi/Core/OfflineStore.swift"]:
    path = Path(name)
    path.write_text(path.read_text().rstrip() + "\n")
