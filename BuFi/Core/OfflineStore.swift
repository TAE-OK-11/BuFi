import CryptoKit
import Foundation

actor OfflineStore {
    static let shared = OfflineStore()

    private struct Entry: Codable, Sendable, Equatable {
        var fileName: String
        var byteCount: Int64
        var lastAccessedAt: Date
        var mediaRevision: String?
    }

    private struct InFlightDownload: Sendable {
        let token: UUID
        let scopeGeneration: UInt64
        let mediaRevision: String?
        let source: DownloadSource
        let task: Task<URL, Error>
        var waiters: Set<UUID>
    }

    private struct StagedDownload: Sendable {
        let url: URL
        let byteCount: Int64
    }

    private let rootDirectory: URL
    private let bootstrapTask: Task<Void, Never>
    private let wifiOnlySession: URLSession
    private let unrestrictedSession: URLSession
    private var directory: URL?
    private var indexURL: URL?
    private var activeScope: String?
    private var entries: [String: Entry] = [:]
    private var inFlight: [OfflineDownloadKey: InFlightDownload] = [:]
    private var scopeGeneration: UInt64 = 0
    private var indexSaveTask: Task<Void, Never>?
    private var indexIsDirty = false
    private var indexRetryCount = 0
    private var dirtySongIDs: Set<String> = []
    private var deletedSongIDs: Set<String> = []
    private var indexMutationEpoch: UInt64 = 0
    private var accessRecency = OfflineAccessRecency()
    private var indexedByteCount: Int64 = 0

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineMusic", isDirectory: true)
        rootDirectory = root
        wifiOnlySession = Self.makeDownloadSession(allowsExpensiveAccess: false)
        unrestrictedSession = Self.makeDownloadSession(allowsExpensiveAccess: true)
        bootstrapTask = Task(priority: .utility) {
            await Self.bootstrapStorage(at: root)
        }
    }

    func activate(accountScope: String) async -> AccountSessionToken? {
        _ = await bootstrapTask.value
        if activeScope == accountScope {
            indexSaveTask?.cancel()
            indexSaveTask = nil
<<<<<<< HEAD
            scopeGeneration &+= 1
=======
>>>>>>> e185574 (Fix API, network, and database audit findings)
            if indexIsDirty {
                scheduleIndexPersistence(immediate: true)
            }
            return AccountSessionToken(
                accountScope: accountScope,
                generation: scopeGeneration
            )
        }
        let previousScope = activeScope
        indexSaveTask?.cancel()
        indexSaveTask = nil
        scopeGeneration &+= 1
        let generation = scopeGeneration
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        indexRetryCount = 0
        activeScope = nil

        if let previousScope {
            await persistIndexIfNeeded(
                retryOnFailure: false,
                scope: previousScope,
                generation: generation,
                permitsInactiveScope: true
            )
            guard generation == scopeGeneration, activeScope == nil else { return nil }
        }

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
        Self.removeOrphanedPartialFiles(in: scopedDirectory)

        let databaseEntries = await AppDatabase.shared.loadOfflineEntries(
            scope: accountScope
        )
        guard generation == scopeGeneration, activeScope == nil else { return nil }
        var loadedEntries = await Self.validatedDatabaseEntries(
            databaseEntries,
            directory: scopedDirectory
        )
        guard generation == scopeGeneration, activeScope == nil else { return nil }
        let missingDatabaseIDs = Swift.Set<String>(databaseEntries.keys).subtracting(loadedEntries.keys)
        if !missingDatabaseIDs.isEmpty {
            _ = await AppDatabase.shared.applyOfflineEntries(
                [:],
                deletedIDs: missingDatabaseIDs,
                scope: accountScope
            )
            guard generation == scopeGeneration, activeScope == nil else { return nil }
        }
        if loadedEntries.isEmpty {
            let legacyEntries = Self.loadEntries(
                indexURL: scopedIndexURL,
                directory: scopedDirectory
            )
            if !legacyEntries.isEmpty {
                loadedEntries = legacyEntries
                let migrated = legacyEntries.mapValues(Self.databaseEntry)
                if await AppDatabase.shared.replaceOfflineEntries(
                    migrated,
                    scope: accountScope
                ) {
                    guard generation == scopeGeneration, activeScope == nil else { return nil }
                    try? FileManager.default.removeItem(at: scopedIndexURL)
                }
            }
        }
        guard generation == scopeGeneration, activeScope == nil else { return nil }
        activeScope = accountScope
        directory = scopedDirectory
        indexURL = scopedIndexURL
        entries = loadedEntries
        indexedByteCount = Self.totalByteCount(of: loadedEntries.values)
        accessRecency.seed(
            lastAccess: loadedEntries.values.map(\.lastAccessedAt).max()
        )
        dirtySongIDs.removeAll(keepingCapacity: true)
        deletedSongIDs.removeAll(keepingCapacity: true)
        indexIsDirty = false
        return AccountSessionToken(
            accountScope: accountScope,
            generation: generation
        )
    }

    @discardableResult
    func deactivate(session: AccountSessionToken) async -> Bool {
        guard session.matches(
            accountScope: activeScope,
            generation: scopeGeneration
        ) else { return false }
        indexSaveTask?.cancel()
        indexSaveTask = nil
        scopeGeneration &+= 1
        let generation = scopeGeneration
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll(keepingCapacity: false)
        activeScope = nil
        await persistIndexIfNeeded(
            retryOnFailure: false,
            scope: session.accountScope,
            generation: generation,
            permitsInactiveScope: true
        )
        guard generation == scopeGeneration, activeScope == nil else { return true }
        directory = nil
        indexURL = nil
        entries.removeAll(keepingCapacity: false)
        indexedByteCount = 0
        accessRecency = OfflineAccessRecency()
        indexIsDirty = false
        indexRetryCount = 0
        dirtySongIDs.removeAll(keepingCapacity: false)
        deletedSongIDs.removeAll(keepingCapacity: false)
        return true
    }

    func localURL(for song: Song) -> URL? {
        localURL(
            for: song.id,
            expectedMediaRevision: song.offlineMediaRevision
        )
    }

    func localURL(for songID: String) -> URL? {
        localURL(for: songID, expectedMediaRevision: nil)
    }

    private func localURL(
        for songID: String,
        expectedMediaRevision: String?
    ) -> URL? {
        guard activeScope != nil, let directory else { return nil }
        if var entry = entries[songID] {
            let url = directory.appendingPathComponent(entry.fileName)
            guard Self.isValidOfflineFile(
                at: url,
                expectedByteCount: entry.byteCount
            ) else {
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                indexedByteCount = max(0, indexedByteCount - entry.byteCount)
                entries[songID] = nil
                markDeleted(songID)
                scheduleIndexPersistence()
                return nil
            }
            guard expectedMediaRevision == nil
                    || entry.mediaRevision == nil
                    || entry.mediaRevision == expectedMediaRevision else {
                // Keep the last known-good file until its replacement is
                // completely downloaded. A failed refresh must not destroy
                // offline playback that was already available.
                return nil
            }
            var entryChanged = false
            if let expectedMediaRevision, entry.mediaRevision == nil {
                // A pre-v6 cache has no revision evidence. Adopt the first
                // canonical revision after validating its bytes so an app
                // upgrade does not destroy usable offline playback; every
                // later revision mismatch is rejected.
                entry.mediaRevision = expectedMediaRevision
                entryChanged = true
            }
            let now = Date()
            if now.timeIntervalSince(entry.lastAccessedAt) > 3_600
                || now < entry.lastAccessedAt {
                entry.lastAccessedAt = accessRecency.next(
                    now: now,
                    after: entry.lastAccessedAt
                )
                entryChanged = true
            }
            if entryChanged {
                entries[songID] = entry
                markDirty(songID)
                scheduleIndexPersistence()
            }
            return url
        }

        guard expectedMediaRevision == nil else { return nil }
        let legacy = legacyFileURL(songID: songID, directory: directory)
        if Self.isValidOfflineFile(at: legacy, expectedByteCount: nil) {
            return legacy
        }
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
        }
        return nil
    }

    func download(song: Song, client: OpenSubsonicClient) async throws -> URL {
        try await download(song: song, client: client, source: .manual)
    }

    /// Idempotent playback lookahead cache. Returns whether the song is stored
    /// locally after this call, without starting duplicate transfers.
    func prefetchPlaybackCache(
        song: Song,
        client: OpenSubsonicClient
    ) async -> Bool {
        if localURL(for: song) != nil { return true }
        do {
            _ = try await download(song: song, client: client, source: .playbackPrefetch)
            return localURL(for: song) != nil
        } catch {
            return localURL(for: song) != nil
        }
    }

    private enum DownloadSource: Sendable {
        case manual
        case playbackPrefetch
    }

    private func download(
        song: Song,
        client: OpenSubsonicClient,
        source: DownloadSource
    ) async throws -> URL {
        try Task.checkCancellation()
        guard let scope = activeScope,
              client.accountScope == scope,
              let directory else {
            throw OpenSubsonicError.invalidResponse
        }
        let mediaRevision = song.offlineMediaRevision
        if let existing = localURL(for: song) { return existing }

        let generation = scopeGeneration
        let taskKey = OfflineDownloadKey(
            accountScope: scope,
            songID: song.id
        )
        if var existing = inFlight[taskKey] {
            if existing.mediaRevision == mediaRevision {
                let waiter = UUID()
                existing.waiters.insert(waiter)
                inFlight[taskKey] = existing
                return try await awaitDownload(
                    existing,
                    taskKey: taskKey,
                    waiter: waiter,
                    scope: scope
                )
            }
            if source == .playbackPrefetch, existing.source == .manual {
                let waiter = UUID()
                existing.waiters.insert(waiter)
                inFlight[taskKey] = existing
                return try await awaitDownload(
                    existing,
                    taskKey: taskKey,
                    waiter: waiter,
                    scope: scope
                )
            }
            existing.task.cancel()
            inFlight[taskKey] = nil
        }

        if source == .playbackPrefetch,
           ProcessInfo.processInfo.isLowPowerModeEnabled {
            throw CancellationError()
        }

        let fileName = Self.fileName(for: song)
        let destination = directory.appendingPathComponent(fileName)
        let wifiOnly = UserDefaults.standard.object(forKey: "offline-wifi-only") as? Bool ?? true
        let session = wifiOnly ? wifiOnlySession : unrestrictedSession
        let token = UUID()
        let waiter = UUID()
        let task = Task<URL, Error>(priority: .utility) { [weak self] in
            let remote = try client.downloadURL(songID: song.id)
            try Task.checkCancellation()
            guard remote.scheme?.lowercased() == "https" else {
                throw OpenSubsonicError.insecureServerURL
            }
            let temporary = try await Self.downloadFileWithRetry(
                remote: remote,
                session: session
            )
            try Task.checkCancellation()

            let staged = try await Self.stageDownloadedFile(
                temporary: temporary,
                directory: directory,
                fileName: fileName
            )
            try Task.checkCancellation()
            guard let self else {
                try? FileManager.default.removeItem(at: staged.url)
                throw CancellationError()
            }
            return try await self.commitDownload(
                staging: staged.url,
                destination: destination,
                byteCount: staged.byteCount,
                songID: song.id,
                mediaRevision: mediaRevision,
                scope: scope,
                scopeGeneration: generation
            )
        }
        let download = InFlightDownload(
            token: token,
            scopeGeneration: generation,
            mediaRevision: mediaRevision,
            source: source,
            task: task,
            waiters: [waiter]
        )
        inFlight[taskKey] = download

        return try await awaitDownload(
            download,
            taskKey: taskKey,
            waiter: waiter,
            scope: scope
        )
    }

    private func awaitDownload(
        _ download: InFlightDownload,
        taskKey: OfflineDownloadKey,
        waiter: UUID,
        scope: String
    ) async throws -> URL {
        do {
            let url = try await withTaskCancellationHandler {
                let url = try await download.task.value
                try Task.checkCancellation()
                return url
            } onCancel: {
                Task {
                    await self.cancelDownloadWaiter(
                        taskKey: taskKey,
                        token: download.token,
                        waiter: waiter
                    )
                }
            }
            clearInFlight(taskKey: taskKey, token: download.token)
            guard activeScope == scope,
                  scopeGeneration == download.scopeGeneration,
                  FileManager.default.fileExists(atPath: url.path) else {
                throw CancellationError()
            }
            return url
        } catch {
            if Task.isCancelled {
                // This caller no longer needs the shared transfer. Other
                // waiters must keep the in-flight entry and task coalescing.
                cancelDownloadWaiter(
                    taskKey: taskKey,
                    token: download.token,
                    waiter: waiter
                )
            } else {
                // A non-caller-cancellation error is the shared task's terminal
                // result, so a future request may start a fresh transfer.
                clearInFlight(taskKey: taskKey, token: download.token)
            }
            throw error
        }
    }

    private func commitDownload(
        staging: URL,
        destination: URL,
        byteCount: Int64,
        songID: String,
        mediaRevision: String?,
        scope: String,
        scopeGeneration generation: UInt64
    ) throws -> URL {
        do {
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        guard activeScope == scope, scopeGeneration == generation else {
            try? FileManager.default.removeItem(at: staging)
            throw CancellationError()
        }

        do {
            let previous = entries[songID]
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: staging
                )
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            if let previous {
                indexedByteCount = max(0, indexedByteCount - previous.byteCount)
                if previous.fileName != destination.lastPathComponent,
                   let directory {
                    try? FileManager.default.removeItem(
                        at: directory.appendingPathComponent(previous.fileName)
                    )
                }
            }
            entries[songID] = Entry(
                fileName: destination.lastPathComponent,
                byteCount: byteCount,
                lastAccessedAt: accessRecency.next(),
                mediaRevision: mediaRevision
            )
            indexedByteCount += byteCount
            markDirty(songID)
            try enforceStorageLimit(keeping: songID)
            scheduleIndexPersistence()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    func removeAll() async throws {
        guard let scope = activeScope, let directory else { return }
        scopeGeneration &+= 1
        let token = AccountSessionToken(
            accountScope: scope,
            generation: scopeGeneration
        )
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var firstError: Error?
        let previousIDs = Set(entries.keys)
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
        indexedByteCount = Self.totalByteCount(of: entries.values)
        accessRecency.seed(
            lastAccess: entries.values.map(\.lastAccessedAt).max()
        )
        let removedIDs = previousIDs.subtracting(entries.keys)
        if !removedIDs.isEmpty {
            _ = await AppDatabase.shared.applyOfflineEntries(
                [:],
                deletedIDs: removedIDs,
                scope: scope
            )
        }
        guard token.matches(
            accountScope: activeScope,
            generation: scopeGeneration
        ) else {
            if let firstError { throw firstError }
            return
        }
        dirtySongIDs = Set(entries.keys)
        deletedSongIDs.removeAll(keepingCapacity: true)
        scheduleIndexPersistence(immediate: true)
        if let firstError { throw firstError }
    }

    func totalBytes() -> Int64 {
        guard activeScope != nil, let directory else { return 0 }
        if !entries.isEmpty { return indexedByteCount }
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

    func availableSongIDs() -> Set<String> {
        activeScope == nil ? [] : Set(entries.keys)
    }

    func flushPendingWrites() async {
        await flushPendingWrites(retryOnFailure: true)
    }

    private func flushPendingWrites(retryOnFailure: Bool) async {
        indexSaveTask?.cancel()
        indexSaveTask = nil
        guard let scope = activeScope else { return }
        let generation = scopeGeneration
        while AccountSessionToken(
            accountScope: scope,
            generation: generation
        ).matches(accountScope: activeScope, generation: scopeGeneration),
              indexIsDirty {
            let beforeDirty = dirtySongIDs
            let beforeDeleted = deletedSongIDs
            let beforeEpoch = indexMutationEpoch
            await persistIndexIfNeeded(
                retryOnFailure: retryOnFailure,
                scope: scope,
                generation: generation
            )
            guard dirtySongIDs != beforeDirty
                    || deletedSongIDs != beforeDeleted
                    || indexMutationEpoch != beforeEpoch else {
                break
            }
        }
    }

    private func persistIndexIfNeeded(
        retryOnFailure: Bool,
        scope: String,
        generation: UInt64,
        permitsInactiveScope: Bool = false
    ) async {
        let ownsGeneration = permitsInactiveScope
            ? activeScope == nil && scopeGeneration == generation
            : AccountSessionToken(
                accountScope: scope,
                generation: generation
            ).matches(accountScope: activeScope, generation: scopeGeneration)
        guard ownsGeneration, indexIsDirty else { return }
        if await persistIndex(
            scope: scope,
            generation: generation,
            permitsInactiveScope: permitsInactiveScope
        ) {
            indexIsDirty = !dirtySongIDs.isEmpty || !deletedSongIDs.isEmpty
            indexRetryCount = 0
        } else {
            let stillOwnsGeneration = permitsInactiveScope
                ? activeScope == nil && scopeGeneration == generation
                : AccountSessionToken(
                    accountScope: scope,
                    generation: generation
                ).matches(accountScope: activeScope, generation: scopeGeneration)
            guard stillOwnsGeneration else { return }
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
        var total = indexedByteCount
        guard total > limit else { return }

        let excess = total - limit
        let averageEntrySize = max(1, total / Int64(max(entries.count, 1)))
        let estimatedEvictions = Int(excess / averageEntrySize) + 1
        if estimatedEvictions < entries.count / 4 {
            while total > limit {
                guard let oldest = oldestEvictionCandidate(excluding: protectedID) else { break }
                try evictEntry(
                    id: oldest.id,
                    entry: oldest.entry,
                    directory: directory,
                    total: &total
                )
            }
            return
        }

        let candidates = entries
            .filter { $0.key != protectedID }
            .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
        for (id, entry) in candidates where total > limit {
            try evictEntry(
                id: id,
                entry: entry,
                directory: directory,
                total: &total
            )
        }
    }

    private func oldestEvictionCandidate(
        excluding protectedID: String
    ) -> (id: String, entry: Entry)? {
        var oldestID: String?
        var oldestDate = Date.distantFuture
        for (id, entry) in entries where id != protectedID {
            if entry.lastAccessedAt < oldestDate {
                oldestDate = entry.lastAccessedAt
                oldestID = id
            }
        }
        guard let oldestID, let entry = entries[oldestID] else { return nil }
        return (oldestID, entry)
    }

    private func evictEntry(
        id: String,
        entry: Entry,
        directory: URL,
        total: inout Int64
    ) throws {
        let url = directory.appendingPathComponent(entry.fileName)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            entries[id] = nil
            markDeleted(id)
            total -= entry.byteCount
            indexedByteCount = max(0, indexedByteCount - entry.byteCount)
        } catch {
            // Keep the index entry when deletion fails so storage accounting
            // remains truthful and a later cleanup can retry.
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

    private func flushScheduledIndex(for generation: UInt64) async {
        guard generation == scopeGeneration, let scope = activeScope else { return }
        indexSaveTask = nil
        await persistIndexIfNeeded(
            retryOnFailure: true,
            scope: scope,
            generation: generation
        )
    }

    private func clearInFlight(taskKey: OfflineDownloadKey, token: UUID) {
        guard inFlight[taskKey]?.token == token else { return }
        inFlight[taskKey] = nil
    }

    private func cancelDownloadWaiter(
        taskKey: OfflineDownloadKey,
        token: UUID,
        waiter: UUID
    ) {
        guard var download = inFlight[taskKey],
              download.token == token else {
            return
        }
        download.waiters.remove(waiter)
        guard download.waiters.isEmpty else {
            inFlight[taskKey] = download
            return
        }
        download.task.cancel()
        inFlight[taskKey] = nil
    }

    private func persistIndex(
        scope: String,
        generation: UInt64,
        permitsInactiveScope: Bool
    ) async -> Bool {
        let token = AccountSessionToken(
            accountScope: scope,
            generation: generation
        )
        guard permitsInactiveScope
                ? activeScope == nil && scopeGeneration == generation
                : token.matches(
                    accountScope: activeScope,
                    generation: scopeGeneration
                ) else { return false }
        let dirty = Dictionary(uniqueKeysWithValues: dirtySongIDs.compactMap { id in
            entries[id].map { (id, Self.databaseEntry($0)) }
        })
        let deleted = deletedSongIDs
        guard await AppDatabase.shared.applyOfflineEntries(
            dirty,
            deletedIDs: deleted,
            scope: scope
        ) else { return false }
        guard permitsInactiveScope
                ? activeScope == nil && scopeGeneration == generation
                : token.matches(
                    accountScope: activeScope,
                    generation: scopeGeneration
                ) else { return false }
        // A read or download can update an entry while the database actor is
        // writing. Do not clear a newer value merely because an older snapshot
        // completed successfully.
        for (id, savedValue) in dirty
            where entries[id].map(Self.databaseEntry) == savedValue {
            dirtySongIDs.remove(id)
        }
        for id in deleted where entries[id] == nil {
            deletedSongIDs.remove(id)
        }
        if let indexURL { try? FileManager.default.removeItem(at: indexURL) }
        return true
    }

    private func legacyFileURL(songID: String, directory: URL) -> URL {
        directory.appendingPathComponent(Self.digest(songID)).appendingPathExtension("audio")
    }

    @concurrent
    private static func bootstrapStorage(at root: URL) async {
        guard !Task.isCancelled else { return }
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication
            ]
        )
        guard !Task.isCancelled else { return }
        removeLegacyUnscopedFiles(in: root)
    }

    private static func removeOrphanedPartialFiles(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for fileURL in files where fileURL.lastPathComponent.contains(".partial") {
            try? FileManager.default.removeItem(at: fileURL)
        }
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

    @concurrent
    private static func validatedDatabaseEntries(
        _ databaseEntries: [String: OfflineDatabaseEntry],
        directory: URL
    ) async -> [String: Entry] {
        guard !Task.isCancelled else { return [:] }
        return databaseEntries.reduce(into: [String: Entry]()) { result, pair in
            guard !Task.isCancelled else { return }
            let entry = Entry(
                fileName: pair.value.fileName,
                byteCount: pair.value.byteCount,
                lastAccessedAt: pair.value.lastAccessedAt,
                mediaRevision: pair.value.mediaRevision
            )
            let fileURL = directory.appendingPathComponent(entry.fileName)
            if Self.isValidOfflineFile(
                at: fileURL,
                expectedByteCount: entry.byteCount
            ) {
                result[pair.key] = entry
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private static func downloadFileWithRetry(
        remote: URL,
        session: URLSession
    ) async throws -> URL {
        let retryPolicy = ReadRequestRetryPolicy()
        var retryCount = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: remote)
            ModernNetworkPolicy.prepareBackgroundMediaRequest(&request)
            do {
                let (temporary, response) = try await session.download(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw OpenSubsonicError.invalidResponse
                }
                guard http.url?.scheme?.lowercased() == "https" else {
                    throw OpenSubsonicError.insecureServerURL
                }
                if (200..<300).contains(http.statusCode) {
                    return temporary
                }
                try? FileManager.default.removeItem(at: temporary)
                let error = OpenSubsonicError.http(http.statusCode)
                guard retryCount < ReadRequestRetryPolicy.maximumRetryCount,
                      retryPolicy.shouldRetry(error: error),
                      let delay = retryPolicy.delay(
                        retryNumber: retryCount + 1,
                        retryAfterHeader: http.value(
                            forHTTPHeaderField: "Retry-After"
                        ),
                        jitter: Double.random(in: 0.75...1.25)
                      ) else {
                    throw error
                }
                retryCount += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as OpenSubsonicError {
                // HTTP status handling above already consumed the bounded
                // retry decision, including Retry-After. Do not catch the
                // terminal status again as a headerless transport retry.
                throw error
            } catch {
                guard retryCount < ReadRequestRetryPolicy.maximumRetryCount,
                      retryPolicy.shouldRetry(error: error),
                      let delay = retryPolicy.delay(
                        retryNumber: retryCount + 1,
                        retryAfterHeader: nil,
                        jitter: Double.random(in: 0.75...1.25)
                      ) else {
                    throw error
                }
                retryCount += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    @concurrent
    private static func stageDownloadedFile(
        temporary: URL,
        directory: URL,
        fileName: String
    ) async throws -> StagedDownload {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(
            atPath: temporary.path
        )
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            throw URLError(.zeroByteResource)
        }

        let staging = directory.appendingPathComponent(
            fileName + "." + UUID().uuidString + ".partial"
        )
        do {
            try FileManager.default.moveItem(at: temporary, to: staging)
            try Task.checkCancellation()
            return StagedDownload(
                url: staging,
                byteCount: size.int64Value
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func loadEntries(indexURL: URL, directory: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return decoded.filter { _, entry in
            isValidOfflineFile(
                at: directory.appendingPathComponent(entry.fileName),
                expectedByteCount: entry.byteCount
            )
        }
    }

    nonisolated static func isValidOfflineFile(
        at url: URL,
        expectedByteCount: Int64?
    ) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ),
        let fileType = attributes[.type] as? FileAttributeType,
        fileType == .typeRegular,
        let fileSizeNumber = attributes[.size] as? NSNumber else {
            return false
        }
        let fileSize = fileSizeNumber.int64Value
        guard fileSize > 0 else { return false }
        guard let expectedByteCount else { return true }
        return expectedByteCount > 0 && fileSize == expectedByteCount
    }

    private func markDirty(_ songID: String) {
        indexMutationEpoch &+= 1
        dirtySongIDs.insert(songID)
        deletedSongIDs.remove(songID)
    }

    private func markDeleted(_ songID: String) {
        indexMutationEpoch &+= 1
        deletedSongIDs.insert(songID)
        dirtySongIDs.remove(songID)
    }

    private static func databaseEntry(_ entry: Entry) -> OfflineDatabaseEntry {
        OfflineDatabaseEntry(
            fileName: entry.fileName,
            byteCount: entry.byteCount,
            lastAccessedAt: entry.lastAccessedAt,
            mediaRevision: entry.mediaRevision
        )
    }

    private static func totalByteCount(
        of entries: Dictionary<String, Entry>.Values
    ) -> Int64 {
        entries.reduce(into: Int64(0)) { total, entry in
            let (next, overflow) = total.addingReportingOverflow(entry.byteCount)
            total = overflow ? Int64.max : next
        }
    }

    private static func makeDownloadSession(allowsExpensiveAccess: Bool) -> URLSession {
        let configuration = ModernNetworkPolicy.makeEphemeralConfiguration(
            requestTimeout: 30,
            resourceTimeout: 60 * 60,
            // Offline media is optional background work. One transfer per
            // origin avoids competing with AVPlayer for server, radio, and
            // thermal headroom while still benefiting from HTTP multiplexing.
            maximumConnectionsPerHost: 1,
            allowsExpensiveNetworkAccess: allowsExpensiveAccess,
            allowsConstrainedNetworkAccess: allowsExpensiveAccess
        )
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
