import MediaPlayer
import UIKit
import XCTest
@testable import BuFi

@MainActor
final class NowPlayingArtworkProviderTests: XCTestCase {
    private final class ArtworkBox: @unchecked Sendable {
        let value: MPMediaItemArtwork

        init(_ value: MPMediaItemArtwork) {
            self.value = value
        }
    }

    func testMediaPlayerCanRequestArtworkOffMainActor() async {
        let sourceSize = CGSize(width: 12, height: 8)
        let source = UIGraphicsImageRenderer(size: sourceSize).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: sourceSize))
        }
        let image = ArtworkImage(source, cacheKey: "now-playing-provider-test")
        let artwork = NowPlayingArtworkProvider(image: image).makeArtwork()
        let box = ArtworkBox(artwork)

        let returnedSize = await Task.detached {
            box.value.image(at: CGSize(width: 64, height: 64))?.size ?? .zero
        }.value

        XCTAssertEqual(returnedSize, sourceSize)
    }
}
