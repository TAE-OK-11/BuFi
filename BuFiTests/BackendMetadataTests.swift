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
