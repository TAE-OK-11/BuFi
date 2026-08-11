import Foundation
import XCTest
@testable import BuFi

final class BackendMetadataTests: XCTestCase {
    func testSongDecodingAcceptsOptionalArtistAndAlbum() throws {
        let data = Data(
            #"{"id":"song-1","title":"Track","coverArt":" cover-1 "}"#.utf8
        )

        let song = try JSONDecoder().decode(Song.self, from: data)

        XCTAssertEqual(song.id, "song-1")
        XCTAssertEqual(song.artist, "")
        XCTAssertEqual(song.album, "")
        XCTAssertEqual(song.artworkID, "cover-1")
    }

    func testAlbumArtworkFillsOnlyMissingMatchingChildArtwork() {
        let missing = song(id: "missing", albumID: "album", coverArt: nil)
        let existing = song(id: "existing", albumID: "album", coverArt: "child")
        let otherAlbum = song(id: "other", albumID: "other-album", coverArt: nil)

        let result = AlbumSongMetadataResolver.resolve(
            songs: [missing, existing, otherAlbum],
            albumID: "album",
            coverArt: "parent"
        )

        XCTAssertEqual(result[0].artworkID, "parent")
        XCTAssertEqual(result[1].artworkID, "child")
        XCTAssertNil(result[2].artworkID)
    }

    func testPlaylistAffinityIsIndependentOfTaskCompletionOrder() {
        let firstVersion = song(id: "shared", coverArt: "first-cover")
        var secondVersion = firstVersion
        secondVersion.coverArt = "second-cover"
        let firstOnly = song(id: "first-only", coverArt: "first-only-cover")
        let secondOnly = song(id: "second-only", coverArt: "second-only-cover")
        let completedOutOfOrder: [(playlistIndex: Int, songs: [Song])] = [
            (1, [secondVersion, secondOnly]),
            (0, [firstVersion, firstOnly])
        ]

        let first = PlaylistAffinityRanking.rank(
            completedOutOfOrder,
            limit: 10
        )
        let second = PlaylistAffinityRanking.rank(
            Array(completedOutOfOrder.reversed()),
            limit: 10
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.first?.id, "shared")
        XCTAssertEqual(first.first?.artworkID, "first-cover")
        XCTAssertEqual(first.map(\.id), ["shared", "first-only", "second-only"])
    }

    func testPlaybackMediaBundlesOneSnapshotButDistinguishesReplays() {
        let value = song(id: "same", coverArt: "cover")

        let first = PlaybackMediaItem(song: value, accountScope: "account")
        let replay = PlaybackMediaItem(song: value, accountScope: "account")

        XCTAssertNotEqual(first.id, replay.id)
        XCTAssertEqual(first.metadataRevision, replay.metadataRevision)
        XCTAssertEqual(first.artwork, replay.artwork)
        XCTAssertEqual(first.stream, replay.stream)
        XCTAssertEqual(first.stream.songID, first.song.id)
        XCTAssertEqual(first.artwork.id, first.song.artworkID)
    }

    func testArtworkRevisionChangesWithCoverButNotFavoriteState() {
        let original = song(id: "song", coverArt: "cover-a")
        var favorite = original
        favorite.starred = "2026-08-11T00:00:00Z"
        var changedCover = original
        changedCover.coverArt = "cover-b"

        XCTAssertEqual(original.artworkRevision, favorite.artworkRevision)
        XCTAssertEqual(
            original.playbackMetadataRevision,
            favorite.playbackMetadataRevision
        )
        XCTAssertNotEqual(original.artworkRevision, changedCover.artworkRevision)
        XCTAssertNotEqual(
            original.playbackMetadataRevision,
            changedCover.playbackMetadataRevision
        )
    }

    func testArtworkRevisionUsesFragmentWithoutChangingServerQuery() throws {
        let source = try XCTUnwrap(
            URL(string: "https://music.example/rest/getCoverArt.view?id=cover&u=user&t=token")
        )

        let first = ArtworkStore.cacheURL(for: source, revision: "revision-a")
        let second = ArtworkStore.cacheURL(for: source, revision: "revision-b")

        XCTAssertEqual(first.query, source.query)
        XCTAssertEqual(second.query, source.query)
        XCTAssertNotEqual(first.fragment, second.fragment)
        XCTAssertTrue(first.fragment?.contains("media-v2") == true)
    }

    private func song(
        id: String,
        albumID: String? = "album",
        coverArt: String?
    ) -> Song {
        Song(
            id: id,
            title: id,
            artist: "Artist",
            album: "Album",
            artistId: "artist",
            albumId: albumID,
            coverArt: coverArt,
            duration: 180,
            track: 1,
            suffix: "m4a",
            contentType: "audio/mp4",
            starred: nil
        )
    }
}
