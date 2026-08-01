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
}
