import Foundation
import XCTest
@testable import BuFi

final class ServerURLNormalizationTests: XCTestCase {
    func testAddsHTTPSAndKeepsReverseProxyPath() throws {
        let url = try ServerURLNormalization.resolvedURL(
            from: " Music.Example.COM:8443/navidrome/ "
        )

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "music.example.com")
        XCTAssertEqual(url.port, 8443)
        XCTAssertEqual(url.path, "/navidrome")
        XCTAssertEqual(
            ServerURLNormalization.persistedServerURL(from: url),
            "https://music.example.com:8443/navidrome"
        )
    }

    func testStripsTrailingRestSuffixAndQuery() throws {
        let url = try ServerURLNormalization.resolvedURL(
            from: "https://demo.navidrome.org/rest/?token=private#account"
        )

        XCTAssertEqual(url.host, "demo.navidrome.org")
        XCTAssertTrue(url.path.isEmpty || url.path == "/")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
    }

    func testKeepsBasePathWhenRestIsOnlyTheSuffix() throws {
        let url = try ServerURLNormalization.resolvedURL(
            from: "https://music.example.com/navidrome/rest/"
        )

        XCTAssertEqual(url.path, "/navidrome")
    }

    func testRejectsHTTP() {
        XCTAssertEqual(
            ServerURLNormalization.normalize("http://music.example.com"),
            .insecure
        )
        XCTAssertThrowsError(
            try ServerURLNormalization.resolvedURL(from: "http://music.example.com")
        ) { error in
            XCTAssertEqual(error as? OpenSubsonicError, .insecureServerURL)
        }
    }

    func testRejectsEmbeddedCredentials() {
        XCTAssertEqual(
            ServerURLNormalization.normalize(
                "https://alice:secret@music.example.com/navidrome"
            ),
            .credentialsInURL
        )
    }

    func testRejectsEmptyAndInvalidValues() {
        XCTAssertEqual(ServerURLNormalization.normalize("   "), .empty)
        XCTAssertEqual(ServerURLNormalization.normalize("not a server"), .invalid)
        XCTAssertNil(ServerURLNormalization.url(from: ""))
    }
}

final class LocalLibrarySearchTests: XCTestCase {
    func testRanksExactTitleAbovePartialAlbumMatch() {
        var snapshot = HomeSnapshot.empty
        snapshot.randomSongs = [
            song(id: "partial", title: "Night Drive", artist: "Other", album: "Midnight"),
            song(id: "exact", title: "Midnight", artist: "Focus", album: "Singles")
        ]
        snapshot.artists = [
            Artist(
                id: "artist-1",
                name: "Midnight Society",
                coverArt: nil,
                albumCount: nil,
                starred: nil
            )
        ]
        snapshot.recentAlbums = [
            Album(
                id: "album-1",
                name: "Midnight Oil",
                artist: "Band",
                coverArt: nil,
                year: nil,
                starred: nil
            )
        ]

        let results = LocalLibrarySearch.results(for: "midnight", in: snapshot)

        XCTAssertEqual(results.songs.map(\.id), ["exact", "partial"])
        XCTAssertEqual(results.artists.map(\.id), ["artist-1"])
        XCTAssertEqual(results.albums.map(\.id), ["album-1"])
    }

    func testEmptyOrUnrelatedQueryReturnsNothing() {
        var snapshot = HomeSnapshot.empty
        snapshot.starredSongs = [
            song(id: "liked", title: "Helium", artist: "Sia", album: "1000")
        ]

        XCTAssertTrue(LocalLibrarySearch.results(for: "   ", in: snapshot).isEmpty)
        XCTAssertTrue(LocalLibrarySearch.results(for: "zzzz", in: snapshot).isEmpty)
    }

    func testRetainsResultsWhileTheQueryIsStillBeingEdited() {
        let previous = SearchResults(
            songs: [
                song(id: "1", title: "Helium", artist: "Sia", album: "1000")
            ]
        )

        XCTAssertEqual(
            SearchPresentationPolicy.retainedResults(
                previousQuery: "hel",
                previousResults: previous,
                nextQuery: "heli"
            ),
            previous
        )
        XCTAssertTrue(
            SearchPresentationPolicy.retainedResults(
                previousQuery: "helium",
                previousResults: previous,
                nextQuery: "radiohead"
            ).isEmpty
        )
    }
}

final class TransientServiceFailurePolicyTests: XCTestCase {
    func testAllowsStaleLibraryAfterTransientFailuresOnly() {
        XCTAssertTrue(
            TransientServiceFailurePolicy.allowsCachedFallback(
                URLError(.notConnectedToInternet)
            )
        )
        XCTAssertTrue(
            TransientServiceFailurePolicy.allowsCachedFallback(
                OpenSubsonicError.http(503)
            )
        )
        XCTAssertTrue(
            TransientServiceFailurePolicy.allowsCachedFallback(
                OpenSubsonicError.invalidResponse
            )
        )
        XCTAssertFalse(
            TransientServiceFailurePolicy.allowsCachedFallback(
                OpenSubsonicError.http(401)
            )
        )
        XCTAssertFalse(
            TransientServiceFailurePolicy.allowsCachedFallback(
                OpenSubsonicError.server(code: 40, message: "wrong password")
            )
        )
        XCTAssertFalse(
            TransientServiceFailurePolicy.allowsCachedFallback(
                OpenSubsonicError.credentialsEmbeddedInServerURL
            )
        )
        XCTAssertFalse(
            TransientServiceFailurePolicy.allowsCachedFallback(CancellationError())
        )
    }
}

private func song(
    id: String,
    title: String,
    artist: String,
    album: String
) -> Song {
    Song(
        id: id,
        title: title,
        artist: artist,
        album: album,
        artistId: nil,
        albumId: nil,
        coverArt: nil,
        duration: nil,
        track: nil,
        suffix: nil,
        contentType: nil,
        starred: nil
    )
}
