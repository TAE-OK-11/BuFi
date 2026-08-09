import Foundation
import GRDB

struct OfflineDatabaseEntry: Sendable, Equatable {
    var fileName: String
    var byteCount: Int64
    var lastAccessedAt: Date
}

private struct ArtworkPaletteCacheKey: Hashable, Sendable {
    let scope: String
    let artworkKey: String
    let engineVersion: Int
}

actor AppDatabase {
    static let shared = AppDatabase()

    private let pool: DatabasePool?
    private let currentDate: @Sendable () -> Date
    private let artworkPaletteTouchDelay: Duration
    private var pendingArtworkPaletteTouches: Set<ArtworkPaletteCacheKey> = []
    private var artworkPaletteTouchTask: Task<Void, Never>?
    private var artworkPaletteTouchTaskToken: UUID?
    private var artworkPaletteTouchRetryCount = 0

    private init() {
        currentDate = { Date() }
        artworkPaletteTouchDelay = .milliseconds(1_500)
        do {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            let directory = support.appendingPathComponent("Database", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ]
            )
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path
            )

            pool = try Self.makePool(
                path: directory.appendingPathComponent("BuFi.sqlite").path
            )
        } catch {
            assertionFailure("Database initialization failed: \(error)")
            pool = nil
        }
    }

    init(
        databaseURL: URL,
        currentDate: @escaping @Sendable () -> Date = { Date() },
        artworkPaletteTouchDelay: Duration = .milliseconds(1_500)
    ) throws {
        self.currentDate = currentDate
        self.artworkPaletteTouchDelay = artworkPaletteTouchDelay
        pool = try Self.makePool(path: databaseURL.path)
    }

    func loadListeningHistory(scope: String) async -> [String: SongBehavior] {
        guard let pool else { return [:] }
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM listening_behavior
                    WHERE account_scope = ?
                    """,
                    arguments: [scope]
                )
                return try Dictionary(uniqueKeysWithValues: rows.map { row in
                    let songID: String = row["song_id"]
                    let songData: Data = row["song_data"]
                    let song = try Self.decode(Song.self, from: songData)
                    let behavior = SongBehavior(
                        song: song,
                        playCount: row["play_count"],
                        firstPlayed: Self.date(row["first_played"]),
                        lastPlayed: Self.date(row["last_played"]),
                        completedCount: row["completed_count"],
                        skipCount: row["skip_count"],
                        earlySkipCount: row["early_skip_count"],
                        repeatedSkipCount: row["repeated_skip_count"],
                        repeatCount: row["repeat_count"],
                        manualPlayCount: row["manual_play_count"],
                        searchPlayCount: row["search_play_count"],
                        albumSelectionCount: row["album_selection_count"],
                        playlistPlayCount: row["playlist_play_count"],
                        autoplayCount: row["autoplay_count"],
                        queueRemovalCount: row["queue_removal_count"],
                        playlistAddCount: row["playlist_add_count"],
                        favoriteCount: row["favorite_count"],
                        totalCompletion: row["total_completion"],
                        completionSamples: row["completion_samples"],
                        consecutiveSkips: row["consecutive_skips"]
                    )
                    return (songID, behavior)
                })
            }
        } catch {
            return [:]
        }
    }

    @discardableResult
    func applyListeningHistory(
        _ values: [String: SongBehavior],
        deletedIDs: Set<String>,
        scope: String
    ) async -> Bool {
        guard let pool else { return false }
        do {
            try await pool.write { db in
                for id in deletedIDs {
                    try db.execute(
                        sql: "DELETE FROM listening_behavior WHERE account_scope = ? AND song_id = ?",
                        arguments: [scope, id]
                    )
                }
                for (id, value) in values {
                    let songData = try Self.encode(value.song)
                    try db.execute(
                        sql: Self.listeningUpsertSQL,
                        arguments: [
                            scope, id, songData, value.playCount,
                            value.firstPlayed.timeIntervalSince1970,
                            value.lastPlayed.timeIntervalSince1970,
                            value.completedCount, value.skipCount,
                            value.earlySkipCount, value.repeatedSkipCount,
                            value.repeatCount, value.manualPlayCount,
                            value.searchPlayCount, value.albumSelectionCount,
                            value.playlistPlayCount, value.autoplayCount,
                            value.queueRemovalCount, value.playlistAddCount,
                            value.favoriteCount, value.totalCompletion,
                            value.completionSamples, value.consecutiveSkips
                        ]
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func replaceListeningHistory(
        _ values: [String: SongBehavior],
        scope: String
    ) async -> Bool {
        guard let pool else { return false }
        do {
            try await pool.write { db in
                try db.execute(
                    sql: "DELETE FROM listening_behavior WHERE account_scope = ?",
                    arguments: [scope]
                )
                for (id, value) in values {
                    let songData = try Self.encode(value.song)
                    try db.execute(
                        sql: Self.listeningUpsertSQL,
                        arguments: [
                            scope, id, songData, value.playCount,
                            value.firstPlayed.timeIntervalSince1970,
                            value.lastPlayed.timeIntervalSince1970,
                            value.completedCount, value.skipCount,
                            value.earlySkipCount, value.repeatedSkipCount,
                            value.repeatCount, value.manualPlayCount,
                            value.searchPlayCount, value.albumSelectionCount,
                            value.playlistPlayCount, value.autoplayCount,
                            value.queueRemovalCount, value.playlistAddCount,
                            value.favoriteCount, value.totalCompletion,
                            value.completionSamples, value.consecutiveSkips
                        ]
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    func clearListeningHistory(scope: String) async {
        try? await pool?.write { db in
            try db.execute(
                sql: "DELETE FROM listening_behavior WHERE account_scope = ?",
                arguments: [scope]
            )
        }
    }

    func loadOfflineEntries(scope: String) async -> [String: OfflineDatabaseEntry] {
        guard let pool else { return [:] }
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM offline_entry WHERE account_scope = ?",
                    arguments: [scope]
                )
                return Dictionary(uniqueKeysWithValues: rows.map { row in
                    let id: String = row["song_id"]
                    return (id, OfflineDatabaseEntry(
                        fileName: row["file_name"],
                        byteCount: row["byte_count"],
                        lastAccessedAt: Self.date(row["last_accessed_at"])
                    ))
                })
            }
        } catch {
            return [:]
        }
    }

    @discardableResult
    func applyOfflineEntries(
        _ values: [String: OfflineDatabaseEntry],
        deletedIDs: Set<String>,
        scope: String
    ) async -> Bool {
        guard let pool else { return false }
        do {
            try await pool.write { db in
                for id in deletedIDs {
                    try db.execute(
                        sql: "DELETE FROM offline_entry WHERE account_scope = ? AND song_id = ?",
                        arguments: [scope, id]
                    )
                }
                for (id, value) in values {
                    try db.execute(
                        sql: """
                        INSERT INTO offline_entry
                            (account_scope, song_id, file_name, byte_count, last_accessed_at)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(account_scope, song_id) DO UPDATE SET
                            file_name = excluded.file_name,
                            byte_count = excluded.byte_count,
                            last_accessed_at = excluded.last_accessed_at
                        """,
                        arguments: [
                            scope, id, value.fileName, value.byteCount,
                            value.lastAccessedAt.timeIntervalSince1970
                        ]
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func replaceOfflineEntries(
        _ values: [String: OfflineDatabaseEntry],
        scope: String
    ) async -> Bool {
        guard let pool else { return false }
        do {
            try await pool.write { db in
                try db.execute(
                    sql: "DELETE FROM offline_entry WHERE account_scope = ?",
                    arguments: [scope]
                )
                for (id, value) in values {
                    try db.execute(
                        sql: """
                        INSERT INTO offline_entry
                            (account_scope, song_id, file_name, byte_count, last_accessed_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            scope, id, value.fileName, value.byteCount,
                            value.lastAccessedAt.timeIntervalSince1970
                        ]
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    func clearOfflineEntries(scope: String) async {
        try? await pool?.write { db in
            try db.execute(
                sql: "DELETE FROM offline_entry WHERE account_scope = ?",
                arguments: [scope]
            )
        }
    }

    func loadHomeSnapshot(
        scope: String,
        maximumAge: TimeInterval
    ) async -> HomeSnapshot? {
        guard let pool else { return nil }
        do {
            return try await pool.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT saved_at, snapshot_data FROM home_snapshot
                    WHERE account_scope = ? AND saved_at >= ?
                    """,
                    arguments: [scope, Date().addingTimeInterval(-maximumAge).timeIntervalSince1970]
                ) else { return nil }
                let savedAt = Self.date(row["saved_at"] as Double)
                guard Date().timeIntervalSince(savedAt) <= maximumAge else {
                    return nil
                }
                let data: Data = row["snapshot_data"]
                return try Self.decode(HomeSnapshot.self, from: data)
            }
        } catch {
            return nil
        }
    }

    @discardableResult
    func saveHomeSnapshot(
        _ snapshot: HomeSnapshot,
        scope: String,
        maximumBytes: Int
    ) async -> Bool {
        guard let pool,
              let data = try? Self.encode(snapshot),
              data.count <= maximumBytes else { return false }
        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO home_snapshot (account_scope, saved_at, snapshot_data)
                    VALUES (?, ?, ?)
                    ON CONFLICT(account_scope) DO UPDATE SET
                        saved_at = excluded.saved_at,
                        snapshot_data = excluded.snapshot_data
                    """,
                    arguments: [scope, Date().timeIntervalSince1970, data]
                )
            }
            return true
        } catch {
            return false
        }
    }

    func removeHomeSnapshot(scope: String) async {
        try? await pool?.write { db in
            try db.execute(
                sql: "DELETE FROM home_snapshot WHERE account_scope = ?",
                arguments: [scope]
            )
        }
    }

    func loadArtworkPalette(
        scope: String,
        artworkKey: String,
        engineVersion: Int
    ) async -> ArtworkPalette? {
        guard let pool,
              !scope.isEmpty,
              scope.utf8.count <= 512,
              !artworkKey.isEmpty,
              artworkKey.utf8.count <= 4_096,
              engineVersion > 0 else { return nil }
        let key = ArtworkPaletteCacheKey(
            scope: scope,
            artworkKey: artworkKey,
            engineVersion: engineVersion
        )
        let data: Data?
        do {
            data = try await pool.read { db in
                try Data.fetchOne(
                    db,
                    sql: """
                    SELECT palette_data FROM artwork_palette_cache
                    WHERE account_scope = ? AND artwork_key = ? AND engine_version = ?
                    """,
                    arguments: [scope, artworkKey, engineVersion]
                )
            }
        } catch {
            return nil
        }
        guard let data else { return nil }
        guard let palette = try? Self.decode(
            ArtworkPalette.self,
            from: data
        ) else {
            await deleteCorruptArtworkPalette(key, matching: data)
            return nil
        }
        recordArtworkPaletteTouch(key)
        return palette
    }

    @discardableResult
    func saveArtworkPalette(
        _ palette: ArtworkPalette,
        scope: String,
        artworkKey: String,
        engineVersion: Int,
        maximumEntriesPerScope: Int = 384,
        maximumTotalEntries: Int = 1_024
    ) async -> Bool {
        guard let pool,
              !scope.isEmpty,
              scope.utf8.count <= 512,
              !artworkKey.isEmpty,
              artworkKey.utf8.count <= 4_096,
              engineVersion > 0,
              let data = try? Self.encode(palette),
              data.count <= 32_768 else { return false }

        let totalLimit = min(max(maximumTotalEntries, 1), 4_096)
        let scopedLimit = min(
            min(max(maximumEntriesPerScope, 1), 2_048),
            totalLimit
        )
        let wallClock = currentDate().timeIntervalSince1970
        let pendingTouches = takePendingArtworkPaletteTouches()
        do {
            try await pool.write { db in
                try Self.applyArtworkPaletteTouches(
                    pendingTouches,
                    in: db,
                    wallClock: wallClock
                )
                let accessedAt = try Self.nextPaletteAccessTimestamp(
                    in: db,
                    wallClock: wallClock
                )
                // A palette is meaningful only to the engine version that produced it.
                // Removing older representations of the same artwork prevents stale
                // versions from consuming the bounded cache indefinitely.
                try db.execute(
                    sql: """
                    DELETE FROM artwork_palette_cache
                    WHERE account_scope = ? AND artwork_key = ? AND engine_version <> ?
                    """,
                    arguments: [scope, artworkKey, engineVersion]
                )
                try db.execute(
                    sql: """
                    INSERT INTO artwork_palette_cache (
                        account_scope, artwork_key, engine_version,
                        palette_data, byte_count, last_accessed_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_scope, artwork_key, engine_version) DO UPDATE SET
                        palette_data = excluded.palette_data,
                        byte_count = excluded.byte_count,
                        last_accessed_at = excluded.last_accessed_at
                    """,
                    arguments: [
                        scope,
                        artworkKey,
                        engineVersion,
                        data,
                        data.count,
                        accessedAt
                    ]
                )
                try Self.pruneArtworkPalettes(
                    in: db,
                    scope: scope,
                    maximumEntries: scopedLimit
                )
                try Self.pruneArtworkPalettes(
                    in: db,
                    maximumEntries: totalLimit
                )
            }
            artworkPaletteTouchRetryCount = 0
            return true
        } catch {
            restoreArtworkPaletteTouchesAfterFailure(pendingTouches)
            return false
        }
    }

    func clearArtworkPalettes(scope: String) async {
        discardPendingArtworkPaletteTouches { $0.scope == scope }
        try? await pool?.write { db in
            try db.execute(
                sql: "DELETE FROM artwork_palette_cache WHERE account_scope = ?",
                arguments: [scope]
            )
        }
    }

    func clearAllArtworkPalettes() async {
        discardAllPendingArtworkPaletteTouches()
        try? await pool?.write { db in
            try db.execute(sql: "DELETE FROM artwork_palette_cache")
        }
    }

    func flushArtworkPaletteTouches() async {
        cancelScheduledArtworkPaletteTouchFlush()
        await persistPendingArtworkPaletteTouches()
    }

    func loadQueue(scope: String) async -> QueueSnapshot? {
        guard Self.isValidAccountScope(scope) else { return nil }
        guard let pool else { return nil }
        do {
            return try await pool.read { db in
                guard let state = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM account_queue_state WHERE account_scope = ?",
                    arguments: [scope]
                ) else {
                    return nil
                }
                let itemRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT song_data FROM account_queue_item
                    WHERE account_scope = ? ORDER BY position
                    """,
                    arguments: [scope]
                )
                let songs = try itemRows.map { row in
                    try Self.decode(Song.self, from: row["song_data"] as Data)
                }
                guard !songs.isEmpty else { return nil }
                return QueueSnapshot(
                    queue: songs,
                    currentID: state["current_song_id"],
                    index: state["current_index"],
                    elapsed: state["elapsed"],
                    shuffle: state["shuffle"],
                    repeatMode: RepeatMode(rawValue: state["repeat_mode"]) ?? .off
                )
            }
        } catch {
            return nil
        }
    }

    @discardableResult
    func saveQueue(
        _ snapshot: QueueSnapshot,
        scope: String,
        replacingItems: Bool = true
    ) async -> Bool {
        guard Self.isValidAccountScope(scope) else { return false }
        guard let pool else { return false }
        do {
            try await pool.write { db in
                guard !snapshot.queue.isEmpty else {
                    try db.execute(
                        sql: "DELETE FROM account_queue_state WHERE account_scope = ?",
                        arguments: [scope]
                    )
                    return
                }
                let storedItemCount = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM account_queue_item
                    WHERE account_scope = ?
                    """,
                    arguments: [scope]
                ) ?? 0
                try db.execute(
                    sql: """
                    INSERT INTO account_queue_state
                        (account_scope, current_song_id, current_index, elapsed,
                         shuffle, repeat_mode, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_scope) DO UPDATE SET
                        current_song_id = excluded.current_song_id,
                        current_index = excluded.current_index,
                        elapsed = excluded.elapsed,
                        shuffle = excluded.shuffle,
                        repeat_mode = excluded.repeat_mode,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        scope, snapshot.currentID, snapshot.index, snapshot.elapsed,
                        snapshot.shuffle, snapshot.repeatMode.rawValue,
                        Date().timeIntervalSince1970
                    ]
                )
                // `replacingItems` is an in-memory optimization hint. If a
                // preceding clear won the race or the stored rows are partial,
                // repair the item set even when the hint says state-only.
                let shouldReplaceItems = replacingItems
                    || storedItemCount != snapshot.queue.count
                guard shouldReplaceItems else { return }
                try db.execute(
                    sql: "DELETE FROM account_queue_item WHERE account_scope = ?",
                    arguments: [scope]
                )
                for (position, song) in snapshot.queue.enumerated() {
                    try db.execute(
                        sql: """
                        INSERT INTO account_queue_item
                            (account_scope, position, song_data)
                        VALUES (?, ?, ?)
                        """,
                        arguments: [scope, position, try Self.encode(song)]
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    func clearQueue(scope: String) async {
        guard Self.isValidAccountScope(scope) else { return }
        try? await pool?.write { db in
            // Deleting state cascades to its ordered items.
            try db.execute(
                sql: "DELETE FROM account_queue_state WHERE account_scope = ?",
                arguments: [scope]
            )
        }
    }

    private static func isValidAccountScope(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
    }

    private static let maximumArtworkPaletteTouchRetryCount = 2

    private func recordArtworkPaletteTouch(_ key: ArtworkPaletteCacheKey) {
        pendingArtworkPaletteTouches.insert(key)
        artworkPaletteTouchRetryCount = 0
        scheduleArtworkPaletteTouchFlushIfNeeded()
    }

    private func scheduleArtworkPaletteTouchFlushIfNeeded() {
        guard !pendingArtworkPaletteTouches.isEmpty,
              artworkPaletteTouchTask == nil else { return }
        let token = UUID()
        let delay = artworkPaletteTouchDelay
        artworkPaletteTouchTaskToken = token
        artworkPaletteTouchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.flushScheduledArtworkPaletteTouches(token: token)
        }
    }

    private func flushScheduledArtworkPaletteTouches(token: UUID) async {
        guard artworkPaletteTouchTaskToken == token else { return }
        artworkPaletteTouchTask = nil
        artworkPaletteTouchTaskToken = nil
        await persistPendingArtworkPaletteTouches()
    }

    private func persistPendingArtworkPaletteTouches() async {
        guard pool != nil else {
            discardAllPendingArtworkPaletteTouches()
            return
        }
        let touches = takePendingArtworkPaletteTouches()
        guard !touches.isEmpty, let pool else { return }
        let wallClock = currentDate().timeIntervalSince1970
        do {
            try await pool.write { db in
                try Self.applyArtworkPaletteTouches(
                    touches,
                    in: db,
                    wallClock: wallClock
                )
            }
            artworkPaletteTouchRetryCount = 0
        } catch {
            restoreArtworkPaletteTouchesAfterFailure(touches)
        }
    }

    private func takePendingArtworkPaletteTouches()
        -> Set<ArtworkPaletteCacheKey> {
        cancelScheduledArtworkPaletteTouchFlush()
        let touches = pendingArtworkPaletteTouches
        pendingArtworkPaletteTouches.removeAll(keepingCapacity: true)
        return touches
    }

    private func restoreArtworkPaletteTouchesAfterFailure(
        _ touches: Set<ArtworkPaletteCacheKey>
    ) {
        guard !touches.isEmpty else { return }
        pendingArtworkPaletteTouches.formUnion(touches)
        artworkPaletteTouchRetryCount += 1
        guard artworkPaletteTouchRetryCount <= Self.maximumArtworkPaletteTouchRetryCount else {
            return
        }
        scheduleArtworkPaletteTouchFlushIfNeeded()
    }

    private func discardPendingArtworkPaletteTouches(
        where shouldDiscard: (ArtworkPaletteCacheKey) -> Bool
    ) {
        pendingArtworkPaletteTouches.subtract(
            Set(pendingArtworkPaletteTouches.filter(shouldDiscard))
        )
        if pendingArtworkPaletteTouches.isEmpty {
            cancelScheduledArtworkPaletteTouchFlush()
            artworkPaletteTouchRetryCount = 0
        }
    }

    private func discardAllPendingArtworkPaletteTouches() {
        cancelScheduledArtworkPaletteTouchFlush()
        pendingArtworkPaletteTouches.removeAll(keepingCapacity: false)
        artworkPaletteTouchRetryCount = 0
    }

    private func cancelScheduledArtworkPaletteTouchFlush() {
        artworkPaletteTouchTask?.cancel()
        artworkPaletteTouchTask = nil
        artworkPaletteTouchTaskToken = nil
    }

    private func deleteCorruptArtworkPalette(
        _ key: ArtworkPaletteCacheKey,
        matching data: Data
    ) async {
        discardPendingArtworkPaletteTouches { $0 == key }
        try? await pool?.write { db in
            // Match the bytes read by the failed decoder so a concurrent save
            // of a repaired value cannot be deleted by this delayed cleanup.
            try db.execute(
                sql: """
                DELETE FROM artwork_palette_cache
                WHERE account_scope = ? AND artwork_key = ?
                  AND engine_version = ? AND palette_data = ?
                """,
                arguments: [
                    key.scope,
                    key.artworkKey,
                    key.engineVersion,
                    data
                ]
            )
        }
    }

    private static func applyArtworkPaletteTouches(
        _ touches: Set<ArtworkPaletteCacheKey>,
        in db: Database,
        wallClock: Double
    ) throws {
        guard !touches.isEmpty else { return }
        let accessedAt = try nextPaletteAccessTimestamp(
            in: db,
            wallClock: wallClock
        )
        for key in touches {
            try db.execute(
                sql: """
                UPDATE artwork_palette_cache SET last_accessed_at = ?
                WHERE account_scope = ? AND artwork_key = ?
                  AND engine_version = ?
                """,
                arguments: [
                    accessedAt,
                    key.scope,
                    key.artworkKey,
                    key.engineVersion
                ]
            )
        }
    }

    private static func date(_ timestamp: Double) -> Date {
        Date(timeIntervalSince1970: timestamp)
    }

    private static func nextPaletteAccessTimestamp(
        in db: Database,
        wallClock: Double
    ) throws -> Double {
        let persisted: Double? = try Double.fetchOne(
            db,
            sql: """
            SELECT last_accessed_at FROM artwork_palette_cache
            ORDER BY last_accessed_at DESC LIMIT 1
            """
        )
        guard let persisted, persisted.isFinite else { return wallClock }
        return max(wallClock, persisted.nextUp)
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        try PropertyListDecoder().decode(type, from: data)
    }

    private static func pruneArtworkPalettes(
        in db: Database,
        scope: String,
        maximumEntries: Int
    ) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT artwork_key, engine_version FROM artwork_palette_cache
            WHERE account_scope = ?
            ORDER BY last_accessed_at DESC, artwork_key ASC, engine_version DESC
            LIMIT -1 OFFSET ?
            """,
            arguments: [scope, maximumEntries]
        )
        for row in rows {
            let artworkKey: String = row["artwork_key"]
            let engineVersion: Int = row["engine_version"]
            try db.execute(
                sql: """
                DELETE FROM artwork_palette_cache
                WHERE account_scope = ? AND artwork_key = ? AND engine_version = ?
                """,
                arguments: [scope, artworkKey, engineVersion]
            )
        }
    }

    private static func pruneArtworkPalettes(
        in db: Database,
        maximumEntries: Int
    ) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT account_scope, artwork_key, engine_version
            FROM artwork_palette_cache
            ORDER BY last_accessed_at DESC, account_scope ASC,
                     artwork_key ASC, engine_version DESC
            LIMIT -1 OFFSET ?
            """,
            arguments: [maximumEntries]
        )
        for row in rows {
            let scope: String = row["account_scope"]
            let artworkKey: String = row["artwork_key"]
            let engineVersion: Int = row["engine_version"]
            try db.execute(
                sql: """
                DELETE FROM artwork_palette_cache
                WHERE account_scope = ? AND artwork_key = ? AND engine_version = ?
                """,
                arguments: [scope, artworkKey, engineVersion]
            )
        }
    }

    private static func makePool(path: String) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.label = "BuFi.Database"
        configuration.maximumReaderCount = 3
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        let database = try DatabasePool(path: path, configuration: configuration)
        try migrator.migrate(database)
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA optimize")
        }
        return database
    }

    private static let listeningUpsertSQL = """
        INSERT INTO listening_behavior (
            account_scope, song_id, song_data, play_count, first_played,
            last_played, completed_count, skip_count, early_skip_count,
            repeated_skip_count, repeat_count, manual_play_count,
            search_play_count, album_selection_count, playlist_play_count,
            autoplay_count, queue_removal_count, playlist_add_count,
            favorite_count, total_completion, completion_samples,
            consecutive_skips
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(account_scope, song_id) DO UPDATE SET
            song_data = excluded.song_data,
            play_count = excluded.play_count,
            first_played = excluded.first_played,
            last_played = excluded.last_played,
            completed_count = excluded.completed_count,
            skip_count = excluded.skip_count,
            early_skip_count = excluded.early_skip_count,
            repeated_skip_count = excluded.repeated_skip_count,
            repeat_count = excluded.repeat_count,
            manual_play_count = excluded.manual_play_count,
            search_play_count = excluded.search_play_count,
            album_selection_count = excluded.album_selection_count,
            playlist_play_count = excluded.playlist_play_count,
            autoplay_count = excluded.autoplay_count,
            queue_removal_count = excluded.queue_removal_count,
            playlist_add_count = excluded.playlist_add_count,
            favorite_count = excluded.favorite_count,
            total_completion = excluded.total_completion,
            completion_samples = excluded.completion_samples,
            consecutive_skips = excluded.consecutive_skips
        """

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("create-persistence-v1") { db in
            try db.execute(sql: """
                CREATE TABLE listening_behavior (
                    account_scope TEXT NOT NULL,
                    song_id TEXT NOT NULL,
                    song_data BLOB NOT NULL,
                    play_count INTEGER NOT NULL,
                    first_played DOUBLE NOT NULL,
                    last_played DOUBLE NOT NULL,
                    completed_count INTEGER NOT NULL,
                    skip_count INTEGER NOT NULL,
                    early_skip_count INTEGER NOT NULL,
                    repeated_skip_count INTEGER NOT NULL,
                    repeat_count INTEGER NOT NULL,
                    manual_play_count INTEGER NOT NULL,
                    search_play_count INTEGER NOT NULL,
                    album_selection_count INTEGER NOT NULL,
                    playlist_play_count INTEGER NOT NULL,
                    autoplay_count INTEGER NOT NULL,
                    queue_removal_count INTEGER NOT NULL,
                    playlist_add_count INTEGER NOT NULL,
                    favorite_count INTEGER NOT NULL,
                    total_completion DOUBLE NOT NULL,
                    completion_samples INTEGER NOT NULL,
                    consecutive_skips INTEGER NOT NULL,
                    PRIMARY KEY (account_scope, song_id)
                ) WITHOUT ROWID;
                CREATE INDEX listening_behavior_recent
                    ON listening_behavior(account_scope, last_played DESC);
                CREATE INDEX listening_behavior_popular
                    ON listening_behavior(account_scope, play_count DESC, last_played DESC);

                CREATE TABLE offline_entry (
                    account_scope TEXT NOT NULL,
                    song_id TEXT NOT NULL,
                    file_name TEXT NOT NULL,
                    byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
                    last_accessed_at DOUBLE NOT NULL,
                    PRIMARY KEY (account_scope, song_id)
                ) WITHOUT ROWID;
                CREATE INDEX offline_entry_lru
                    ON offline_entry(account_scope, last_accessed_at);

                CREATE TABLE home_snapshot (
                    account_scope TEXT PRIMARY KEY NOT NULL,
                    saved_at DOUBLE NOT NULL,
                    snapshot_data BLOB NOT NULL
                ) WITHOUT ROWID;

                CREATE TABLE queue_state (
                    id INTEGER PRIMARY KEY CHECK(id = 1),
                    current_song_id TEXT,
                    current_index INTEGER NOT NULL,
                    elapsed DOUBLE NOT NULL,
                    shuffle INTEGER NOT NULL,
                    repeat_mode TEXT NOT NULL,
                    updated_at DOUBLE NOT NULL
                );
                CREATE TABLE queue_item (
                    position INTEGER PRIMARY KEY,
                    song_data BLOB NOT NULL
                );
                """)
        }
        migrator.registerMigration("create-artwork-palette-cache-v3") { db in
            try db.execute(sql: """
                CREATE TABLE artwork_palette_cache (
                    account_scope TEXT NOT NULL,
                    artwork_key TEXT NOT NULL,
                    engine_version INTEGER NOT NULL CHECK(engine_version > 0),
                    palette_data BLOB NOT NULL,
                    byte_count INTEGER NOT NULL CHECK(byte_count > 0 AND byte_count <= 32768),
                    last_accessed_at DOUBLE NOT NULL,
                    PRIMARY KEY (account_scope, artwork_key, engine_version)
                ) WITHOUT ROWID;
                CREATE INDEX artwork_palette_cache_scope_lru
                    ON artwork_palette_cache(
                        account_scope, last_accessed_at DESC, artwork_key
                    );
                CREATE INDEX artwork_palette_cache_global_lru
                    ON artwork_palette_cache(last_accessed_at DESC);
                """)
        }
        migrator.registerMigration("create-account-queue-v4") { db in
            try db.execute(sql: """
                CREATE TABLE account_queue_state (
                    account_scope TEXT PRIMARY KEY NOT NULL,
                    current_song_id TEXT,
                    current_index INTEGER NOT NULL,
                    elapsed DOUBLE NOT NULL,
                    shuffle INTEGER NOT NULL,
                    repeat_mode TEXT NOT NULL,
                    updated_at DOUBLE NOT NULL
                ) WITHOUT ROWID;
                CREATE TABLE account_queue_item (
                    account_scope TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    song_data BLOB NOT NULL,
                    PRIMARY KEY (account_scope, position),
                    FOREIGN KEY (account_scope)
                        REFERENCES account_queue_state(account_scope)
                        ON DELETE CASCADE
                ) WITHOUT ROWID;

                -- The v1 queue has no account identity. Assigning it to the
                -- next login could expose one account's songs to another, so
                -- discard only this unattributable legacy queue once.
                DELETE FROM queue_item;
                DELETE FROM queue_state;
                """)
        }
        return migrator
    }
}
