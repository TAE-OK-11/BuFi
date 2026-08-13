import Foundation
import XCTest
@testable import BuFi

final class AppDatabaseTests: XCTestCase {
    func testLazyDatabaseRetriesAfterTransientOpenFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let blockedDirectory = root.appendingPathComponent("Database")
        try Data().write(to: blockedDirectory)
        let database = AppDatabase(
            lazyDatabaseURL: blockedDirectory.appendingPathComponent("BuFi.sqlite")
        )

        let unavailableHistory = await database.loadListeningHistory(scope: "account")
        XCTAssertTrue(unavailableHistory.isEmpty)

        try FileManager.default.removeItem(at: blockedDirectory)
        try FileManager.default.createDirectory(
            at: blockedDirectory,
            withIntermediateDirectories: true
        )
        let behavior = SongBehavior(
            song: song(id: "retry"),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let saved = await database.applyListeningHistory(
            ["retry": behavior],
            deletedIDs: [],
            scope: "account"
        )
        XCTAssertTrue(saved)
        let recoveredHistory = await database.loadListeningHistory(scope: "account")
        XCTAssertEqual(
            recoveredHistory["retry"]?.song.id,
            "retry"
        )
    }

    func testAccountScopeCanonicalizationMatchesClientScope() async throws {
        let credentials = ServerCredentials(
            serverURL: " HTTPS://Music.Example.test/?ignored=true#fragment ",
            username: " listener ",
            password: "secret"
        )
        let client = try OpenSubsonicClient(credentials: credentials)
        let clientCredentials = await client.credentials
        let clientScope = await client.accountScope
        let expected = AccountScope.identifier(for: clientCredentials)

        XCTAssertEqual(clientScope, expected)
        XCTAssertEqual(
            AccountScope.identifier(for: credentials),
            AccountScope.identifier(for: ServerCredentials(
                serverURL: "https://music.example.test",
                username: "listener",
                password: "different-password"
            ))
        )
    }

    func testListeningHistoryIsIsolatedByAccountAndUpdatesOneSong() async throws {
        let context = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var behavior = SongBehavior(song: song(id: "one"), at: date)
        behavior.playCount = 2
        behavior.completedCount = 1

        let inserted = await context.database.applyListeningHistory(
            ["one": behavior],
            deletedIDs: [],
            scope: "account-a"
        )
        XCTAssertTrue(inserted)
        let otherAccount = await context.database.loadListeningHistory(scope: "account-b")
        XCTAssertEqual(otherAccount.count, 0)

        behavior.playCount = 3
        let updated = await context.database.applyListeningHistory(
            ["one": behavior],
            deletedIDs: [],
            scope: "account-a"
        )
        XCTAssertTrue(updated)
        let loaded = await context.database.loadListeningHistory(scope: "account-a")
        XCTAssertEqual(loaded["one"]?.playCount, 3)
        XCTAssertEqual(loaded["one"]?.song.title, "Song one")
    }

    func testOfflineEntriesSupportUpsertAndDelete() async throws {
        let context = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let entry = OfflineDatabaseEntry(
            fileName: "one.m4a",
            byteCount: 1_024,
            lastAccessedAt: Date(timeIntervalSince1970: 1_800_000_000),
            mediaRevision: "audio-revision"
        )

        let inserted = await context.database.applyOfflineEntries(
            ["one": entry],
            deletedIDs: [],
            scope: "account-a"
        )
        XCTAssertTrue(inserted)
        let loaded = await context.database.loadOfflineEntries(scope: "account-a")
        XCTAssertEqual(loaded["one"], entry)

        let deleted = await context.database.applyOfflineEntries(
            [:],
            deletedIDs: ["one"],
            scope: "account-a"
        )
        XCTAssertTrue(deleted)
        let afterDelete = await context.database.loadOfflineEntries(scope: "account-a")
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testOfflineFileValidationRejectsTruncationAndZeroBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("track.audio")
        try Data(repeating: 7, count: 32).write(to: file)

        XCTAssertTrue(OfflineStore.isValidOfflineFile(
            at: file,
            expectedByteCount: 32
        ))
        XCTAssertFalse(OfflineStore.isValidOfflineFile(
            at: file,
            expectedByteCount: 64
        ))

        try Data().write(to: file)
        XCTAssertFalse(OfflineStore.isValidOfflineFile(
            at: file,
            expectedByteCount: nil
        ))
    }

