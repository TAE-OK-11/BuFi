import XCTest
@testable import BuFi

final class UIOptimizationTests: XCTestCase {
    func testProgrammaticPagerSelectionDoesNotRequestPlayback() {
        let current = PlayerArtworkPageID(
            queueIndex: 0,
            songID: "song-a",
            coverArtID: "cover-a"
        )
        let destination = PlayerArtworkPageID(
            queueIndex: 1,
            songID: "song-b",
            coverArtID: "cover-b"
        )
        var gate = PlayerPagerSelectionGate()

        XCTAssertTrue(gate.prepareProgrammaticChange(from: current, to: destination))
        XCTAssertFalse(gate.prepareProgrammaticChange(from: destination, to: destination))
        XCTAssertFalse(gate.shouldStartPlayback(for: destination))
        XCTAssertTrue(gate.shouldStartPlayback(for: current))
    }

    func testPagerDoesNotArmWhenAlreadyAtDestination() {
        let page = PlayerArtworkPageID(
            queueIndex: 0,
            songID: "song-a",
            coverArtID: nil
        )
        var gate = PlayerPagerSelectionGate()

        XCTAssertFalse(gate.prepareProgrammaticChange(from: page, to: page))
        XCTAssertNil(gate.programmaticDestination)
    }

    func testBiographySanitizationRemovesMarkupAndCollapsesWhitespace() {
        let result = ArtistBiographySanitizer.sanitize(
            " <p>Hello</p>\n\t<strong>BuFi</strong>  listeners "
        )

        XCTAssertEqual(result, "Hello BuFi listeners")
    }

    func testHomePresentationPreservesRecommendedAlbumOrderAndDeduplicates() {
        let firstAlbum = album(id: "album-a", name: "First")
        let secondAlbum = album(id: "album-b", name: "Second")
        let snapshot = HomeSnapshot(
            randomAlbums: [secondAlbum, firstAlbum],
            recommendedSongs: [
                song(id: "1", albumID: firstAlbum.id),
                song(id: "2", albumID: firstAlbum.id),
                song(id: "3", albumID: secondAlbum.id)
            ]
        )

        let presentation = HomePresentation.make(
            input: HomePresentationInput(snapshot: snapshot, selectedArtists: [])
        )

        XCTAssertEqual(presentation.recommendedAlbums.map(\.id), ["album-a", "album-b"])
    }

    func testLibraryArtistPresentationUsesStableFavoriteMarker() {
        let favorite = Artist(
            id: "favorite",
            name: "Favorite",
            coverArt: nil,
            albumCount: nil,
            starred: nil
        )
        let input = LibraryArtistPresentationInput(
            artists: [],
            starredArtists: [favorite]
        )

        let first = LibraryArtistPresentation.make(input: input)
        let second = LibraryArtistPresentation.make(input: input)

        XCTAssertEqual(first.favorites, second.favorites)
        XCTAssertTrue(first.favorites.first?.isStarred == true)
    }

    private func album(id: String, name: String) -> Album {
        Album(
            id: id,
            name: name,
            artist: "Artist",
            coverArt: "cover-\(id)",
            year: nil,
            starred: nil
        )
    }

    private func song(id: String, albumID: String) -> Song {
        Song(
            id: id,
            title: "Song \(id)",
            artist: "Artist",
            album: "Album",
            artistId: "artist",
            albumId: albumID,
            coverArt: "cover-\(albumID)",
            duration: 180,
            track: nil,
            suffix: "flac",
            contentType: "audio/flac",
            starred: nil
        )
    }
}
