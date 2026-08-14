from pathlib import Path


def replace_exact(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    if old not in text:
        raise SystemExit(f"missing expected block in {path}: {old[:120]!r}")
    text = text.replace(old, new, 1)
    file.write_text(text)


# RootView: replace Combine/GCD notification bridges with structured AsyncSequence tasks.
replace_exact(
    "BuFi/UI/RootView.swift",
    "import Combine\nimport SwiftUI\nimport UIKit\n",
    "import SwiftUI\nimport UIKit\n",
)
replace_exact(
    "BuFi/UI/RootView.swift",
    '''        .onReceive(\n            NotificationCenter.default\n                .publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)\n                .receive(on: DispatchQueue.main)\n        ) { _ in\n            let currentLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled\n            lowPowerMode = currentLowPowerMode\n            model.handleEnergyConstraints(\n                lowPowerMode: currentLowPowerMode,\n                thermalState: thermalState\n            )\n            audio.handleEnergyConstraints(\n                lowPowerMode: currentLowPowerMode,\n                thermalState: thermalState\n            )\n        }\n        .onReceive(\n            NotificationCenter.default\n                .publisher(for: ProcessInfo.thermalStateDidChangeNotification)\n                .receive(on: DispatchQueue.main)\n        ) { _ in\n            let currentThermalState = ProcessInfo.processInfo.thermalState\n            thermalState = currentThermalState\n            model.handleEnergyConstraints(\n                lowPowerMode: lowPowerMode,\n                thermalState: currentThermalState\n            )\n            audio.handleEnergyConstraints(\n                lowPowerMode: lowPowerMode,\n                thermalState: currentThermalState\n            )\n        }\n        .onReceive(\n            NotificationCenter.default\n                .publisher(for: UIApplication.didReceiveMemoryWarningNotification)\n                .receive(on: DispatchQueue.main)\n        ) { _ in\n            model.handleMemoryPressure()\n            audio.handleMemoryPressure()\n            Task(priority: .utility) {\n                await ArtworkStore.shared.clearMemory()\n            }\n        }\n''',
    '''        .task {\n            await observePowerStateChanges()\n        }\n        .task {\n            await observeThermalStateChanges()\n        }\n        .task {\n            await observeMemoryWarnings()\n        }\n''',
)
replace_exact(
    "BuFi/UI/RootView.swift",
    '''    private func runAutomaticSync() async {\n        guard session.phase == .ready,\n              scenePhase == .active,\n              !lowPowerMode,\n              !isThermallyConstrained else {\n            return\n        }\n\n        while !Task.isCancelled {\n            do {\n                try await Task.sleep(for: .seconds(baseSyncInterval))\n            } catch {\n                return\n            }\n\n            guard session.phase == .ready,\n                  scenePhase == .active,\n                  !lowPowerMode,\n                  !isThermallyConstrained else {\n                return\n            }\n            await model.refresh(silent: true)\n        }\n    }\n''',
    '''    @MainActor\n    private func observePowerStateChanges() async {\n        for await _ in NotificationCenter.default.notifications(\n            named: Notification.Name.NSProcessInfoPowerStateDidChange\n        ) {\n            guard !Task.isCancelled else { return }\n            let currentLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled\n            lowPowerMode = currentLowPowerMode\n            model.handleEnergyConstraints(\n                lowPowerMode: currentLowPowerMode,\n                thermalState: thermalState\n            )\n            audio.handleEnergyConstraints(\n                lowPowerMode: currentLowPowerMode,\n                thermalState: thermalState\n            )\n        }\n    }\n\n    @MainActor\n    private func observeThermalStateChanges() async {\n        for await _ in NotificationCenter.default.notifications(\n            named: ProcessInfo.thermalStateDidChangeNotification\n        ) {\n            guard !Task.isCancelled else { return }\n            let currentThermalState = ProcessInfo.processInfo.thermalState\n            thermalState = currentThermalState\n            model.handleEnergyConstraints(\n                lowPowerMode: lowPowerMode,\n                thermalState: currentThermalState\n            )\n            audio.handleEnergyConstraints(\n                lowPowerMode: lowPowerMode,\n                thermalState: currentThermalState\n            )\n        }\n    }\n\n    @MainActor\n    private func observeMemoryWarnings() async {\n        for await _ in NotificationCenter.default.notifications(\n            named: UIApplication.didReceiveMemoryWarningNotification\n        ) {\n            guard !Task.isCancelled else { return }\n            model.handleMemoryPressure()\n            audio.handleMemoryPressure()\n            await ArtworkStore.shared.clearMemory()\n        }\n    }\n\n    private func runAutomaticSync() async {\n        guard session.phase == .ready,\n              scenePhase == .active,\n              !lowPowerMode,\n              !isThermallyConstrained else {\n            return\n        }\n\n        while !Task.isCancelled {\n            do {\n                try await Task.sleep(for: .seconds(baseSyncInterval))\n            } catch {\n                return\n            }\n\n            guard session.phase == .ready,\n                  scenePhase == .active,\n                  !lowPowerMode,\n                  !isThermallyConstrained else {\n                return\n            }\n            await model.refresh(silent: true)\n        }\n    }\n''',
)

# Home presentation: structured @concurrent boundary instead of Task.detached.
replace_exact(
    "BuFi/UI/HomeView.swift",
    '''        let work = Task.detached(priority: .userInitiated) {\n            HomePresentation.make(input: input)\n        }\n        let next = await withTaskCancellationHandler {\n            await work.value\n        } onCancel: {\n            work.cancel()\n        }\n''',
    '''        let next = await HomePresentation.makeConcurrently(input: input)\n''',
)
replace_exact(
    "BuFi/UI/HomeView.swift",
    '''    static func make(input: HomePresentationInput) -> HomePresentation {\n        let snapshot = input.snapshot\n''',
    '''    @concurrent\n    static func makeConcurrently(\n        input: HomePresentationInput\n    ) async -> HomePresentation {\n        guard !Task.isCancelled else { return .empty }\n        let value = make(input: input)\n        return Task.isCancelled ? .empty : value\n    }\n\n    static func make(input: HomePresentationInput) -> HomePresentation {\n        let snapshot = input.snapshot\n''',
)

# Search presentation: structured helper boundary.
replace_exact(
    "BuFi/UI/SearchView.swift",
    '''        let selectedArtists = ArtistMixPreferences.decode(selectedArtistsStorage)\n        let work = Task.detached(priority: .userInitiated) {\n            PersonalizedMixBuilder.make(\n                snapshot: snapshot,\n                snapshotRevision: revision,\n                selectedArtists: selectedArtists\n            )\n        }\n        let next = await withTaskCancellationHandler {\n            await work.value\n        } onCancel: {\n            work.cancel()\n        }\n''',
    '''        let selectedArtists = ArtistMixPreferences.decode(selectedArtistsStorage)\n        let next = await SearchPersonalizedMixWork.make(\n            snapshot: snapshot,\n            revision: revision,\n            selectedArtists: selectedArtists\n        )\n''',
)
replace_exact(
    "BuFi/UI/SearchView.swift",
    '''private enum SearchScrollAnchor: Hashable {\n    case top\n}\n\nprivate struct SearchMixTaskIdentity: Hashable, Sendable {\n''',
    '''private enum SearchScrollAnchor: Hashable {\n    case top\n}\n\nprivate enum SearchPersonalizedMixWork {\n    @concurrent\n    static func make(\n        snapshot: HomeSnapshot,\n        revision: HomeSnapshotRevision,\n        selectedArtists: [String]\n    ) async -> [PersonalizedMix] {\n        guard !Task.isCancelled else { return [] }\n        let value = PersonalizedMixBuilder.make(\n            snapshot: snapshot,\n            snapshotRevision: revision,\n            selectedArtists: selectedArtists\n        )\n        return Task.isCancelled ? [] : value\n    }\n}\n\nprivate struct SearchMixTaskIdentity: Hashable, Sendable {\n''',
)

# Library presentation: structured @concurrent boundary.
replace_exact(
    "BuFi/UI/LibraryView.swift",
    '''        let work = Task.detached(priority: .userInitiated) {\n            LibraryArtistPresentation.make(input: input)\n        }\n        let next = await withTaskCancellationHandler {\n            await work.value\n        } onCancel: {\n            work.cancel()\n        }\n''',
    '''        let next = await LibraryArtistPresentation.makeConcurrently(input: input)\n''',
)
replace_exact(
    "BuFi/UI/LibraryView.swift",
    '''    static func make(input: LibraryArtistPresentationInput) -> LibraryArtistPresentation {\n        let favoriteIDs = Set(input.starredArtists.map(\\.id))\n''',
    '''    @concurrent\n    static func makeConcurrently(\n        input: LibraryArtistPresentationInput\n    ) async -> LibraryArtistPresentation {\n        guard !Task.isCancelled else { return .empty }\n        let value = make(input: input)\n        return Task.isCancelled ? .empty : value\n    }\n\n    static func make(input: LibraryArtistPresentationInput) -> LibraryArtistPresentation {\n        let favoriteIDs = Set(input.starredArtists.map(\\.id))\n''',
)

# Music detail derived data: structured @concurrent value boundary.
replace_exact(
    "BuFi/UI/MusicDetailView.swift",
    '''                let rawBiography = detail.info?.biography ?? ""\n                let artistAlbums = detail.albums\n                let work = Task.detached(priority: .utility) {\n                    (\n                        ArtistBiographySanitizer.sanitize(rawBiography),\n                        ArtistDiscographyPresentation.make(artistAlbums)\n                    )\n                }\n                let preparedArtistContent = await withTaskCancellationHandler {\n                    await work.value\n                } onCancel: {\n                    work.cancel()\n                }\n                guard !Task.isCancelled, route == loadingRoute else { return }\n                artistBiography = preparedArtistContent.0\n                discography = preparedArtistContent.1\n''',
    '''                let preparedArtistContent = await ArtistDetailPresentation.make(\n                    biography: detail.info?.biography ?? "",\n                    albums: detail.albums\n                )\n                guard !Task.isCancelled, route == loadingRoute else { return }\n                artistBiography = preparedArtistContent.biography\n                discography = preparedArtistContent.discography\n''',
)
replace_exact(
    "BuFi/UI/MusicDetailView.swift",
    '''enum ArtistBiographySanitizer {\n    static func sanitize(_ biography: String) -> String {\n''',
    '''private struct ArtistDetailPresentation: Sendable {\n    let biography: String\n    let discography: ArtistDiscographyPresentation\n\n    @concurrent\n    static func make(\n        biography: String,\n        albums: [Album]\n    ) async -> ArtistDetailPresentation {\n        guard !Task.isCancelled else {\n            return ArtistDetailPresentation(\n                biography: "",\n                discography: .empty\n            )\n        }\n        let value = ArtistDetailPresentation(\n            biography: ArtistBiographySanitizer.sanitize(biography),\n            discography: ArtistDiscographyPresentation.make(albums)\n        )\n        if Task.isCancelled {\n            return ArtistDetailPresentation(\n                biography: "",\n                discography: .empty\n            )\n        }\n        return value\n    }\n}\n\nenum ArtistBiographySanitizer {\n    static func sanitize(_ biography: String) -> String {\n''',
)

# AppModel: typed artwork context + monotonic runtime/cache timing.
replace_exact(
    "BuFi/App/AppModel.swift",
    '''@MainActor\nfinal class AppSessionState: ObservableObject {\n''',
    '''struct ArtworkContextIdentity: Hashable, Sendable {\n    let sessionGeneration: Int\n    let accountScope: String?\n}\n\n@MainActor\nfinal class AppSessionState: ObservableObject {\n''',
)
replace_exact(
    "BuFi/App/AppModel.swift",
    '''    private struct CachedValue<Value> {\n        let value: Value\n        let expiresAt: Date\n    }\n''',
    '''    private struct CachedValue<Value> {\n        let value: Value\n        let expiresAt: ContinuousClock.Instant\n    }\n''',
)
replace_exact(
    "BuFi/App/AppModel.swift",
    '''    private var lastFullRefresh = Date.distantPast\n    private var lastHomeSnapshotSave = Date.distantPast\n''',
    '''    private let runtimeClock = ContinuousClock()\n    private var lastFullRefresh: ContinuousClock.Instant?\n    private var lastHomeSnapshotSave: ContinuousClock.Instant?\n''',
)
replace_exact(
    "BuFi/App/AppModel.swift",
    '''        lastFullRefresh = .distantPast\n        lastHomeSnapshotSave = .distantPast\n''',
    '''        lastFullRefresh = nil\n        lastHomeSnapshotSave = nil\n''',
)
replace_exact(
    "BuFi/App/AppModel.swift",
    '''            let needsFullRefresh = forceFull ||\n                Date().timeIntervalSince(lastFullRefresh) >= 300 ||\n                isHomeEmpty\n''',
    '''            let refreshNow = runtimeClock.now\n            let needsFullRefresh = forceFull\n                || lastFullRefresh.map {\n                    $0.duration(to: refreshNow) >= .seconds(300)\n                } ?? true\n                || isHomeEmpty\n''',
)
replace_exact(
    "BuFi/App/AppModel.swift",
    '''            if needsFullRefresh { lastFullRefresh = Date() }\n''',
    '''            if needsFullRefresh { lastFullRefresh = runtimeClock.now }\n''',
)
replace_exact(
    "BuFi/App/AppModel.swift",
    '''            let now = Date()\n            if snapshotChanged\n                || now.timeIntervalSince(lastHomeSnapshotSave) >= 3_600 {\n''',
    '''            let saveNow = runtimeClock.now\n            let snapshotSaveIsDue = lastHomeSnapshotSave.map {\n                $0.duration(to: saveNow) >= .seconds(3_600)\n            } ?? true\n            if snapshotChanged || snapshotSaveIsDue {\n''',
)
replace_exact(
    "BuFi/App/AppModel.swift",
    '''                lastHomeSnapshotSave = now\n''',
    '''                lastHomeSnapshotSave = saveNow\n''',
)
replace_exact(
    "BuFi/App/AppModel.swift",
    '''    var artworkContextID: String {\n        "\\(sessionGeneration):\\(client?.accountScope ?? "signed-out")"\n    }\n''',
    '''    var artworkContextID: ArtworkContextIdentity {\n        ArtworkContextIdentity(\n            sessionGeneration: sessionGeneration,\n            accountScope: client?.accountScope\n        )\n    }\n''',
)
replace_exact(
    "BuFi/App/AppModel.swift",
    '''        guard let cached = cache[id] else { return nil }\n        guard cached.expiresAt > Date() else {\n''',
    '''        guard let cached = cache[id] else { return nil }\n        guard cached.expiresAt > ContinuousClock().now else {\n''',
)
replace_exact(
    "BuFi/App/AppModel.swift",
    '''        let now = Date()\n        cache[id] = CachedValue(\n            value: value,\n            expiresAt: now.addingTimeInterval(lifetime)\n        )\n''',
    '''        let clock = ContinuousClock()\n        let now = clock.now\n        cache[id] = CachedValue(\n            value: value,\n            expiresAt: now.advanced(by: .seconds(lifetime))\n        )\n''',
)

# Artwork views: typed request identity, structurally separating all fields.
replace_exact(
    "BuFi/UI/Components.swift",
    '''struct ArtworkView: View {\n    private struct LoadedArtwork {\n        let requestIdentity: String\n        let image: UIImage\n    }\n''',
    '''struct ArtworkLoadRequestIdentity: Hashable, Sendable {\n    let context: ArtworkContextIdentity\n    let coverArtID: String?\n    let cacheRevision: String?\n    let pixelSize: Int\n}\n\nstruct ArtworkView: View {\n    private struct LoadedArtwork {\n        let requestIdentity: ArtworkLoadRequestIdentity\n        let image: UIImage\n    }\n''',
)
replace_exact(
    "BuFi/UI/Components.swift",
    '''    private var artworkRequestIdentity: String {\n        "\\(model.artworkContextID)-\\(normalizedCoverArt ?? "")-\\(cacheRevision ?? "base")-\\(Int(requestedPixelSize))"\n    }\n''',
    '''    private var artworkRequestIdentity: ArtworkLoadRequestIdentity {\n        ArtworkLoadRequestIdentity(\n            context: model.artworkContextID,\n            coverArtID: normalizedCoverArt,\n            cacheRevision: cacheRevision,\n            pixelSize: Int(requestedPixelSize)\n        )\n    }\n''',
)
replace_exact(
    "BuFi/UI/ArtistHeroArtwork.swift",
    '''    private struct LoadedArtwork {\n        let requestIdentity: String\n        let image: UIImage\n    }\n''',
    '''    private struct LoadedArtwork {\n        let requestIdentity: ArtworkLoadRequestIdentity\n        let image: UIImage\n    }\n''',
)
replace_exact(
    "BuFi/UI/ArtistHeroArtwork.swift",
    '''    private func loadImage(requestID: String) async {\n''',
    '''    private func loadImage(requestID: ArtworkLoadRequestIdentity) async {\n''',
)
replace_exact(
    "BuFi/UI/ArtistHeroArtwork.swift",
    '''    private var artworkRequestIdentity: String {\n        "\\(model.artworkContextID)-\\(normalizedCoverArt ?? "")-\\(cacheRevision ?? "base")-\\(Int(requestedPixelSize))"\n    }\n''',
    '''    private var artworkRequestIdentity: ArtworkLoadRequestIdentity {\n        ArtworkLoadRequestIdentity(\n            context: model.artworkContextID,\n            coverArtID: normalizedCoverArt,\n            cacheRevision: cacheRevision,\n            pixelSize: Int(requestedPixelSize)\n        )\n    }\n''',
)

# Diagnostics: elapsed RTT is monotonic and independent of wall-clock adjustments.
replace_exact(
    "BuFi/Core/OpenSubsonicClient+Diagnostics.swift",
    '''            let startedAt = Date()\n            let (encodedData, response) = try await session.data(for: request)\n            let elapsed = Date().timeIntervalSince(startedAt) * 1_000\n''',
    '''            let clock = ContinuousClock()\n            let startedAt = clock.now\n            let (encodedData, response) = try await session.data(for: request)\n            let elapsed = Self.milliseconds(from: startedAt.duration(to: clock.now))\n''',
)
replace_exact(
    "BuFi/Core/OpenSubsonicClient+Diagnostics.swift",
    '''    private static func isRetryableDiagnosticFailure(_ error: Error) -> Bool {\n''',
    '''    static func milliseconds(from duration: Duration) -> Double {\n        let components = duration.components\n        return Double(components.seconds) * 1_000\n            + Double(components.attoseconds) / 1_000_000_000_000_000\n    }\n\n    private static func isRetryableDiagnosticFailure(_ error: Error) -> Bool {\n''',
)

# Marquee: preserve motion but spend more time at rest between repeated GPU animations.
replace_exact(
    "BuFi/UI/OverflowMarqueeText.swift",
    '''                try await Task.sleep(for: .seconds(returnDuration + 1.6))\n''',
    '''                // Long titles remain discoverable, but repeated GPU animation\n                // is intentionally sparse after the first cycle. The view task still\n                // cancels immediately on scene/identity changes.\n                let restDuration = max(5.5, min(8.0, Double(distance / 32)))\n                try await Task.sleep(for: .seconds(returnDuration + restDuration))\n''',
)

# Regression coverage: typed identities and structured presentation APIs.
replace_exact(
    "BuFiTests/UIOptimizationTests.swift",
    '''    func testArtworkRequestSizingUsesStableBoundedPixelBuckets() {\n''',
    '''    func testArtworkRequestIdentityKeepsFieldsStructurallyDistinct() {\n        let first = ArtworkLoadRequestIdentity(\n            context: ArtworkContextIdentity(\n                sessionGeneration: 7,\n                accountScope: "scope-part"\n            ),\n            coverArtID: "cover",\n            cacheRevision: "revision",\n            pixelSize: 600\n        )\n        let second = ArtworkLoadRequestIdentity(\n            context: ArtworkContextIdentity(\n                sessionGeneration: 7,\n                accountScope: "scope"\n            ),\n            coverArtID: "part-cover",\n            cacheRevision: "revision",\n            pixelSize: 600\n        )\n\n        XCTAssertNotEqual(first, second)\n    }\n\n    func testArtworkRequestSizingUsesStableBoundedPixelBuckets() {\n''',
)
replace_exact(
    "BuFiTests/UIOptimizationTests.swift",
    '''        let presentation = HomePresentation.make(\n            input: HomePresentationInput(snapshot: snapshot, selectedArtists: [])\n        )\n\n        XCTAssertEqual(presentation.recommendedAlbums.map(\\.id), ["album-a", "album-b"])\n''',
    '''        let presentation = HomePresentation.make(\n            input: HomePresentationInput(snapshot: snapshot, selectedArtists: [])\n        )\n\n        XCTAssertEqual(presentation.recommendedAlbums.map(\\.id), ["album-a", "album-b"])\n''',
)
replace_exact(
    "BuFiTests/SwiftConcurrencyArchitectureTests.swift",
    '''    func testConcurrentContentDecoderPassesThroughPlainData() async throws {\n''',
    '''    func testConcurrentUIPresentationBoundariesPreserveEmptyInputs() async {\n        let home = await HomePresentation.makeConcurrently(\n            input: HomePresentationInput(\n                snapshot: .empty,\n                selectedArtists: []\n            )\n        )\n        let library = await LibraryArtistPresentation.makeConcurrently(\n            input: LibraryArtistPresentationInput(\n                artists: [],\n                starredArtists: []\n            )\n        )\n\n        XCTAssertTrue(home.personalizedMixes.isEmpty)\n        XCTAssertTrue(library.allArtists.isEmpty)\n        XCTAssertTrue(library.sections.isEmpty)\n    }\n\n    func testLatencyDurationConversionUsesMonotonicDurationUnits() {\n        XCTAssertEqual(\n            OpenSubsonicClient.milliseconds(from: .milliseconds(125)),\n            125,\n            accuracy: 0.001\n        )\n    }\n\n    func testConcurrentContentDecoderPassesThroughPlainData() async throws {\n''',
)

# Guardrails for this modernization pass.
source_files = list(Path("BuFi").rglob("*.swift"))
legacy_detached = [str(path) for path in source_files if "Task.detached" in path.read_text()]
if legacy_detached:
    raise SystemExit(f"Task.detached remains in app source: {legacy_detached}")

root = Path("BuFi/UI/RootView.swift").read_text()
if "import Combine" in root or ".receive(on: DispatchQueue.main)" in root or ".onReceive(" in root:
    raise SystemExit("legacy RootView Combine/GCD notification bridge remains")

for path in ["BuFi/UI/Components.swift", "BuFi/UI/ArtistHeroArtwork.swift"]:
    text = Path(path).read_text()
    if "private var artworkRequestIdentity: String" in text:
        raise SystemExit(f"string artwork identity remains in {path}")

print("Swift 6.4 modernization patch applied")
