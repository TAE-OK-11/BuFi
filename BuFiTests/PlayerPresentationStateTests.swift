import XCTest
@testable import BuFi

private actor PlayerTaskGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class PlayerTaskRecorder {
    var obsoleteStarted = false
    var obsoleteObservedCancellation = false
    var replacementStarted = false
    var recoveries: [String] = []
}

@MainActor
final class PlayerPresentationStateTests: XCTestCase {
    func testEachNewPlayerPresentationGetsFreshIdentity() {
        let state = PlayerPresentationState()
        let initialID = state.presentationID

        state.setShowPlayer(true)
        let firstPresentationID = state.presentationID
        XCTAssertNotEqual(firstPresentationID, initialID)

        state.setShowPlayer(true)
        XCTAssertEqual(state.presentationID, firstPresentationID)

        state.showFullLyrics = true
        state.setShowPlayer(false)
        XCTAssertEqual(state.presentationID, firstPresentationID)
        XCTAssertFalse(state.showFullLyrics)

        state.setShowPlayer(true)
        XCTAssertNotEqual(state.presentationID, firstPresentationID)
    }

    func testArtworkIdentityComesFromOneAtomicPlaybackItem() {
        let current = song(id: "song", coverArt: "current-cover")
        let item = PlaybackMediaItem(
            song: current,
            accountScope: "account"
        )

        XCTAssertEqual(item.artworkIdentity.playbackGenerationID, item.id)
        XCTAssertEqual(item.artworkIdentity.queueEntryID, item.queueEntryID)
        XCTAssertEqual(item.artworkIdentity.songID, current.id)
        XCTAssertEqual(item.artworkIdentity.coverArtID, "current-cover")
        XCTAssertEqual(item.artworkIdentity.artworkRevision, current.artworkRevision)
        XCTAssertEqual(item.artworkIdentity.accountScope, "account")
    }

    func testArtworkIdentityRejectsPreviousPlaybackGenerationAndQueueOccurrence() {
        let current = song(id: "same-song", coverArt: "same-cover")
        let first = PlaybackMediaItem(song: current, accountScope: "account")
        let replay = PlaybackMediaItem(
            song: current,
            accountScope: "account",
            queueEntryID: first.queueEntryID
        )
        let duplicate = PlaybackMediaItem(song: current, accountScope: "account")

        XCTAssertNotEqual(first.artworkIdentity, replay.artworkIdentity)
        XCTAssertNotEqual(first.artworkIdentity, duplicate.artworkIdentity)
        XCTAssertNotEqual(replay.artworkIdentity, duplicate.artworkIdentity)
    }

    func testSessionTransitionDrainsObsoleteScrobbleBeforeReplacement() async {
        let lifecycle = PlayerTaskLifecycle()
        let gate = PlayerTaskGate()
        let recorder = PlayerTaskRecorder()

        lifecycle.scheduleScrobble {
            recorder.obsoleteStarted = true
            await gate.wait()
            recorder.obsoleteObservedCancellation = Task.isCancelled
        }
        for _ in 0..<100 where !recorder.obsoleteStarted {
            await Task.yield()
        }
        XCTAssertTrue(recorder.obsoleteStarted)

        let transition = lifecycle.beginSessionTransition()
        lifecycle.scheduleScrobble {
            recorder.replacementStarted = true
        }
        let replacement = lifecycle.scrobbleTask
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertFalse(recorder.replacementStarted)

        await gate.open()
        _ = await transition?.value
        _ = await replacement?.value

        XCTAssertTrue(recorder.obsoleteObservedCancellation)
        XCTAssertTrue(recorder.replacementStarted)
    }

    func testReplacingBackgroundRecoveryCancelsPredecessor() async {
        let lifecycle = PlayerTaskLifecycle()
        let recorder = PlayerTaskRecorder()

        lifecycle.scheduleBackgroundRecovery(after: .seconds(30)) {
            recorder.recoveries.append("obsolete")
        }
        let obsolete = lifecycle.backgroundRecoveryTask
        lifecycle.scheduleBackgroundRecovery(after: .milliseconds(0)) {
            recorder.recoveries.append("current")
        }
        let current = lifecycle.backgroundRecoveryTask

        _ = await obsolete?.value
        _ = await current?.value

        XCTAssertEqual(recorder.recoveries, ["current"])
    }

    func testSessionTransitionCancelsAndDrainsBackgroundRecovery() async {
        let lifecycle = PlayerTaskLifecycle()
        let recorder = PlayerTaskRecorder()

        lifecycle.scheduleBackgroundRecovery(after: .seconds(30)) {
            recorder.recoveries.append("obsolete")
        }
        let backgroundRecovery = lifecycle.backgroundRecoveryTask
        let transition = lifecycle.beginSessionTransition()

        _ = await transition?.value
        _ = await backgroundRecovery?.value

        XCTAssertTrue(recorder.recoveries.isEmpty)
        XCTAssertNil(lifecycle.backgroundRecoveryTask)
    }

