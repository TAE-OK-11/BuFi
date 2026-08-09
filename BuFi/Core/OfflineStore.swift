import CryptoKit
import Foundation

protocol OfflineEntryPersistence: Sendable {
    func loadOfflineEntries(scope: String) async -> [String: OfflineDatabaseEntry]

    func applyOfflineEntries(
        _ values: [String: OfflineDatabaseEntry],
        deletedIDs: Set<String>,
        scope: String
    ) async -> Bool

    func replaceOfflineEntries(
        _ values: [String: OfflineDatabaseEntry],
        scope: String
    ) async -> Bool

    func clearOfflineEntries(scope: String) async
}

extension AppDatabase: OfflineEntryPersistence {}

actor OfflineStore {
    static let shared = OfflineStore()

    private struct Entry: Codable, Sendable, Equatable {
        var fileName: String
        var byteCount: Int64
        var lastAccessedAt: Date
    }

    private struct InFlightDownload: Sendable {
        let token: UUID
        let scopeGeneration: UInt64
        let task: Task<URL, Error>
        var waiters: Set<UUID>
    }

    private let rootDirectory: URL
    private let wifiOnlySession: URLSession
    private let unrestrictedSession: URLSession
    private let database: any OfflineEntryPersistence
    private var directory: URL?
    private var indexURL: URL?
    private var activeScope: String?
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: InFlightDownload] = [:]
    private var scopeGeneration: UInt64 = 0
    private var scopeTransitionGeneration: UInt64?
    private var indexSaveTask: Task<Void, Never>?
    private var indexIsDirty = false
    private var indexRetryCount = 0
    private var dirtySongIDs: Set<String> = []
    private var deletedSongIDs: Set<String> = []

    init(
        database: any OfflineEntryPersistence = AppDatabase.shared,
        storageRoot: URL? = nil
    ) {
        let root = storageRoot ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("OfflineMusic", isDirectory: true)
        rootDirectory = root
        self.database = database
        wifiOnlySession = Self.makeDownloadSession(allowsExpensiveAccess: false)
        unrestrictedSession = Self.makeDownloadSession(allowsExpensiveAccess: true)
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        Self.removeLegacyUnscopedFiles(in: root)
    }

    @discardableResult
    func activate(accountScope: String) async -> Bool {
        guard activeScope != accountScope || scopeTransitionGeneration != nil else {
            return true
        }

        let previousScope = activeScope
        let generation = beginScopeTransition()
        if let previousScope {
            let persisted = await persistPendingWritesForTransition(
                scope: previousScope,
                generation: generation
            )
            guard isCurrentTransition(generation) else { return false }
            guard persisted, !Task.isCancelled else {
                abortScopeTransition(generation)
                return false
            }
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

        activeScope = accountScope
        directory = scopedDirectory
        indexURL = scopedIndexURL
        entries.removeAll(keepingCapacity: false)
        dirtySongIDs.removeAll(keepingCapacity: true)
        deletedSongIDs.removeAll(keepingCapacity: true)
        indexIsDirty = false
        indexRetryCount = 0

        let databaseEntries = await database.loadOfflineEntries(
            scope: accountScope
        )
        guard isCurrentTransition(
            generation,
            accountScope: accountScope
        ) else { return false }

        var loadedEntries = databaseEntries.reduce(into: [String: Entry]()) { result, pair in
            let entry = Entry(
                fileName: pair.value.fileName,
                byteCount: pair.value.byteCount,
                lastAccessedAt: pair.value.lastAccessedAt
            )
            if FileManager.default.fileExists(
                atPath: scopedDirectory.appendingPathComponent(entry.fileName).path
            ) {
                result[pair.key] = entry
            }
        }
        let missingDatabaseIDs = Set(databaseEntries.keys).subtracting(
            loadedEntries.keys
        )
        if !missingDatabaseIDs.isEmpty {
            _ = await database.applyOfflineEntries(
                [:],
                deletedIDs: missingDatabaseIDs,
                scope: accountScope
            )
            guard isCurrentTransition(
                generation,
                accountScope: accountScope
            ) else { return false }
        }
        if loadedEntries.isEmpty {
            let legacyEntries = Self.loadEntries(
                indexURL: scopedIndexURL,
                directory: scopedDirectory
            )
            if !legacyEntries.isEmpty {
                let migrated = legacyEntries.mapValues(Self.databaseEntry)
                if await database.replaceOfflineEntries(
                    migrated,
                    scope: accountScope
                ) {
                    try? FileManager.default.removeItem(at: scopedIndexURL)
                }
                guard isCurrentTransition(
                    generation,
                    accountScope: accountScope
                ) else { return false }
                loadedEntries = legacyEntries
            }
        }
        guard isCurrentTransition(
            generation,
            accountScope: accountScope
        ) else { return false }
        entries = loadedEntries
        dirtySongIDs.removeAll(keepingCapacity: true)
        deletedSongIDs.removeAll(keepingCapacity: true)
        indexIsDirty = false
        scopeTransitionGeneration = nil
        return true
    }

    func isActive(accountScope: String) -> Bool {
        activeScope == accountScope && scopeTransitionGeneration == nil
    }

    func deactivate(accountScope: String) async {
        guard activeScope == accountScope else { return }
        let generation = beginScopeTransition()
        let persisted = await persistPendingWritesForTransition(
            scope: accountScope,
            generation: generation
        )
        guard isCurrentTransition(
            generation,
            accountScope: accountScope
        ) else { return }
        guard persisted, !Task.isCancelled else {
            abortScopeTransition(generation)
            return
        }
        activeScope = nil
        directory = nil
        indexURL = nil
        entries.removeAll(keepingCapacity: false)
        indexIsDirty = false
        indexRetryCount = 0
        dirtySongIDs.removeAll(keepingCapacity: false)
        deletedSongIDs.removeAll(keepingCapacity: false)
        scopeTransitionGeneration = nil
    }

    func localURL(for songID: String) -> URL? {
        guard scopeTransitionGeneration == nil, let directory else { return nil }
        if var entry = entries[songID] {
            let url = directory.appendingPathComponent(entry.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                entries[songID] = nil
                markDeleted(songID)
                scheduleIndexPersistence()
                return nil
            }
            if Date().timeIntervalSince(entry.lastAccessedAt) > 3_600 {
                entry.lastAccessedAt = Date()
                entries[songID] = entry
                markDirty(songID)
                scheduleIndexPersistence()
            }
            return url
        }

        let legacy = legacyFileURL(songID: songID, directory: directory)
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }

    func download(
        song: Song,
        client: OpenSubsonicClient,
        expectedAccountScope: String
    ) async throws -> URL {
        try Task.checkCancellation()
        guard scopeTransitionGeneration == nil,
              let scope = activeScope,
              scope == expectedAccountScope,
              AccountScope.identifier(for: client.credentials) == expectedAccountScope,
              let directory else {
            throw CancellationError()
        }
        if let existing = localURL(for: song.id) { return existing }

        let generation = scopeGeneration
        let taskKey = scope + ":" + song.id
        if var existing = inFlight[taskKey],
           existing.scopeGeneration == generation {
            let waiter = UUID()
            existing.waiters.insert(waiter)
            inFlight[taskKey] = existing
            return try await awaitDownload(
                existing,
                taskKey: taskKey,
                waiter: waiter,
                scope: scope
            )
        } else if let stale = inFlight.removeValue(forKey: taskKey) {
            stale.task.cancel()
        }

        let fileName = Self.fileName(for: song)
        let destination = directory.appendingPathComponent(fileName)
        let wifiOnly = UserDefaults.standard.object(forKey: "offline-wifi-only") as? Bool ?? true
        let session = wifiOnly ? wifiOnlySession : unrestrictedSession
        let token = UUID()
        let waiter = UUID()
        let task = Task<URL, Error>(priority: .utility) { [weak self] in
            let remote = try await client.downloadURL(songID: song.id)
            try Task.checkCancellation()
            guard remote.scheme?.lowercased() == "https" else {
                throw OpenSubsonicError.insecureServerURL
            }
            var request = URLRequest(url: remote)
            ModernNetworkPolicy.prepareMediaRequest(&request)
            let (temporary, response) = try await session.download(for: request)
            try Task.checkCancellation()
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
            do {
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
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
        let download = InFlightDownload(
            token: token,
            scopeGeneration: generation,
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
        taskKey: String,
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
                  scopeTransitionGeneration == nil,
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
        scope: String,
        scopeGeneration generation: UInt64
    ) throws -> URL {
        do {
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        guard activeScope == scope,
              scopeGeneration == generation,
              scopeTransitionGeneration == nil else {
            try? FileManager.default.removeItem(at: staging)
            throw CancellationError()
        }

        if let limit = configuredStorageLimitBytes(), byteCount > limit {
            try? FileManager.default.removeItem(at: staging)
            throw URLError(.dataLengthExceedsMaximum)
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
        guard scopeTransitionGeneration == nil,
              let scope = activeScope,
              let directory else { return }
        scopeGeneration &+= 1
        let generation = scopeGeneration
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
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
        await database.clearOfflineEntries(scope: scope)
        guard activeScope == scope,
              scopeGeneration == generation,
              scopeTransitionGeneration == nil else {
            if let firstError { throw firstError }
            return
        }
        dirtySongIDs = Set(entries.keys)
        deletedSongIDs.removeAll(keepingCapacity: true)
        scheduleIndexPersistence(immediate: true)
        if let firstError { throw firstError }
    }

    func totalBytes() -> Int64 {
        guard scopeTransitionGeneration == nil, let directory else { return 0 }
        let indexed = Self.totalByteCount(
            entries.values.lazy.map(\.byteCount)
        )
        if indexed > 0 { return indexed }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return Self.totalByteCount(files.lazy.compactMap { url in
            if let indexURL, url == indexURL { return nil }
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey]
            )
            return Int64(values?.fileSize ?? 0)
        })
    }

    func availableSongIDs() -> Set<String> {
        scopeTransitionGeneration == nil ? Set(entries.keys) : []
    }

    func flushPendingWrites() async {
        await flushPendingWrites(retryOnFailure: true)
    }

    private func flushPendingWrites(retryOnFailure: Bool) async {
        indexSaveTask?.cancel()
        indexSaveTask = nil
        guard let scope = activeScope else { return }
        await flushPendingWrites(
            retryOnFailure: retryOnFailure,
            scope: scope,
            generation: scopeGeneration
        )
    }

    private func flushPendingWrites(
        retryOnFailure: Bool,
        scope: String,
        generation: UInt64
    ) async {
        indexSaveTask?.cancel()
        indexSaveTask = nil
        await persistIndexIfNeeded(
            retryOnFailure: retryOnFailure,
            scope: scope,
            generation: generation
        )
    }

    private func persistIndexIfNeeded(
        retryOnFailure: Bool,
        scope: String,
        generation: UInt64
    ) async {
        guard activeScope == scope,
              scopeGeneration == generation,
              hasPendingIndexWrites else { return }
        indexIsDirty = true
        switch await persistIndex(scope: scope, generation: generation) {
        case .saved:
            indexRetryCount = 0
            if indexIsDirty {
                scheduleIndexPersistence(
                    immediate: true,
                    resetRetry: false
                )
            }
        case .failed:
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
        case .stale:
            return
        }
    }

    private static let maximumTransitionPersistenceRetryCount = 2

    private func persistPendingWritesForTransition(
        scope: String,
        generation: UInt64
    ) async -> Bool {
        var retryCount = 0
        while activeScope == scope,
              scopeGeneration == generation,
              hasPendingIndexWrites {
            indexIsDirty = true
            switch await persistIndex(
                scope: scope,
                generation: generation
            ) {
            case .saved:
                retryCount = 0
            case .failed:
                guard retryCount < Self.maximumTransitionPersistenceRetryCount else {
                    return false
                }
                retryCount += 1
                let delay: Duration = retryCount == 1
                    ? .milliseconds(250)
                    : .milliseconds(750)
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return false
                }
            case .stale:
                return false
            }
        }
        return activeScope == scope
            && scopeGeneration == generation
            && !hasPendingIndexWrites
    }

    private func enforceStorageLimit(keeping protectedID: String) throws {
        guard let directory else { return }
        guard let limit = configuredStorageLimitBytes() else { return }
        var total = Self.totalByteCount(entries.values.lazy.map(\.byteCount))
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
                markDeleted(id)
                total = max(0, total - max(0, entry.byteCount))
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
        guard activeScope != nil, scopeTransitionGeneration == nil else { return }
        indexIsDirty = true
        if resetRetry { indexRetryCount = 0 }
        indexSaveTask?.cancel()
        let generation = scopeGeneration
        let scope = activeScope
        let delay: Duration = retryDelay ?? (immediate ? .zero : .milliseconds(500))
        indexSaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flushScheduledIndex(
                for: generation,
                scope: scope
            )
        }
    }

    private func flushScheduledIndex(
        for generation: UInt64,
        scope: String?
    ) async {
        guard let scope,
              activeScope == scope,
              generation == scopeGeneration,
              scopeTransitionGeneration == nil else { return }
        indexSaveTask = nil
        await persistIndexIfNeeded(
            retryOnFailure: true,
            scope: scope,
            generation: generation
        )
    }

    private func clearInFlight(taskKey: String, token: UUID) {
        guard inFlight[taskKey]?.token == token else { return }
        inFlight[taskKey] = nil
    }

    private func cancelDownloadWaiter(
        taskKey: String,
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

    private enum PersistenceAttempt {
        case saved
        case failed
        case stale
    }

    private func persistIndex(
        scope: String,
        generation: UInt64
    ) async -> PersistenceAttempt {
        guard activeScope == scope, scopeGeneration == generation else {
            return .stale
        }
        let dirty = Dictionary(uniqueKeysWithValues: dirtySongIDs.compactMap { id in
            entries[id].map { (id, Self.databaseEntry($0)) }
        })
        let deleted = deletedSongIDs
        let legacyIndexURL = indexURL
        let saved = await database.applyOfflineEntries(
            dirty,
            deletedIDs: deleted,
            scope: scope
        )
        guard activeScope == scope, scopeGeneration == generation else {
            return .stale
        }
        guard saved else { return .failed }
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
        indexIsDirty = !dirtySongIDs.isEmpty || !deletedSongIDs.isEmpty
        if let legacyIndexURL {
            try? FileManager.default.removeItem(at: legacyIndexURL)
        }
        return .saved
    }

    private func beginScopeTransition() -> UInt64 {
        scopeGeneration &+= 1
        let generation = scopeGeneration
        scopeTransitionGeneration = generation
        indexSaveTask?.cancel()
        indexSaveTask = nil
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll(keepingCapacity: false)
        return generation
    }

    private func abortScopeTransition(_ generation: UInt64) {
        guard isCurrentTransition(generation) else { return }
        scopeTransitionGeneration = nil
        if hasPendingIndexWrites {
            scheduleIndexPersistence(
                retryDelay: .seconds(1),
                resetRetry: false
            )
        }
    }

    private func isCurrentTransition(
        _ generation: UInt64,
        accountScope: String? = nil
    ) -> Bool {
        guard scopeGeneration == generation,
              scopeTransitionGeneration == generation else {
            return false
        }
        return accountScope.map { activeScope == $0 } ?? true
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

    private func markDirty(_ songID: String) {
        dirtySongIDs.insert(songID)
        deletedSongIDs.remove(songID)
    }

    private func markDeleted(_ songID: String) {
        deletedSongIDs.insert(songID)
        dirtySongIDs.remove(songID)
    }

    private var hasPendingIndexWrites: Bool {
        indexIsDirty || !dirtySongIDs.isEmpty || !deletedSongIDs.isEmpty
    }

    private func configuredStorageLimitBytes() -> Int64? {
        let configured = UserDefaults.standard.object(
            forKey: "offline-storage-limit-gb"
        ) as? Double
        return Self.effectiveStorageLimitBytes(
            configuredGigabytes: configured
        )
    }

    static func effectiveStorageLimitBytes(
        configuredGigabytes: Double?
    ) -> Int64? {
        let defaultGigabytes = 10.0
        let configured = configuredGigabytes ?? defaultGigabytes
        let safeConfiguration = configured.isFinite
            ? configured
            : defaultGigabytes
        return storageLimitBytes(configuredGigabytes: safeConfiguration)
    }

    static func storageLimitBytes(
        configuredGigabytes: Double
    ) -> Int64? {
        guard configuredGigabytes.isFinite,
              configuredGigabytes > 0 else { return nil }
        let bytes = configuredGigabytes * 1_024 * 1_024 * 1_024
        if !bytes.isFinite || bytes >= Double(Int64.max) {
            return Int64.max
        }
        return max(1, Int64(bytes.rounded(.down)))
    }

    private static func totalByteCount<Values: Sequence>(
        _ values: Values
    ) -> Int64 where Values.Element == Int64 {
        values.reduce(into: Int64(0)) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(max(0, value))
            total = overflow ? .max : sum
        }
    }

    private static func databaseEntry(_ entry: Entry) -> OfflineDatabaseEntry {
        OfflineDatabaseEntry(
            fileName: entry.fileName,
            byteCount: entry.byteCount,
            lastAccessedAt: entry.lastAccessedAt
        )
    }

    private static func makeDownloadSession(allowsExpensiveAccess: Bool) -> URLSession {
        let configuration = ModernNetworkPolicy.makeEphemeralConfiguration(
            requestTimeout: 30,
            resourceTimeout: 60 * 60,
            maximumConnectionsPerHost: 2,
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
