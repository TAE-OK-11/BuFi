import Foundation
import XCTest
@testable import BuFi

final class ResponseBodyCacheTests: XCTestCase {
    func testRecentlyReadEntrySurvivesCountEviction() {
        var cache = ResponseBodyCache(
            countLimit: 2,
            byteLimit: 32,
            maximumEntryBytes: 16
        )
        let now = ContinuousClock().now

        cache.insert(Data([1]), for: "first", now: now)
        cache.insert(Data([2]), for: "second", now: now)
        XCTAssertEqual(
            cache.value(for: "first", maximumAge: 60, now: now),
            Data([1])
        )
        cache.insert(Data([3]), for: "third", now: now)

        XCTAssertNil(cache.value(for: "second", maximumAge: 60, now: now))
        XCTAssertEqual(cache.value(for: "first", maximumAge: 60, now: now), Data([1]))
        XCTAssertEqual(cache.value(for: "third", maximumAge: 60, now: now), Data([3]))
    }

    func testByteBudgetEvictsLeastRecentlyUsedEntry() {
        var cache = ResponseBodyCache(
            countLimit: 8,
            byteLimit: 3,
            maximumEntryBytes: 3
        )
        let now = ContinuousClock().now

        cache.insert(Data([1, 2]), for: "first", now: now)
        cache.insert(Data([3, 4]), for: "second", now: now)

        XCTAssertNil(cache.value(for: "first", maximumAge: 60, now: now))
        XCTAssertEqual(cache.value(for: "second", maximumAge: 60, now: now), Data([3, 4]))
        XCTAssertEqual(cache.byteCount, 2)
    }

    func testExpiredEntryIsRemovedFromAccounting() {
        var cache = ResponseBodyCache(
            countLimit: 2,
            byteLimit: 16,
            maximumEntryBytes: 16
        )
        let storedAt = ContinuousClock().now
        cache.insert(Data([1, 2, 3]), for: "value", now: storedAt)

        XCTAssertNil(cache.value(
            for: "value",
            maximumAge: 5,
            now: storedAt.advanced(by: .seconds(6))
        ))
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.byteCount, 0)
    }

    func testUncacheableReplacementInvalidatesOlderBody() {
        var cache = ResponseBodyCache(
            countLimit: 2,
            byteLimit: 8,
            maximumEntryBytes: 4
        )
        let now = ContinuousClock().now
        cache.insert(Data([1]), for: "value", now: now)
        cache.insert(Data(repeating: 2, count: 5), for: "value", now: now)

        XCTAssertNil(cache.value(for: "value", maximumAge: 60, now: now))
        XCTAssertEqual(cache.byteCount, 0)
    }
}