    func testQueueSnapshotPublishesAValidSelectionWithItsSongs() {
        let songs = [
            song(id: "first", coverArt: "cover-a"),
            song(id: "second", coverArt: "cover-b")
        ]

        let entries = songs.map { PlaybackQueueEntry(song: $0) }
        let selected = PlaybackSnapshot(
            entries: entries,
            index: 1,
            accountScope: "account"
        )
        XCTAssertEqual(selected.index, 1)
        XCTAssertEqual(selected.songs[selected.index].id, "second")
        XCTAssertEqual(selected.currentItem?.queueEntryID, entries[1].id)

        let clamped = PlaybackSnapshot(
            entries: entries,
            index: 8,
            accountScope: "account"
        )
        XCTAssertEqual(clamped.index, 1)
        XCTAssertEqual(PlaybackSnapshot.empty.index, -1)
    }

    func testDuplicateSongIDsKeepDistinctQueueOccurrences() {
        let duplicate = song(id: "same-song", coverArt: "cover")
        let first = PlaybackQueueEntry(song: duplicate)
        let second = PlaybackQueueEntry(song: duplicate)
        let snapshot = PlaybackSnapshot(
            entries: [first, second],
            index: 1,
            accountScope: "account"
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(snapshot.currentItem?.queueEntryID, second.id)
        XCTAssertEqual(
            snapshot.currentItem?.id,
            snapshot.playbackGenerationID
        )
        XCTAssertEqual(snapshot.currentSong?.id, duplicate.id)
    }

    func testQueueEntryIdentityIsIndependentFromPlaybackGeneration() {
        let entry = PlaybackQueueEntry(
            song: song(id: "replay", coverArt: "cover")
        )
        let first = PlaybackSnapshot(
            entries: [entry],
            index: 0,
            accountScope: "account",
            playbackGenerationID: UUID()
        )
        let replay = PlaybackSnapshot(
            entries: [entry],
            index: 0,
            accountScope: "account",
            playbackGenerationID: UUID()
        )

        XCTAssertEqual(first.currentItem?.queueEntryID, entry.id)
        XCTAssertEqual(replay.currentItem?.queueEntryID, entry.id)
        XCTAssertNotEqual(first.currentItem?.id, replay.currentItem?.id)
    }

    func testCurrentPlaybackSnapshotKeepsOnlyPresentationCriticalQueueState() {
        let entries = [
            PlaybackQueueEntry(song: song(id: "first", coverArt: "cover-a")),
            PlaybackQueueEntry(song: song(id: "second", coverArt: "cover-b"))
        ]
        let queue = PlaybackSnapshot(
            entries: entries,
            index: 1,
            accountScope: "account"
        )

        let current = CurrentPlaybackSnapshot(snapshot: queue)

        XCTAssertEqual(current.item?.queueEntryID, entries[1].id)
        XCTAssertEqual(current.song?.id, "second")
        XCTAssertEqual(current.index, 1)
        XCTAssertEqual(current.queueCount, 2)
    }

    func testNonCurrentQueueMetadataDoesNotInvalidateCurrentPresentation() {
        let generation = UUID()
        let currentEntry = PlaybackQueueEntry(
            song: song(id: "current", coverArt: "current-cover")
        )
        var upcoming = PlaybackQueueEntry(
            song: song(id: "upcoming", coverArt: "old-cover")
        )
        let before = PlaybackSnapshot(
            entries: [currentEntry, upcoming],
            index: 0,
            accountScope: "account",
            playbackGenerationID: generation
        )
        upcoming.song.coverArt = "new-cover"
        let after = PlaybackSnapshot(
            entries: [currentEntry, upcoming],
            index: 0,
            accountScope: "account",
            playbackGenerationID: generation
        )

        XCTAssertEqual(
            CurrentPlaybackSnapshot(snapshot: before),
            CurrentPlaybackSnapshot(snapshot: after)
        )
        XCTAssertNotEqual(before, after)
    }

    func testPagerGateSuppressesProgrammaticScrollUntilDestination() {
    let intermediate = artworkPageID(songID: "intermediate")
    let destination = artworkPageID(songID: "destination")
    var gate = PlayerPagerSelectionGate()

    gate.beginProgrammaticMove(to: destination)

    XCTAssertFalse(gate.shouldStartPlayback(for: intermediate))
    XCTAssertEqual(gate.programmaticDestination, destination)
    XCTAssertFalse(gate.shouldStartPlayback(for: destination))
    XCTAssertNil(gate.programmaticDestination)
}

func testPagerGateLetsUserTakeOverProgrammaticScroll() {
    let destination = artworkPageID(songID: "destination")
    let userSelection = artworkPageID(songID: "user-selection")
    var gate = PlayerPagerSelectionGate()

    gate.beginProgrammaticMove(to: destination)
    gate.beginUserInteraction()

    XCTAssertNil(gate.programmaticDestination)
    XCTAssertTrue(gate.shouldStartPlayback(for: userSelection))
}

private func artworkPageID(songID: String) -> PlayerArtworkPageID {
    PlayerArtworkPageID(
        queueEntryID: UUID(),
        songID: songID,
        coverArtID: "cover-" + songID,
        artworkRevision: "revision-" + songID,
        accountScope: "account"
    )
}

private func song(id: String, coverArt: String?) -> Song {
        Song(
            id: id,
            title: id,
            artist: "Artist",
            album: "Album",
            artistId: "artist",
            albumId: "album",
            coverArt: coverArt,
            duration: 180,
            track: 1,
            suffix: "m4a",
            contentType: "audio/mp4",
            starred: nil
        )
    }
}
