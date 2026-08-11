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

        let selected = PlaybackQueueSnapshot(songs: songs, index: 1)
        XCTAssertEqual(selected.index, 1)
        XCTAssertEqual(selected.songs[selected.index].id, "second")

        let clamped = PlaybackQueueSnapshot(songs: songs, index: 8)
        XCTAssertEqual(clamped.index, 1)
        XCTAssertEqual(PlaybackQueueSnapshot.empty.index, -1)
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
