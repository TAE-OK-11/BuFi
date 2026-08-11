import AVFoundation
import XCTest
@testable import BuFi

final class PlaybackPrefetchPlanTests: XCTestCase {
    func testPrefetchWaitsUntilCurrentSongIsActivelyPlaying() {
        let current = song(id: "current")
        let next = song(id: "next")

        XCTAssertNil(PlaybackPrefetchPlan.make(
            currentSong: current,
            queue: [current, next],
            queueIndex: 0,
            quality: .automatic,
            maximumUpcoming: 2,
            isActivelyPlaying: false
        ))

        XCTAssertEqual(
            PlaybackPrefetchPlan.make(
                currentSong: current,
                queue: [current, next],
                queueIndex: 0,
                quality: .automatic,
                maximumUpcoming: 2,
                isActivelyPlaying: true
            )?.key.upcomingSongIDs,
            ["next"]
        )
    }

    func testPrefetchSkipsExternalStreamsAndFillsFromLaterQueueItems() {
        let current = song(id: "current")
        let radio = song(id: "radio", externalStreamURL: "https://radio.example/live")
        let firstServerSong = song(id: "server-1")
        let secondServerSong = song(id: "server-2")

        let plan = PlaybackPrefetchPlan.make(
            currentSong: current,
            queue: [current, radio, firstServerSong, secondServerSong],
            queueIndex: 0,
            quality: .aac320,
            maximumUpcoming: 2,
            isActivelyPlaying: true
        )

        XCTAssertEqual(plan?.key.upcomingSongIDs, ["server-1", "server-2"])
        XCTAssertEqual(plan?.key.quality, StreamQuality.aac320.rawValue)
    }

    func testPrefetchRejectsAQueuePositionThatDoesNotMatchCurrentSong() {
        let current = song(id: "current")
        let other = song(id: "other")

        XCTAssertNil(PlaybackPrefetchPlan.make(
            currentSong: current,
            queue: [other, current],
            queueIndex: 0,
            quality: .automatic,
            maximumUpcoming: 1,
            isActivelyPlaying: true
        ))
    }

    func testNetworkFailureRetriesTransportInsteadOfChangingCodec() {
        let error = URLError(.networkConnectionLost)
        XCTAssertEqual(
            PlaybackFailureClassifier.disposition(for: error),
            .retryTransport
        )
    }

    func testDecoderFailureUsesCompatibilityFallback() {
        let error = NSError(
            domain: AVFoundationErrorDomain,
            code: -11_800
        )
        XCTAssertEqual(
            PlaybackFailureClassifier.disposition(for: error),
            .tryCompatibilityFormat
        )
    }

    func testWrappedNetworkFailureStillRetriesTransport() {
        let wrapped = NSError(
            domain: AVFoundationErrorDomain,
            code: -11_828,
            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)]
        )
        XCTAssertEqual(
            PlaybackFailureClassifier.disposition(for: wrapped),
            .retryTransport
        )
    }

    func testGaplessPlanStagesOnlyDeterministicSuccessor() {
        XCTAssertEqual(
            GaplessSuccessorPlan.make(
                queueCount: 3,
                currentIndex: 1,
                shuffleEnabled: false,
                repeatMode: .off
            )?.queueIndex,
            2
        )
        XCTAssertNil(GaplessSuccessorPlan.make(
            queueCount: 3,
            currentIndex: 1,
            shuffleEnabled: true,
            repeatMode: .off
        ))
        XCTAssertNil(GaplessSuccessorPlan.make(
            queueCount: 3,
            currentIndex: 1,
            shuffleEnabled: false,
            repeatMode: .one
        ))
    }

    func testGaplessPlanWrapsOnlyForRepeatAll() {
        XCTAssertNil(GaplessSuccessorPlan.make(
            queueCount: 2,
            currentIndex: 1,
            shuffleEnabled: false,
            repeatMode: .off
        ))
        XCTAssertEqual(
            GaplessSuccessorPlan.make(
                queueCount: 2,
                currentIndex: 1,
                shuffleEnabled: false,
                repeatMode: .all
            )?.queueIndex,
            0
        )
    }

    private func song(
        id: String,
        externalStreamURL: String? = nil
    ) -> Song {
        Song(
            id: id,
            title: id,
            artist: "Artist",
            album: "Album",
            artistId: "artist",
            albumId: "album",
            coverArt: nil,
            duration: 180,
            track: 1,
            suffix: "m4a",
            contentType: "audio/mp4",
            starred: nil,
            externalStreamURL: externalStreamURL
        )
    }
}
