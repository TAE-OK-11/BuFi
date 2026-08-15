import Foundation
import XCTest
@testable import BuFi

final class LyricsReliabilityTests: XCTestCase {
    func testParserSkipsEmptyFirstSourceAndUsesNextAvailableLyrics() throws {
        let payload = try decodePayload(
            """
            {
              "lyricsList": {
                "structuredLyrics": [
                  {
                    "synced": true,
                    "line": [{ "start": 0, "value": "   " }]
                  },
                  {
                    "synced": true,
                    "offset": 100,
                    "line": [
                      { "start": 2000, "value": "Second" },
                      { "start": 1000, "value": "First" }
                    ]
                  }
                ]
              }
            }
            """
        )

        let document = LyricsDocumentParser.parse(payload)

        XCTAssertTrue(document.synced)
        XCTAssertEqual(document.lines.map(\.text), ["First", "Second"])
        XCTAssertEqual(document.lines.map(\.start), [1.1, 2.1])
    }

    func testParserPreservesServerOrderForUnsyncedLyrics() throws {
        let payload = try decodePayload(
            """
            {
              "lyricsList": {
                "structuredLyrics": [{
                  "synced": false,
                  "line": [
                    { "start": 9000, "value": "Opening" },
                    { "start": 1000, "value": "Closing" }
                  ]
                }]
              }
            }
            """
        )

        let document = LyricsDocumentParser.parse(payload)

        XCTAssertFalse(document.synced)
        XCTAssertEqual(document.lines.map(\.text), ["Opening", "Closing"])
        XCTAssertEqual(document.lines.map(\.start), [0, 0])
    }

    func testLegacyParserCreatesUnsyncedLinesAndSkipsWhitespace() throws {
        let payload = try JSONDecoder().decode(
            LegacyLyricsPayload.self,
            from: Data(
                """
                {
                  "lyrics": {
                    "artist": "Artist",
                    "title": "Title",
                    "value": " First line \\n  \\nSecond line "
                  }
                }
                """.utf8
            )
        )

        let document = LyricsDocumentParser.parse(payload)

        XCTAssertFalse(document.synced)
        XCTAssertEqual(document.lines.map(\.text), ["First line", "Second line"])
        XCTAssertEqual(document.lines.map(\.start), [0, 0])
    }

    func testPositiveLyricsCacheNeverStoresEmptyDocument() {
        var cache = LyricsDocumentCache(countLimit: 2)
        let now = ContinuousClock().now

        cache.insert(.empty, for: "missing", now: now)

        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.value(for: "missing", maximumAge: 60, now: now))
    }

    func testPositiveLyricsCacheExpiresAndEvictsLeastRecentDocument() {
        var cache = LyricsDocumentCache(countLimit: 2)
        let now = ContinuousClock().now
        let first = document("First")
        let second = document("Second")
        let third = document("Third")

        cache.insert(first, for: "first", now: now)
        cache.insert(second, for: "second", now: now)
        XCTAssertEqual(
            cache.value(for: "first", maximumAge: 60, now: now),
            first
        )
        cache.insert(third, for: "third", now: now)

        XCTAssertNil(cache.value(for: "second", maximumAge: 60, now: now))
        XCTAssertNil(cache.value(
            for: "first",
            maximumAge: 5,
            now: now.advanced(by: .seconds(6))
        ))
        XCTAssertEqual(
            cache.value(for: "third", maximumAge: 60, now: now),
            third
        )
    }

    func testCanonicalMetadataRestartsOnlyUnresolvedLegacyLookup() {
        let provisional = Song(
            id: "song",
            title: "Provisional",
            artist: "",
            album: "Album",
            artistId: nil,
            albumId: nil,
            coverArt: nil,
            duration: 180,
            track: nil,
            suffix: nil,
            contentType: nil,
            starred: nil
        )
        var canonical = provisional
        canonical.title = "Canonical"
        canonical.artist = "Artist"

        XCTAssertTrue(LyricsLookupIdentity.shouldReload(
            from: provisional,
            to: canonical,
            lyricsAreAvailable: false
        ))
        XCTAssertFalse(LyricsLookupIdentity.shouldReload(
            from: provisional,
            to: canonical,
            lyricsAreAvailable: true
        ))
        XCTAssertFalse(LyricsLookupIdentity.shouldReload(
            from: canonical,
            to: canonical,
            lyricsAreAvailable: false
        ))
    }

    private func decodePayload(_ json: String) throws -> LyricsPayload {
        try JSONDecoder().decode(LyricsPayload.self, from: Data(json.utf8))
    }

    private func document(_ text: String) -> LyricsDocument {
        LyricsDocument(
            synced: true,
            lines: [LyricLine(id: 0, start: 1, text: text)]
        )
    }
}