    func testListeningHistorySkipsOnlyCorruptRows() async throws {
        let context = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = SongBehavior(song: song(id: "valid"), at: date)
        let corrupt = SongBehavior(song: song(id: "corrupt"), at: date)
        let inserted = await context.database.applyListeningHistory(
            ["valid": valid, "corrupt": corrupt],
            deletedIDs: [],
            scope: "account-a"
        )
        XCTAssertTrue(inserted)

        let overwritten = await context.database
            .overwriteListeningHistoryPayloadForTesting(
                Data([0]),
                songID: "corrupt",
                scope: "account-a"
            )
        XCTAssertTrue(overwritten)

        let loaded = await context.database.loadListeningHistory(scope: "account-a")
        XCTAssertEqual(Set(loaded.keys), ["valid"])
    }

    func testOfflineStoreRejectsClientFromAnotherAccountScope() async throws {
        let store = OfflineStore()
        let activeCredentials = ServerCredentials(
            serverURL: "https://active.example.test",
            username: "listener",
            password: "secret"
        )
        let otherClient = try OpenSubsonicClient(credentials: ServerCredentials(
            serverURL: "https://other.example.test",
            username: "listener",
            password: "secret"
        ))
        let scope = AccountScope.identifier(for: activeCredentials)
        let activation = await store.activate(accountScope: scope)
        let session = try XCTUnwrap(activation)

        do {
            _ = try await store.download(song: song(id: "one"), client: otherClient)
            XCTFail("A client from another account scope must be rejected")
        } catch let error as OpenSubsonicError {
            XCTAssertEqual(error, .invalidResponse)
        }

        try await store.removeAll()
        await store.deactivate(session: session)
    }

    func testOfflineStoreStaleLeaseCannotDeactivateNewSameAccountActivation() async throws {
        let store = OfflineStore()
        let scope = "offline-lease-\(UUID().uuidString)"
        let firstActivation = await store.activate(accountScope: scope)
        let first = try XCTUnwrap(firstActivation)
        let secondActivation = await store.activate(accountScope: scope)
        let second = try XCTUnwrap(secondActivation)

        XCTAssertNotEqual(first, second)
        let staleDeactivated = await store.deactivate(session: first)
        XCTAssertFalse(staleDeactivated)
        let currentDeactivated = await store.deactivate(session: second)
        XCTAssertTrue(currentDeactivated)
    }

    func testArtworkStoreStaleLeaseCannotDeactivateNewSameAccountActivation() async {
        let store = ArtworkStore()
        let scope = "artwork-lease-\(UUID().uuidString)"
        let first = await store.activate(accountScope: scope)
        let second = await store.activate(accountScope: scope)

        XCTAssertNotEqual(first, second)
        let staleDeactivated = await store.deactivate(session: first)
        XCTAssertFalse(staleDeactivated)
        let currentDeactivated = await store.deactivate(session: second)
        XCTAssertTrue(currentDeactivated)
    }

    func testListeningHistoryStoreStaleLeaseCannotDeactivateNewSameAccountActivation() async throws {
        let store = ListeningHistoryStore.shared
        let scope = "history-lease-\(UUID().uuidString)"
        let firstActivation = await store.activate(accountScope: scope)
        let first = try XCTUnwrap(firstActivation)
        let secondActivation = await store.activate(accountScope: scope)
        let second = try XCTUnwrap(secondActivation)

        XCTAssertNotEqual(first, second)
        let staleDeactivated = await store.deactivate(session: first)
        XCTAssertFalse(staleDeactivated)
        let currentDeactivated = await store.deactivate(session: second)
        XCTAssertTrue(currentDeactivated)
    }

