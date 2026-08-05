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

struct PalettePosition: Equatable, Sendable {
    let x: Double
    let y: Double

    static let topTrailing = PalettePosition(x: 0.78, y: 0.18)
    static let bottomLeading = PalettePosition(x: 0.22, y: 0.82)
}

struct ArtworkPalette: Equatable, Sendable {
    let top: RGBAColor
    let bottom: RGBAColor
    let accent: RGBAColor
    let secondary: RGBAColor
    let accentPosition: PalettePosition
    let secondaryPosition: PalettePosition

    init(
        top: RGBAColor,
        bottom: RGBAColor,
        accent: RGBAColor? = nil,
        secondary: RGBAColor? = nil,
        accentPosition: PalettePosition = .bottomLeading,
        secondaryPosition: PalettePosition = .topTrailing
    ) {
        self.top = top
        self.bottom = bottom
        self.accent = accent ?? top
        self.secondary = secondary ?? bottom
        self.accentPosition = accentPosition
        self.secondaryPosition = secondaryPosition
    }

    static let fallback = ArtworkPalette(
        top: .fallbackTop,
        bottom: .fallbackBottom,
        accent: RGBAColor(red: 0.36, green: 0.48, blue: 0.42, alpha: 1),
        secondary: RGBAColor(red: 0.18, green: 0.27, blue: 0.34, alpha: 1)
    )
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
            pipeline.cache.removeAll(caches: [.all])
            didDiscardLegacyCache = true
        } else {
            pipeline.cache.removeAll(caches: [.memory])
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

    func deactivate(accountScope: String) {
        guard activeScope == accountScope else { return }
        pipeline.cache.removeAll(caches: [.memory])
        paletteMemory.removeAllObjects()
        activeScope = nil
    }

    func image(for url: URL, pixelSize: CGFloat) async throws -> UIImage {
        guard let scope = activeScope else {
            throw URLError(.userAuthenticationRequired)
        }
        let requestedPixelSize = min(max(pixelSize, 64), 1_536)
        var urlRequest = URLRequest(url: url)
        ModernNetworkPolicy.prepareImageRequest(&urlRequest)
        let request = ImageRequest(
            urlRequest: urlRequest,
            processors: [.resize(width: requestedPixelSize)]
        )
        let scopedPipeline = pipeline
        let image = try await scopedPipeline.image(for: request)
        try Task.checkCancellation()
        guard activeScope == scope, pipeline === scopedPipeline else {
            throw CancellationError()
        }
        return image
    }


    func palette(for url: URL, image: UIImage? = nil) async -> ArtworkPalette {
        guard let scope = activeScope, !Task.isCancelled else { return .fallback }
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

        let prominentColors = Self.prominentColors(in: source)
        guard let base = prominentColors.first else { return .fallback }
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
        let perceptualSwatches = Self.perceptualSwatches(in: source)
        let baseLab = Self.labComponents(of: base)
        let accentSwatch = perceptualSwatches.first {
            Self.colorDistance($0.lab, baseLab) >= 0.045
        } ?? perceptualSwatches.first
        let secondarySwatch = perceptualSwatches.first { candidate in
            guard let accentSwatch else { return true }
            return Self.colorDistance(candidate.lab, accentSwatch.lab) >= 0.065
                && Self.colorDistance(candidate.lab, baseLab) >= 0.032
        } ?? perceptualSwatches.dropFirst().first

        let accent = Self.gradientColor(
            from: accentSwatch?.color ?? prominentColors.dropFirst().first ?? base,
            fallbackHueOffset: 0.08,
            saturationRange: 0.28...0.86,
            brightnessRange: 0.46...0.80
        )
        let secondary = Self.gradientColor(
            from: secondarySwatch?.color
                ?? prominentColors.dropFirst(2).first
                ?? prominentColors.dropFirst().first
                ?? base,
            fallbackHueOffset: -0.10,
            saturationRange: 0.24...0.78,
            brightnessRange: 0.38...0.72
        )

        let value = ArtworkPalette(
            top: Self.components(top),
            bottom: Self.components(bottom),
            accent: Self.components(accent),
            secondary: Self.components(secondary),
            accentPosition: accentSwatch?.position ?? .bottomLeading,
            secondaryPosition: secondarySwatch?.position ?? .topTrailing
        )
        guard activeScope == scope, !Task.isCancelled else { return .fallback }
        paletteMemory.setObject(PaletteBox(value), forKey: key)
        return value
    }

    func clearMemory() async {
        pipeline.cache.removeAll(caches: [.memory])
        paletteMemory.removeAllObjects()
    }

    func clearAll() async {
        pipeline.cache.removeAll(caches: [.all])
        paletteMemory.removeAllObjects()
    }


    private static func makePipeline(name: String) -> ImagePipeline {
        var configuration = ImagePipeline.Configuration.withDataCache(
            name: name,
            sizeLimit: 256 * 1_024 * 1_024
        )
        configuration.dataLoader = DataLoader(
            configuration: ModernNetworkPolicy.makeEphemeralConfiguration(
                requestTimeout: 20,
                resourceTimeout: 120,
                maximumConnectionsPerHost: 6,
                allowsExpensiveNetworkAccess: true,
                allowsConstrainedNetworkAccess: true
            )
        )
        configuration.maximumResponseDataSize = 32 * 1_024 * 1_024
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

    private static func gradientColor(
        from color: UIColor,
        fallbackHueOffset: CGFloat,
        saturationRange: ClosedRange<CGFloat>,
        brightnessRange: ClosedRange<CGFloat>
    ) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if saturation < 0.14 {
            hue = (hue + fallbackHueOffset + 1).truncatingRemainder(dividingBy: 1)
        }
        return UIColor(
            hue: hue,
            saturation: min(max(saturation * 1.16, saturationRange.lowerBound), saturationRange.upperBound),
            brightness: min(max(brightness * 0.96, brightnessRange.lowerBound), brightnessRange.upperBound),
            alpha: 1
        )
    }

    private struct LabColor {
        let lightness: Double
        let a: Double
        let b: Double
    }

    private struct PaletteSample {
        let red: Double
        let green: Double
        let blue: Double
        let lab: LabColor
        let x: Double
        let y: Double
        let weight: Double
    }

    private struct PerceptualSwatch {
        let color: UIColor
        let lab: LabColor
        let position: PalettePosition
        let score: Double
    }

    private struct ClusterAccumulator {
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var lightness = 0.0
        var a = 0.0
        var b = 0.0
        var x = 0.0
        var y = 0.0
        var weight = 0.0
        var samples = 0
    }

    private static func perceptualSwatches(in image: UIImage) -> [PerceptualSwatch] {
        let width = 32
        let height = 32
        guard let bytes = pixelBytes(in: image, width: width, height: height) else { return [] }
        var samples: [PaletteSample] = []
        samples.reserveCapacity(width * height)

        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[offset + 3]) / 255
            guard alpha > 0.55 else { continue }
            let red = Double(bytes[offset]) / 255
            let green = Double(bytes[offset + 1]) / 255
            let blue = Double(bytes[offset + 2]) / 255
            let lab = labComponents(red: red, green: green, blue: blue)
            let chroma = hypot(lab.a, lab.b)
            guard lab.lightness > 0.035, lab.lightness < 0.985 else { continue }

            let pixel = offset / 4
            let x = Double(pixel % width) / Double(width - 1)
            let y = Double(pixel / width) / Double(height - 1)
            let midtonePreference = 0.72 + max(0, 1 - abs(lab.lightness - 0.58) * 1.7) * 0.28
            let colorWeight = 0.52 + min(chroma * 4.2, 1.10)
            let pastelBonus = lab.lightness > 0.68 && chroma > 0.025 ? 1.12 : 1
            samples.append(PaletteSample(
                red: red,
                green: green,
                blue: blue,
                lab: lab,
                x: x,
                y: y,
                weight: alpha * midtonePreference * colorWeight * pastelBonus
            ))
        }
        guard !samples.isEmpty else { return [] }

        let clusterCount = min(6, samples.count)
        var centers: [LabColor] = []
        if let first = samples.max(by: { $0.weight < $1.weight }) {
            centers.append(first.lab)
        }
        while centers.count < clusterCount {
            guard let next = samples.max(by: { lhs, rhs in
                weightedDistance(lhs, centers: centers) < weightedDistance(rhs, centers: centers)
            }) else {
                break
            }
            centers.append(next.lab)
        }

        var assignments = [Int](repeating: 0, count: samples.count)
        for _ in 0..<7 {
            var accumulators = [ClusterAccumulator](repeating: ClusterAccumulator(), count: centers.count)
            for index in samples.indices {
                let sample = samples[index]
                let cluster = centers.indices.min {
                    colorDistance(sample.lab, centers[$0]) < colorDistance(sample.lab, centers[$1])
                } ?? 0
                assignments[index] = cluster
                let weight = sample.weight
                accumulators[cluster].lightness += sample.lab.lightness * weight
                accumulators[cluster].a += sample.lab.a * weight
                accumulators[cluster].b += sample.lab.b * weight
                accumulators[cluster].weight += weight
            }
            for index in centers.indices where accumulators[index].weight > 0 {
                let accumulator = accumulators[index]
                centers[index] = LabColor(
                    lightness: accumulator.lightness / accumulator.weight,
                    a: accumulator.a / accumulator.weight,
                    b: accumulator.b / accumulator.weight
                )
            }
        }

        var accumulators = [ClusterAccumulator](repeating: ClusterAccumulator(), count: centers.count)
        for index in samples.indices {
            let sample = samples[index]
            let cluster = assignments[index]
            let weight = sample.weight
            accumulators[cluster].red += sample.red * weight
            accumulators[cluster].green += sample.green * weight
            accumulators[cluster].blue += sample.blue * weight
            accumulators[cluster].lightness += sample.lab.lightness * weight
            accumulators[cluster].a += sample.lab.a * weight
            accumulators[cluster].b += sample.lab.b * weight
            accumulators[cluster].x += sample.x * weight
            accumulators[cluster].y += sample.y * weight
            accumulators[cluster].weight += weight
            accumulators[cluster].samples += 1
        }

        let minimumPopulation = max(4, samples.count / 160)
        let candidates = accumulators.compactMap { accumulator -> PerceptualSwatch? in
            guard accumulator.samples >= minimumPopulation, accumulator.weight > 0 else { return nil }
            let inverseWeight = 1 / accumulator.weight
            let lab = LabColor(
                lightness: accumulator.lightness * inverseWeight,
                a: accumulator.a * inverseWeight,
                b: accumulator.b * inverseWeight
            )
            let chroma = hypot(lab.a, lab.b)
            let population = Double(accumulator.samples) / Double(samples.count)
            let score = accumulator.weight
                * (0.82 + min(chroma * 3.6, 0.90))
                * (0.84 + min(population * 2.5, 0.36))
            return PerceptualSwatch(
                color: UIColor(
                    red: accumulator.red * inverseWeight,
                    green: accumulator.green * inverseWeight,
                    blue: accumulator.blue * inverseWeight,
                    alpha: 1
                ),
                lab: lab,
                position: aestheticPosition(
                    x: accumulator.x * inverseWeight,
                    y: accumulator.y * inverseWeight
                ),
                score: score
            )
        }
        .sorted { $0.score > $1.score }

        var selected: [PerceptualSwatch] = []
        for candidate in candidates {
            guard selected.allSatisfy({
                colorDistance(candidate.lab, $0.lab) >= 0.052
            }) else {
                continue
            }
            selected.append(candidate)
            if selected.count == 4 { break }
        }
        return selected
    }

    private static func pixelBytes(in image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let source = image.cgImage else { return nil }
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
        return didDraw ? bytes : nil
    }

    private static func labComponents(of color: UIColor) -> LabColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return labComponents(red: Double(red), green: Double(green), blue: Double(blue))
    }

    private static func labComponents(red: Double, green: Double, blue: Double) -> LabColor {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let red = linear(red)
        let green = linear(green)
        let blue = linear(blue)
        let l = 0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue
        let m = 0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue
        let s = 0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue
        let lRoot = cbrt(l)
        let mRoot = cbrt(m)
        let sRoot = cbrt(s)
        return LabColor(
            lightness: 0.2104542553 * lRoot + 0.7936177850 * mRoot - 0.0040720468 * sRoot,
            a: 1.9779984951 * lRoot - 2.4285922050 * mRoot + 0.4505937099 * sRoot,
            b: 0.0259040371 * lRoot + 0.7827717662 * mRoot - 0.8086757660 * sRoot
        )
    }

    private static func colorDistance(_ lhs: LabColor, _ rhs: LabColor) -> Double {
        let lightness = lhs.lightness - rhs.lightness
        let a = lhs.a - rhs.a
        let b = lhs.b - rhs.b
        return sqrt(lightness * lightness + a * a + b * b)
    }

    private static func weightedDistance(_ sample: PaletteSample, centers: [LabColor]) -> Double {
        let distance = centers.map { colorDistance(sample.lab, $0) }.min() ?? 0
        return distance * distance * sample.weight
    }

    private static func aestheticPosition(x: Double, y: Double) -> PalettePosition {
        func spread(_ value: Double) -> Double {
            let shifted = 0.5 + (value - 0.5) * 1.28
            return min(max(shifted, 0.10), 0.90)
        }
        return PalettePosition(x: spread(x), y: spread(y))
    }

    private static func prominentColors(in image: UIImage) -> [UIColor] {
        guard let source = image.cgImage else { return [] }
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
        guard didDraw else { return [] }

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
        let rankedIndices = buckets.indices.sorted {
            clusterScore($0) > clusterScore($1)
        }
        let bestScore = rankedIndices.first.map(clusterScore) ?? 0
        var selectedColors: [UIColor] = []
        var selectedHues: [Double] = []

        func mergedColor(at selectedIndex: Int) -> UIColor? {
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
            guard selected.weight > 0 else { return nil }
            return UIColor(
                red: selected.red / selected.weight,
                green: selected.green / selected.weight,
                blue: selected.blue / selected.weight,
                alpha: 1
            )
        }

        // Preserve the exact primary-color choice used by the original
        // two-color player background.
        if let dominantIndex = rankedIndices.first,
           clusterScore(dominantIndex) > max(0.9, neutral.weight * 0.18),
           let dominantColor = mergedColor(at: dominantIndex) {
            selectedColors.append(dominantColor)
            selectedHues.append((Double(dominantIndex) + 0.5) / Double(buckets.count))
        } else if neutral.weight > 0 {
            selectedColors.append(UIColor(
                red: neutral.red / neutral.weight,
                green: neutral.green / neutral.weight,
                blue: neutral.blue / neutral.weight,
                alpha: 1
            ))
        }

        for selectedIndex in rankedIndices {
            guard selectedColors.count < 3 else { break }
            let score = clusterScore(selectedIndex)
            guard score > max(0.62, max(bestScore * 0.14, neutral.weight * 0.08)) else { continue }
            let selectedHue = (Double(selectedIndex) + 0.5) / Double(buckets.count)
            let isDistinct = selectedHues.allSatisfy { existingHue in
                let distance = abs(selectedHue - existingHue)
                return min(distance, 1 - distance) >= 0.075
            }
            guard isDistinct else { continue }
            guard let color = mergedColor(at: selectedIndex) else { continue }
            selectedColors.append(color)
            selectedHues.append(selectedHue)
        }
        return selectedColors
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
