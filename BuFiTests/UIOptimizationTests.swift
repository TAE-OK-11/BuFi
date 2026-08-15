import XCTest
import CoreGraphics
@testable import BuFi

@MainActor
final class UIOptimizationTests: XCTestCase {
    func testFavoriteOverridePublishesOnlyChangedIdentity() {
        let state = FavoriteOverrideState()
        let first = state.valueState(for: "song:first")
        let second = state.valueState(for: "song:second")

        state.setValue(true, for: "song:first")

        XCTAssertEqual(first.value, true)
        XCTAssertNil(second.value)
    }

    func testArtworkSkipsReloadWhenRequestIdentityIsUnchanged() {
        let identity = ArtworkLoadRequestIdentity(
            context: ArtworkContextIdentity(
                sessionGeneration: 2,
                accountScope: "scope"
            ),
            coverArtID: "cover",
            cacheRevision: "rev-1",
            pixelSize: 384
        )

        XCTAssertFalse(
            UIRenderPolicy.shouldReloadArtwork(
                loadedIdentity: identity,
                requestedIdentity: identity
            )
        )
        XCTAssertTrue(
            UIRenderPolicy.shouldReloadArtwork(
                loadedIdentity: nil,
                requestedIdentity: identity
            )
        )
        XCTAssertTrue(
            UIRenderPolicy.shouldReloadArtwork(
                loadedIdentity: identity,
                requestedIdentity: ArtworkLoadRequestIdentity(
                    context: identity.context,
                    coverArtID: "cover",
                    cacheRevision: "rev-2",
                    pixelSize: 384
                )
            )
        )
    }

    func testArtworkRequestIdentityKeepsFieldsStructurallyDistinct() {
        let first = ArtworkLoadRequestIdentity(
            context: ArtworkContextIdentity(
                sessionGeneration: 7,
                accountScope: "scope-part"
            ),
            coverArtID: "cover",
            cacheRevision: "revision",
            pixelSize: 600
        )
        let second = ArtworkLoadRequestIdentity(
            context: ArtworkContextIdentity(
                sessionGeneration: 7,
                accountScope: "scope"
            ),
            coverArtID: "part-cover",
            cacheRevision: "revision",
            pixelSize: 600
        )

        XCTAssertNotEqual(first, second)
    }

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
            1_536
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

    func testMediaIdentityDropsDuplicateSongIDsAndHonorsLimit() {
        let songs = (0..<8).flatMap { index -> [Song] in
            let song = Song(
                id: "song-\(index % 4)",
                title: "Song \(index)",
                artist: "Artist",
                album: "Album",
                artistId: "artist",
                albumId: "album",
                coverArt: nil,
                duration: 180,
                track: nil,
                suffix: "m4a",
                contentType: "audio/mp4",
                starred: nil
            )
            return [song]
        }

        XCTAssertEqual(MediaIdentity.uniqueSongs(songs).map(\.id), [
            "song-0", "song-1", "song-2", "song-3"
        ])
        XCTAssertEqual(
            MediaIdentity.uniqueSongs(from: [songs, songs], limit: 2).map(\.id),
            ["song-0", "song-1"]
        )
    }

    func testHomeSnapshotMapsEverySongCollection() {
        var snapshot = HomeSnapshot(
            randomSongs: [
                Song(
                    id: "one",
                    title: "One",
                    artist: "Artist",
                    album: "Album",
                    artistId: "artist",
                    albumId: "album",
                    coverArt: nil,
                    duration: 180,
                    track: nil,
                    suffix: "m4a",
                    contentType: "audio/mp4",
                    starred: nil
                )
            ]
        )
        snapshot.mapSongs { song in
            var value = song
            value.title = "Mapped"
            return value
        }
        XCTAssertEqual(snapshot.randomSongs.first?.title, "Mapped")
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

    func testLibraryArtistPresentationClearsStaleFavoriteOutsideAuthoritativeList() {
        let stale = Artist(
            id: "stale",
            name: "Stale",
            coverArt: nil,
            albumCount: nil,
            starred: "old"
        )

        let presentation = LibraryArtistPresentation.make(input: .init(
            artists: [stale],
            starredArtists: []
        ))

        XCTAssertTrue(presentation.favorites.isEmpty)
        XCTAssertFalse(presentation.allArtists[0].isStarred)
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