    func testQueueAndHomeSnapshotRoundTripBinaryPayloads() async throws {
        let context = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let first = song(id: "one")
        let second = song(id: "two")
        let queue = QueueSnapshot(
            queue: [first, second],
            currentID: second.id,
            index: 1,
            elapsed: 42,
            shuffle: true,
            repeatMode: .all,
            revision: 1
        )
        let queueSaved = await context.database.saveQueue(queue, scope: "account-a")
        XCTAssertTrue(queueSaved)
        let restored = await context.database.loadQueue(scope: "account-a")
        XCTAssertEqual(restored?.queue, [first, second])
        XCTAssertEqual(restored?.currentID, second.id)
        XCTAssertEqual(restored?.currentQueueEntryID, queue.currentQueueEntryID)
        XCTAssertEqual(restored?.elapsed, 42)
        XCTAssertEqual(restored?.repeatMode, .all)
        let missingOtherAccount = await context.database.loadQueue(scope: "account-b")
        XCTAssertNil(missingOtherAccount)

        let stateOnlyUpdate = QueueSnapshot(
            entries: queue.entries,
            currentID: first.id,
            currentQueueEntryID: queue.entries[0].id,
            index: 0,
            elapsed: 84,
            shuffle: false,
            repeatMode: .one,
            revision: 2
        )
        let stateSaved = await context.database.saveQueue(
            stateOnlyUpdate,
            scope: "account-a",
            replacingItems: false
        )
        XCTAssertTrue(stateSaved)
        let stateRestored = await context.database.loadQueue(scope: "account-a")
        XCTAssertEqual(stateRestored?.queue, [first, second])
        XCTAssertEqual(stateRestored?.currentID, first.id)
        XCTAssertEqual(stateRestored?.elapsed, 84)
        XCTAssertEqual(stateRestored?.shuffle, false)
        XCTAssertEqual(stateRestored?.repeatMode, .one)

        let staleSave = await context.database.saveQueue(
            QueueSnapshot(
                queue: [first, second],
                currentID: second.id,
                index: 1,
                elapsed: 999,
                shuffle: true,
                repeatMode: .all,
                revision: 1
            ),
            scope: "account-a"
        )
        XCTAssertFalse(staleSave)
        let staleRestored = await context.database.loadQueue(scope: "account-a")
        XCTAssertEqual(staleRestored?.elapsed, 84)

        let tombstoneRevision = await context.database.clearQueue(
            scope: "account-a",
            minimumRevision: 2
        )
        XCTAssertEqual(tombstoneRevision, 3)
        let tombstone = await context.database.loadQueue(scope: "account-a")
        XCTAssertEqual(tombstone?.queue, [])
        XCTAssertEqual(tombstone?.revision, 3)

        let resurrectingSave = await context.database.saveQueue(
            QueueSnapshot(
                queue: [first],
                currentID: first.id,
                index: 0,
                elapsed: 1,
                shuffle: false,
                repeatMode: .off,
                revision: 3
            ),
            scope: "account-a"
        )
        XCTAssertFalse(resurrectingSave)
        let afterResurrection = await context.database.loadQueue(
            scope: "account-a"
        )
        XCTAssertEqual(afterResurrection?.queue, [])

        let secondAccountQueue = QueueSnapshot(
            queue: [second],
            currentID: second.id,
            index: 0,
            elapsed: 12,
            shuffle: false,
            repeatMode: .off,
            revision: 1
        )
        let secondAccountSaved = await context.database.saveQueue(
            secondAccountQueue,
            scope: "account-b"
        )
        XCTAssertTrue(secondAccountSaved)
        let firstAccountRestored = await context.database.loadQueue(scope: "account-a")
        let secondAccountRestored = await context.database.loadQueue(scope: "account-b")
        XCTAssertEqual(firstAccountRestored?.queue, [])
        XCTAssertEqual(secondAccountRestored?.queue, [second])

        let snapshot = HomeSnapshot(starredSongs: [first])
        let snapshotSaved = await context.database.saveHomeSnapshot(
            snapshot,
            scope: "account-a",
            maximumBytes: 1_000_000
        )
        XCTAssertTrue(snapshotSaved)
        let loadedSnapshot = await context.database.loadHomeSnapshot(
            scope: "account-a",
            maximumAge: 60
        )
        XCTAssertEqual(loadedSnapshot, snapshot)
    }

    func testQueueRestorePreservesSelectedDuplicateOccurrence() async throws {
        let context = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let duplicate = song(id: "duplicate")
        let first = PlaybackQueueEntry(song: duplicate)
        let second = PlaybackQueueEntry(song: duplicate)
        let snapshot = QueueSnapshot(
            entries: [first, second],
            currentID: duplicate.id,
            currentQueueEntryID: second.id,
            index: 1,
            elapsed: 12,
            shuffle: false,
            repeatMode: .off,
            revision: 7
        )

        let saved = await context.database.saveQueue(snapshot, scope: "account")
        XCTAssertTrue(saved)
        let restored = await context.database.loadQueue(scope: "account")

        XCTAssertEqual(restored?.entries.map(\.id), [first.id, second.id])
        XCTAssertEqual(restored?.currentQueueEntryID, second.id)
        XCTAssertEqual(restored?.index, 1)
        XCTAssertEqual(restored?.revision, 7)
    }

