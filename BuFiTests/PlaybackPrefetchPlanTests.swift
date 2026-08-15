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

    func testPlaybackRecoveryNudgesOnlyOnceAtTheStreamStart() {
        let target = PlaybackRecoveryPolicy.startupNudgeTarget(
            elapsed: 0,
            duration: 180,
            alreadyAttempted: false
        )
        XCTAssertNotNil(target)
        XCTAssertEqual(
            target ?? -1,
            0.18,
            accuracy: 0.001
        )
        XCTAssertNil(PlaybackRecoveryPolicy.startupNudgeTarget(
            elapsed: 0.2,
            duration: 180,
            alreadyAttempted: false
        ))
        XCTAssertNil(PlaybackRecoveryPolicy.startupNudgeTarget(
            elapsed: 0,
            duration: 180,
            alreadyAttempted: true
        ))
        XCTAssertNil(PlaybackRecoveryPolicy.startupNudgeTarget(
            elapsed: 0,
            duration: 0,
            alreadyAttempted: false
        ))
        let forwardTarget = PlaybackRecoveryPolicy.startupNudgeTarget(
            elapsed: 0.1,
            duration: 20,
            alreadyAttempted: false
        )
        XCTAssertGreaterThan(forwardTarget ?? 0, 0.1)
        XCTAssertNil(PlaybackRecoveryPolicy.startupNudgeTarget(
            elapsed: 0.1,
            duration: 0.1,
            alreadyAttempted: false
        ))
    }

    func testPlaybackRecoveryRequiresActualClockProgress() {
        XCTAssertFalse(PlaybackRecoveryPolicy.hasMeaningfulProgress(
            from: 0,
            to: 0
        ))
        XCTAssertFalse(PlaybackRecoveryPolicy.hasMeaningfulProgress(
            from: 42,
            to: 42.05
        ))
        XCTAssertTrue(PlaybackRecoveryPolicy.hasMeaningfulProgress(
            from: 42,
            to: 42.2
        ))
    }

    func testAutomaticBufferingWaitIsNotForcedImmediately() {
        XCTAssertTrue(PlaybackRecoveryPolicy.isManagedBufferingWait(
            timeControlStatus: .waitingToPlayAtSpecifiedRate,
            waitingReason: .toMinimizeStalls
        ))
        XCTAssertTrue(PlaybackRecoveryPolicy.isManagedBufferingWait(
            timeControlStatus: .waitingToPlayAtSpecifiedRate,
            waitingReason: .evaluatingBufferingRate
        ))
        XCTAssertFalse(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(
            timeControlStatus: .waitingToPlayAtSpecifiedRate,
            waitingReason: .toMinimizeStalls
        ))
        XCTAssertFalse(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(
            timeControlStatus: .waitingToPlayAtSpecifiedRate,
            waitingReason: .evaluatingBufferingRate
        ))
        XCTAssertFalse(PlaybackRecoveryPolicy.isManagedBufferingWait(
            timeControlStatus: .paused,
            waitingReason: nil
        ))
        XCTAssertTrue(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(
            timeControlStatus: .paused,
            waitingReason: nil
        ))
    }

    func testNetworkRecoverySkipsRawBeforeTryingLowerBandwidthFormat() {
        let originalQualityFallbacks = ["aac", "mp3"]
        let opusQualityFallbacks = ["aac", "mp3", "raw"]

        XCTAssertEqual(
            PlaybackRecoveryPolicy.nextCompatibilityIndex(
                in: originalQualityFallbacks,
                from: 0,
                allowsRaw: false
            ),
            0
        )
        XCTAssertEqual(
            PlaybackRecoveryPolicy.nextCompatibilityIndex(
                in: opusQualityFallbacks,
                from: 2,
                allowsRaw: false
            ),
            nil
        )
    }

    func testOpusQualityCompatibilityFallbackNeverIncreasesBitRate() {
        XCTAssertEqual(
            OpenSubsonicClient.compatibilityBitRate(
                for: .opus160,
                format: "aac"
            ),
            160
        )
        XCTAssertEqual(
            OpenSubsonicClient.compatibilityBitRate(
                for: .opus160,
                format: "mp3"
            ),
            160
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

    func testGaplessPreparationDoesNotOpenSecondStreamEarly() {
        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldPrepare(
            elapsed: 30,
            duration: 180,
            isBuffering: false,
            isActivelyPlaying: true
        ))
        XCTAssertTrue(PlaybackGaplessPreparationPolicy.shouldPrepare(
            elapsed: 162,
            duration: 180,
            isBuffering: false,
            isActivelyPlaying: true
        ))
    }

    func testGaplessPreparationStopsDuringBuffering() {
        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldPrepare(
            elapsed: 175,
            duration: 180,
            isBuffering: true,
            isActivelyPlaying: true
        ))
        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldPrepare(
            elapsed: 175,
            duration: 180,
            isBuffering: false,
            isActivelyPlaying: false
        ))
    }

    func testGaplessPreparationRequiresKnownFiniteDuration() {
        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldPrepare(
            elapsed: 10,
            duration: 0,
            isBuffering: false,
            isActivelyPlaying: true
        ))
        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldPrepare(
            elapsed: 10,
            duration: .infinity,
            isBuffering: false,
            isActivelyPlaying: true
        ))
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
