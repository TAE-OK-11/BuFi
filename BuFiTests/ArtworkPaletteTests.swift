import UIKit
import XCTest
@testable import BuFi

final class ArtworkPaletteTests: XCTestCase {
    func testMostlyBlackArtworkPrefersMeaningfulColor() {
        let image = makeImage(
            background: .black,
            accent: UIColor(red: 0.86, green: 0.08, blue: 0.12, alpha: 1),
            accentFraction: 0.20
        )

        let palette = ArtworkStore.paletteValue(in: image)

        XCTAssertGreaterThan(palette.top.red, palette.top.green + 0.12)
        XCTAssertGreaterThan(palette.top.red, palette.top.blue + 0.08)
        XCTAssertNotEqual(palette, .darkArtwork)
    }

    func testBlackArtworkUsesNeutralGrayPalette() {
        let palette = ArtworkStore.paletteValue(
            in: makeImage(background: .black)
        )

        XCTAssertEqual(palette, .darkArtwork)
        assertNeutral(palette.top)
        assertNeutral(palette.bottom)
        XCTAssertGreaterThan(palette.top.red, palette.bottom.red)
    }

    func testTinyColorNoiseDoesNotOverrideBlackFallback() {
        let image = makeImage(
            background: .black,
            accent: .systemBlue,
            accentFraction: 0.02
        )

        XCTAssertEqual(ArtworkStore.paletteValue(in: image), .darkArtwork)
    }

    func testNeutralArtworkDoesNotInventAHue() {
        let gray = UIColor(white: 0.52, alpha: 1)
        let palette = ArtworkStore.paletteValue(in: makeImage(background: gray))

        assertNeutral(palette.top)
        assertNeutral(palette.bottom)
        assertNeutral(palette.accent)
        assertNeutral(palette.secondary)
    }

    func testTransparentArtworkUsesFallback() {
        let image = makeImage(background: .clear)

        XCTAssertEqual(ArtworkStore.paletteValue(in: image), .fallback)
    }

    private func assertNeutral(
        _ color: RGBAColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(color.red, color.green, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(color.green, color.blue, accuracy: 0.001, file: file, line: line)
    }

    private func makeImage(
        background: UIColor,
        accent: UIColor? = nil,
        accentFraction: CGFloat = 0
    ) -> UIImage {
        let size = CGSize(width: 100, height: 100)
        return UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.setFillColor(background.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            guard let accent, accentFraction > 0 else { return }
            context.cgContext.setFillColor(accent.cgColor)
            context.cgContext.fill(CGRect(
                x: 0,
                y: 0,
                width: size.width * min(accentFraction, 1),
                height: size.height
            ))
        }
    }
}
