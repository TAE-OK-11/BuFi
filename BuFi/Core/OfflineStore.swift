import CryptoKit
import Foundation

actor OfflineStore {
    static let shared = OfflineStore()

    private struct Entry: Codable, Sendable {
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

    private let rootDirectory: URL
    private let wifiOnlySession: URLSession
    private let unrestrictedSession: URLSession
    private var directory: URL?
    private var indexURL: URL?
    private var activeScope: String?
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: InFlightDownload] = [:]
    private var scopeGeneration: UInt64 = 0
    private var songGenerations: [String: UInt64] = [:]
    private var indexSaveTask: Task<Void, Never>?
    private var indexIsDirty = false
    private var indexRetryCount = 0

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineMusic", isDirectory: true)
        rootDirectory = root
        wifiOnlySession = Self.makeDownloadSession(allowsExpensiveAccess: false)
        unrestrictedSession = Self.makeDownloadSession(allowsExpensiveAccess: true)
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        Self.removeLegacyUnscopedFiles(in: root)
    }

    func activate(accountScope: String) {
        guard activeScope != accountScope else { return }

        flushPendingWrites(retryOnFailure: false)
        scopeGeneration &+= 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        songGenerations.removeAll(keepingCapacity: false)
        indexRetryCount = 0

        let scopedDirectory = rootDirectory.appendingPathComponent(accountScope, isDirectory: true)
        let scopedIndexURL = scopedDirectory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(
            at: scopedDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: scopedDirectory.path
        )

        activeScope = accountScope
        directory = scopedDirectory
        indexURL = scopedIndexURL
        entries = Self.loadEntries(indexURL: scopedIndexURL, directory: scopedDirectory)
        indexIsDirty = false
    }

    func localURL(for songID: String) -> URL? {
        guard let directory else { return nil }
        if var entry = entries[songID] {
            let url = directory.appendingPathComponent(entry.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                entries[songID] = nil
                scheduleIndexPersistence()
                return nil
            }
            if Date().timeIntervalSince(entry.lastAccessedAt) > 3_600 {
                entry.lastAccessedAt = Date()
                entries[songID] = entry
                scheduleIndexPersistence()
            }
            return url
        }

        let legacy = legacyFileURL(songID: songID, directory: directory)
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }

    func isDownloaded(songID: String) -> Bool {
        localURL(for: songID) != nil
    }

    func downloadedSongs() -> [Song] {
        guard let directory else { return [] }
        let valid = entries.filter { _, entry in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(entry.fileName).path
            )
        }
        if valid.count != entries.count {
            entries = valid
            scheduleIndexPersistence()
        }
        return valid.values
            .sorted { $0.downloadedAt > $1.downloadedAt }
            .map(\.song)
    }

    func download(song: Song, client: OpenSubsonicClient) async throws -> URL {
        guard let scope = activeScope, let directory else {
            throw OpenSubsonicError.invalidResponse
        }
        if let existing = localURL(for: song.id) { return existing }

        let generation = scopeGeneration
        let songGeneration = songGenerations[song.id, default: 0]
        let taskKey = scope + ":" + song.id
        if let existingTask = inFlight[taskKey] {
            return try await existingTask.task.value.url
        }

        let remote = try await client.downloadURL(songID: song.id)
        guard remote.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        let fileName = Self.fileName(for: song)
        let destination = directory.appendingPathComponent(fileName)
        let wifiOnly = UserDefaults.standard.object(forKey: "offline-wifi-only") as? Bool ?? true
        let session = wifiOnly ? wifiOnlySession : unrestrictedSession

        let task = Task<DownloadResult, Error>(priority: .utility) {
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

            let staging = destination.appendingPathExtension("partial")
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            return DownloadResult(url: destination, byteCount: bytes)
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
            guard activeScope == scope,
                  scopeGeneration == generation,
                  songGenerations[song.id, default: 0] == songGeneration else {
                try? FileManager.default.removeItem(at: result.url)
                throw CancellationError()
            }
            let now = Date()
            entries[song.id] = Entry(
                song: song,
                fileName: fileName,
                byteCount: result.byteCount,
                downloadedAt: now,
                lastAccessedAt: now
            )
            try enforceStorageLimit(keeping: song.id)
            scheduleIndexPersistence()
            return result.url
        } catch {
            clearInFlight(
                taskKey: taskKey,
                scopeGeneration: generation,
                songGeneration: songGeneration
            )
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("partial"))
            throw error
        }
    }

    func remove(songID: String) throws {
        guard let directory else { return }
        invalidateDownload(songID: songID)
        if let entry = entries.removeValue(forKey: songID) {
            let url = directory.appendingPathComponent(entry.fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        let legacy = legacyFileURL(songID: songID, directory: directory)
        if FileManager.default.fileExists(atPath: legacy.path) {
            try FileManager.default.removeItem(at: legacy)
        }
        scheduleIndexPersistence(immediate: true)
    }

    func removeAll() throws {
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
        for file in files { try FileManager.default.removeItem(at: file) }
        entries.removeAll()
        scheduleIndexPersistence(immediate: true)
    }

    func totalBytes() -> Int64 {
        guard let directory else { return 0 }
        let indexed = entries.values.reduce(into: Int64(0)) { $0 += $1.byteCount }
        if indexed > 0 { return indexed }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return files.reduce(into: Int64(0)) { total, url in
            if let indexURL, url == indexURL { return }
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    func flushPendingWrites() {
        flushPendingWrites(retryOnFailure: true)
    }

    private func flushPendingWrites(retryOnFailure: Bool) {
        indexSaveTask?.cancel()
        indexSaveTask = nil
        persistIndexIfNeeded(retryOnFailure: retryOnFailure)
    }

    private func persistIndexIfNeeded(retryOnFailure: Bool) {
        guard indexIsDirty else { return }
        do {
            try persistIndex()
            indexIsDirty = false
            indexRetryCount = 0
        } catch {
            guard retryOnFailure else { return }
            indexRetryCount += 1
            guard indexRetryCount <= 3 else { return }
            let delay: Duration
            switch indexRetryCount {
            case 1: delay = .seconds(1)
            case 2: delay = .seconds(2)
            default: delay = .seconds(4)
            }
            scheduleIndexPersistence(retryDelay: delay, resetRetry: false)
        }
    }

    private func enforceStorageLimit(keeping protectedID: String) throws {
        guard let directory else { return }
        let configured = UserDefaults.standard.object(forKey: "offline-storage-limit-gb") as? Double ?? 10
        guard configured > 0 else { return }
        let limit = Int64(configured * 1_024 * 1_024 * 1_024)
        var total = entries.values.reduce(into: Int64(0)) { $0 += $1.byteCount }
        guard total > limit else { return }

        let candidates = entries
            .filter { $0.key != protectedID }
            .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
        for (id, entry) in candidates where total > limit {
            let url = directory.appendingPathComponent(entry.fileName)
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                entries[id] = nil
                total -= entry.byteCount
            } catch {
                // Keep the index entry when deletion fails so storage accounting
                // remains truthful and a later cleanup can retry.
            }
        }
    }

    private func scheduleIndexPersistence(
        immediate: Bool = false,
        retryDelay: Duration? = nil,
        resetRetry: Bool = true
    ) {
        indexIsDirty = true
        if resetRetry { indexRetryCount = 0 }
        indexSaveTask?.cancel()
        let generation = scopeGeneration
        let delay: Duration = retryDelay ?? (immediate ? .zero : .milliseconds(500))
        indexSaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flushScheduledIndex(for: generation)
        }
    }

    private func flushScheduledIndex(for generation: UInt64) {
        guard generation == scopeGeneration else { return }
        indexSaveTask = nil
        persistIndexIfNeeded(retryOnFailure: true)
    }

    private func invalidateDownload(songID: String) {
        songGenerations[songID, default: 0] &+= 1
        guard let activeScope else { return }
        let taskKey = activeScope + ":" + songID
        inFlight.removeValue(forKey: taskKey)?.task.cancel()
    }

    private func clearInFlight(
        taskKey: String,
        scopeGeneration: UInt64,
        songGeneration: UInt64
    ) {
        guard let current = inFlight[taskKey],
              current.scopeGeneration == scopeGeneration,
              current.songGeneration == songGeneration else {
            return
        }
        inFlight[taskKey] = nil
    }

    private func persistIndex() throws {
        guard let indexURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(
            to: indexURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func legacyFileURL(songID: String, directory: URL) -> URL {
        directory.appendingPathComponent(Self.digest(songID)).appendingPathExtension("audio")
    }

    private static func fileName(for song: Song) -> String {
        let sanitized = song.suffix?
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()
        let bounded = sanitized.map { String($0.prefix(12)) }
        let ext = (bounded?.isEmpty == false ? bounded : nil) ?? "audio"
        return digest(song.id) + "." + ext
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func loadEntries(indexURL: URL, directory: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return decoded.filter { _, entry in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(entry.fileName).path
            )
        }
    }

    private static func makeDownloadSession(allowsExpensiveAccess: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveAccess
        configuration.allowsConstrainedNetworkAccess = allowsExpensiveAccess
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: HTTPSOnlyURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    private static func removeLegacyUnscopedFiles(in root: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            let isDirectory = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