    func testQueueRestoreSkipsCorruptRowsAndPersistsRepair() async throws {
        let context = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let first = PlaybackQueueEntry(song: song(id: "first"))
        let corrupt = PlaybackQueueEntry(song: song(id: "corrupt"))
        let current = PlaybackQueueEntry(song: song(id: "current"))
        let snapshot = QueueSnapshot(
            entries: [first, corrupt, current],
            currentID: current.song.id,
            currentQueueEntryID: current.id,
            index: 2,
            elapsed: 37,
            shuffle: true,
            repeatMode: .all,
            revision: 5
        )
        let saved = await context.database.saveQueue(snapshot, scope: "account")
        XCTAssertTrue(saved)
        let corrupted = await context.database.overwriteQueuePayloadForTesting(
            Data([0]),
            position: 1,
            scope: "account"
        )
        XCTAssertTrue(corrupted)

        let repaired = await context.database.loadQueue(scope: "account")

        XCTAssertEqual(repaired?.entries.map(\.id), [first.id, current.id])
        XCTAssertEqual(repaired?.currentQueueEntryID, current.id)
        XCTAssertEqual(repaired?.index, 1)
        XCTAssertEqual(repaired?.elapsed, 37)
        XCTAssertEqual(repaired?.revision, 6)

        let persistedRepair = await context.database.loadQueue(scope: "account")
        XCTAssertEqual(persistedRepair?.entries.map(\.id), [first.id, current.id])
        XCTAssertEqual(persistedRepair?.revision, 6)
    }

