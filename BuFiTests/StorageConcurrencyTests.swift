import Foundation
import XCTest
@testable import BuFi

final class StorageConcurrencyTests: XCTestCase {
    func testOfflineDownloadKeyDoesNotFlattenScopeAndSong() {
        let first = OfflineDownloadKey(accountScope: "account:a", songID: "b")
        let second = OfflineDownloadKey(accountScope: "account", songID: "a:b")
        XCTAssertNotEqual(first, second)
    }

    func testOfflineAccessRecencyRemainsMonotonicAcrossClockRollback() {
        var recency = OfflineAccessRecency()
        let initial = Date(timeIntervalSince1970: 2_000)
        recency.seed(lastAccess: initial, now: initial)
        let first = recency.next(now: initial.addingTimeInterval(10))
        let rolledBack = recency.next(now: initial.addingTimeInterval(-100))
        XCTAssertGreaterThan(rolledBack, first)
    }

    func testOfflineAccessRecencyClampsFutureSeed() {
        var recency = OfflineAccessRecency()
        let now = Date(timeIntervalSince1970: 2_000)
        recency.seed(lastAccess: now.addingTimeInterval(3_600), now: now)
        XCTAssertLessThanOrEqual(recency.lastIssued, now)
    }

    func testCacheFreshnessRejectsFarFutureSnapshot() {
        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertFalse(CacheFreshnessPolicy.isFresh(
            savedAt: now.addingTimeInterval(3_600),
            now: now,
            maximumAge: 7 * 24 * 60 * 60
        ))
    }

    func testCacheFreshnessAllowsSmallClockSkew() {
        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(CacheFreshnessPolicy.isFresh(
            savedAt: now.addingTimeInterval(60),
            now: now,
            maximumAge: 7 * 24 * 60 * 60
        ))
    }

    func testArtworkPaletteRequestKeySeparatesAccountsAndGenerations() {
        let first = ArtworkPaletteRequestKey(
            accountScope: "a",
            cacheKey: "cover",
            generation: 1
        )
        let second = ArtworkPaletteRequestKey(
            accountScope: "a",
            cacheKey: "cover",
            generation: 2
        )
        let third = ArtworkPaletteRequestKey(
            accountScope: "b",
            cacheKey: "cover",
            generation: 1
        )
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, third)
    }
}
