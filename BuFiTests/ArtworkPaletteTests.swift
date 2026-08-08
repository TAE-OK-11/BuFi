import UIKit
import XCTest
@testable import BuFi

final class ArtworkPaletteTests: XCTestCase {
    func testColorfulArtworkProducesDistinctSpatialSwatches() {
        let image = pixelImage { x, y in
            switch (x < 24, y < 24) {
            case (true, true): return Pixel(red: 238, green: 48, blue: 72, alpha: 255)
            case (false, true): return Pixel(red: 50, green: 92, blue: 238, alpha: 255)
            case (true, false): return Pixel(red: 242, green: 190, blue: 42, alpha: 255)
            case (false, false): return Pixel(red: 42, green: 184, blue: 112, alpha: 255)
            }
        }

        let palette = ArtworkStore.extractPalette(from: image)

        XCTAssertGreaterThan(chroma(palette.accent), 0.09)
        XCTAssertGreaterThan(chroma(palette.secondary), 0.07)
        XCTAssertGreaterThan(colorDistance(palette.accent, palette.secondary), 0.045)
        XCTAssertGreaterThan(
            hypot(
                palette.accentPosition.x - palette.secondaryPosition.x,
                palette.accentPosition.y - palette.secondaryPosition.y
            ),
            0.18
        )
    }

    func testPastelArtworkRetainsPastelsWithoutInventingSaturation() {
        let pink = Pixel(red: 236, green: 194, blue: 210, alpha: 255)
        let blue = Pixel(red: 190, green: 216, blue: 240, alpha: 255)
        let image = pixelImage { x, _ in x < 24 ? pink : blue }
        let sourceMaximum = max(chroma(pink), chroma(blue))

        let palette = ArtworkStore.extractPalette(from: image)
        let output = [palette.top, palette.bottom, palette.accent, palette.secondary]

        XCTAssertGreaterThan(output.map { chroma($0) }.max() ?? 0, 0.025)
        XCTAssertLessThanOrEqual(
            output.map { chroma($0) }.max() ?? 1,
            sourceMaximum + 0.012
        )
    }

    func testPureBlackPaletteUsesVisibleNeutralGray() {
        let palette = ArtworkStore.extractPalette(from: pixelImage { _, _ in .black })

        assertNeutral(palette)
        XCTAssertGreaterThan(luminance(palette.top), 0.04)
        XCTAssertLessThan(luminance(palette.top), 0.16)
        XCTAssertLessThan(luminance(palette.bottom), luminance(palette.top))
    }

    func testMostlyBlackArtworkPrefersMeaningfulColor() {
        let image = pixelImage { x, _ in
            x < 9
                ? Pixel(red: 224, green: 24, blue: 36, alpha: 255)
                : .black
        }

        let palette = ArtworkStore.extractPalette(from: image)

        XCTAssertGreaterThan(chroma(palette.accent), 0.12)
        XCTAssertGreaterThan(palette.accent.red, palette.accent.green + 0.12)
        XCTAssertGreaterThan(palette.accent.red, palette.accent.blue + 0.08)
    }

    func testTinyColorNoiseDoesNotOverrideDarkNeutralPalette() {
        let image = pixelImage { x, _ in
            x == 0
                ? Pixel(red: 22, green: 86, blue: 238, alpha: 255)
                : .black
        }

        let palette = ArtworkStore.extractPalette(from: image)

        assertNeutral(palette)
        XCTAssertGreaterThan(luminance(palette.top), 0.04)
    }

    func testPureWhitePaletteRemainsWhiteFamily() {
        let palette = ArtworkStore.extractPalette(from: pixelImage { _, _ in .white })

        assertNeutral(palette)
        XCTAssertGreaterThan(luminance(palette.top), 0.55)
        XCTAssertGreaterThan(luminance(palette.accent), luminance(palette.top))
        XCTAssertLessThan(luminance(palette.bottom), luminance(palette.top))
    }

    func testNeutralGrayArtworkRetainsTonalAndSpatialVariation() {
        let image = pixelImage { x, _ in
            if x < 16 { return Pixel(red: 38, green: 38, blue: 38, alpha: 255) }
            if x < 32 { return Pixel(red: 132, green: 132, blue: 132, alpha: 255) }
            return Pixel(red: 224, green: 224, blue: 224, alpha: 255)
        }
        let palette = ArtworkStore.extractPalette(from: image)

        assertNeutral(palette)
        XCTAssertGreaterThan(
            abs(luminance(palette.accent) - luminance(palette.secondary)),
            0.08
        )
        XCTAssertGreaterThan(
            abs(palette.accentPosition.x - palette.secondaryPosition.x),
            0.18
        )
    }

    func testMixedArtworkSwitchesAtInclusiveEightyFivePercentNeutralBoundary() {
        // 1,958 / 2,304 = 84.98%; 1,959 / 2,304 = 85.03%.
        let belowBoundary = neutralMix(neutralPixelCount: 1_958)
        let atBoundary = neutralMix(neutralPixelCount: 1_959)

        let mixedPalette = ArtworkStore.extractPalette(from: belowBoundary)
        let neutralPalette = ArtworkStore.extractPalette(from: atBoundary)

        XCTAssertGreaterThan(chroma(mixedPalette.accent), 0.12)
        XCTAssertLessThan(chroma(neutralPalette.accent), 0.008)
        XCTAssertGreaterThan(
            chroma(mixedPalette.accent),
            chroma(neutralPalette.accent) + 0.10
        )
    }

