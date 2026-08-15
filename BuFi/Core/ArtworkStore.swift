import Foundation
import Nuke
import UIKit

enum ArtworkRequestSizing {
    private static let pixelBuckets = [
        128, 192, 256, 384, 512, 768, 1_024, 1_200, 1_536
    ]

    static func pixelSize(pointSize: CGFloat, displayScale: CGFloat) -> CGFloat {
        let requested = max(96, Int(ceil(pointSize * max(displayScale, 1))))
        return CGFloat(pixelBuckets.first(where: { $0 >= requested }) ?? 1_536)
    }
}

struct RGBAColor: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    static let fallbackTop = RGBAColor(red: 0.26, green: 0.34, blue: 0.30, alpha: 1)
    static let fallbackBottom = RGBAColor(red: 0.08, green: 0.09, blue: 0.09, alpha: 1)
}

struct PalettePosition: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    static let topTrailing = PalettePosition(x: 0.78, y: 0.18)
    static let bottomLeading = PalettePosition(x: 0.22, y: 0.82)
}

struct ArtworkPalette: Codable, Equatable, Sendable {
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

/// Immutable Core Graphics pixels can safely cross executors. Each consumer
/// constructs its own UIImage wrapper locally, so UIKit references never leave
/// the executor that created them.
struct ArtworkImage: Sendable {
    let cgImage: CGImage
    let scale: CGFloat
    let orientationRawValue: Int
    let size: CGSize
    fileprivate let cacheKey: String

    init?(_ value: UIImage, cacheKey: String) {
        guard let cgImage = value.cgImage else { return nil }
        self.cgImage = cgImage
        scale = value.scale
        orientationRawValue = value.imageOrientation.rawValue
        size = value.size
        self.cacheKey = cacheKey
    }

