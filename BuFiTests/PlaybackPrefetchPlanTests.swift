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

    func testHTTPClientErrorFailsInsteadOfCyclingCodecs() {
        let notFound = NSError(
            domain: AVFoundationErrorDomain,
            code: -11_828,
            userInfo: ["statusCode": 404]
        )
        XCTAssertEqual(
            PlaybackFailureClassifier.disposition(for: notFound),
            .failPermanent
        )
        XCTAssertEqual(
            PlaybackFailureClassifier.disposition(
                for: NSError(domain: AVFoundationErrorDomain, code: -11_800)
            ),
            .tryCompatibilityFormat
        )
    }

    func testServerUnavailableRetriesTransport() {
        let unavailable = NSError(
            domain: AVFoundationErrorDomain,
            code: -11_828,
            userInfo: ["AVErrorHTTPStatusCodeKey": 503]
        )
        XCTAssertEqual(
            PlaybackFailureClassifier.disposition(for: unavailable),
            .retryTransport
        )
    }

    func testWatchdogStaysOffHealthyPlayingClock() {
        XCTAssertEqual(
            PlaybackWatchdogPolicy.decision(
                wantsPlayback: true,
                timeControlStatus: .playing,
                elapsed: 12,
                hasCurrentItem: true
            ),
            .cancelWatchdog
        )
        XCTAssertEqual(
            PlaybackWatchdogPolicy.decision(
                wantsPlayback: true,
                timeControlStatus: .playing,
                elapsed: 0.2,
                hasCurrentItem: true
            ),
            .arm(.startup)
        )
        XCTAssertEqual(
            PlaybackWatchdogPolicy.decision(
                wantsPlayback: true,
                timeControlStatus: .waitingToPlayAtSpecifiedRate,
                elapsed: 40,
                hasCurrentItem: true
            ),
            .arm(.stall)
        )
        XCTAssertEqual(
            PlaybackWatchdogPolicy.decision(
                wantsPlayback: false,
                timeControlStatus: .paused,
                elapsed: 40,
                hasCurrentItem: true
            ),
            .cancelWatchdog
        )
    }

    func testTransportBackoffGrowsThenCaps() {
        XCTAssertEqual(
            PlaybackWatchdogPolicy.transportBackoff(afterFailedAttempt: 1),
            .milliseconds(400)
        )
        XCTAssertEqual(
            PlaybackWatchdogPolicy.transportBackoff(afterFailedAttempt: 2),
            .milliseconds(900)
        )
        XCTAssertEqual(
            PlaybackWatchdogPolicy.maximumTransportRetries,
            2
        )
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

    func testManualSkipCommitsOnlyTheStagedSuccessorOccurrence() {
        let occurrence = UUID()
        XCTAssertTrue(
            PlaybackSkipPlan.shouldCommitStagedSuccessor(
                stagedQueueIndex: 2,
                stagedOccurrenceID: occurrence,
                nextQueueIndex: 2,
                nextOccurrenceID: occurrence
            )
        )
        XCTAssertFalse(
            PlaybackSkipPlan.shouldCommitStagedSuccessor(
                stagedQueueIndex: 2,
                stagedOccurrenceID: occurrence,
                nextQueueIndex: 3,
                nextOccurrenceID: occurrence
            )
        )
        XCTAssertFalse(
            PlaybackSkipPlan.shouldCommitStagedSuccessor(
                stagedQueueIndex: 2,
                stagedOccurrenceID: occurrence,
                nextQueueIndex: 2,
                nextOccurrenceID: UUID()
            )
        )
        XCTAssertFalse(
            PlaybackSkipPlan.shouldCommitStagedSuccessor(
                stagedQueueIndex: nil,
                stagedOccurrenceID: occurrence,
                nextQueueIndex: 2,
                nextOccurrenceID: occurrence
            )
        )
    }

    func testSuccessorWarmupDelayStaysSubSecond() {
        XCTAssertEqual(
            PlaybackSuccessorWarmupPolicy.readinessCheckDelay,
            .milliseconds(280)
        )
        XCTAssertEqual(
            PlaybackSuccessorWarmupPolicy.maximumReadinessChecks,
            3
        )
    }

    func testStableSuccessorWarmupRequiresHealthyPlayback() {
        XCTAssertTrue(PlaybackSuccessorWarmupPolicy.shouldWarm(
            isBuffering: false,
            isActivelyPlaying: true,
            isLikelyToKeepUp: true
        ))
        XCTAssertFalse(PlaybackSuccessorWarmupPolicy.shouldWarm(
            isBuffering: true,
            isActivelyPlaying: true,
            isLikelyToKeepUp: true
        ))
        XCTAssertFalse(PlaybackSuccessorWarmupPolicy.shouldWarm(
            isBuffering: false,
            isActivelyPlaying: true,
            isLikelyToKeepUp: false
        ))
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

    func testGaplessStagingWaitsUntilFinalPlaybackWindow() {
        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldStage(
            elapsed: 170,
            duration: 180,
            isBuffering: false,
            isActivelyPlaying: true
        ))
        XCTAssertTrue(PlaybackGaplessPreparationPolicy.shouldStage(
            elapsed: 174,
            duration: 180,
            isBuffering: false,
            isActivelyPlaying: true
        ))
        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldStage(
            elapsed: 179,
            duration: 180,
            isBuffering: true,
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

    func testShuffleFreshPartitionMovesRecentSongsBehindFreshCandidates() {
        var entries = [
            PlaybackQueueEntry(song: song(id: "recent-a")),
            PlaybackQueueEntry(song: song(id: "fresh-a")),
            PlaybackQueueEntry(song: song(id: "recent-b")),
            PlaybackQueueEntry(song: song(id: "fresh-b"))
        ]
        let recent: Set<String> = ["recent-a", "recent-b"]

        PlaybackShufflePolicy.prioritizeFresh(
            &entries,
            recentSongIDs: recent
        )

        let firstRecent = entries.firstIndex { recent.contains($0.song.id) }
        XCTAssertNotNil(firstRecent)
        let boundary = firstRecent ?? entries.endIndex
        XCTAssertTrue(entries[..<boundary].allSatisfy {
            !recent.contains($0.song.id)
        })
        XCTAssertTrue(entries[boundary...].allSatisfy {
            recent.contains($0.song.id)
        })
    }

    func testShuffleFastCandidatePathOnlyActivatesForLargeQueues() {
        XCTAssertFalse(PlaybackShufflePolicy.shouldUseFastCandidatePath(
            queueCount: PlaybackShufflePolicy.recentWindowLimit * 2
        ))
        XCTAssertTrue(PlaybackShufflePolicy.shouldUseFastCandidatePath(
            queueCount: PlaybackShufflePolicy.recentWindowLimit * 2 + 1
        ))
        XCTAssertEqual(PlaybackShufflePolicy.fastCandidateAttemptLimit, 4)
    }

    func testPlaybackSnapshotSelectionKeepsCurrentSongSemantics() {
        let entries = [
            PlaybackQueueEntry(song: song(id: "first")),
            PlaybackQueueEntry(song: song(id: "second"))
        ]
        let generation = UUID()
        let first = PlaybackSnapshot(
            entries: entries,
            index: 0,
            accountScope: "account",
            playbackGenerationID: generation
        )
        let second = PlaybackSnapshot(
            entries: entries,
            index: 1,
            accountScope: "account",
            playbackGenerationID: generation
        )

        XCTAssertEqual(first.currentSong?.id, "first")
        XCTAssertEqual(second.currentSong?.id, "second")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.songs.map(\.id), second.songs.map(\.id))
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
