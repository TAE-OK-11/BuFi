import Foundation
import XCTest
@testable import BuFi

final class AppDatabaseTests: XCTestCase {
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
            lastAccessedAt: Date(timeIntervalSince1970: 1_800_000_000)
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
            repeatMode: .all
        )
        let queueSaved = await context.database.saveQueue(queue)
        XCTAssertTrue(queueSaved)
        let restored = await context.database.loadQueue()
        XCTAssertEqual(restored?.queue, [first, second])
        XCTAssertEqual(restored?.currentID, second.id)
        XCTAssertEqual(restored?.elapsed, 42)
        XCTAssertEqual(restored?.repeatMode, .all)

        let stateOnlyUpdate = QueueSnapshot(
            queue: [first, second],
            currentID: first.id,
            index: 0,
            elapsed: 84,
            shuffle: false,
            repeatMode: .one
        )
        let stateSaved = await context.database.saveQueue(
            stateOnlyUpdate,
            replacingItems: false
        )
        XCTAssertTrue(stateSaved)
        let stateRestored = await context.database.loadQueue()
        XCTAssertEqual(stateRestored?.queue, [first, second])
        XCTAssertEqual(stateRestored?.currentID, first.id)
        XCTAssertEqual(stateRestored?.elapsed, 84)
        XCTAssertEqual(stateRestored?.shuffle, false)
        XCTAssertEqual(stateRestored?.repeatMode, .one)

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

    private func makeDatabase() throws -> (database: AppDatabase, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (
            try AppDatabase(databaseURL: directory.appendingPathComponent("test.sqlite")),
            directory
        )
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