    var value: UIImage {
        UIImage(
            cgImage: cgImage,
            scale: scale,
            orientation: UIImage.Orientation(rawValue: orientationRawValue) ?? .up
        )
    }
}

actor ArtworkStore {
    static let shared = ArtworkStore()

    private static let legacyCacheName = "cloud.tae00217.BuFi.Artwork"
    private static let cacheSchemaRevision = "media-v2"
    private static let artworkFreshnessInterval: TimeInterval = 12 * 60 * 60
    private static let paletteEngineVersion = 5
    private static let sampleSide = 48
    private static let neutralChromaLimit = 0.035
    private static let darkLightnessLimit = 0.12
    private static let darkCanvasLimit = 0.55
    private static let meaningfulColorLimit = 0.06

    private var pipeline: ImagePipeline
    private var pipelineScope: String?
    private var activeScope: String?
    private var scopeGeneration: UInt64 = 0
    private var didDiscardLegacyCache = false
    private let paletteMemory = NSCache<NSString, PaletteBox>()
    private let database: AppDatabase
    private var inFlightPalettes: [ArtworkPaletteRequestKey: InFlightPalette] = [:]
    private var paletteGeneration: UInt64 = 0
    private var clearRequestID: UUID?

    init(database: AppDatabase = .shared) {
        pipeline = Self.makePipeline(name: Self.legacyCacheName)
        self.database = database
        paletteMemory.countLimit = 160
    }

    /// URL fragments are never transmitted in HTTP requests, but Nuke keeps
    /// them in its cache identity. This gives an updated metadata snapshot a
    /// fresh decoded image, data-cache entry, and palette without adding an
    /// unsupported query parameter to an OpenSubsonic server.
    nonisolated static func cacheURL(
        for url: URL,
        revision: String?,
        date: Date = Date()
    ) -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return url
        }
        // OpenSubsonic does not standardize an artwork validator. Keep the
        // twelve-hour freshness bound, but deterministically stagger each URL's
        // epoch. A wall-clock boundary can no longer expire every visible cover
        // at once and trigger a burst of radio, decode, and palette work.
        let freshnessEpoch = artworkFreshnessEpoch(for: url, at: date)
        let boundedRevision = "\(revision ?? "unversioned")-\(freshnessEpoch)"
        components.fragment = [cacheSchemaRevision, boundedRevision]
            .joined(separator: "-")
        return components.url ?? url
    }

    nonisolated static func artworkFreshnessEpoch(
        for url: URL,
        at date: Date
    ) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let interval = artworkFreshnessInterval
        let offset = Double(hash % UInt64(Int(interval)))
        return Int(floor((date.timeIntervalSince1970 + offset) / interval))
    }

    func activate(accountScope: String) async -> AccountSessionToken {
        scopeGeneration &+= 1

        // A clear from the previous account may still be draining cancelled
        // work. Its captured pipeline remains safe to clear, but it must not
        // suppress palette work for this newly activated account.
        clearRequestID = nil
        invalidateInFlightPalettes()
        if !didDiscardLegacyCache {
            pipeline.cache.removeAll(caches: [.all])
            didDiscardLegacyCache = true
        } else {
            pipeline.cache.removeAll(caches: [.memory])
        }

        if pipelineScope != accountScope {
            pipeline = Self.makePipeline(name: Self.legacyCacheName + "." + accountScope)
            pipelineScope = accountScope
        }
        activeScope = accountScope
        paletteMemory.removeAllObjects()
        return AccountSessionToken(
            accountScope: accountScope,
            generation: scopeGeneration
        )
    }

    @discardableResult
    func deactivate(session: AccountSessionToken) -> Bool {
        guard session.matches(
            accountScope: activeScope,
            generation: scopeGeneration
        ) else { return false }
        scopeGeneration &+= 1
        invalidateInFlightPalettes()
        pipeline.cache.removeAll(caches: [.memory])
        paletteMemory.removeAllObjects()
        activeScope = nil
        return true
    }

    func image(for url: URL, pixelSize: CGFloat) async throws -> ArtworkImage {
        guard let scope = activeScope else {
            throw URLError(.userAuthenticationRequired)
        }
        let session = AccountSessionToken(
            accountScope: scope,
            generation: scopeGeneration
        )
        let requestedPixelSize = min(max(pixelSize, 64), 1_536)
        var urlRequest = URLRequest(url: url)
        ModernNetworkPolicy.prepareImageRequest(&urlRequest)
        let request = ImageRequest(
            urlRequest: urlRequest,
            processors: [.resize(width: requestedPixelSize)]
        )
        let scopedPipeline = pipeline
        let image: UIImage
        do {
            image = try await scopedPipeline.image(for: request)
        } catch {
            guard CoreRequestClassifier.shouldRetryImageFetch(error) else {
                throw error
            }
            try await Task.sleep(for: .milliseconds(280))
            try Task.checkCancellation()
            guard session.matches(
                accountScope: activeScope,
                generation: scopeGeneration
            ), pipeline === scopedPipeline else {
                throw CancellationError()
            }
            image = try await scopedPipeline.image(for: request)
        }
        try Task.checkCancellation()
        guard session.matches(
            accountScope: activeScope,
            generation: scopeGeneration
        ), pipeline === scopedPipeline else {
            throw CancellationError()
        }
        guard let result = ArtworkImage(
            image,
            cacheKey: ArtworkPipelineDelegate.normalizedCacheKey(for: url)
        ) else {
            throw URLError(.cannotDecodeContentData)
        }
        return result
    }

    func prefetch(urls: [URL], pixelSize: CGFloat) async {
        guard activeScope != nil else { return }
        var seen = Set<URL>()
        for url in urls.prefix(2) where seen.insert(url).inserted {
            guard !Task.isCancelled else { return }
            _ = try? await image(for: url, pixelSize: pixelSize)
            await Task.yield()
        }
    }

    func palette(for url: URL, image: ArtworkImage? = nil) async -> ArtworkPalette {
        guard let scope = activeScope,
              clearRequestID == nil,
              !Task.isCancelled else {
            return .fallback
        }
        let generation = paletteGeneration
        let cacheKey = ArtworkPipelineDelegate.normalizedCacheKey(for: url)
        let validatedImage = image?.cacheKey == cacheKey ? image : nil
        let memoryKey = cacheKey as NSString
        if let cached = paletteMemory.object(forKey: memoryKey) { return cached.value }

        let value = await coalescedPalette(
            for: url,
            providedImage: validatedImage,
            scope: scope,
            cacheKey: cacheKey,
            generation: generation
        )

        guard activeScope == scope,
              paletteGeneration == generation,
              clearRequestID == nil,
              !Task.isCancelled else {
            return .fallback
        }
        if value != .fallback {
            paletteMemory.setObject(PaletteBox(value), forKey: memoryKey)
        }
        return value
    }

    func clearMemory() async {
        invalidateInFlightPalettes()
        pipeline.cache.removeAll(caches: [.memory])
        paletteMemory.removeAllObjects()
    }

    func clearAll(session expectedSession: AccountSessionToken? = nil) async {
        guard clearRequestID == nil else { return }
        let session = activeScope.map {
            AccountSessionToken(
                accountScope: $0,
                generation: scopeGeneration
            )
        }
        if let expectedSession, session != expectedSession { return }
        let requestID = UUID()
        clearRequestID = requestID
        let scope = activeScope
        let scopedPipeline = pipeline
        let staleTasks = invalidateInFlightPalettes()
        let generation = paletteGeneration
        for task in staleTasks {
            _ = await task.value
        }
        guard session?.matches(
            accountScope: activeScope,
            generation: scopeGeneration
        ) ?? (activeScope == nil) else {
            if clearRequestID == requestID {
                clearRequestID = nil
            }
            return
        }
        // Clear only the pipeline captured for this request. `activate` may
        // install another account's pipeline while the cancelled palette work
        // is draining at the suspension point above.
        scopedPipeline.cache.removeAll(caches: [.all])
        if activeScope == scope,
           pipeline === scopedPipeline,
           paletteGeneration == generation {
            paletteMemory.removeAllObjects()
        }
        if let scope,
           session?.matches(
               accountScope: activeScope,
               generation: scopeGeneration
           ) == true {
            await database.clearArtworkPalettes(scope: scope)
        }
        if clearRequestID == requestID {
            clearRequestID = nil
        }
    }

    /// Synchronous testable entry point. Production calls execute this on the
    /// store actor's executor, never on a UI `MainActor` caller.
    static func extractPalette(from image: UIImage) -> ArtworkPalette {
        guard let bytes = sampleBytes(from: image) else { return .fallback }
        return analyzedPalette(from: bytes) ?? .fallback
    }

    private func resolvePalette(
        for url: URL,
        providedImage: ArtworkImage?,
        scope: String,
        cacheKey: String,
        generation: UInt64
    ) async -> ArtworkPalette {
        if let cached = await database.loadArtworkPalette(
            scope: scope,
            artworkKey: cacheKey,
            engineVersion: Self.paletteEngineVersion
        ) {
            guard activeScope == scope,
                  paletteGeneration == generation,
                  !Task.isCancelled else {
                return .fallback
            }
            return cached
        }
        guard activeScope == scope,
              paletteGeneration == generation,
              !Task.isCancelled else {
            return .fallback
        }

        let source: ArtworkImage
        if let providedImage {
            source = providedImage
        } else {
            guard let loaded = try? await image(for: url, pixelSize: 96) else {
                return .fallback
            }
            source = loaded
        }
        guard activeScope == scope,
              paletteGeneration == generation,
              !Task.isCancelled else { return .fallback }

        // UIKit objects do not cross into the detached clustering task. Create
        // a fixed-size value buffer on the store actor, then transfer only the
        // immutable bytes into the independent executor.
        guard let sampleBytes = Self.sampleBytes(from: source.value) else {
            return .fallback
        }

        // Palette clustering is CPU-heavy. `@concurrent` keeps the work off
        // the store actor while preserving structured cancellation ownership.
        let value = await Self.analyzedPaletteConcurrently(from: sampleBytes)
        guard activeScope == scope,
              paletteGeneration == generation,
              !Task.isCancelled,
              let value else { return .fallback }

        guard paletteGeneration == generation else { return .fallback }
        _ = await database.saveArtworkPalette(
            value,
            scope: scope,
            artworkKey: cacheKey,
            engineVersion: Self.paletteEngineVersion
        )
        guard activeScope == scope,
              paletteGeneration == generation,
              !Task.isCancelled else {
            return .fallback
        }
        return value
    }

    private func coalescedPalette(
        for url: URL,
        providedImage: ArtworkImage?,
        scope: String,
        cacheKey: String,
        generation: UInt64
    ) async -> ArtworkPalette {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerPaletteWaiter(
                    continuation,
                    waiterID: waiterID,
                    url: url,
                    providedImage: providedImage,
                    scope: scope,
                    cacheKey: cacheKey,
                    generation: generation
                )
            }
        } onCancel: {
            Task {
                await self.cancelPaletteWaiter(
                    scope: scope,
                    cacheKey: cacheKey,
                    generation: generation,
                    waiterID: waiterID
                )
            }
        }
    }

    private func registerPaletteWaiter(
        _ continuation: CheckedContinuation<ArtworkPalette, Never>,
        waiterID: UUID,
        url: URL,
        providedImage: ArtworkImage?,
        scope: String,
        cacheKey: String,
        generation: UInt64
    ) {
        guard activeScope == scope,
              paletteGeneration == generation,
              clearRequestID == nil,
              !Task.isCancelled else {
            continuation.resume(returning: .fallback)
            return
        }

        let requestKey = ArtworkPaletteRequestKey(
            accountScope: scope,
            cacheKey: cacheKey,
            generation: generation
        )
        if var pending = inFlightPalettes[requestKey],
           pending.generation == generation {
            pending.waiters[waiterID] = continuation
            inFlightPalettes[requestKey] = pending
            return
        }

        let requestID = UUID()
        let task = Task { [self] in
            let value = await resolvePalette(
                for: url,
                providedImage: providedImage,
                scope: scope,
                cacheKey: cacheKey,
                generation: generation
            )
            finishPaletteRequest(
                scope: scope,
                cacheKey: cacheKey,
                generation: generation,
                requestID: requestID,
                value: value
            )
        }
        inFlightPalettes[requestKey] = InFlightPalette(
            id: requestID,
            generation: generation,
            task: task,
            waiters: [waiterID: continuation]
        )
    }

    @discardableResult
    private func invalidateInFlightPalettes() -> [Task<Void, Never>] {
        paletteGeneration &+= 1
        let tasks = inFlightPalettes.values.map(\.task)
        for pending in inFlightPalettes.values {
            pending.task.cancel()
            pending.waiters.values.forEach {
                $0.resume(returning: .fallback)
            }
        }
        inFlightPalettes.removeAll(keepingCapacity: true)
        return tasks
    }

    private func cancelPaletteWaiter(
        scope: String,
        cacheKey: String,
        generation: UInt64,
        waiterID: UUID
    ) {
        let requestKey = ArtworkPaletteRequestKey(
            accountScope: scope,
            cacheKey: cacheKey,
            generation: generation
        )
        guard var request = inFlightPalettes[requestKey],
              request.generation == generation,
              let continuation = request.waiters.removeValue(
                forKey: waiterID
              ) else {
            return
        }
        continuation.resume(returning: .fallback)
        if request.waiters.isEmpty {
            request.task.cancel()
            inFlightPalettes[requestKey] = nil
        } else {
            inFlightPalettes[requestKey] = request
        }
    }

    private func finishPaletteRequest(
        scope: String,
        cacheKey: String,
        generation: UInt64,
        requestID: UUID,
        value: ArtworkPalette
    ) {
        let requestKey = ArtworkPaletteRequestKey(
            accountScope: scope,
            cacheKey: cacheKey,
            generation: generation
        )
        guard let request = inFlightPalettes[requestKey],
              request.id == requestID else {
            return
        }
        inFlightPalettes[requestKey] = nil
        request.waiters.values.forEach { $0.resume(returning: value) }
    }

    private static func makePipeline(name: String) -> ImagePipeline {
        var configuration = ImagePipeline.Configuration.withDataCache(
            name: name,
            sizeLimit: 256 * 1_024 * 1_024
        )
        let dataLoader = DataLoader(
            configuration: ModernNetworkPolicy.makeEphemeralConfiguration(
                requestTimeout: 20,
                resourceTimeout: 120,
                maximumConnectionsPerHost: 6,
                allowsExpensiveNetworkAccess: true,
                allowsConstrainedNetworkAccess: true
            )
        )
        // Nuke forwards URLSession delegate callbacks to this proxy. Keeping
        // BuFi's delegate attached ensures HTTPS-only redirects, HTTP/3 request
        // policy reapplication, and transport metrics also cover artwork CDNs.
        dataLoader.delegate = HTTPSOnlyURLSessionDelegate()
        configuration.dataLoader = dataLoader
        // Nuke defaults to ImageCache.shared. A pipeline can outlive an account
        // switch while finishing a request, so each account-scoped pipeline
        // must own its decoded-memory cache just as it owns its disk cache.
        configuration.imageCache = ImageCache()
        configuration.maximumResponseDataSize = 32 * 1_024 * 1_024
        configuration.isTaskCoalescingEnabled = true
        configuration.isProgressiveDecodingEnabled = false
        configuration.dataCachePolicy = .automatic
        return ImagePipeline(
            configuration: configuration,
            delegate: ArtworkPipelineDelegate()
        )
    }

    // MARK: - Palette Engine V3

    private struct OKLab {
        var lightness: Double
        var a: Double
        var b: Double

        var chroma: Double { hypot(a, b) }
    }

    private struct Sample {
        let lab: OKLab
        let x: Double
        let y: Double
        let alpha: Double
        let visibility: Double
    }

    private struct ClusterAccumulator {
        var lightness = 0.0
        var a = 0.0
        var b = 0.0
        var x = 0.0
        var y = 0.0
        var alpha = 0.0
        var weight = 0.0
        var sampleCount = 0
    }

    private struct Swatch {
        let lab: OKLab
        let position: PalettePosition
        let population: Double
        let averageAlpha: Double
        let score: Double
    }

    @concurrent
    private static func analyzedPaletteConcurrently(
        from bytes: [UInt8]
    ) async -> ArtworkPalette? {
        guard !Task.isCancelled else { return nil }
        return analyzedPalette(from: bytes)
    }

    private static func analyzedPalette(from bytes: [UInt8]) -> ArtworkPalette? {
        guard !bytes.isEmpty else { return nil }
        let samples = makeSamples(from: bytes)
        guard !samples.isEmpty else { return nil }

        let visibleWeight = samples.reduce(0) { $0 + $1.visibility }
        guard visibleWeight > 0 else { return nil }
        let neutralWeight = samples.reduce(0) { partial, sample in
            partial + (sample.lab.chroma <= neutralChromaLimit ? sample.visibility : 0)
        }
        let darkWeight = samples.reduce(0) { partial, sample in
            partial + (sample.lab.lightness <= darkLightnessLimit ? sample.visibility : 0)
        }
        let colorfulWeight = samples.reduce(0) { partial, sample in
            partial + (sample.lab.chroma > neutralChromaLimit ? sample.visibility : 0)
        }
        // A dark canvas should not swallow a real colored subject. Six percent
        // survives small logos and edge accents while rejecting compression
        // speckles and isolated colored noise.
        let prefersColorOnDarkCanvas = darkWeight / visibleWeight >= darkCanvasLimit
            && colorfulWeight / visibleWeight >= meaningfulColorLimit
        // Inclusive by design: exactly 85% belongs to the neutral family.
        let isNeutralFamily = !prefersColorOnDarkCanvas
            && qualifiesAsNeutralFamily(
                neutralWeight: neutralWeight,
                visibleWeight: visibleWeight
            )
        let clusteringSamples: [Sample]
        if isNeutralFamily {
            clusteringSamples = samples.filter { $0.lab.chroma <= neutralChromaLimit }
        } else if prefersColorOnDarkCanvas {
            clusteringSamples = samples.filter { $0.lab.chroma > neutralChromaLimit }
        } else {
            clusteringSamples = samples
        }
        guard !clusteringSamples.isEmpty else { return nil }

        var swatches = cluster(clusteringSamples, neutralFamily: isNeutralFamily)
        if !isNeutralFamily {
            // Below the boundary, black/white/gray may describe the canvas but
            // must not displace the actual artwork colors.
            let colorful = swatches.filter { $0.lab.chroma > neutralChromaLimit }
            if !colorful.isEmpty {
                swatches = colorful
            }
        }
        // The primary palette color represents the largest valid area of the
        // cover. Score still breaks population ties, but a small vivid detail
        // can no longer replace the color that visually fills most of the art.
        let populationOrdered = swatches.sorted { lhs, rhs in
            if lhs.population != rhs.population {
                return lhs.population > rhs.population
            }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.lab.chroma != rhs.lab.chroma {
                return lhs.lab.chroma > rhs.lab.chroma
            }
            if lhs.lab.lightness != rhs.lab.lightness {
                return lhs.lab.lightness > rhs.lab.lightness
            }
            if lhs.position.y != rhs.position.y {
                return lhs.position.y < rhs.position.y
            }
            return lhs.position.x < rhs.position.x
        }
        guard let primary = populationOrdered.first else { return nil }
        let distinctDistance = isNeutralFamily ? 0.075 : 0.055
        let secondary = swatches.first {
            colorDistance($0.lab, primary.lab) >= distinctDistance
        } ?? swatches.first {
            colorDistance($0.lab, primary.lab) > 0.000_001
        }

        return isNeutralFamily
            ? neutralPalette(primary: primary, secondary: secondary)
            : colorfulPalette(primary: primary, secondary: secondary)
    }

    private static func sampleBytes(from image: UIImage) -> [UInt8]? {
        guard let source = image.cgImage else { return nil }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let side = sampleSide
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.setBlendMode(.copy)
            // UIKit's visual coordinate space has its origin at the top left.
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return rendered ? bytes : nil
    }

    private static func makeSamples(from bytes: [UInt8]) -> [Sample] {
        let side = sampleSide
        var samples: [Sample] = []
        samples.reserveCapacity(side * side)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[offset + 3]) / 255
            guard alpha >= 0.01 else { continue }

            // The bitmap is premultiplied. Recover the source color before the
            // perceptual conversion and use alpha only as visibility evidence.
            let inverseAlpha = 1 / alpha
            let red = clamp(Double(bytes[offset]) / 255 * inverseAlpha, 0, 1)
            let green = clamp(Double(bytes[offset + 1]) / 255 * inverseAlpha, 0, 1)
            let blue = clamp(Double(bytes[offset + 2]) / 255 * inverseAlpha, 0, 1)
            let pixel = offset / 4
            samples.append(Sample(
                lab: oklab(red: red, green: green, blue: blue),
                x: Double(pixel % side) / Double(side - 1),
                y: Double(pixel / side) / Double(side - 1),
                alpha: alpha,
                visibility: pow(alpha, 1.5)
            ))
        }
        return samples
    }

    private static func cluster(
        _ samples: [Sample],
        neutralFamily: Bool
    ) -> [Swatch] {
        let clusterLimit = min(8, samples.count)
        let totalWeight = samples.reduce(0) { $0 + $1.visibility }
        guard clusterLimit > 0, totalWeight > 0 else { return [] }

        var centers = [weightedMean(of: samples)]
        while centers.count < clusterLimit {
            var bestIndex: Int?
            var bestMerit = -Double.infinity
            for index in samples.indices {
                let sample = samples[index]
                let nearest = centers.reduce(Double.infinity) {
                    min($0, squaredDistance(sample.lab, $1))
                }
                let colorPriority: Double
                if neutralFamily {
                    colorPriority = 1
                } else if sample.lab.chroma > neutralChromaLimit {
                    colorPriority = 0.55 + min(sample.lab.chroma / 0.16, 1.25)
                } else if sample.lab.lightness < 0.10 || sample.lab.lightness > 0.93 {
                    colorPriority = 0.025
                } else {
                    colorPriority = 0.16
                }
                let merit = nearest * sample.visibility * colorPriority
                if merit > bestMerit + 1e-15 {
                    bestMerit = merit
                    bestIndex = index
                }
            }
            guard let bestIndex, bestMerit > 1e-12 else { break }
            centers.append(samples[bestIndex].lab)
        }

        for _ in 0..<9 {
            var accumulators = [ClusterAccumulator](
                repeating: ClusterAccumulator(),
                count: centers.count
            )
            for sample in samples {
                let index = nearestCenter(to: sample.lab, centers: centers)
                let weight = sample.visibility
                accumulators[index].lightness += sample.lab.lightness * weight
                accumulators[index].a += sample.lab.a * weight
                accumulators[index].b += sample.lab.b * weight
                accumulators[index].weight += weight
            }
            var didMove = false
            for index in centers.indices where accumulators[index].weight > 0 {
                let accumulator = accumulators[index]
                let inverseWeight = 1 / accumulator.weight
                let next = OKLab(
                    lightness: accumulator.lightness * inverseWeight,
                    a: accumulator.a * inverseWeight,
                    b: accumulator.b * inverseWeight
                )
                didMove = didMove || squaredDistance(next, centers[index]) > 1e-12
                centers[index] = next
            }
            if !didMove { break }
        }

        // Reassign once after the final center update so population and spatial
        // centroids describe the final clusters, not the preceding iteration.
        var accumulators = [ClusterAccumulator](
            repeating: ClusterAccumulator(),
            count: centers.count
        )
        for sample in samples {
            let index = nearestCenter(to: sample.lab, centers: centers)
            let weight = sample.visibility
            accumulators[index].lightness += sample.lab.lightness * weight
            accumulators[index].a += sample.lab.a * weight
            accumulators[index].b += sample.lab.b * weight
            accumulators[index].x += sample.x * weight
            accumulators[index].y += sample.y * weight
            accumulators[index].alpha += sample.alpha * weight
            accumulators[index].weight += weight
            accumulators[index].sampleCount += 1
        }

        var swatches: [Swatch] = []
        for accumulator in accumulators {
            let population = accumulator.weight / totalWeight
            guard accumulator.sampleCount >= 2, population >= 0.004 else { continue }
            let inverseWeight = 1 / accumulator.weight
            let lab = OKLab(
                lightness: accumulator.lightness * inverseWeight,
                a: accumulator.a * inverseWeight,
                b: accumulator.b * inverseWeight
            )
            let averageAlpha = accumulator.alpha * inverseWeight
            let x = accumulator.x * inverseWeight
            let y = accumulator.y * inverseWeight
            let lightnessUtility: Double
            let chromaUtility: Double
            if neutralFamily {
                lightnessUtility = 0.82 + 0.18 * (1 - min(abs(lab.lightness - 0.5) * 2, 1))
                chromaUtility = 1
            } else {
                lightnessUtility = 0.58 + 0.42 * (
                    1 - min(abs(lab.lightness - 0.56) / 0.56, 1)
                )
                if lab.chroma > neutralChromaLimit {
                    chromaUtility = 0.72 + min(lab.chroma / 0.16, 1.20)
                } else if lab.lightness < 0.10 || lab.lightness > 0.93 {
                    chromaUtility = 0.025
                } else {
                    chromaUtility = 0.16
                }
            }
            let opacityUtility = 0.58 + 0.42 * averageAlpha
            let spatialDistance = min(hypot(x - 0.5, y - 0.5), 0.5)
            let spatialUtility = 0.95 + spatialDistance * 0.10
            let score = pow(population, 0.64)
                * chromaUtility
                * lightnessUtility
                * opacityUtility
                * spatialUtility
            swatches.append(Swatch(
                lab: lab,
                position: aestheticPosition(x: x, y: y),
                population: population,
                averageAlpha: averageAlpha,
                score: score
            ))
        }

        return swatches.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.population != rhs.population {
                return lhs.population > rhs.population
            }
            if lhs.lab.chroma != rhs.lab.chroma {
                return lhs.lab.chroma > rhs.lab.chroma
            }
            if lhs.lab.lightness != rhs.lab.lightness {
                return lhs.lab.lightness > rhs.lab.lightness
            }
            if lhs.position.y != rhs.position.y {
                return lhs.position.y < rhs.position.y
            }
            return lhs.position.x < rhs.position.x
        }
    }

    static func qualifiesAsNeutralFamily(
        neutralWeight: Double,
        visibleWeight: Double
    ) -> Bool {
        guard neutralWeight.isFinite,
              visibleWeight.isFinite,
              visibleWeight > 0 else {
            return false
        }
        return max(0, neutralWeight) / visibleWeight >= 0.85
    }

    private static func colorfulPalette(
        primary: Swatch,
        secondary: Swatch?
    ) -> ArtworkPalette {
        let secondaryLab = secondary?.lab ?? primary.lab
        let top = adjusted(
            primary.lab,
            lightness: clamp(primary.lab.lightness * 0.78, 0.28, 0.62),
            chromaScale: 0.82
        )
        let bottom = adjusted(
            primary.lab,
            lightness: clamp(primary.lab.lightness * 0.29, 0.055, 0.19),
            chromaScale: 0.42
        )
        let accent = adjusted(
            primary.lab,
            lightness: clamp(primary.lab.lightness, 0.42, 0.78),
            chromaScale: 0.98
        )
        let secondaryColor = adjusted(
            secondaryLab,
            lightness: clamp(secondaryLab.lightness, 0.38, 0.74),
            chromaScale: 0.94
        )
        return ArtworkPalette(
            top: rgba(from: top),
            bottom: rgba(from: bottom),
            accent: rgba(from: accent),
            secondary: rgba(from: secondaryColor),
            accentPosition: primary.position,
            secondaryPosition: secondary?.position ?? opposite(of: primary.position)
        )
    }

    private static func neutralPalette(
        primary: Swatch,
        secondary: Swatch?
    ) -> ArtworkPalette {
        // Near-black covers need a small neutral lift so the surrounding player
        // surface remains distinguishable from the artwork edge. Keep the lift
        // achromatic and bounded instead of manufacturing an unrelated hue.
        let isDarkNeutral = primary.lab.lightness <= darkLightnessLimit
        let top = adjusted(
            primary.lab,
            lightness: isDarkNeutral
                ? 0.24
                : 0.08 + 0.60 * primary.lab.lightness,
            chromaScale: 0.72
        )
        let bottom = adjusted(
            primary.lab,
            lightness: isDarkNeutral
                ? 0.16
                : 0.025 + 0.20 * primary.lab.lightness,
            chromaScale: 0.34
        )
        let accent = adjusted(
            primary.lab,
            lightness: isDarkNeutral
                ? 0.32
                : clamp(0.14 + 0.76 * primary.lab.lightness, 0.14, 0.90),
            chromaScale: 0.90
        )

        let secondaryLab: OKLab
        if let secondary {
            secondaryLab = adjusted(
                secondary.lab,
                lightness: clamp(
                    0.10 + 0.68 * secondary.lab.lightness,
                    isDarkNeutral ? 0.20 : 0.10,
                    0.82
                ),
                chromaScale: 0.82
            )
        } else {
            secondaryLab = adjusted(
                primary.lab,
                lightness: clamp(
                    0.05 + 0.54 * primary.lab.lightness,
                    isDarkNeutral ? 0.20 : 0.05,
                    0.68
                ),
                chromaScale: 0.62
            )
        }
        return ArtworkPalette(
            top: rgba(from: top),
            bottom: rgba(from: bottom),
            accent: rgba(from: accent),
            secondary: rgba(from: secondaryLab),
            accentPosition: primary.position,
            secondaryPosition: secondary?.position ?? opposite(of: primary.position)
        )
    }

    private static func weightedMean(of samples: [Sample]) -> OKLab {
        var lightness = 0.0
        var a = 0.0
        var b = 0.0
        var weight = 0.0
        for sample in samples {
            lightness += sample.lab.lightness * sample.visibility
            a += sample.lab.a * sample.visibility
            b += sample.lab.b * sample.visibility
            weight += sample.visibility
        }
        guard weight > 0 else { return OKLab(lightness: 0, a: 0, b: 0) }
        return OKLab(lightness: lightness / weight, a: a / weight, b: b / weight)
    }

    private static func nearestCenter(to lab: OKLab, centers: [OKLab]) -> Int {
        var bestIndex = 0
        var bestDistance = squaredDistance(lab, centers[0])
        for index in centers.indices.dropFirst() {
            let distance = squaredDistance(lab, centers[index])
            if distance < bestDistance - 1e-15 {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func squaredDistance(_ lhs: OKLab, _ rhs: OKLab) -> Double {
        let lightness = lhs.lightness - rhs.lightness
        let a = lhs.a - rhs.a
        let b = lhs.b - rhs.b
        return lightness * lightness + a * a + b * b
    }

    private static func colorDistance(_ lhs: OKLab, _ rhs: OKLab) -> Double {
        sqrt(squaredDistance(lhs, rhs))
    }

    private static func adjusted(
        _ lab: OKLab,
        lightness: Double,
        chromaScale: Double
    ) -> OKLab {
        OKLab(
            lightness: clamp(lightness, 0, 1),
            a: lab.a * min(max(chromaScale, 0), 1),
            b: lab.b * min(max(chromaScale, 0), 1)
        )
    }

    private static func aestheticPosition(x: Double, y: Double) -> PalettePosition {
        func spread(_ value: Double) -> Double {
            clamp(0.5 + (value - 0.5) * 1.34, 0.08, 0.92)
        }
        return PalettePosition(x: spread(x), y: spread(y))
    }

    private static func opposite(of position: PalettePosition) -> PalettePosition {
        let mirrored = PalettePosition(x: 1 - position.x, y: 1 - position.y)
        if hypot(mirrored.x - position.x, mirrored.y - position.y) >= 0.20 {
            return mirrored
        }
        return position.y < 0.5 ? .bottomLeading : .topTrailing
    }

    private static func oklab(red: Double, green: Double, blue: Double) -> OKLab {
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
        return OKLab(
            lightness: 0.2104542553 * lRoot + 0.7936177850 * mRoot - 0.0040720468 * sRoot,
            a: 1.9779984951 * lRoot - 2.4285922050 * mRoot + 0.4505937099 * sRoot,
            b: 0.0259040371 * lRoot + 0.7827717662 * mRoot - 0.8086757660 * sRoot
        )
    }

    private static func rgba(from requestedLab: OKLab) -> RGBAColor {
        var lab = requestedLab
        var linear = linearRGB(from: lab)
        if !isInGamut(linear) {
            var lower = 0.0
            var upper = 1.0
            for _ in 0..<18 {
                let scale = (lower + upper) / 2
                let candidate = OKLab(
                    lightness: requestedLab.lightness,
                    a: requestedLab.a * scale,
                    b: requestedLab.b * scale
                )
                if isInGamut(linearRGB(from: candidate)) {
                    lower = scale
                } else {
                    upper = scale
                }
            }
            lab.a = requestedLab.a * lower
            lab.b = requestedLab.b * lower
            linear = linearRGB(from: lab)
        }

        func gamma(_ component: Double) -> Double {
            let component = clamp(component, 0, 1)
            return component <= 0.0031308
                ? 12.92 * component
                : 1.055 * pow(component, 1 / 2.4) - 0.055
        }
        return RGBAColor(
            red: gamma(linear.red),
            green: gamma(linear.green),
            blue: gamma(linear.blue),
            alpha: 1
        )
    }

    private static func linearRGB(from lab: OKLab) -> (red: Double, green: Double, blue: Double) {
        let lRoot = lab.lightness + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let mRoot = lab.lightness - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let sRoot = lab.lightness - 0.0894841775 * lab.a - 1.2914855480 * lab.b
        let l = lRoot * lRoot * lRoot
        let m = mRoot * mRoot * mRoot
        let s = sRoot * sRoot * sRoot
        return (
            red: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            green: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            blue: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    private static func isInGamut(
        _ color: (red: Double, green: Double, blue: Double)
    ) -> Bool {
        let tolerance = 1e-9
        return color.red >= -tolerance && color.red <= 1 + tolerance
            && color.green >= -tolerance && color.green <= 1 + tolerance
            && color.blue >= -tolerance && color.blue <= 1 + tolerance
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private struct InFlightPalette {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<ArtworkPalette, Never>]
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