    func testArtworkPaletteCacheIsAccountAndVersionIsolated() async throws {
        let context = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let palette = artworkPalette(seed: 0.1)

        let saved = await context.database.saveArtworkPalette(
            palette,
            scope: "account-a",
            artworkKey: "cover-one",
            engineVersion: 3
        )
        XCTAssertTrue(saved)
        let loaded = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "cover-one",
            engineVersion: 3
        )
        XCTAssertEqual(loaded, palette)
        let otherAccount = await context.database.loadArtworkPalette(
            scope: "account-b",
            artworkKey: "cover-one",
            engineVersion: 3
        )
        XCTAssertNil(otherAccount)
        let otherVersion = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "cover-one",
            engineVersion: 2
        )
        XCTAssertNil(otherVersion)

        let nextVersion = artworkPalette(seed: 0.2)
        let nextSaved = await context.database.saveArtworkPalette(
            nextVersion,
            scope: "account-a",
            artworkKey: "cover-one",
            engineVersion: 4
        )
        XCTAssertTrue(nextSaved)
        let stale = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "cover-one",
            engineVersion: 3
        )
        XCTAssertNil(stale)
        let current = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "cover-one",
            engineVersion: 4
        )
        XCTAssertEqual(current, nextVersion)
    }

    func testArtworkPaletteCachePrunesLeastRecentlyUsedWithinScope() async throws {
        let context = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: context.directory) }

        for index in 1...2 {
            let saved = await context.database.saveArtworkPalette(
                artworkPalette(seed: Double(index) / 10),
                scope: "account-a",
                artworkKey: "cover-\(index)",
                engineVersion: 3,
                maximumEntriesPerScope: 2,
                maximumTotalEntries: 4
            )
            XCTAssertTrue(saved)
        }
        // Touch cover-1, making cover-2 the least recently used entry.
        let touched = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "cover-1",
            engineVersion: 3
        )
        XCTAssertNotNil(touched)
        let thirdSaved = await context.database.saveArtworkPalette(
            artworkPalette(seed: 0.3),
            scope: "account-a",
            artworkKey: "cover-3",
            engineVersion: 3,
            maximumEntriesPerScope: 2,
            maximumTotalEntries: 4
        )
        XCTAssertTrue(thirdSaved)

        let first = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "cover-1",
            engineVersion: 3
        )
        let second = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "cover-2",
            engineVersion: 3
        )
        let third = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "cover-3",
            engineVersion: 3
        )
        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertNotNil(third)

        let otherAccountPalette = artworkPalette(seed: 0.8)
        let otherSaved = await context.database.saveArtworkPalette(
            otherAccountPalette,
            scope: "account-b",
            artworkKey: "cover-1",
            engineVersion: 3
        )
        XCTAssertTrue(otherSaved)
        await context.database.clearArtworkPalettes(scope: "account-a")
        let cleared = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "cover-1",
            engineVersion: 3
        )
        let preserved = await context.database.loadArtworkPalette(
            scope: "account-b",
            artworkKey: "cover-1",
            engineVersion: 3
        )
        XCTAssertNil(cleared)
        XCTAssertEqual(preserved, otherAccountPalette)
    }

    func testArtworkPaletteCacheEnforcesIndependentTotalLimit() async throws {
        let context = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: context.directory) }

        for index in 1...3 {
            let saved = await context.database.saveArtworkPalette(
                artworkPalette(seed: Double(index) / 10),
                scope: "account-a",
                artworkKey: "total-\(index)",
                engineVersion: 3,
                maximumEntriesPerScope: 10,
                maximumTotalEntries: 2
            )
            XCTAssertTrue(saved)
        }

        let oldest = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "total-1",
            engineVersion: 3
        )
        let second = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "total-2",
            engineVersion: 3
        )
        let newest = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "total-3",
            engineVersion: 3
        )
        XCTAssertNil(oldest)
        XCTAssertNotNil(second)
        XCTAssertNotNil(newest)
    }

    func testArtworkPaletteCachePrunesGloballyLeastRecentlyUsedRow() async throws {
        let context = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: context.directory) }

        for (scope, key, seed) in [
            ("account-a", "a-1", 0.1),
            ("account-b", "b-1", 0.2)
        ] {
            let saved = await context.database.saveArtworkPalette(
                artworkPalette(seed: seed),
                scope: scope,
                artworkKey: key,
                engineVersion: 3,
                maximumEntriesPerScope: 2,
                maximumTotalEntries: 2
            )
            XCTAssertTrue(saved)
        }

        let touched = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "a-1",
            engineVersion: 3
        )
        XCTAssertNotNil(touched)
        let overflowSaved = await context.database.saveArtworkPalette(
            artworkPalette(seed: 0.3),
            scope: "account-a",
            artworkKey: "a-2",
            engineVersion: 3,
            maximumEntriesPerScope: 2,
            maximumTotalEntries: 2
        )
        XCTAssertTrue(overflowSaved)

        let first = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "a-1",
            engineVersion: 3
        )
        let second = await context.database.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "a-2",
            engineVersion: 3
        )
        let evicted = await context.database.loadArtworkPalette(
            scope: "account-b",
            artworkKey: "b-1",
            engineVersion: 3
        )
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNil(evicted)
    }

    func testArtworkPaletteLRURemainsMonotonicAcrossClockRollback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("clock.sqlite")
        let future = Date(timeIntervalSince1970: 2_000_000_000)
        let past = Date(timeIntervalSince1970: 1_000_000_000)

        let beforeRestart = try AppDatabase(
            databaseURL: databaseURL,
            currentDate: { future }
        )
        let oldSaved = await beforeRestart.saveArtworkPalette(
            artworkPalette(seed: 0.1),
            scope: "account-a",
            artworkKey: "old",
            engineVersion: 3,
            maximumEntriesPerScope: 1,
            maximumTotalEntries: 1
        )
        XCTAssertTrue(oldSaved)

        let afterRestart = try AppDatabase(
            databaseURL: databaseURL,
            currentDate: { past }
        )
        let newSaved = await afterRestart.saveArtworkPalette(
            artworkPalette(seed: 0.2),
            scope: "account-a",
            artworkKey: "new",
            engineVersion: 3,
            maximumEntriesPerScope: 1,
            maximumTotalEntries: 1
        )
        XCTAssertTrue(newSaved)

        let old = await afterRestart.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "old",
            engineVersion: 3
        )
        let new = await afterRestart.loadArtworkPalette(
            scope: "account-a",
            artworkKey: "new",
            engineVersion: 3
        )
        XCTAssertNil(old)
        XCTAssertNotNil(new)
    }

    private func makeDatabase() throws -> (
        database: AppDatabase,
        directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        return (try AppDatabase(databaseURL: databaseURL), directory)
    }

    private func song(id: String) -> Song {
        Song(
            id: id,
            title: "Song \(id)",
            artist: "Artist",
            album: "Album"
        )
    }

    private func artworkPalette(seed: Double) -> ArtworkPalette {
        ArtworkPalette(
            top: RGBAColor(red: seed, green: 0.3, blue: 0.4, alpha: 1),
            bottom: RGBAColor(red: 0.05, green: seed, blue: 0.1, alpha: 1),
            accent: RGBAColor(red: 0.7, green: seed, blue: 0.2, alpha: 1),
            secondary: RGBAColor(red: 0.2, green: 0.4, blue: seed, alpha: 1),
            accentPosition: PalettePosition(x: 0.2, y: 0.8),
            secondaryPosition: PalettePosition(x: 0.8, y: 0.2)
        )
    }
}
