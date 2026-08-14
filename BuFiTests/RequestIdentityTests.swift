import Foundation
import XCTest
@testable import BuFi

final class RequestIdentityTests: XCTestCase {
    func testOpenSubsonicReadKeyIsIndependentOfQueryOrder() {
        let revision = OpenSubsonicCacheRevision(entries: [])
        let first = OpenSubsonicReadRequestKey(
            endpoint: "search3",
            queryItems: [
                URLQueryItem(name: "query", value: "Taylor Swift"),
                URLQueryItem(name: "songCount", value: "25")
            ],
            cacheRevision: revision
        )
        let second = OpenSubsonicReadRequestKey(
            endpoint: "search3",
            queryItems: [
                URLQueryItem(name: "songCount", value: "25"),
                URLQueryItem(name: "query", value: "Taylor Swift")
            ],
            cacheRevision: revision
        )

        XCTAssertEqual(first, second)
    }

    func testOpenSubsonicReadKeyDoesNotFlattenQuerySeparators() {
        let revision = OpenSubsonicCacheRevision(entries: [])
        let first = OpenSubsonicReadRequestKey(
            endpoint: "test",
            queryItems: [URLQueryItem(name: "a", value: "b=c")],
            cacheRevision: revision
        )
        let second = OpenSubsonicReadRequestKey(
            endpoint: "test",
            queryItems: [URLQueryItem(name: "a=b", value: "c")],
            cacheRevision: revision
        )

        XCTAssertNotEqual(first, second)
    }

    func testOpenSubsonicReadKeyDistinguishesNilAndEmptyValues() {
        let revision = OpenSubsonicCacheRevision(entries: [])
        let missingValue = OpenSubsonicReadRequestKey(
            endpoint: "test",
            queryItems: [URLQueryItem(name: "flag", value: nil)],
            cacheRevision: revision
        )
        let emptyValue = OpenSubsonicReadRequestKey(
            endpoint: "test",
            queryItems: [URLQueryItem(name: "flag", value: "")],
            cacheRevision: revision
        )

        XCTAssertNotEqual(missingValue, emptyValue)
    }

    func testPreparedPlaybackKeyDoesNotAliasDelimiterBearingFields() {
        let occurrence = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let first = PreparedPlaybackKey(
            accountScope: "account",
            queueEntryID: occurrence,
            streamRevision: "rev|aac320",
            quality: .automatic,
            compatibilityFormat: "aac"
        )
        let second = PreparedPlaybackKey(
            accountScope: "account",
            queueEntryID: occurrence,
            streamRevision: "rev",
            quality: .aac320,
            compatibilityFormat: "automatic|aac"
        )

        XCTAssertNotEqual(first, second)
    }

    func testPreparedPlaybackKeyNormalizesCompatibilityFormatCase() {
        let occurrence = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let first = PreparedPlaybackKey(
            accountScope: nil,
            queueEntryID: occurrence,
            streamRevision: "revision",
            quality: .original,
            compatibilityFormat: "AAC"
        )
        let second = PreparedPlaybackKey(
            accountScope: nil,
            queueEntryID: occurrence,
            streamRevision: "revision",
            quality: .original,
            compatibilityFormat: "aac"
        )

        XCTAssertEqual(first, second)
    }
}
