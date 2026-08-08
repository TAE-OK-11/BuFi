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
    }
}
