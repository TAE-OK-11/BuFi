import Foundation
import Nuke
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

    private static let legacyCacheName = "cloud.tae00217.BuFi.Artwork"

    private var pipeline: ImagePipeline
    private var pipelineScope: String?
    private var activeScope: String?
    private var didDiscardLegacyCache = false
    private let paletteMemory = NSCache<NSString, PaletteBox>()

    init() {
        pipeline = Self.makePipeline(name: Self.legacyCacheName)
        paletteMemory.countLimit = 160
    }

    func activate(accountScope: String) async {
        guard activeScope != accountScope else { return }

        if !didDiscardLegacyCache {
            await pipeline.cache.removeAll(caches: [.all])
            didDiscardLegacyCache = true
        } else {
            await pipeline.cache.removeAll(caches: [.memory])
        }

        if pipelineScope != accountScope {
            pipeline = Self.makePipeline(
                name: Self.legacyCacheName + "." + accountScope
            )
            pipelineScope = accountScope
        }
        activeScope = accountScope
        paletteMemory.removeAllObjects()
    }

    func image(for url: URL, pixelSize: CGFloat) async throws -> UIImage {
        guard activeScope != nil else { throw URLError(.userAuthenticationRequired) }
        let requestedPixelSize = min(max(pixelSize, 64), 1_536)
        let request = ImageRequest(
            url: url,
            processors: [.resize(width: requestedPixelSize)]
        )
        return try await pipeline.image(for: request)
    }

    func prefetch(urls: [URL], pixelSize: CGFloat) async {
        guard activeScope != nil,
              !urls.isEmpty,
              Self.allowsDiscretionaryWork else {
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for url in urls.prefix(2) {
                group.addTask(priority: .utility) { [pipeline] in
                    let request = ImageRequest(
                        url: url,
                        processors: [.resize(width: min(max(pixelSize, 64), 1_024))],
                        priority: .low
                    )
                    _ = try? await pipeline.image(for: request)
                }
            }
        }
    }

    func palette(for url: URL, image: UIImage? = nil) async -> ArtworkPalette {
        guard activeScope != nil else { return .fallback }
        let key = ArtworkPipelineDelegate.normalizedCacheKey(for: url) as NSString
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

    func clearMemory() async {
        await pipeline.cache.removeAll(caches: [.memory])
        paletteMemory.removeAllObjects()
    }

    func clearAll() async {
        await pipeline.cache.removeAll(caches: [.all])
        paletteMemory.removeAllObjects()
    }

    private static var allowsDiscretionaryWork: Bool {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair:
            return true
        case .serious, .critical:
            return false
        @unknown default:
            return false
        }
    }

    private static func makePipeline(name: String) -> ImagePipeline {
        var configuration = ImagePipeline.Configuration.withDataCache(
            name: name,
            sizeLimit: 256 * 1_024 * 1_024
        )
        configuration.isTaskCoalescingEnabled = true
        configuration.isProgressiveDecodingEnabled = false
        configuration.dataCachePolicy = .automatic
        return ImagePipeline(
            configuration: configuration,
            delegate: ArtworkPipelineDelegate()
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
}

private final class ArtworkPipelineDelegate: ImagePipeline.Delegate, @unchecked Sendable {
    func cacheKey(for request: ImageRequest, pipeline: ImagePipeline) -> String? {
        guard let url = request.url else { return nil }
        let processors = request.processors.map(\.identifier).joined(separator: "|")
        return Self.normalizedCacheKey(for: url) + "#" + processors
    }

    static func normalizedCacheKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let authenticationFields: Set<String> = [
            "u", "s", "t", "p", "apiKey", "v", "c", "f"
        ]
        components.queryItems = components.queryItems?
            .filter { !authenticationFields.contains($0.name) }
            .sorted {
                if $0.name == $1.name { return ($0.value ?? "") < ($1.value ?? "") }
                return $0.name < $1.name
            }
        return components.string ?? url.absoluteString
    }
}

private final class PaletteBox {
    let value: ArtworkPalette
    init(_ value: ArtworkPalette) { self.value = value }
}
