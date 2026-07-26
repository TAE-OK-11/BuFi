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

    private let memory = NSCache<NSString, UIImage>()
    private let paletteMemory = NSCache<NSString, PaletteBox>()
    private var inFlightImages: [NSString: Task<UIImage, Error>] = [:]
    private let session: URLSession
    private let directory: URL

    init() {
        memory.totalCostLimit = 64 * 1_024 * 1_024
        memory.countLimit = 140
        paletteMemory.countLimit = 100

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)

        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = root.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for url: URL, pixelSize: CGFloat) async throws -> UIImage {
        let dataKey = Self.cacheKey(for: url)
        let requestedPixelSize = min(max(pixelSize, 64), 1_024)
        let imageKey = "\(dataKey)#\(Int(requestedPixelSize.rounded()))" as NSString
        if let cached = memory.object(forKey: imageKey) { return cached }
        if let existing = inFlightImages[imageKey] { return try await existing.value }

        let diskURL = directory.appendingPathComponent(Self.hash(dataKey as String))
        let task = Task(priority: .utility) { [session] () throws -> UIImage in
            let data: Data
            if let diskData = try? Data(contentsOf: diskURL, options: [.mappedIfSafe]),
               !diskData.isEmpty {
                data = diskData
            } else {
                let (downloaded, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      !downloaded.isEmpty else {
                    throw URLError(.badServerResponse)
                }
                data = downloaded
                try? data.write(
                    to: diskURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            }

            guard let image = Self.downsample(data: data, pixelSize: requestedPixelSize) else {
                throw URLError(.cannotDecodeContentData)
            }
            return image
        }
        inFlightImages[imageKey] = task

        do {
            let image = try await task.value
            inFlightImages[imageKey] = nil
            memory.setObject(image, forKey: imageKey, cost: Self.imageCost(image))
            return image
        } catch {
            inFlightImages[imageKey] = nil
            throw error
        }
    }

    func palette(for url: URL, image: UIImage? = nil) async -> ArtworkPalette {
        let key = Self.cacheKey(for: url)
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
            saturation: min(max(saturation * 1.05, 0.24), 0.76),
            brightness: min(max(brightness * 0.78, 0.28), 0.58),
            alpha: 1
        )
        let bottom = UIColor(
            hue: hue,
            saturation: min(max(saturation * 0.74, 0.16), 0.56),
            brightness: min(max(brightness * 0.30, 0.065), 0.20),
            alpha: 1
        )

        let value = ArtworkPalette(top: Self.components(top), bottom: Self.components(bottom))
        paletteMemory.setObject(PaletteBox(value), forKey: key)
        return value
    }

    func clearMemory() {
        inFlightImages.values.forEach { $0.cancel() }
        inFlightImages.removeAll()
        memory.removeAllObjects()
        paletteMemory.removeAllObjects()
    }

    func clearAll() {
        clearMemory()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
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

    private static func imageCost(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else {
            return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        }
        return cgImage.width * cgImage.height * 4
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

    private static func dominantColor(in image: UIImage) -> UIColor? {
        guard let source = image.cgImage else { return nil }
        let width = 36
        let height = 36
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
            var samples = 0
        }
        var buckets = [Bucket](repeating: Bucket(), count: 48)
        var neutral = Bucket()
        var acceptedSamples = 0

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
            acceptedSamples += 1

            let pixel = offset / 4
            let x = Double(pixel % width) / Double(width - 1)
            let y = Double(pixel / width) / Double(height - 1)
            let edgeDistance = max(abs(x - 0.5), abs(y - 0.5)) * 2
            let spatialWeight = 0.94 + min(0.20, edgeDistance * 0.20)

            let saturation = maximum == 0 ? 0 : delta / maximum
            if saturation < 0.12 {
                let weight = (0.24 + maximum * 0.18) * spatialWeight
                neutral.red += red * weight
                neutral.green += green * weight
                neutral.blue += blue * weight
                neutral.weight += weight
                neutral.samples += 1
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
            let index = min(47, max(0, Int(normalizedHue * 48)))
            let brightnessPreference = max(0.25, 1 - abs(maximum - 0.56) * 1.25)
            let weight = (
                0.22 + pow(saturation, 1.18) * brightnessPreference
            ) * spatialWeight
            buckets[index].red += red * weight
            buckets[index].green += green * weight
            buckets[index].blue += blue * weight
            buckets[index].weight += weight
            buckets[index].samples += 1
        }

        let minimumPopulation = max(3, acceptedSamples / 100)
        func clusterScore(_ index: Int) -> Double {
            let bucket = buckets[index]
            guard bucket.samples >= minimumPopulation else { return 0 }
            let previous = buckets[(index + buckets.count - 1) % buckets.count]
            let next = buckets[(index + 1) % buckets.count]
            return bucket.weight + (previous.weight + next.weight) * 0.34
        }
        let selectedIndex = buckets.indices.max { lhs, rhs in
            clusterScore(lhs) < clusterScore(rhs)
        }

        if let selectedIndex,
           clusterScore(selectedIndex) > max(0.9, neutral.weight * 0.18) {
            var selected = buckets[selectedIndex]
            for neighbor in [
                (selectedIndex + buckets.count - 1) % buckets.count,
                (selectedIndex + 1) % buckets.count
            ] where buckets[neighbor].samples >= minimumPopulation {
                selected.red += buckets[neighbor].red * 0.38
                selected.green += buckets[neighbor].green * 0.38
                selected.blue += buckets[neighbor].blue * 0.38
                selected.weight += buckets[neighbor].weight * 0.38
            }
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

    private static func cacheKey(for url: URL) -> NSString {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString as NSString
        }
        let authenticationFields: Set<String> = ["u", "s", "t", "v", "c", "f"]
        components.queryItems = components.queryItems?
            .filter { !authenticationFields.contains($0.name) }
            .sorted {
                if $0.name == $1.name { return ($0.value ?? "") < ($1.value ?? "") }
                return $0.name < $1.name
            }
        return (components.string ?? url.absoluteString) as NSString
    }
}

private final class PaletteBox {
    let value: ArtworkPalette
    init(_ value: ArtworkPalette) { self.value = value }
}