    func testNeutralFamilyPolicyIncludesExactlyEightyFivePercent() {
        XCTAssertTrue(ArtworkStore.qualifiesAsNeutralFamily(
            neutralWeight: 85,
            visibleWeight: 100
        ))
        XCTAssertFalse(ArtworkStore.qualifiesAsNeutralFamily(
            neutralWeight: Double(0.85).nextDown,
            visibleWeight: 1
        ))
    }

    func testAlphaWeightPreventsNearlyTransparentColorFromDominating() {
        let image = pixelImage { x, y in
            let index = y * 48 + x
            if index < 2_189 {
                return Pixel(red: 255, green: 0, blue: 0, alpha: 5)
            }
            return Pixel(red: 28, green: 74, blue: 236, alpha: 255)
        }

        let palette = ArtworkStore.extractPalette(from: image)

        XCTAssertGreaterThan(palette.accent.blue, palette.accent.red * 1.8)
        XCTAssertGreaterThan(palette.accent.blue, palette.accent.green * 1.5)
        XCTAssertEqual(palette.accent.alpha, 1)
    }

    func testLowChromaArtworkNeverInventsSaturatedHue() {
        let tint = Pixel(red: 174, green: 168, blue: 164, alpha: 255)
        let image = pixelImage { _, _ in tint }
        let palette = ArtworkStore.extractPalette(from: image)
        let output = [palette.top, palette.bottom, palette.accent, palette.secondary]

        XCTAssertLessThanOrEqual(
            output.map { chroma($0) }.max() ?? 1,
            chroma(tint) + 0.004
        )
    }

    func testExtractionIsBitForBitDeterministic() {
        let image = pixelImage { x, y in
            Pixel(
                red: UInt8((x * 31 + y * 7) % 256),
                green: UInt8((x * 11 + y * 29) % 256),
                blue: UInt8((x * 19 + y * 17) % 256),
                alpha: UInt8(96 + ((x * 5 + y * 3) % 160))
            )
        }
        let expected = ArtworkStore.extractPalette(from: image)

        for _ in 0..<8 {
            XCTAssertEqual(ArtworkStore.extractPalette(from: image), expected)
        }
    }

    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8

        static let black = Pixel(red: 0, green: 0, blue: 0, alpha: 255)
        static let white = Pixel(red: 255, green: 255, blue: 255, alpha: 255)
    }

    private func neutralMix(neutralPixelCount: Int) -> UIImage {
        pixelImage { x, y in
            y * 48 + x < neutralPixelCount
                ? .white
                : Pixel(red: 235, green: 38, blue: 58, alpha: 255)
        }
    }

    private func pixelImage(
        width: Int = 48,
        height: Int = 48,
        pixel: (Int, Int) -> Pixel
    ) -> UIImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                let offset = (y * width + x) * 4
                let alpha = Int(value.alpha)
                bytes[offset] = UInt8((Int(value.red) * alpha + 127) / 255)
                bytes[offset + 1] = UInt8((Int(value.green) * alpha + 127) / 255)
                bytes[offset + 2] = UInt8((Int(value.blue) * alpha + 127) / 255)
                bytes[offset + 3] = value.alpha
            }
        }

        let data = Data(bytes) as CFData
        let provider = CGDataProvider(data: data)!
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue
        )
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: image)
    }

    private func assertNeutral(
        _ palette: ArtworkPalette,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for color in [palette.top, palette.bottom, palette.accent, palette.secondary] {
            XCTAssertLessThan(chroma(color), 0.008, file: file, line: line)
        }
    }

    private func chroma(_ pixel: Pixel) -> Double {
        chroma(RGBAColor(
            red: Double(pixel.red) / 255,
            green: Double(pixel.green) / 255,
            blue: Double(pixel.blue) / 255,
            alpha: Double(pixel.alpha) / 255
        ))
    }

    private func chroma(_ color: RGBAColor) -> Double {
        let lab = oklab(color)
        return hypot(lab.a, lab.b)
    }

    private func colorDistance(_ lhs: RGBAColor, _ rhs: RGBAColor) -> Double {
        let left = oklab(lhs)
        let right = oklab(rhs)
        return sqrt(
            pow(left.lightness - right.lightness, 2)
                + pow(left.a - right.a, 2)
                + pow(left.b - right.b, 2)
        )
    }

    private func oklab(_ color: RGBAColor) -> (lightness: Double, a: Double, b: Double) {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let red = linear(color.red)
        let green = linear(color.green)
        let blue = linear(color.blue)
        let lRoot = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
        let mRoot = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
        let sRoot = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
        return (
            lightness: 0.2104542553 * lRoot + 0.7936177850 * mRoot - 0.0040720468 * sRoot,
            a: 1.9779984951 * lRoot - 2.4285922050 * mRoot + 0.4505937099 * sRoot,
            b: 0.0259040371 * lRoot + 0.7827717662 * mRoot - 0.8086757660 * sRoot
        )
    }

    private func luminance(_ color: RGBAColor) -> Double {
        0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }
}
