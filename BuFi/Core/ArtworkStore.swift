import CryptoKit
import Foundation
import ImageIO
import UIKit

struct RGBAColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    static let fallbackTop = RGBAColor(red: 0.26, green: 0.34, blue: 0.30, alpha: 1)
    static let fallbackBottom = RGBAColor(red: 0.08, green: 0.09, blue: 0.09, alpha: 1)
}

struct ArtworkPalette: Equatable, Sendable {
    let top: RGBAColor
    let bottom: RGBAColor

    static let fallback = ArtworkPalette(top: .fallbackTop, bottom: .fallbackBottom)
}

actor ArtworkStore {
    static let shared = ArtworkStore()

    private let memory = NSCache<NSURL, UIImage>()
    private let paletteMemory = NSCache<NSURL, PaletteBox>()
    private let session: URLSession
    private let directory: URL

    init() {
        memory.totalCostLimit = 64 * 1_024 * 1_024
        memory.countLimit = 180
        paletteMemory.countLimit = 100

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1_024 * 1_024,
            diskCapacity: 180 * 1_024 * 1_024,
            diskPath: "BuFiArtwork"
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 5
        session = URLSession(configuration: configuration)

        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = root.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for url: URL, pixelSize: CGFloat) async throws -> UIImage {
        let key = url as NSURL
        if let cached = memory.object(forKey: key) { return cached }

        let diskURL = directory.appendingPathComponent(Self.hash(url.absoluteString))
        let data: Data
        if let diskData = try? Data(contentsOf: diskURL), !diskData.isEmpty {
            data = diskData
        } else {
            let (downloaded, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !downloaded.isEmpty else {
                throw URLError(.badServerResponse)
            }
            data = downloaded
            try? data.write(to: diskURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }

        guard let image = Self.downsample(data: data, pixelSize: pixelSize) else {
            throw URLError(.cannotDecodeContentData)
        }
        memory.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        return image
    }

    func palette(for url: URL, image: UIImage? = nil) async -> ArtworkPalette {
        let key = url as NSURL
        if let cached = paletteMemory.object(forKey: key) { return cached.value }

        let source: UIImage
        if let providedImage = image {
            source = providedImage
        } else {
            let loadedImage = try? await self.image(for: url, pixelSize: 96)
            guard let loadedImage else { return .fallback }
            source = loadedImage
        }

        guard let base = Self.dominantColor(in: source) else { return .fallback }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let top = UIColor(
            hue: hue,
            saturation: min(max(saturation * 1.15, 0.30), 0.80),
            brightness: min(max(brightness * 0.72, 0.25), 0.52),
            alpha: 1
        )
        let bottom = UIColor(
            hue: hue,
            saturation: min(max(saturation * 0.72, 0.18), 0.58),
            brightness: min(max(brightness * 0.28, 0.07), 0.18),
            alpha: 1
        )

        let value = ArtworkPalette(top: Self.components(top), bottom: Self.components(bottom))
        paletteMemory.setObject(PaletteBox(value), forKey: key)
        return value
    }

    func clearMemory() {
        memory.removeAllObjects()
        paletteMemory.removeAllObjects()
    }

    private static func components(_ color: UIColor) -> RGBAColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGBAColor(
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            alpha: Double(alpha)
        )
    }

    private static func downsample(data: Data, pixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, Int(pixelSize))
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    /// Samples a small Core Graphics bitmap and chooses the strongest hue cluster.
    /// This avoids the muddy result produced by averaging unrelated foreground and
    /// background colors while keeping the operation deterministic and inexpensive.
    private static func dominantColor(in image: UIImage) -> UIColor? {
        guard let source = image.cgImage else { return nil }
        let width = 28
        let height = 28
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        struct Bucket {
            var red = 0.0
            var green = 0.0
            var blue = 0.0
            var weight = 0.0
        }
        var buckets = [Bucket](repeating: Bucket(), count: 36)
        var neutral = Bucket()

        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[offset + 3]) / 255
            guard alpha > 0.5 else { continue }
            let red = Double(bytes[offset]) / 255
            let green = Double(bytes[offset + 1]) / 255
            let blue = Double(bytes[offset + 2]) / 255
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let delta = maximum - minimum
            guard maximum > 0.08, maximum < 0.96 else { continue }

            let saturation = maximum == 0 ? 0 : delta / maximum
            if saturation < 0.12 {
                let weight = 0.22 + maximum * 0.2
                neutral.red += red * weight
                neutral.green += green * weight
                neutral.blue += blue * weight
                neutral.weight += weight
                continue
            }

            let hue: Double
            if maximum == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            let normalizedHue = ((hue / 6).truncatingRemainder(dividingBy: 1) + 1)
                .truncatingRemainder(dividingBy: 1)
            let index = min(35, max(0, Int(normalizedHue * 36)))
            let brightnessPreference = max(0.25, 1 - abs(maximum - 0.56) * 1.25)
            let weight = pow(saturation, 1.35) * brightnessPreference
            buckets[index].red += red * weight
            buckets[index].green += green * weight
            buckets[index].blue += blue * weight
            buckets[index].weight += weight
        }

        if let selected = buckets.max(by: { $0.weight < $1.weight }),
           selected.weight > max(0.8, neutral.weight * 0.22) {
            return UIColor(
                red: selected.red / selected.weight,
                green: selected.green / selected.weight,
                blue: selected.blue / selected.weight,
                alpha: 1
            )
        }
        guard neutral.weight > 0 else { return nil }
        return UIColor(
            red: neutral.red / neutral.weight,
            green: neutral.green / neutral.weight,
            blue: neutral.blue / neutral.weight,
            alpha: 1
        )
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class PaletteBox {
    let value: ArtworkPalette
    init(_ value: ArtworkPalette) { self.value = value }
}
