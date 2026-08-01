import Foundation
import GRDB

struct OfflineDatabaseEntry: Sendable, Equatable {
    var fileName: String
    var byteCount: Int64
    var lastAccessedAt: Date
}

actor AppDatabase {
    static let shared = AppDatabase()

    private let pool: DatabasePool?

    private init() {
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

    init(databaseURL: URL) throws {
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

    func loadQueue() async -> QueueSnapshot? {
        guard let pool else { return nil }
        do {
            return try await pool.read { db in
                guard let state = try Row.fetchOne(db, sql: "SELECT * FROM queue_state WHERE id = 1") else {
                    return nil
                }
                let itemRows = try Row.fetchAll(
                    db,
                    sql: "SELECT song_data FROM queue_item ORDER BY position"
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
        replacingItems: Bool = true
    ) async -> Bool {
        guard let pool else { return false }
        do {
            try await pool.write { db in
                guard !snapshot.queue.isEmpty else {
                    try db.execute(sql: "DELETE FROM queue_item")
                    try db.execute(sql: "DELETE FROM queue_state")
                    return
                }
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO queue_state
                        (id, current_song_id, current_index, elapsed, shuffle, repeat_mode, updated_at)
                    VALUES (1, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        snapshot.currentID, snapshot.index, snapshot.elapsed,
                        snapshot.shuffle, snapshot.repeatMode.rawValue,
                        Date().timeIntervalSince1970
                    ]
                )
                guard replacingItems else { return }
                try db.execute(sql: "DELETE FROM queue_item")
                for (position, song) in snapshot.queue.enumerated() {
                    try db.execute(
                        sql: "INSERT INTO queue_item (position, song_data) VALUES (?, ?)",
                        arguments: [position, try Self.encode(song)]
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    func clearQueue() async {
        try? await pool?.write { db in
            try db.execute(sql: "DELETE FROM queue_item")
            try db.execute(sql: "DELETE FROM queue_state")
        }
    }

    private static func date(_ timestamp: Double) -> Date {
        Date(timeIntervalSince1970: timestamp)
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
        return migrator
    }
}
