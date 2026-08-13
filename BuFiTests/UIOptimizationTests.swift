import XCTest
import CoreGraphics
@testable import BuFi

final class UIOptimizationTests: XCTestCase {
    func testArtworkRequestSizingUsesStableBoundedPixelBuckets() {
        XCTAssertEqual(
            ArtworkRequestSizing.pixelSize(pointSize: 50, displayScale: 3),
            192
        )
        XCTAssertEqual(
            ArtworkRequestSizing.pixelSize(pointSize: 349, displayScale: 3),
            1_200
        )
        XCTAssertEqual(
            ArtworkRequestSizing.pixelSize(pointSize: 2_000, displayScale: 3),
            2_048
        )
    }

    func testArtworkSwipeRequestsNextQueueOccurrence() {
        let destination = PlayerArtworkSwipeNavigation.destinationIndex(
            translation: CGSize(width: -70, height: 4),
            predictedEndTranslation: CGSize(width: -130, height: 8),
            currentIndex: 1,
            queueCount: 4
        )

        XCTAssertEqual(destination, 2)
    }

    func testArtworkSwipeRequestsPreviousQueueOccurrence() {
        let destination = PlayerArtworkSwipeNavigation.destinationIndex(
            translation: CGSize(width: 72, height: 3),
            predictedEndTranslation: CGSize(width: 120, height: 5),
            currentIndex: 2,
            queueCount: 4
        )

        XCTAssertEqual(destination, 1)
    }

    func testArtworkSwipeIgnoresShortAndVerticalGestures() {
        XCTAssertNil(PlayerArtworkSwipeNavigation.destinationIndex(
            translation: CGSize(width: -20, height: 2),
            predictedEndTranslation: CGSize(width: -30, height: 3),
            currentIndex: 1,
            queueCount: 3
        ))
        XCTAssertNil(PlayerArtworkSwipeNavigation.destinationIndex(
            translation: CGSize(width: -80, height: 100),
            predictedEndTranslation: CGSize(width: -110, height: 150),
            currentIndex: 1,
            queueCount: 3
        ))
    }

    func testArtworkSwipeDoesNotLeaveQueueBoundaries() {
        XCTAssertNil(PlayerArtworkSwipeNavigation.destinationIndex(
            translation: CGSize(width: 90, height: 0),
            predictedEndTranslation: CGSize(width: 120, height: 0),
            currentIndex: 0,
            queueCount: 2
        ))
        XCTAssertNil(PlayerArtworkSwipeNavigation.destinationIndex(
            translation: CGSize(width: -90, height: 0),
            predictedEndTranslation: CGSize(width: -120, height: 0),
            currentIndex: 1,
            queueCount: 2
        ))
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

    func testHomePresentationInputUsesRevisionInsteadOfSnapshotTraversal() {
        let revision = HomeSnapshotRevision()
        let first = HomePresentationInput(
            snapshot: HomeSnapshot(randomSongs: [song(id: "first", albumID: "a")]),
            revision: revision,
            selectedArtists: ["artist"]
        )
        let sameRevision = HomePresentationInput(
            snapshot: HomeSnapshot(randomSongs: [song(id: "second", albumID: "b")]),
            revision: revision,
            selectedArtists: ["artist"]
        )
        let nextRevision = HomePresentationInput(
            snapshot: first.snapshot,
            revision: revision.advanced(),
            selectedArtists: ["artist"]
        )

        XCTAssertEqual(first, sameRevision)
        XCTAssertNotEqual(first, nextRevision)
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
