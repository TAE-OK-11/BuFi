import XCTest
@testable import BuFi

/// Cheap, synchronous checks for the few behaviors CI should still guard.
final class BuFiSmokeTests: XCTestCase {
    func testPlaybackStartsWithoutALookaheadBuffer() {
        XCTAssertEqual(PlaybackBufferPolicy.startupForwardBuffer, 0)
        XCTAssertEqual(
            PlaybackBufferPolicy.forwardBufferDuration(
                isLocalFile: false,
                phase: .startup
            ),
            0
        )
        XCTAssertEqual(
            PlaybackBufferPolicy.forwardBufferDuration(
                isLocalFile: false,
                phase: .settled
            ),
            12
        )
    }

    func testHealthyPlaybackDoesNotTripTheStallWatchdog() {
        XCTAssertEqual(
            PlaybackWatchdogPolicy.decision(
                wantsPlayback: true,
                timeControlStatus: .playing,
                elapsed: 12,
                hasCurrentItem: true
            ),
            .cancelWatchdog
        )
    }

    func testSameArtistAndTitleCountAsOneRecording() {
        let original = Song(id: "a", title: "Exile", artist: "Taylor Swift", album: "Folklore")
        let copy = Song(id: "b", title: "Exile", artist: "Taylor Swift", album: "Folklore")
        let live = Song(id: "c", title: "Exile (Live)", artist: "Taylor Swift", album: "Folklore")
        XCTAssertEqual(
            TrackWorkIdentity.uniqueRecordings([original, copy, live]).map(\.id),
            ["a", "c"]
        )
        XCTAssertEqual(
            TrackWorkIdentity.coreTitle("Exile (Live)"),
            TrackWorkIdentity.coreTitle("Exile")
        )
    }

    func testRadioIDStreamYieldsIdsAsTextArrives() {
        var already = Set<String>()
        let allowed: Set<String> = ["a1", "b2", "c3"]
        let first = RadioIDStream.newIDs(
            in: #"{"ids":["a1","b"#,
            allowed: allowed,
            already: already
        )
        XCTAssertEqual(first, ["a1"])
        already.formUnion(first)
        XCTAssertEqual(
            RadioIDStream.newIDs(
                in: #"{"ids":["a1","b2","c3"]}"#,
                allowed: allowed,
                already: already
            ),
            ["b2", "c3"]
        )
    }

    func testCanonicalRemastersCollapseToOneMixEntry() {
        let original = Song(
            id: "original",
            title: "Midnight Rain",
            artist: "Taylor Swift",
            album: "Album",
            duration: 180
        )
        let remaster = Song(
            id: "remaster",
            title: "Midnight Rain (Remastered 2026)",
            artist: "Taylor Swift",
            album: "Album",
            duration: 180
        )
        let result = RecommendationMixer.mix(
            snapshot: HomeSnapshot(randomSongs: [original, remaster]),
            weights: RecommendationWeights.current(
                UserDefaults(suiteName: "BuFi.Smoke.\(UUID().uuidString)")!
            ),
            limit: 10,
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(result.count, 1)
    }
}
