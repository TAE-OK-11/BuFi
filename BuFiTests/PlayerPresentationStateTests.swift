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

    func testArtworkPageIdentityIncludesSongAndQueuePosition() {
        let original = PlayerArtworkPageID(
            queueIndex: 2,
            songID: "song-a",
            coverArtID: "cover-a"
        )

        XCTAssertNotEqual(
            original,
            PlayerArtworkPageID(queueIndex: 2, songID: "song-b", coverArtID: "cover-b")
        )
        XCTAssertNotEqual(
            original,
            PlayerArtworkPageID(queueIndex: 3, songID: "song-a", coverArtID: "cover-a")
        )
        XCTAssertNotEqual(
            original,
            PlayerArtworkPageID(queueIndex: 2, songID: "song-a", coverArtID: "cover-b")
        )
        XCTAssertNotEqual(
            PlayerArtworkPageID(
                queueIndex: 2,
                songID: "song-a",
                coverArtID: "cover-a",
                artworkRevision: "revision-a",
                accountScope: "account"
            ),
            PlayerArtworkPageID(
                queueIndex: 2,
                songID: "song-a",
                coverArtID: "cover-a",
                artworkRevision: "revision-b",
                accountScope: "account"
            )
        )
    }

    func testArtworkSnapshotUsesExactCoverWhenQueueIndexStillPointsAtOldMetadata() {
        let old = song(id: "song", coverArt: "old-cover")
        let current = song(id: "song", coverArt: "current-cover")

        let snapshot = PlayerArtworkPagerSnapshot.make(
            currentSong: current,
            queue: [old, current],
            queueIndex: 0
        )

        XCTAssertEqual(snapshot.currentPage.queueIndex, 1)
        XCTAssertEqual(snapshot.currentPage.coverArtID, "current-cover")
        XCTAssertEqual(
            snapshot.pages.first(where: { $0.id == snapshot.currentPage })?.song,
            current
        )
    }

    func testArtworkSnapshotFallsBackToCurrentSongInsteadOfPreviousQueueCover() {
        let queued = song(id: "song", coverArt: "old-cover")
        let current = song(id: "song", coverArt: "current-cover")

        let snapshot = PlayerArtworkPagerSnapshot.make(
            currentSong: current,
            queue: [queued],
            queueIndex: 0
        )

        XCTAssertEqual(snapshot.pages.count, 1)
        XCTAssertEqual(snapshot.currentPage.queueIndex, -1)
        XCTAssertEqual(snapshot.currentPage.coverArtID, "current-cover")
        XCTAssertEqual(snapshot.pages.first?.song, current)
    }

    func testArtworkSnapshotNormalizesWhitespaceAroundCoverIdentifier() {
        let queued = song(id: "song", coverArt: "cover")
        let current = song(id: "song", coverArt: "  cover  ")

        let snapshot = PlayerArtworkPagerSnapshot.make(
            currentSong: current,
            queue: [queued],
            queueIndex: 0
        )

        XCTAssertEqual(snapshot.currentPage.queueIndex, 0)
        XCTAssertEqual(snapshot.currentPage.coverArtID, "cover")
    }

    func testArtworkSnapshotBuildsOnlyCurrentCenteredWindowForLargeQueue() {
        let songs = (0..<1_000).map {
            song(id: "song-\($0)", coverArt: "cover-\($0)")
        }

        let snapshot = PlayerArtworkPagerSnapshot.make(
            currentSong: songs[500],
            queue: songs,
            queueIndex: 500
        )

        XCTAssertEqual(snapshot.pages.count, 5)
        XCTAssertEqual(snapshot.pages.map(\.id.queueIndex), [498, 499, 500, 501, 502])
        XCTAssertEqual(snapshot.currentPage.queueIndex, 500)
    }

    func testArtworkSnapshotResolvesFreshCurrentMetadataOutsideStaleIndex() {
        let current = song(id: "target", coverArt: "fresh-cover")
        var songs = (0..<1_000).map {
            song(id: "song-\($0)", coverArt: "cover-\($0)")
        }
        songs[10] = song(id: "target", coverArt: "stale-cover")
        songs[800] = current

        let snapshot = PlayerArtworkPagerSnapshot.make(
            currentSong: current,
            queue: songs,
            queueIndex: 10
        )

        XCTAssertEqual(snapshot.currentPage.queueIndex, 800)
        XCTAssertEqual(snapshot.currentPage.coverArtID, "fresh-cover")
        XCTAssertEqual(snapshot.pages.map(\.id.queueIndex), [798, 799, 800, 801, 802])
    }

    func testArtworkSnapshotClampsWindowAtQueueBoundary() {
        let songs = (0..<10).map {
            song(id: "song-\($0)", coverArt: "cover-\($0)")
        }

        let snapshot = PlayerArtworkPagerSnapshot.make(
            currentSong: songs[0],
            queue: songs,
            queueIndex: 0
        )

        XCTAssertEqual(snapshot.pages.map(\.id.queueIndex), [0, 1, 2])
        XCTAssertEqual(snapshot.currentPage.queueIndex, 0)
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
