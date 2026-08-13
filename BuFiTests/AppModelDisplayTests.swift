import Combine
import XCTest
@testable import BuFi

final class AppModelDisplayTests: XCTestCase {
    @MainActor
    func testHomeLibraryRevisionStartsAtZeroWithPerStateEpoch() {
        let first = HomeLibraryState()
        let second = HomeLibraryState()

        XCTAssertEqual(first.snapshot, .empty)
        XCTAssertEqual(first.revision.generation, 0)
        XCTAssertEqual(second.revision.generation, 0)
        XCTAssertNotEqual(first.revision.epoch, second.revision.epoch)
    }

    func testHomeSnapshotRevisionAdvancesWithinItsEpoch() {
        let initial = HomeSnapshotRevision()
        let advanced = initial.advanced()

        XCTAssertEqual(advanced.epoch, initial.epoch)
        XCTAssertEqual(advanced.generation, initial.generation + 1)
        XCTAssertNotEqual(advanced, initial)
    }

    @MainActor
    func testHomeSnapshotAndRevisionPublishAtomicallyOnce() {
        let state = HomeLibraryState()
        var publications = 0
        let observation = state.objectWillChange.sink {
            publications += 1
        }
        var snapshot = HomeSnapshot.empty
        snapshot.playlists = [Playlist(
            id: "playlist",
            name: "Playlist",
            owner: nil,
            songCount: 1,
            coverArt: nil
        )]

        XCTAssertTrue(state.setSnapshot(snapshot))
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(state.snapshot, snapshot)
        XCTAssertEqual(state.revision.generation, 1)
        XCTAssertFalse(state.setSnapshot(snapshot))
        XCTAssertEqual(publications, 1)
        _ = observation
    }

    func testServerDisplayAddressKeepsHostExplicitPortAndBasePath() {
        let value = AppModel.serverDisplayAddress(
            from: "https://alice:super-secret@Music.Example.COM:8443/navidrome/?token=private#account"
        )

        XCTAssertEqual(value, "music.example.com:8443/navidrome")
        XCTAssertFalse(value.contains("https"))
        XCTAssertFalse(value.contains("alice"))
        XCTAssertFalse(value.contains("super-secret"))
        XCTAssertFalse(value.contains("private"))
        XCTAssertFalse(value.contains("account"))
    }

    func testServerDisplayAddressPreservesExplicitDefaultPort() {
        XCTAssertEqual(
            AppModel.serverDisplayAddress(
                from: "https://music.example.com:443/subsonic/"
            ),
            "music.example.com:443/subsonic"
        )
    }

    func testServerDisplayAddressFormatsIPv6WithoutCredentials() {
        let value = AppModel.serverDisplayAddress(
            from: "https://listener:password@[2001:DB8::1]:9443/music/?apiKey=secret#profile"
        )

        XCTAssertEqual(value, "[2001:db8::1]:9443/music")
        XCTAssertFalse(value.contains("listener"))
        XCTAssertFalse(value.contains("password"))
        XCTAssertFalse(value.contains("secret"))
        XCTAssertFalse(value.contains("profile"))
    }

    func testServerDisplayAddressRejectsValuesWithoutAHost() {
        XCTAssertEqual(
            AppModel.serverDisplayAddress(from: "not a server URL"),
            ""
        )
    }
}
