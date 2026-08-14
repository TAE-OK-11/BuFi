import Foundation
import XCTest
@testable import BuFi

final class SwiftConcurrencyArchitectureTests: XCTestCase {
    func testNowPlayingVisualIdentityKeepsFieldsStructurallyDistinct() {
        let playbackID = UUID()
        let lhs = NowPlayingVisualIdentity(
            accountScope: "account|segment",
            playbackID: playbackID,
            metadataRevision: "meta",
            artworkRevision: "art"
        )
        let rhs = NowPlayingVisualIdentity(
            accountScope: "account",
            playbackID: playbackID,
            metadataRevision: "segment|meta",
            artworkRevision: "art"
        )

        XCTAssertNotEqual(lhs, rhs)
    }

    func testConcurrentUIPresentationBoundariesPreserveEmptyInputs() async {
        let home = await HomePresentation.makeConcurrently(
            input: HomePresentationInput(
                snapshot: .empty,
                selectedArtists: []
            )
        )
        let library = await LibraryArtistPresentation.makeConcurrently(
            input: LibraryArtistPresentationInput(
                artists: [],
                starredArtists: []
            )
        )

        XCTAssertTrue(home.personalizedMixes.isEmpty)
        XCTAssertTrue(library.allArtists.isEmpty)
        XCTAssertTrue(library.sections.isEmpty)
    }

    func testLatencyDurationConversionUsesMonotonicDurationUnits() {
        XCTAssertEqual(
            OpenSubsonicClient.milliseconds(from: .milliseconds(125)),
            125,
            accuracy: 0.001
        )
    }

    func testConcurrentContentDecoderPassesThroughPlainData() async throws {
        let input = Data("swift-6.4".utf8)
        let output = try await HTTPContentDecoder.decodeAsync(
            input,
            contentEncoding: nil
        )
        XCTAssertEqual(output, input)
    }
}
