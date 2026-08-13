import Foundation
import GRDB

struct OfflineDatabaseEntry: Sendable, Equatable {
    var fileName: String
    var byteCount: Int64
    var lastAccessedAt: Date
}

actor AppDatabase {
    static let shared = AppDatabase()

    private struct StoredQueueItem: Sendable {
        let position: Int
        let queueEntryID: String?
        let songData: Data
    }

    private struct StoredQueueState: Sendable {
        let items: [StoredQueueItem]
        let currentSongID: String?
        let currentQueueEntryID: String?
        let index: Int
        let elapsed: TimeInterval
        let shuffle: Bool
        let repeatMode: String
        let revision: Int64
    }

    private struct EncodedQueueItem: Sendable {
        let position: Int
        let queueEntryID: String
        let songData: Data
    }

    private struct PaletteTouch: Hashable, Sendable {
        let scope: String
        let artworkKey: String
        let engineVersion: Int
    }

    private let databasePath: String
    private let currentDate: @Sendable () -> Date
    private var pool: DatabasePool?
    private var poolTask: Task<DatabasePool?, Never>?
    private var pendingPaletteTouches = Set<PaletteTouch>()
    private var paletteTouchTask: Task<Void, Never>?

    private init() {
        currentDate = { Date() }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        databasePath = support
            .appendingPathComponent("Database", isDirectory: true)
            .appendingPathComponent("BuFi.sqlite")
            .path
        pool = nil
        poolTask = nil
        paletteTouchTask = nil
    }

    init(
        databaseURL: URL,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.currentDate = currentDate
        databasePath = databaseURL.path
        pool = try Self.makePool(path: databaseURL.path)
        poolTask = nil
        paletteTouchTask = nil
    }

    init(
        lazyDatabaseURL databaseURL: URL,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.currentDate = currentDate
        databasePath = databaseURL.path
        pool = nil
        poolTask = nil
        paletteTouchTask = nil
    }

    private func databasePool() async -> DatabasePool? {
        if let pool {
            return pool
        }
        if let poolTask {
            return await poolTask.value
        }

        let path = databasePath
        let task = Task.detached(priority: .utility) { () -> DatabasePool? in
            Self.openPool(path: path)
        }
        poolTask = task
        let openedPool = await task.value
        poolTask = nil
        pool = openedPool
        return openedPool
    }

    func loadListeningHistory(scope: String) async -> [String: SongBehavior] {
        guard let pool = await databasePool() else { return [:] }
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
                return Dictionary(uniqueKeysWithValues: rows.compactMap {
                    row -> (String, SongBehavior)? in
                    do {
                        let songID: String = row["song_id"]
                        let songData: Data = row["song_data"]
                        let song = try Self.decode(Song.self, from: songData)
                        guard song.id == songID else { return nil }
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
                    } catch {
                        return nil
                    }
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
        guard let pool = await databasePool() else { return false }
        do {
            try await pool.write { db in
                for id in deletedIDs {
                    try db.execute(
                        sql: "DELETE FROM listening_behavior WHERE account_scope = ? AND song_id = ?",
                        arguments: [scope, id]
                    )
                }
                for (id, value) in values {
                    guard id == value.song.id else { continue }
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
        guard let pool = await databasePool() else { return false }
        do {
            try await pool.write { db in
                try db.execute(
                    sql: "DELETE FROM listening_behavior WHERE account_scope = ?",
                    arguments: [scope]
                )
                for (id, value) in values {
                    guard id == value.song.id else { continue }
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
        guard let pool = await databasePool() else { return }
        try? await pool.write { db in
            try db.execute(
                sql: "DELETE FROM listening_behavior WHERE account_scope = ?",
                arguments: [scope]
            )
        }
    }

#if DEBUG
    @discardableResult
    func overwriteQueuePayloadForTesting(
        _ data: Data,
        position: Int,
        scope: String
    ) async -> Bool {
        guard let pool = await databasePool() else { return false }
        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                    UPDATE queue_item SET song_data = ?
                    WHERE account_scope = ? AND position = ?
                    """,
                    arguments: [data, scope, position]
                )
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func overwriteListeningHistoryPayloadForTesting(
        _ data: Data,
        songID: String,
        scope: String
    ) async -> Bool {
        guard let pool = await databasePool() else { return false }
        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                    UPDATE listening_behavior SET song_data = ?
                    WHERE account_scope = ? AND song_id = ?
                    """,
                    arguments: [data, scope, songID]
                )
            }
            return true
        } catch {
            return false
        }
    }
#endif

    func loadOfflineEntries(scope: String) async -> [String: OfflineDatabaseEntry] {
        guard let pool = await databasePool() else { return [:] }
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
        guard let pool = await databasePool() else { return false }
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
        guard let pool = await databasePool() else { return false }
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
        guard let pool = await databasePool() else { return }
        try? await pool.write { db in
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
        guard let pool = await databasePool() else { return nil }
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
        guard let pool = await databasePool(),
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
        guard let pool = await databasePool() else { return }
        try? await pool.write { db in
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
        guard let pool = await databasePool(),
              !scope.isEmpty,
              scope.utf8.count <= 512,
              !artworkKey.isEmpty,
              artworkKey.utf8.count <= 4_096,
              engineVersion > 0 else { return nil }
        do {
            guard let data = try await pool.read({ db -> Data? in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT palette_data FROM artwork_palette_cache
                    WHERE account_scope = ? AND artwork_key = ? AND engine_version = ?
                    """,
                    arguments: [scope, artworkKey, engineVersion]
                ) else { return nil }
                let value: Data = row["palette_data"]
                return value
            }) else {
                return nil
            }
            guard let palette = try? Self.decode(ArtworkPalette.self, from: data) else {
                try? await pool.write { db in
                    try db.execute(
                        sql: """
                        DELETE FROM artwork_palette_cache
                        WHERE account_scope = ? AND artwork_key = ? AND engine_version = ?
                        """,
                        arguments: [scope, artworkKey, engineVersion]
                    )
                }
                return nil
            }
            schedulePaletteTouch(PaletteTouch(
                scope: scope,
                artworkKey: artworkKey,
                engineVersion: engineVersion
            ))
            return palette
        } catch {
            return nil
        }
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
        await flushPaletteTouchesNow()
        guard let pool = await databasePool(),
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
        do {
            try await pool.write { db in
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
            return true
        } catch {
            return false
        }
    }

    func clearArtworkPalettes(scope: String) async {
        let staleTouches = pendingPaletteTouches.filter { $0.scope == scope }
        pendingPaletteTouches.subtract(staleTouches)
        cancelPaletteTouchTaskIfIdle()
        guard let pool = await databasePool() else { return }
        try? await pool.write { db in
            try db.execute(
                sql: "DELETE FROM artwork_palette_cache WHERE account_scope = ?",
                arguments: [scope]
            )
        }
    }

    func clearAllArtworkPalettes() async {
        pendingPaletteTouches.removeAll(keepingCapacity: true)
        paletteTouchTask?.cancel()
        paletteTouchTask = nil
        guard let pool = await databasePool() else { return }
        try? await pool.write { db in
            try db.execute(sql: "DELETE FROM artwork_palette_cache")
        }
    }

    func loadQueue(scope: String) async -> QueueSnapshot? {
        guard let pool = await databasePool() else { return nil }
        do {
            let stored = try await pool.read { db -> StoredQueueState? in
                guard let state = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM queue_state WHERE account_scope = ?",
                    arguments: [scope]
                ) else {
                    return nil
                }
                let itemRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT position, occurrence_id, song_data FROM queue_item
                    WHERE account_scope = ? ORDER BY position
                    """,
                    arguments: [scope]
                )
                let items = itemRows.map { row in
                    StoredQueueItem(
                        position: row["position"],
                        queueEntryID: row["occurrence_id"],
                        songData: row["song_data"]
                    )
                }
                return StoredQueueState(
                    items: items,
                    currentSongID: state["current_song_id"],
                    currentQueueEntryID: state["current_occurrence_id"],
                    index: state["current_index"],
                    elapsed: state["elapsed"],
                    shuffle: state["shuffle"],
                    repeatMode: state["repeat_mode"],
                    revision: state["revision"]
                )
            }
            guard let stored else { return nil }
            var repairedItems = false
            let decodedItems = stored.items.compactMap { item -> (
                position: Int,
                entry: PlaybackQueueEntry
            )? in
                guard let song = try? Self.decode(Song.self, from: item.songData) else {
                    repairedItems = true
                    return nil
                }
                let parsedID = item.queueEntryID.flatMap(UUID.init(uuidString:))
                if parsedID == nil { repairedItems = true }
                return (
                    position: item.position,
                    entry: PlaybackQueueEntry(
                        song: song,
                        queueEntryID: parsedID ?? UUID()
                    )
                )
            }
            let storedRevision = UInt64(max(0, stored.revision))
            guard !decodedItems.isEmpty else {
                let emptyStateNeedsRepair = repairedItems
                    || stored.currentSongID != nil
                    || stored.currentQueueEntryID != nil
                    || stored.index != -1
                    || stored.elapsed != 0
                let empty = QueueSnapshot(
                    entries: [],
                    currentID: nil,
                    currentQueueEntryID: nil,
                    index: -1,
                    elapsed: 0,
                    shuffle: false,
                    repeatMode: .off,
                    revision: emptyStateNeedsRepair
                        ? Self.nextQueueRevision(after: storedRevision)
                        : storedRevision
                )
                if emptyStateNeedsRepair, empty.revision > storedRevision {
                    _ = await saveQueue(empty, scope: scope)
                }
                return empty
            }

            let requestedOccurrenceID = stored.currentQueueEntryID.flatMap(
                UUID.init(uuidString:)
            )
            if stored.currentQueueEntryID != nil, requestedOccurrenceID == nil {
                repairedItems = true
            }
            let selectedIndex: Int
            if let requestedOccurrenceID,
               let occurrenceIndex = decodedItems.firstIndex(where: {
                   $0.entry.id == requestedOccurrenceID
               }) {
                selectedIndex = occurrenceIndex
            } else if let positionIndex = decodedItems.firstIndex(where: {
                $0.position == stored.index
                    && (stored.currentSongID == nil
                        || $0.entry.song.id == stored.currentSongID)
            }) {
                selectedIndex = positionIndex
            } else if let songID = stored.currentSongID,
                      let songIndex = decodedItems.firstIndex(where: {
                          $0.entry.song.id == songID
                      }) {
                selectedIndex = songIndex
            } else {
                selectedIndex = min(max(stored.index, 0), decodedItems.count - 1)
            }
            let selected = decodedItems[selectedIndex]
            let selectionWasPreserved = requestedOccurrenceID == selected.entry.id
                || (selected.position == stored.index
                    && (stored.currentSongID == nil
                        || selected.entry.song.id == stored.currentSongID))
            let entries = decodedItems.map { $0.entry }
            let stateNeedsRepair = stored.index != selectedIndex
                || stored.currentSongID != selected.entry.song.id
                || requestedOccurrenceID != selected.entry.id
            let needsRepair = repairedItems || stateNeedsRepair
            let revision = needsRepair
                ? Self.nextQueueRevision(after: storedRevision)
                : storedRevision
            let snapshot = QueueSnapshot(
                entries: entries,
                currentID: selected.entry.song.id,
                currentQueueEntryID: selected.entry.id,
                index: selectedIndex,
                elapsed: selectionWasPreserved ? stored.elapsed : 0,
                shuffle: stored.shuffle,
                repeatMode: RepeatMode(rawValue: stored.repeatMode) ?? .off,
                revision: revision
            )
            if needsRepair, revision > storedRevision {
                _ = await saveQueue(snapshot, scope: scope)
            }
            return snapshot
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
        guard let pool = await databasePool() else { return false }
        let encodedItems: [EncodedQueueItem]
        do {
            if replacingItems {
                encodedItems = try snapshot.entries.enumerated().map {
                    position, entry in
                    EncodedQueueItem(
                        position: position,
                        queueEntryID: entry.id.uuidString,
                        songData: try Self.encode(entry.song)
                    )
                }
            } else {
                encodedItems = []
            }
        } catch {
            return false
        }
        do {
            return try await pool.write { db in
                let incomingRevision = Int64(clamping: snapshot.revision)
                let persistedRevision: Int64? = try Int64.fetchOne(
                    db,
                    sql: """
                    SELECT revision FROM queue_state WHERE account_scope = ?
                    """,
                    arguments: [scope]
                )
                if let persistedRevision,
                   incomingRevision <= persistedRevision {
                    return false
                }
                guard !snapshot.queue.isEmpty else {
                    _ = try Self.writeQueueTombstone(
                        in: db,
                        scope: scope,
                        minimumRevision: snapshot.revision
                    )
                    return true
                }
                try db.execute(
                    sql: """
                    INSERT INTO queue_state
                        (account_scope, current_song_id, current_occurrence_id,
                         current_index, elapsed, shuffle, repeat_mode, revision,
                         updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(account_scope) DO UPDATE SET
                        current_song_id = excluded.current_song_id,
                        current_occurrence_id = excluded.current_occurrence_id,
                        current_index = excluded.current_index,
                        elapsed = excluded.elapsed,
                        shuffle = excluded.shuffle,
                        repeat_mode = excluded.repeat_mode,
                        revision = excluded.revision,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        scope, snapshot.currentID,
                        snapshot.currentQueueEntryID?.uuidString,
                        snapshot.index, snapshot.elapsed, snapshot.shuffle,
                        snapshot.repeatMode.rawValue, incomingRevision,
                        Date().timeIntervalSince1970
                    ]
                )
                guard replacingItems else { return true }
                try db.execute(
                    sql: "DELETE FROM queue_item WHERE account_scope = ?",
                    arguments: [scope]
                )
                for item in encodedItems {
                    try db.execute(
                        sql: """
                            INSERT INTO queue_item
                            (account_scope, position, occurrence_id, song_data)
                            VALUES (?, ?, ?, ?)
                        """,
                        arguments: [
                            scope, item.position, item.queueEntryID,
                            item.songData
                        ]
                    )
                }
                return true
            }
        } catch {
            return false
        }
    }

    @discardableResult
    func clearQueue(
        scope: String,
        minimumRevision: UInt64
    ) async -> UInt64? {
        guard let pool = await databasePool() else { return nil }
        return try? await pool.write { db in
            try Self.writeQueueTombstone(
                in: db,
                scope: scope,
                minimumRevision: minimumRevision
            )
        }
    }

    private static func writeQueueTombstone(
        in db: Database,
        scope: String,
        minimumRevision: UInt64
    ) throws -> UInt64 {
        let persistedRevision: Int64 = try Int64.fetchOne(
            db,
            sql: "SELECT revision FROM queue_state WHERE account_scope = ?",
            arguments: [scope]
        ) ?? -1
        let requested = Int64(clamping: minimumRevision)
        let nextRevision = max(requested, persistedRevision + 1)
        try db.execute(
            sql: """
                INSERT INTO queue_state
                    (account_scope, current_song_id, current_occurrence_id,
                     current_index, elapsed, shuffle, repeat_mode, revision,
                     updated_at)
                VALUES (?, NULL, NULL, -1, 0, 0, ?, ?, ?)
                ON CONFLICT(account_scope) DO UPDATE SET
                    current_song_id = NULL,
                    current_occurrence_id = NULL,
                    current_index = -1,
                    elapsed = 0,
                    shuffle = 0,
                    repeat_mode = excluded.repeat_mode,
                    revision = excluded.revision,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                scope, RepeatMode.off.rawValue, nextRevision,
                Date().timeIntervalSince1970
            ]
        )
        try db.execute(
            sql: "DELETE FROM queue_item WHERE account_scope = ?",
            arguments: [scope]
        )
        return UInt64(max(0, nextRevision))
    }

    private static func date(_ timestamp: Double) -> Date {
        Date(timeIntervalSince1970: timestamp)
    }

    private static func nextQueueRevision(after revision: UInt64) -> UInt64 {
        let maximum = UInt64(Int64.max)
        return revision < maximum ? revision + 1 : revision
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

    private func schedulePaletteTouch(_ touch: PaletteTouch) {
        pendingPaletteTouches.insert(touch)
        guard paletteTouchTask == nil else { return }
        paletteTouchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flushScheduledPaletteTouches()
        }
    }

    private func cancelPaletteTouchTaskIfIdle() {
        guard pendingPaletteTouches.isEmpty else { return }
        paletteTouchTask?.cancel()
        paletteTouchTask = nil
    }

    private func flushPaletteTouchesNow() async {
        paletteTouchTask?.cancel()
        paletteTouchTask = nil
        await flushPaletteTouches()
    }

    private func flushScheduledPaletteTouches() async {
        paletteTouchTask = nil
        await flushPaletteTouches()
    }

    private func flushPaletteTouches() async {
        guard !pendingPaletteTouches.isEmpty else { return }
        let touches = pendingPaletteTouches.sorted {
            ($0.scope, $0.artworkKey, $0.engineVersion)
                < ($1.scope, $1.artworkKey, $1.engineVersion)
        }
        pendingPaletteTouches.removeAll(keepingCapacity: true)
        guard let pool = await databasePool() else { return }
        let wallClock = currentDate().timeIntervalSince1970
        try? await pool.write { db in
            var accessedAt = try Self.nextPaletteAccessTimestamp(
                in: db,
                wallClock: wallClock
            )
            for touch in touches {
                try db.execute(
                    sql: """
                    UPDATE artwork_palette_cache SET last_accessed_at = ?
                    WHERE account_scope = ? AND artwork_key = ? AND engine_version = ?
                    """,
                    arguments: [
                        accessedAt,
                        touch.scope,
                        touch.artworkKey,
                        touch.engineVersion
                    ]
                )
                accessedAt = accessedAt.nextUp
            }
        }
    }

    private static func pruneArtworkPalettes(
        in db: Database,
        scope: String,
        maximumEntries: Int
    ) throws {
        try db.execute(
            sql: """
            DELETE FROM artwork_palette_cache WHERE rowid IN (
                SELECT rowid FROM artwork_palette_cache
                WHERE account_scope = ?
                ORDER BY last_accessed_at DESC, artwork_key ASC,
                         engine_version DESC
                LIMIT -1 OFFSET ?
            )
            """,
            arguments: [scope, maximumEntries]
        )
    }

    private static func pruneArtworkPalettes(
        in db: Database,
        maximumEntries: Int
    ) throws {
        try db.execute(
            sql: """
            DELETE FROM artwork_palette_cache WHERE rowid IN (
                SELECT rowid FROM artwork_palette_cache
                ORDER BY last_accessed_at DESC, account_scope ASC,
                         artwork_key ASC, engine_version DESC
                LIMIT -1 OFFSET ?
            )
            """,
            arguments: [maximumEntries]
        )
    }

    private static func openPool(path: String) -> DatabasePool? {
        do {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication
                ]
            )
            try FileManager.default.setAttributes(
                [
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: directory.path
            )
            return try makePool(path: path)
        } catch {
            return nil
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
        migrator.registerMigration("scope-play-queue-v4") { db in
            // The v1 queue had no account owner. It is safer to discard that
            // one legacy snapshot than to expose it after a different login.
            try db.execute(sql: """
                DROP TABLE queue_item;
                DROP TABLE queue_state;
                CREATE TABLE queue_state (
                    account_scope TEXT PRIMARY KEY NOT NULL,
                    current_song_id TEXT,
                    current_index INTEGER NOT NULL,
                    elapsed DOUBLE NOT NULL,
                    shuffle INTEGER NOT NULL,
                    repeat_mode TEXT NOT NULL,
                    updated_at DOUBLE NOT NULL
                ) WITHOUT ROWID;
                CREATE TABLE queue_item (
                    account_scope TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    song_data BLOB NOT NULL,
                    PRIMARY KEY (account_scope, position),
                    FOREIGN KEY (account_scope) REFERENCES queue_state(account_scope)
                        ON DELETE CASCADE
                ) WITHOUT ROWID;
                """)
        }
        migrator.registerMigration("queue-occurrence-revision-v5") { db in
            try db.execute(sql: """
                ALTER TABLE queue_state
                    ADD COLUMN current_occurrence_id TEXT;
                ALTER TABLE queue_state
                    ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE queue_item
                    ADD COLUMN occurrence_id TEXT;
                """)
        }
        return migrator
    }
}
