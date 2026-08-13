import XCTest
@testable import BuFi

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
        XCTAssertEqual(snapshot.pages[snapshot.currentPage.queueIndex].song, current)
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
