import Foundation
import GRDB

struct OfflineDatabaseEntry: Sendable, Equatable {
    var fileName: String
    var byteCount: Int64
    var lastAccessedAt: Date
    var mediaRevision: String? = nil
}

struct DatabaseHealth: Sendable, Equatable {
    let isAvailable: Bool
    let lastOpenErrorDescription: String?
}

struct LyricsTranslationRecord: Sendable, Equatable {
    let lineID: Int
    let sourceLanguage: String
    let sourceText: String
    let translatedText: String
}

struct LibraryCatalogRecord: Sendable {
    var songID: String
    var songData: Data
    var titleKey: String
    var artistKey: String
    var albumKey: String
    var mbid: String
    var isrc: String
    var hashEmbedding: Data
    var neuralEmbedding: Data
}

actor AppDatabase {
    static let shared = AppDatabase()

    private nonisolated static let propertyListEncoder = PropertyListEncoder()
    private nonisolated static let propertyListDecoder = PropertyListDecoder()

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

    private struct StoredListeningBehavior: Sendable {
        let songID: String
        let songData: Data
        let playCount: Int
        let firstPlayed: Double
        let lastPlayed: Double
        let completedCount: Int
        let skipCount: Int
        let earlySkipCount: Int
        let repeatedSkipCount: Int
        let repeatCount: Int
        let manualPlayCount: Int
        let searchPlayCount: Int
        let albumSelectionCount: Int
        let playlistPlayCount: Int
        let autoplayCount: Int
        let queueRemovalCount: Int
        let playlistAddCount: Int
        let favoriteCount: Int
        let totalCompletion: Double
        let completionSamples: Int
        let consecutiveSkips: Int
    }

    private struct EncodedListeningBehavior: Sendable {
        let songID: String
        let songData: Data
        let value: SongBehavior
    }

    private struct DecodedQueueItem: Sendable {
        let position: Int
        let entry: PlaybackQueueEntry
    }

    private struct DecodedQueueItems: Sendable {
        let values: [DecodedQueueItem]
        let repairedItems: Bool
    }

    private struct PaletteTouch: Hashable, Sendable {
        let scope: String
        let artworkKey: String
        let engineVersion: Int
    }

    private let databasePath: String
    private let currentDate: @Sendable () -> Date
    private var pool: DatabasePool?
    private var poolTask: Task<(DatabasePool?, Error?), Never>?
    private var lastOpenErrorDescription: String?
    private var pendingPaletteTouches = Set<PaletteTouch>()
    private var paletteTouchTask: Task<Void, Never>?
    private var lyricsTranslationSaveCount: UInt = 0

    private static let externalRecommendationMaximumBytes = 512 * 1_024
    private static let externalRecommendationRetention: TimeInterval = 7 * 24 * 60 * 60
    private static let externalRecommendationEntriesPerSource = 48
    private static let externalRecommendationTotalEntries = 128
    private static let lyricsDocumentMaximumBytes = 512 * 1_024
    private static let lyricsDocumentRetention: TimeInterval = 30 * 24 * 60 * 60
    private static let lyricsDocumentEntriesPerAccount = 256
    private static let lyricsDocumentTotalEntries = 1_024
    private static let lyricsTranslationRetention: TimeInterval = 365 * 24 * 60 * 60
    private static let lyricsTranslationSongsPerAccount = 384
    private static let lyricsTranslationTotalSongs = 1_536
    private static let playbackMetadataMaximumBytes = 64 * 1_024
    private static let playbackMetadataRetention: TimeInterval = 30 * 24 * 60 * 60
    private static let playbackMetadataEntriesPerAccount = 768
    private static let playbackMetadataTotalEntries = 2_048

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

    @concurrent
    private static func openPoolConcurrently(path: String) async -> (DatabasePool?, Error?) {
        guard !Task.isCancelled else { return (nil, nil) }
        return openPool(path: path)
    }

    private func databasePool() async -> DatabasePool? {
        if let pool {
            return pool
        }
        if let poolTask {
            let (openedPool, openError) = await poolTask.value
            if let openError {
                recordOpenFailure(openError)
            } else if openedPool != nil {
                clearOpenFailure()
            }
            pool = openedPool
            return openedPool
        }

        let path = databasePath
        let task = Task(priority: .utility) {
            await Self.openPoolConcurrently(path: path)
        }
        poolTask = task
        let (openedPool, openError) = await task.value
        poolTask = nil
        if let openError {
            recordOpenFailure(openError)
        } else if openedPool != nil {
            clearOpenFailure()
        }
        pool = openedPool
        return openedPool
    }

    /// Opens the GRDB pool off the connect critical path when possible.
    func warmupIfNeeded() async {
        _ = await databasePool()
    }

    func health() async -> DatabaseHealth {
        _ = await databasePool()
        return DatabaseHealth(
            isAvailable: pool != nil,
            lastOpenErrorDescription: lastOpenErrorDescription
        )
    }

    func loadLyricsDocument(
        scope: String,
        songID: String,
        maximumAge: TimeInterval
    ) async -> LyricsDocument? {
        guard !scope.isEmpty, !songID.isEmpty else { return nil }
        let cutoff = currentDate()
            .addingTimeInterval(-max(0, maximumAge))
            .timeIntervalSince1970
        guard let pool = await databasePool() else { return nil }
        do {
            guard let data = try await pool.read({ db -> Data? in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT document_data FROM lyrics_document_cache
                    WHERE account_scope = ? AND song_id = ? AND saved_at >= ?
                    """,
                    arguments: [scope, songID, cutoff]
                ) else { return nil }
                let data: Data = row["document_data"]
                return data
            }), data.count <= Self.lyricsDocumentMaximumBytes,
              let document = await Self.decodeLyricsDocumentConcurrently(data),
              !document.lines.isEmpty else {
                return nil
            }
            return document
        } catch {
            return nil
        }
    }

    @discardableResult
    func saveLyricsDocument(
        _ document: LyricsDocument,
        scope: String,
        songID: String
    ) async -> Bool {
        guard !scope.isEmpty, !songID.isEmpty, !document.lines.isEmpty,
              let data = await Self.encodeLyricsDocumentConcurrently(
                  document,
                  maximumBytes: Self.lyricsDocumentMaximumBytes
              ), let pool = await databasePool() else {
            return false
        }
        let savedAt = currentDate().timeIntervalSince1970
        let expirationCutoff = savedAt - Self.lyricsDocumentRetention
        do {
            try await pool.write { db in
                try db.execute(
                    sql: "DELETE FROM lyrics_document_cache WHERE saved_at < ?",
                    arguments: [expirationCutoff]
                )
                try db.execute(
                    sql: """
                    INSERT INTO lyrics_document_cache (
                        account_scope, song_id, saved_at, document_data
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(account_scope, song_id) DO UPDATE SET
                        saved_at = excluded.saved_at,
                        document_data = excluded.document_data
                    """,
                    arguments: [scope, songID, savedAt, data]
                )
                try db.execute(
                    sql: """
                    DELETE FROM lyrics_document_cache
                    WHERE account_scope = ? AND song_id IN (
                        SELECT song_id FROM lyrics_document_cache
                        WHERE account_scope = ?
                        ORDER BY saved_at DESC, song_id ASC
                        LIMIT -1 OFFSET ?
                    )
                    """,
                    arguments: [
                        scope, scope, Self.lyricsDocumentEntriesPerAccount
                    ]
                )
                try db.execute(
                    sql: """
                    DELETE FROM lyrics_document_cache
                    WHERE (account_scope, song_id) IN (
                        SELECT account_scope, song_id
                        FROM lyrics_document_cache
                        ORDER BY saved_at DESC, account_scope ASC, song_id ASC
                        LIMIT -1 OFFSET ?
                    )
                    """,
                    arguments: [Self.lyricsDocumentTotalEntries]
                )
            }
            return true
        } catch {
            return false
        }
    }

    func loadPlaybackMetadata(
        scope: String,
        songID: String,
        maximumAge: TimeInterval
    ) async -> Song? {
        guard !scope.isEmpty, scope.utf8.count <= 512,
              !songID.isEmpty, songID.utf8.count <= 4_096,
              let pool = await databasePool() else { return nil }
        let cutoff = currentDate()
            .addingTimeInterval(-max(0, maximumAge))
            .timeIntervalSince1970
        do {
            guard let data = try await pool.read({ db -> Data? in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT song_data FROM playback_metadata_cache
                    WHERE account_scope = ? AND song_id = ? AND updated_at >= ?
                    """,
                    arguments: [scope, songID, cutoff]
                ) else { return nil }
                let value: Data = row["song_data"]
                return value
            }), data.count <= Self.playbackMetadataMaximumBytes,
              let song = try? Self.decode(Song.self, from: data),
              song.id == songID else {
                return nil
            }
            return song
        } catch {
            return nil
        }
    }

    @discardableResult
    func savePlaybackMetadata(
        _ song: Song,
        scope: String
    ) async -> Bool {
        guard !scope.isEmpty, scope.utf8.count <= 512,
              !song.id.isEmpty, song.id.utf8.count <= 4_096,
              let data = try? Self.encode(song),
              data.count <= Self.playbackMetadataMaximumBytes,
              let pool = await databasePool() else { return false }
        let updatedAt = currentDate().timeIntervalSince1970
        let expirationCutoff = updatedAt - Self.playbackMetadataRetention
        do {
            try await pool.write { db in
                try db.execute(
                    sql: "DELETE FROM playback_metadata_cache WHERE updated_at < ?",
                    arguments: [expirationCutoff]
                )
                try db.execute(
                    sql: """
                    INSERT INTO playback_metadata_cache (
                        account_scope, song_id, updated_at, song_data
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(account_scope, song_id) DO UPDATE SET
                        updated_at = excluded.updated_at,
                        song_data = excluded.song_data
                    """,
                    arguments: [scope, song.id, updatedAt, data]
                )
                try db.execute(
                    sql: """
                    DELETE FROM playback_metadata_cache
                    WHERE account_scope = ? AND song_id IN (
                        SELECT song_id FROM playback_metadata_cache
                        WHERE account_scope = ?
                        ORDER BY updated_at DESC, song_id ASC
                        LIMIT -1 OFFSET ?
                    )
                    """,
                    arguments: [
                        scope, scope, Self.playbackMetadataEntriesPerAccount
                    ]
                )
                try db.execute(
                    sql: """
                    DELETE FROM playback_metadata_cache
                    WHERE (account_scope, song_id) IN (
                        SELECT account_scope, song_id
                        FROM playback_metadata_cache
                        ORDER BY updated_at DESC, account_scope ASC, song_id ASC
                        LIMIT -1 OFFSET ?
                    )
                    """,
                    arguments: [Self.playbackMetadataTotalEntries]
                )
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func clearPlaybackMetadata(scope: String) async -> Bool {
        guard !scope.isEmpty, scope.utf8.count <= 512,
              let pool = await databasePool() else { return false }
        do {
            try await pool.write { db in
                try db.execute(
                    sql: "DELETE FROM playback_metadata_cache WHERE account_scope = ?",
                    arguments: [scope]
                )
            }
            return true
        } catch {
            return false
        }
    }

    func loadLyricsTranslations(
        scope: String,
        songID: String,
        targetLanguage: String,
        sourceLines: [Int: String]
    ) async -> [Int: String] {
        await loadLyricsTranslations(
            scope: scope,
            songID: songID,
            targetLanguages: [targetLanguage],
            sourceLines: sourceLines
        )
    }

    func loadLyricsTranslations(
        scope: String,
        songID: String,
        targetLanguages: [String],
        sourceLines: [Int: String]
    ) async -> [Int: String] {
        let languages = Array(
            Set(
                targetLanguages.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
            )
        )
        guard !sourceLines.isEmpty,
              !languages.isEmpty,
              let pool = await databasePool() else { return [:] }
        do {
            return try await pool.read { db in
                let placeholders = Array(repeating: "?", count: languages.count)
                    .joined(separator: ", ")
                var arguments: [DatabaseValueConvertible] = [scope, songID]
                arguments.append(contentsOf: languages)
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT line_id, source_text, translated_text, target_language
                    FROM lyrics_translation_cache
                    WHERE account_scope = ?
                      AND song_id = ?
                      AND target_language IN (\(placeholders))
                    """,
                    arguments: StatementArguments(arguments)
                )
                var translations = [Int: String](minimumCapacity: sourceLines.count)
                var translationsBySource = [String: String](
                    minimumCapacity: sourceLines.count
                )
                let languagePriority = Dictionary(
                    uniqueKeysWithValues: languages.enumerated().map {
                        ($0.element, $0.offset)
                    }
                )
                let sortedRows = rows.sorted {
                    let left = languagePriority[$0["target_language"]] ?? Int.max
                    let right = languagePriority[$1["target_language"]] ?? Int.max
                    return left < right
                }
                for row in sortedRows {
                    let lineID: Int = row["line_id"]
                    let sourceText: String = row["source_text"]
                    let translatedText: String = row["translated_text"]
                    guard !translatedText.isEmpty else { continue }
                    let normalizedSource = Self.normalizedLyricSource(sourceText)
                    guard !normalizedSource.isEmpty else { continue }
                    if translationsBySource[normalizedSource] == nil {
                        translationsBySource[normalizedSource] = translatedText
                    }
                    if let currentSource = sourceLines[lineID],
                       Self.normalizedLyricSource(currentSource) == normalizedSource,
                       translations[lineID] == nil {
                        translations[lineID] = translatedText
                    }
                }
                for (lineID, sourceText) in sourceLines
                    where translations[lineID] == nil {
                    let normalizedSource = Self.normalizedLyricSource(sourceText)
                    if let translatedText = translationsBySource[normalizedSource] {
                        translations[lineID] = translatedText
                    }
                }
                return translations
            }
        } catch {
            return [:]
        }
    }

    @discardableResult
    func saveLyricsTranslations(
        _ records: [LyricsTranslationRecord],
        scope: String,
        songID: String,
        targetLanguage: String
    ) async -> Bool {
        guard !records.isEmpty,
              let pool = await databasePool() else { return false }
        lyricsTranslationSaveCount &+= 1
        let prunesCapacity = lyricsTranslationSaveCount == 1
            || lyricsTranslationSaveCount.isMultiple(of: 16)
        let updatedAt = currentDate().timeIntervalSince1970
        let expirationCutoff = updatedAt - Self.lyricsTranslationRetention
        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                    DELETE FROM lyrics_translation_cache
                    WHERE account_scope = ? AND updated_at < ?
                    """,
                    arguments: [scope, expirationCutoff]
                )
                let upsert = try db.makeStatement(sql: """
                    INSERT INTO lyrics_translation_cache (
                        account_scope, song_id, target_language, line_id,
                        source_language, source_text, translated_text, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(
                        account_scope, song_id, target_language, line_id
                    ) DO UPDATE SET
                        source_language = excluded.source_language,
                        source_text = excluded.source_text,
                        translated_text = excluded.translated_text,
                        updated_at = excluded.updated_at
                    """)
                for record in records where !record.translatedText.isEmpty {
                    try upsert.execute(arguments: [
                        scope,
                        songID,
                        targetLanguage,
                        record.lineID,
                        record.sourceLanguage,
                        record.sourceText,
                        record.translatedText,
                        updatedAt
                    ])
                }
                if prunesCapacity {
                    try db.execute(
                        sql: """
                        DELETE FROM lyrics_translation_cache
                        WHERE account_scope = ? AND song_id IN (
                            SELECT song_id FROM lyrics_translation_cache
                            WHERE account_scope = ?
                            GROUP BY song_id
                            ORDER BY MAX(updated_at) DESC, song_id ASC
                            LIMIT -1 OFFSET ?
                        )
                        """,
                        arguments: [
                            scope, scope, Self.lyricsTranslationSongsPerAccount
                        ]
                    )
                    try db.execute(
                        sql: """
                        DELETE FROM lyrics_translation_cache
                        WHERE (account_scope, song_id) IN (
                            SELECT account_scope, song_id
                            FROM lyrics_translation_cache
                            GROUP BY account_scope, song_id
                            ORDER BY MAX(updated_at) DESC,
                                     account_scope ASC,
                                     song_id ASC
                            LIMIT -1 OFFSET ?
                        )
                        """,
                        arguments: [Self.lyricsTranslationTotalSongs]
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    func loadListeningHistory(scope: String) async -> [String: SongBehavior] {
        guard let pool = await databasePool() else { return [:] }
        do {
            let stored = try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM listening_behavior
                    WHERE account_scope = ?
                    """,
                    arguments: [scope]
                )
                return rows.map { row in
                    StoredListeningBehavior(
                        songID: row["song_id"],
                        songData: row["song_data"],
                        playCount: row["play_count"],
                        firstPlayed: row["first_played"],
                        lastPlayed: row["last_played"],
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
                }
            }
            return await Self.decodeListeningHistoryConcurrently(stored)
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
        let encoded: [EncodedListeningBehavior]
        do {
            encoded = try await Self.encodeListeningHistoryConcurrently(values)
        } catch {
            return false
        }
        guard !Task.isCancelled else { return false }
        guard let pool = await databasePool() else { return false }
        do {
            try await pool.write { db in
                for id in deletedIDs {
                    try db.execute(
                        sql: "DELETE FROM listening_behavior WHERE account_scope = ? AND song_id = ?",
                        arguments: [scope, id]
                    )
                }
                for item in encoded {
                    let value = item.value
                    try db.execute(
                        sql: Self.listeningUpsertSQL,
                        arguments: [
                            scope, item.songID, item.songData, value.playCount,
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
        let encoded: [EncodedListeningBehavior]
        do {
            encoded = try await Self.encodeListeningHistoryConcurrently(values)
        } catch {
            return false
        }
        guard !Task.isCancelled else { return false }
        guard let pool = await databasePool() else { return false }
        do {
            try await pool.write { db in
                try db.execute(
                    sql: "DELETE FROM listening_behavior WHERE account_scope = ?",
                    arguments: [scope]
                )
                for item in encoded {
                    let value = item.value
                    try db.execute(
                        sql: Self.listeningUpsertSQL,
                        arguments: [
                            scope, item.songID, item.songData, value.playCount,
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
                        lastAccessedAt: Self.date(row["last_accessed_at"]),
                        mediaRevision: row["media_revision"]
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
                            (account_scope, song_id, file_name, byte_count,
                             last_accessed_at, media_revision)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(account_scope, song_id) DO UPDATE SET
                            file_name = excluded.file_name,
                            byte_count = excluded.byte_count,
                            last_accessed_at = excluded.last_accessed_at,
                            media_revision = excluded.media_revision
                        """,
                        arguments: [
                            scope, id, value.fileName, value.byteCount,
                            value.lastAccessedAt.timeIntervalSince1970,
                            value.mediaRevision
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
                            (account_scope, song_id, file_name, byte_count,
                             last_accessed_at, media_revision)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            scope, id, value.fileName, value.byteCount,
                            value.lastAccessedAt.timeIntervalSince1970,
                            value.mediaRevision
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
        maximumAge: TimeInterval,
        maximumBytes: Int
    ) async -> (snapshot: HomeSnapshot, savedAt: Date)? {
        let cutoff = currentDate()
            .addingTimeInterval(-max(0, maximumAge))
            .timeIntervalSince1970
        guard let pool = await databasePool() else { return nil }
        do {
            guard let loaded = try await pool.read({ db -> (Data, TimeInterval)? in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT snapshot_data, saved_at FROM home_snapshot
                    WHERE account_scope = ? AND saved_at >= ?
                    """,
                    arguments: [scope, cutoff]
                ) else { return nil }
                let data: Data = row["snapshot_data"]
                let savedAt: TimeInterval = row["saved_at"]
                return (data, savedAt)
            }) else { return nil }
            let data = loaded.0
            guard data.count <= max(0, maximumBytes) else { return nil }
            guard let snapshot = await Self.decodeHomeSnapshotConcurrently(data) else {
                return nil
            }
            return (snapshot, Date(timeIntervalSince1970: loaded.1))
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
        guard let data = await Self.encodeHomeSnapshotConcurrently(
            snapshot,
            maximumBytes: maximumBytes
        ), let pool = await databasePool() else { return false }
        let savedAt = currentDate().timeIntervalSince1970
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
                    arguments: [scope, savedAt, data]
                )
            }
            return true
        } catch {
            return false
        }
    }

    func loadLibraryCatalog(scope: String) async -> [LibraryCatalogRecord] {
        guard let pool = await databasePool() else { return [] }
        do {
            return try await pool.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT song_id, song_data, title_key, artist_key, album_key,
                           mbid, isrc, hash_embedding, neural_embedding
                    FROM library_catalog
                    WHERE account_scope = ?
                    """,
                    arguments: [scope]
                )
                return rows.map { row in
                    LibraryCatalogRecord(
                        songID: row["song_id"],
                        songData: row["song_data"],
                        titleKey: row["title_key"],
                        artistKey: row["artist_key"],
                        albumKey: row["album_key"],
                        mbid: row["mbid"],
                        isrc: row["isrc"],
                        hashEmbedding: row["hash_embedding"],
                        neuralEmbedding: row["neural_embedding"]
                    )
                }
            }
        } catch {
            return []
        }
    }

    @discardableResult
    func applyLibraryCatalog(
        _ records: [LibraryCatalogRecord],
        deletedIDs: Set<String>,
        scope: String
    ) async -> Bool {
        guard !records.isEmpty || !deletedIDs.isEmpty else { return true }
        guard let pool = await databasePool() else { return false }
        do {
            try await pool.write { db in
                for id in deletedIDs {
                    try db.execute(
                        sql: """
                        DELETE FROM library_catalog
                        WHERE account_scope = ? AND song_id = ?
                        """,
                        arguments: [scope, id]
                    )
                }
                for record in records {
                    try db.execute(
                        sql: """
                        INSERT INTO library_catalog (
                            account_scope, song_id, song_data, title_key,
                            artist_key, album_key, mbid, isrc,
                            hash_embedding, neural_embedding
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(account_scope, song_id) DO UPDATE SET
                            song_data = excluded.song_data,
                            title_key = excluded.title_key,
                            artist_key = excluded.artist_key,
                            album_key = excluded.album_key,
                            mbid = excluded.mbid,
                            isrc = excluded.isrc,
                            hash_embedding = excluded.hash_embedding,
                            neural_embedding = excluded.neural_embedding
                        """,
                        arguments: [
                            scope, record.songID, record.songData,
                            record.titleKey, record.artistKey, record.albumKey,
                            record.mbid, record.isrc,
                            record.hashEmbedding, record.neuralEmbedding
                        ]
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    func loadExternalRecommendationCache(
        scope: String,
        source: String,
        key: String,
        maximumAge: TimeInterval
    ) async -> [Song] {
        guard !scope.isEmpty,
              !source.isEmpty,
              !key.isEmpty else { return [] }
        let cutoff = currentDate()
            .addingTimeInterval(-max(0, maximumAge))
            .timeIntervalSince1970
        guard let pool = await databasePool() else { return [] }
        do {
            guard let data = try await pool.read({ db -> Data? in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT song_data FROM external_recommendation_cache
                    WHERE account_scope = ? AND source = ? AND cache_key = ?
                      AND saved_at >= ?
                    """,
                    arguments: [scope, source, key, cutoff]
                ) else { return nil }
                let data: Data = row["song_data"]
                return data
            }), data.count <= Self.externalRecommendationMaximumBytes else {
                return []
            }
            return await Self.decodeSongsConcurrently(data) ?? []
        } catch {
            return []
        }
    }

    @discardableResult
    func saveExternalRecommendationCache(
        _ songs: [Song],
        scope: String,
        source: String,
        key: String
    ) async -> Bool {
        guard !scope.isEmpty,
              !source.isEmpty,
              !key.isEmpty,
              !songs.isEmpty,
              let data = await Self.encodeSongsConcurrently(songs),
              data.count <= Self.externalRecommendationMaximumBytes,
              let pool = await databasePool() else { return false }
        let savedAt = currentDate().timeIntervalSince1970
        let expirationCutoff = savedAt - Self.externalRecommendationRetention
        do {
            try await pool.write { db in
                try db.execute(
                    sql: """
                    DELETE FROM external_recommendation_cache
                    WHERE saved_at < ?
                    """,
                    arguments: [expirationCutoff]
                )
                try db.execute(
                    sql: """
                    INSERT INTO external_recommendation_cache (
                        account_scope, source, cache_key, saved_at, song_data
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(account_scope, source, cache_key) DO UPDATE SET
                        saved_at = excluded.saved_at,
                        song_data = excluded.song_data
                    """,
                    arguments: [
                        scope, source, key, savedAt, data
                    ]
                )
                try Self.pruneExternalRecommendationCache(
                    in: db,
                    scope: scope,
                    source: source,
                    maximumEntries: Self.externalRecommendationEntriesPerSource
                )
                try Self.pruneExternalRecommendationCache(
                    in: db,
                    maximumEntries: Self.externalRecommendationTotalEntries
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
        guard !scope.isEmpty,
              scope.utf8.count <= 512,
              !artworkKey.isEmpty,
              artworkKey.utf8.count <= 4_096,
              engineVersion > 0,
              let data = try? Self.encode(palette),
              data.count <= 32_768,
              let pool = await databasePool() else { return false }

        let totalLimit = min(max(maximumTotalEntries, 1), 4_096)
        let scopedLimit = min(
            min(max(maximumEntriesPerScope, 1), 2_048),
            totalLimit
        )
        let wallClock = currentDate().timeIntervalSince1970
        let touches = takePendingPaletteTouches()
        do {
            try await pool.write { db in
                var accessedAt = try Self.nextPaletteAccessTimestamp(
                    in: db,
                    wallClock: wallClock
                )
                try Self.applyPaletteTouches(
                    touches,
                    in: db,
                    nextAccessedAt: &accessedAt
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
            restorePaletteTouches(touches)
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
            let decoded = try await Self.decodeQueueItemsConcurrently(stored.items)
            let decodedItems = decoded.values
            var repairedItems = decoded.repairedItems
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
            let normalizedElapsed = stored.elapsed.isFinite
                ? max(0, stored.elapsed)
                : 0
            let restoredElapsed = selectionWasPreserved ? normalizedElapsed : 0
            let stateNeedsRepair = stored.index != selectedIndex
                || stored.currentSongID != selected.entry.song.id
                || requestedOccurrenceID != selected.entry.id
                || stored.elapsed != restoredElapsed
            let needsRepair = repairedItems || stateNeedsRepair
            let revision = needsRepair
                ? Self.nextQueueRevision(after: storedRevision)
                : storedRevision
            let snapshot = QueueSnapshot(
                entries: entries,
                currentID: selected.entry.song.id,
                currentQueueEntryID: selected.entry.id,
                index: selectedIndex,
                elapsed: restoredElapsed,
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
                encodedItems = try await Self.encodeQueueItemsConcurrently(
                    snapshot.entries
                )
            } else {
                encodedItems = []
            }
        } catch {
            return false
        }
        guard !Task.isCancelled else { return false }
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
                    guard incomingRevision > (persistedRevision ?? -1) else {
                        return false
                    }
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
                    sql: """
                    DELETE FROM queue_item
                    WHERE account_scope = ? AND position >= ?
                    """,
                    arguments: [scope, encodedItems.count]
                )
                for item in encodedItems {
                    try db.execute(
                        sql: """
                        INSERT INTO queue_item
                            (account_scope, position, occurrence_id, song_data)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(account_scope, position) DO UPDATE SET
                            occurrence_id = excluded.occurrence_id,
                            song_data = excluded.song_data
                        WHERE queue_item.occurrence_id IS NOT excluded.occurrence_id
                           OR queue_item.song_data IS NOT excluded.song_data
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
        let revisionAfterPersisted = persistedRevision < Int64.max
            ? persistedRevision + 1
            : Int64.max
        let nextRevision = max(requested, revisionAfterPersisted)
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

    @concurrent
    private static func encodeHomeSnapshotConcurrently(
        _ snapshot: HomeSnapshot,
        maximumBytes: Int
    ) async -> Data? {
        guard !Task.isCancelled,
              let data = try? encode(snapshot),
              data.count <= maximumBytes else {
            return nil
        }
        return data
    }

    @concurrent
    private static func decodeHomeSnapshotConcurrently(
        _ data: Data
    ) async -> HomeSnapshot? {
        guard !Task.isCancelled else { return nil }
        return try? decode(HomeSnapshot.self, from: data)
    }

    @concurrent
    private static func encodeLyricsDocumentConcurrently(
        _ document: LyricsDocument,
        maximumBytes: Int
    ) async -> Data? {
        guard !Task.isCancelled,
              let data = try? encode(document),
              data.count <= maximumBytes else {
            return nil
        }
        return data
    }

    @concurrent
    private static func decodeLyricsDocumentConcurrently(
        _ data: Data
    ) async -> LyricsDocument? {
        guard !Task.isCancelled else { return nil }
        return try? decode(LyricsDocument.self, from: data)
    }

    @concurrent
    private static func decodeListeningHistoryConcurrently(
        _ stored: [StoredListeningBehavior]
    ) async -> [String: SongBehavior] {
        guard !Task.isCancelled else { return [:] }
        var result: [String: SongBehavior] = [:]
        result.reserveCapacity(stored.count)
        let decoder = propertyListDecoder
        for (index, item) in stored.enumerated() {
            if index.isMultiple(of: 32), Task.isCancelled { return [:] }
            guard let song = try? decoder.decode(Song.self, from: item.songData),
                  song.id == item.songID else {
                continue
            }
            result[item.songID] = SongBehavior(
                song: song,
                playCount: item.playCount,
                firstPlayed: date(item.firstPlayed),
                lastPlayed: date(item.lastPlayed),
                completedCount: item.completedCount,
                skipCount: item.skipCount,
                earlySkipCount: item.earlySkipCount,
                repeatedSkipCount: item.repeatedSkipCount,
                repeatCount: item.repeatCount,
                manualPlayCount: item.manualPlayCount,
                searchPlayCount: item.searchPlayCount,
                albumSelectionCount: item.albumSelectionCount,
                playlistPlayCount: item.playlistPlayCount,
                autoplayCount: item.autoplayCount,
                queueRemovalCount: item.queueRemovalCount,
                playlistAddCount: item.playlistAddCount,
                favoriteCount: item.favoriteCount,
                totalCompletion: item.totalCompletion,
                completionSamples: item.completionSamples,
                consecutiveSkips: item.consecutiveSkips
            )
        }
        return result
    }

    @concurrent
    private static func encodeListeningHistoryConcurrently(
        _ values: [String: SongBehavior]
    ) async throws -> [EncodedListeningBehavior] {
        try Task.checkCancellation()
        var result: [EncodedListeningBehavior] = []
        result.reserveCapacity(values.count)
        let encoder = propertyListEncoder
        for (index, pair) in values.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            guard pair.key == pair.value.song.id else { continue }
            result.append(EncodedListeningBehavior(
                songID: pair.key,
                songData: try encoder.encode(pair.value.song),
                value: pair.value
            ))
        }
        return result
    }

    @concurrent
    private static func decodeQueueItemsConcurrently(
        _ items: [StoredQueueItem]
    ) async throws -> DecodedQueueItems {
        try Task.checkCancellation()
        var values: [DecodedQueueItem] = []
        values.reserveCapacity(items.count)
        var repairedItems = false
        let decoder = propertyListDecoder
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            guard let song = try? decoder.decode(Song.self, from: item.songData) else {
                repairedItems = true
                continue
            }
            let parsedID = item.queueEntryID.flatMap(UUID.init(uuidString:))
            if parsedID == nil { repairedItems = true }
            values.append(DecodedQueueItem(
                position: item.position,
                entry: PlaybackQueueEntry(
                    song: song,
                    queueEntryID: parsedID ?? UUID()
                )
            ))
        }
        return DecodedQueueItems(
            values: values,
            repairedItems: repairedItems
        )
    }

    @concurrent
    private static func encodeSongsConcurrently(_ songs: [Song]) async -> Data? {
        guard !Task.isCancelled else { return nil }
        return try? encode(songs)
    }

    @concurrent
    private static func decodeSongsConcurrently(_ data: Data) async -> [Song]? {
        guard !Task.isCancelled else { return nil }
        return try? decode([Song].self, from: data)
    }

    @concurrent
    private static func encodeQueueItemsConcurrently(
        _ entries: [PlaybackQueueEntry]
    ) async throws -> [EncodedQueueItem] {
        try Task.checkCancellation()
        var encoded: [EncodedQueueItem] = []
        encoded.reserveCapacity(entries.count)
        let encoder = propertyListEncoder
        for (position, entry) in entries.enumerated() {
            if position.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            encoded.append(EncodedQueueItem(
                position: position,
                queueEntryID: entry.id.uuidString,
                songData: try encoder.encode(entry.song)
            ))
        }
        return encoded
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try propertyListEncoder.encode(value)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        try propertyListDecoder.decode(type, from: data)
    }

    private static func normalizedLyricSource(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func schedulePaletteTouch(_ touch: PaletteTouch) {
        pendingPaletteTouches.insert(touch)
        schedulePaletteTouchFlushIfNeeded()
    }

    private func schedulePaletteTouchFlushIfNeeded() {
        guard !pendingPaletteTouches.isEmpty else { return }
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

    private func takePendingPaletteTouches() -> [PaletteTouch] {
        paletteTouchTask?.cancel()
        paletteTouchTask = nil
        let touches = pendingPaletteTouches.sorted {
            ($0.scope, $0.artworkKey, $0.engineVersion)
                < ($1.scope, $1.artworkKey, $1.engineVersion)
        }
        pendingPaletteTouches.removeAll(keepingCapacity: true)
        return touches
    }

    private func restorePaletteTouches(_ touches: [PaletteTouch]) {
        guard !touches.isEmpty else { return }
        pendingPaletteTouches.formUnion(touches)
    }

    private func flushScheduledPaletteTouches() async {
        paletteTouchTask = nil
        await flushPaletteTouches()
    }

    /// Commits coalesced cache-recency writes before iOS suspends the app.
    /// The larger stores already expose their own flush points; keeping this
    /// operation inside the database actor preserves write ordering without
    /// making foreground reads wait for a lifecycle checkpoint.
    func flushPendingWrites() async {
        await flushPaletteTouches()
    }

    private func flushPaletteTouches() async {
        guard !pendingPaletteTouches.isEmpty else { return }
        let touches = takePendingPaletteTouches()
        guard let pool = await databasePool() else {
            restorePaletteTouches(touches)
            return
        }
        let wallClock = currentDate().timeIntervalSince1970
        do {
            try await pool.write { db in
                var accessedAt = try Self.nextPaletteAccessTimestamp(
                    in: db,
                    wallClock: wallClock
                )
                try Self.applyPaletteTouches(
                    touches,
                    in: db,
                    nextAccessedAt: &accessedAt
                )
            }
        } catch {
            restorePaletteTouches(touches)
        }
    }

    private static func applyPaletteTouches(
        _ touches: [PaletteTouch],
        in db: Database,
        nextAccessedAt: inout Double
    ) throws {
        for touch in touches {
            try db.execute(
                sql: """
                UPDATE artwork_palette_cache SET last_accessed_at = ?
                WHERE account_scope = ? AND artwork_key = ? AND engine_version = ?
                """,
                arguments: [
                    nextAccessedAt,
                    touch.scope,
                    touch.artworkKey,
                    touch.engineVersion
                ]
            )
            nextAccessedAt = nextAccessedAt.nextUp
        }
    }

    private static func pruneExternalRecommendationCache(
        in db: Database,
        scope: String,
        source: String,
        maximumEntries: Int
    ) throws {
        try db.execute(
            sql: """
            DELETE FROM external_recommendation_cache
            WHERE (account_scope, source, cache_key) IN (
                SELECT account_scope, source, cache_key
                FROM external_recommendation_cache
                WHERE account_scope = ? AND source = ?
                ORDER BY saved_at DESC, cache_key ASC
                LIMIT -1 OFFSET ?
            )
            """,
            arguments: [scope, source, maximumEntries]
        )
    }

    private static func pruneExternalRecommendationCache(
        in db: Database,
        maximumEntries: Int
    ) throws {
        try db.execute(
            sql: """
            DELETE FROM external_recommendation_cache
            WHERE (account_scope, source, cache_key) IN (
                SELECT account_scope, source, cache_key
                FROM external_recommendation_cache
                ORDER BY saved_at DESC, account_scope ASC, source ASC,
                         cache_key ASC
                LIMIT -1 OFFSET ?
            )
            """,
            arguments: [maximumEntries]
        )
    }

    private static func pruneArtworkPalettes(
        in db: Database,
        scope: String,
        maximumEntries: Int
    ) throws {
        try db.execute(
            sql: """
            DELETE FROM artwork_palette_cache
            WHERE (account_scope, artwork_key, engine_version) IN (
                SELECT account_scope, artwork_key, engine_version
                FROM artwork_palette_cache
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
            DELETE FROM artwork_palette_cache
            WHERE (account_scope, artwork_key, engine_version) IN (
                SELECT account_scope, artwork_key, engine_version
                FROM artwork_palette_cache
                ORDER BY last_accessed_at DESC, account_scope ASC,
                         artwork_key ASC, engine_version DESC
                LIMIT -1 OFFSET ?
            )
            """,
            arguments: [maximumEntries]
        )
    }

    private static func openPool(path: String) -> (DatabasePool?, Error?) {
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
            return (try makePool(path: path), nil)
        } catch {
            return (nil, error)
        }
    }

    private func recordOpenFailure(_ error: Error) {
        lastOpenErrorDescription = String(describing: error)
    }

    private func clearOpenFailure() {
        lastOpenErrorDescription = nil
    }

    private static func makePool(path: String) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.label = "BuFi.Database"
        configuration.maximumReaderCount = 3
        configuration.busyMode = .timeout(5)
        configuration.journalMode = .wal
        configuration.automaticMemoryManagement = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
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
        migrator.registerMigration("offline-media-revision-v6") { db in
            try db.execute(sql: """
                ALTER TABLE offline_entry ADD COLUMN media_revision TEXT;
                """)
        }
        migrator.registerMigration("library-catalog-index-v7") { db in
            try db.execute(sql: """
                CREATE TABLE library_catalog (
                    account_scope TEXT NOT NULL,
                    song_id TEXT NOT NULL,
                    song_data BLOB NOT NULL,
                    title_key TEXT NOT NULL,
                    artist_key TEXT NOT NULL,
                    album_key TEXT NOT NULL,
                    mbid TEXT NOT NULL,
                    isrc TEXT NOT NULL,
                    hash_embedding BLOB NOT NULL,
                    neural_embedding BLOB NOT NULL,
                    PRIMARY KEY (account_scope, song_id)
                ) WITHOUT ROWID;
                CREATE INDEX library_catalog_mbid
                    ON library_catalog(account_scope, mbid);
                CREATE INDEX library_catalog_identity
                    ON library_catalog(account_scope, title_key, artist_key);
                """)
        }
        migrator.registerMigration("external-recommendation-cache-v8") { db in
            try db.execute(sql: """
                CREATE TABLE external_recommendation_cache (
                    account_scope TEXT NOT NULL,
                    source TEXT NOT NULL,
                    cache_key TEXT NOT NULL,
                    saved_at DOUBLE NOT NULL,
                    song_data BLOB NOT NULL,
                    PRIMARY KEY (account_scope, source, cache_key)
                ) WITHOUT ROWID;
                """)
        }
        migrator.registerMigration("drop-unused-write-indexes-v9") { db in
            // These indexes were inherited from the first persistence schema,
            // but every current reader loads one account through the composite
            // primary key and processes its in-memory snapshot. Maintaining the
            // unused trees on every playback/catalog write only adds WAL, flash,
            // and checkpoint work.
            try db.execute(sql: """
                DROP INDEX IF EXISTS listening_behavior_recent;
                DROP INDEX IF EXISTS listening_behavior_popular;
                DROP INDEX IF EXISTS offline_entry_lru;
                DROP INDEX IF EXISTS library_catalog_mbid;
                DROP INDEX IF EXISTS library_catalog_identity;
                """)
        }
        migrator.registerMigration("lyrics-translation-cache-v10") { db in
            try db.execute(sql: """
                CREATE TABLE lyrics_translation_cache (
                    account_scope TEXT NOT NULL,
                    song_id TEXT NOT NULL,
                    target_language TEXT NOT NULL,
                    line_id INTEGER NOT NULL,
                    source_language TEXT NOT NULL,
                    source_text TEXT NOT NULL,
                    translated_text TEXT NOT NULL,
                    updated_at DOUBLE NOT NULL,
                    PRIMARY KEY (
                        account_scope, song_id, target_language, line_id
                    )
                ) WITHOUT ROWID;
                CREATE INDEX lyrics_translation_cache_recent
                    ON lyrics_translation_cache(account_scope, updated_at DESC);
                """)
        }
        migrator.registerMigration("lyrics-document-cache-v11") { db in
            try db.execute(sql: """
                CREATE TABLE lyrics_document_cache (
                    account_scope TEXT NOT NULL,
                    song_id TEXT NOT NULL,
                    saved_at DOUBLE NOT NULL,
                    document_data BLOB NOT NULL,
                    PRIMARY KEY (account_scope, song_id)
                ) WITHOUT ROWID;
                CREATE INDEX lyrics_document_cache_recent
                    ON lyrics_document_cache(account_scope, saved_at DESC);
                """)
        }
        migrator.registerMigration("playback-metadata-cache-v12") { db in
            try db.execute(sql: """
                CREATE TABLE playback_metadata_cache (
                    account_scope TEXT NOT NULL,
                    song_id TEXT NOT NULL,
                    updated_at DOUBLE NOT NULL,
                    song_data BLOB NOT NULL,
                    PRIMARY KEY (account_scope, song_id)
                ) WITHOUT ROWID;
                CREATE INDEX playback_metadata_cache_recent
                    ON playback_metadata_cache(account_scope, updated_at DESC);
                """)
        }
        return migrator
    }
}
