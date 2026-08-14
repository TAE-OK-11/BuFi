from pathlib import Path
import re


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}\n--- pattern ---\n{old[:800]}")
    file.write_text(text.replace(old, new, 1))


def insert_before_once(path: str, marker: str, addition: str) -> None:
    replace_once(path, marker, addition + marker)


def insert_after_once(path: str, marker: str, addition: str) -> None:
    replace_once(path, marker, marker + addition)


def replace_regex_once(path: str, pattern: str, replacement: str) -> None:
    file = Path(path)
    text = file.read_text()
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S | re.M)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one regex match, found {count}\n--- regex ---\n{pattern[:800]}")
    file.write_text(updated)


# MARK: Recommendation CPU work: explicit Swift 6 concurrent boundaries
insert_after_once(
    "BuFi/Core/RecommendationEngine.swift",
    "enum RecommendationMixer {\n    private static let cache = RecommendationMixCache()\n\n",
    '''    /// CPU-heavy recommendation scoring deliberately leaves the caller's
    /// actor. The async boundary stays structured, so cancellation belongs to
    /// the request that asked for the mix instead of an orphan detached task.
    @concurrent
    static func mixConcurrently(
        snapshot: HomeSnapshot,
        snapshotRevision: HomeSnapshotRevision? = nil,
        weights: RecommendationWeights,
        purpose: RecommendationPurpose = .home,
        behavior: RecommendationBehaviorSnapshot = .empty,
        limit: Int = 30,
        date: Date = Date()
    ) async -> [Song] {
        guard !Task.isCancelled else { return [] }
        return mix(
            snapshot: snapshot,
            snapshotRevision: snapshotRevision,
            weights: weights,
            purpose: purpose,
            behavior: behavior,
            limit: limit,
            date: date
        )
    }

    /// Home and daylist deliberately share one concurrent job and evaluation
    /// timestamp. Running them in parallel would compete for CPU/radio-adjacent
    /// work and increase energy use without improving first-result latency.
    @concurrent
    static func sectionsConcurrently(
        snapshot: HomeSnapshot,
        snapshotRevision: HomeSnapshotRevision? = nil,
        weights: RecommendationWeights,
        behavior: RecommendationBehaviorSnapshot,
        date: Date = Date()
    ) async -> (recommended: [Song], daylist: [Song]) {
        guard !Task.isCancelled else { return ([], []) }
        let recommended = mix(
            snapshot: snapshot,
            snapshotRevision: snapshotRevision,
            weights: weights,
            behavior: behavior,
            date: date
        )
        guard !Task.isCancelled else { return (recommended, []) }
        let daylist = mix(
            snapshot: snapshot,
            snapshotRevision: snapshotRevision,
            weights: weights,
            purpose: .daylist,
            behavior: behavior,
            limit: 24,
            date: date
        )
        return (recommended, daylist)
    }

'''
)

replace_once(
    "BuFi/App/AppModel.swift",
    '''    nonisolated private static func recommendations(
        snapshot: HomeSnapshot,
        snapshotRevision: HomeSnapshotRevision? = nil,
        weights: RecommendationWeights,
        purpose: RecommendationPurpose = .home,
        behavior: RecommendationBehaviorSnapshot = .empty,
        limit: Int = 30
    ) async -> [Song] {
        let task = Task.detached(priority: .userInitiated) {
            RecommendationMixer.mix(
                snapshot: snapshot,
                snapshotRevision: snapshotRevision,
                weights: weights,
                purpose: purpose,
                behavior: behavior,
                limit: limit
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func recommendationSections(
        snapshot: HomeSnapshot,
        snapshotRevision: HomeSnapshotRevision? = nil,
        weights: RecommendationWeights,
        behavior: RecommendationBehaviorSnapshot
    ) async -> (recommended: [Song], daylist: [Song]) {
        let task = Task.detached(priority: .userInitiated) { () -> (recommended: [Song], daylist: [Song]) in
            let recommended = RecommendationMixer.mix(
                snapshot: snapshot,
                snapshotRevision: snapshotRevision,
                weights: weights,
                behavior: behavior
            )
            guard !Task.isCancelled else { return (recommended, []) }
            let daylist = RecommendationMixer.mix(
                snapshot: snapshot,
                snapshotRevision: snapshotRevision,
                weights: weights,
                purpose: .daylist,
                behavior: behavior,
                limit: 24
            )
            return (recommended, daylist)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
''',
    '''    nonisolated private static func recommendations(
        snapshot: HomeSnapshot,
        snapshotRevision: HomeSnapshotRevision? = nil,
        weights: RecommendationWeights,
        purpose: RecommendationPurpose = .home,
        behavior: RecommendationBehaviorSnapshot = .empty,
        limit: Int = 30
    ) async -> [Song] {
        await RecommendationMixer.mixConcurrently(
            snapshot: snapshot,
            snapshotRevision: snapshotRevision,
            weights: weights,
            purpose: purpose,
            behavior: behavior,
            limit: limit
        )
    }

    nonisolated private static func recommendationSections(
        snapshot: HomeSnapshot,
        snapshotRevision: HomeSnapshotRevision? = nil,
        weights: RecommendationWeights,
        behavior: RecommendationBehaviorSnapshot
    ) async -> (recommended: [Song], daylist: [Song]) {
        await RecommendationMixer.sectionsConcurrently(
            snapshot: snapshot,
            snapshotRevision: snapshotRevision,
            weights: weights,
            behavior: behavior
        )
    }
'''
)


# MARK: Artwork CPU work + staggered refresh to prevent cache-expiry stampedes
replace_once(
    "BuFi/Core/ArtworkStore.swift",
    '    private static let cacheSchemaRevision = "media-v2"\n    private static let paletteEngineVersion = 5\n',
    '    private static let cacheSchemaRevision = "media-v2"\n'
    '    private static let artworkFreshnessInterval: TimeInterval = 12 * 60 * 60\n'
    '    private static let paletteEngineVersion = 5\n'
)

replace_once(
    "BuFi/Core/ArtworkStore.swift",
    '''    nonisolated static func cacheURL(for url: URL, revision: String?) -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return url
        }
        // OpenSubsonic does not standardize an artwork validator. Every image
        // therefore receives a bounded freshness epoch, including generic list
        // thumbnails that do not yet have a metadata revision. This prevents a
        // server-side image replacement under the same coverArt ID from being
        // retained indefinitely.
        let freshnessEpoch = Int(Date().timeIntervalSince1970 / (12 * 60 * 60))
        let boundedRevision = "\\(revision ?? \"unversioned\")-\\(freshnessEpoch)"
        components.fragment = [cacheSchemaRevision, boundedRevision]
            .joined(separator: "-")
        return components.url ?? url
    }
''',
    '''    nonisolated static func cacheURL(
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
        let boundedRevision = "\\(revision ?? \"unversioned\")-\\(freshnessEpoch)"
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
'''
)

replace_once(
    "BuFi/Core/ArtworkStore.swift",
    '''        // Palette clustering is CPU-heavy. Keep it off the store actor so an
        // account switch, cache clear, or visible image request is not blocked
        // behind color analysis.
        let analysisTask: Task<ArtworkPalette?, Never> = Task.detached(
            priority: .utility
        ) {
            guard !Task.isCancelled else { return nil }
            return Self.analyzedPalette(from: sampleBytes)
        }
        let value = await withTaskCancellationHandler {
            await analysisTask.value
        } onCancel: {
            analysisTask.cancel()
        }
''',
    '''        // Palette clustering is CPU-heavy. `@concurrent` keeps the work off
        // the store actor while preserving structured cancellation ownership.
        let value = await Self.analyzedPaletteConcurrently(from: sampleBytes)
'''
)

insert_before_once(
    "BuFi/Core/ArtworkStore.swift",
    "    private static func analyzedPalette(from bytes: [UInt8]) -> ArtworkPalette? {\n",
    '''    @concurrent
    private static func analyzedPaletteConcurrently(
        from bytes: [UInt8]
    ) async -> ArtworkPalette? {
        guard !Task.isCancelled else { return nil }
        return analyzedPalette(from: bytes)
    }

'''
)


# MARK: Offline store: owned tasks + explicit concurrent file-system work
replace_once(
    "BuFi/Core/OfflineStore.swift",
    '''        bootstrapTask = Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication
                ]
            )
            Self.removeLegacyUnscopedFiles(in: root)
        }
''',
    '''        bootstrapTask = Task(priority: .utility) {
            await Self.bootstrapStorage(at: root)
        }
'''
)

insert_before_once(
    "BuFi/Core/OfflineStore.swift",
    "    private static func fileName(for song: Song) -> String {\n",
    '''    @concurrent
    private static func bootstrapStorage(at root: URL) async {
        guard !Task.isCancelled else { return }
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication
            ]
        )
        guard !Task.isCancelled else { return }
        removeLegacyUnscopedFiles(in: root)
    }

'''
)

replace_regex_once(
    "BuFi/Core/OfflineStore.swift",
    r'''    private static func validatedDatabaseEntries\(\n        _ databaseEntries: \[String: OfflineDatabaseEntry\],\n        directory: URL\n    \) async -> \[String: Entry\] \{.*?^    \}\n\n(?=    private static func stageDownloadedFile)''',
    '''    @concurrent
    private static func validatedDatabaseEntries(
        _ databaseEntries: [String: OfflineDatabaseEntry],
        directory: URL
    ) async -> [String: Entry] {
        guard !Task.isCancelled else { return [:] }
        return databaseEntries.reduce(into: [String: Entry]()) { result, pair in
            guard !Task.isCancelled else { return }
            let entry = Entry(
                fileName: pair.value.fileName,
                byteCount: pair.value.byteCount,
                lastAccessedAt: pair.value.lastAccessedAt,
                mediaRevision: pair.value.mediaRevision
            )
            let fileURL = directory.appendingPathComponent(entry.fileName)
            if Self.isValidOfflineFile(
                at: fileURL,
                expectedByteCount: entry.byteCount
            ) {
                result[pair.key] = entry
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

'''
)

replace_regex_once(
    "BuFi/Core/OfflineStore.swift",
    r'''    private static func stageDownloadedFile\(\n        temporary: URL,\n        directory: URL,\n        fileName: String\n    \) async throws -> StagedDownload \{.*?^    \}\n\n(?=    private static func loadEntries)''',
    '''    @concurrent
    private static func stageDownloadedFile(
        temporary: URL,
        directory: URL,
        fileName: String
    ) async throws -> StagedDownload {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(
            atPath: temporary.path
        )
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            throw URLError(.zeroByteResource)
        }

        let staging = directory.appendingPathComponent(
            fileName + "." + UUID().uuidString + ".partial"
        )
        do {
            try FileManager.default.moveItem(at: temporary, to: staging)
            try Task.checkCancellation()
            return StagedDownload(
                url: staging,
                byteCount: size.int64Value
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

'''
)


# MARK: Database: coalesced ownership without detached tasks; CPU encoding off actor
insert_before_once(
    "BuFi/Core/AppDatabase.swift",
    "    private func databasePool() async -> DatabasePool? {\n",
    '''    @concurrent
    private static func openPoolConcurrently(path: String) async -> DatabasePool? {
        guard !Task.isCancelled else { return nil }
        return openPool(path: path)
    }

'''
)

replace_once(
    "BuFi/Core/AppDatabase.swift",
    '''        let path = databasePath
        let task = Task.detached(priority: .utility) { () -> DatabasePool? in
            Self.openPool(path: path)
        }
        poolTask = task
        let openedPool = await task.value
''',
    '''        let path = databasePath
        let task = Task(priority: .utility) {
            await Self.openPoolConcurrently(path: path)
        }
        poolTask = task
        let openedPool = await task.value
'''
)

replace_once(
    "BuFi/Core/AppDatabase.swift",
    '''        guard let pool = await databasePool(),
              let data = try? Self.encode(snapshot),
              data.count <= maximumBytes else { return false }
''',
    '''        guard let pool = await databasePool(),
              let data = await Self.encodeHomeSnapshotConcurrently(
                snapshot,
                maximumBytes: maximumBytes
              ) else { return false }
'''
)

replace_once(
    "BuFi/Core/AppDatabase.swift",
    '''        let encodedItems: [EncodedQueueItem]
        do {
            if replacingItems {
                encodedItems = try snapshot.entries.enumerated().map {
                    position, entry in
                    EncodedQueueItem(
                        position: position,
                        queueEntryID: entry.id.uuidString,
                        songData: try Self.encode(entry.song)
                    )
                }
            } else {
                encodedItems = []
            }
        } catch {
            return false
        }
''',
    '''        let encodedItems: [EncodedQueueItem]
        do {
            if replacingItems {
                encodedItems = try await Self.encodeQueueItemsConcurrently(
                    snapshot.entries
                )
            } else {
                encodedItems = []
            }
        } catch {
            return false
        }
        guard !Task.isCancelled else { return false }
'''
)

insert_before_once(
    "BuFi/Core/AppDatabase.swift",
    "    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {\n",
    '''    @concurrent
    private static func encodeHomeSnapshotConcurrently(
        _ snapshot: HomeSnapshot,
        maximumBytes: Int
    ) async -> Data? {
        guard !Task.isCancelled,
              let data = try? encode(snapshot),
              data.count <= maximumBytes else {
            return nil
        }
        return data
    }

    @concurrent
    private static func encodeQueueItemsConcurrently(
        _ entries: [PlaybackQueueEntry]
    ) async throws -> [EncodedQueueItem] {
        try Task.checkCancellation()
        var encoded: [EncodedQueueItem] = []
        encoded.reserveCapacity(entries.count)
        for (position, entry) in entries.enumerated() {
            if position.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            encoded.append(EncodedQueueItem(
                position: position,
                queueEntryID: entry.id.uuidString,
                songData: try encode(entry.song)
            ))
        }
        return encoded
    }

'''
)


# MARK: Playback energy: event-driven refresh cadence
insert_before_once(
    "BuFi/Playback/AudioEngine.swift",
    "/// Owns AVPlayer and NotificationCenter tokens as one lifecycle unit. All\n",
    '''enum PlaybackTimelineRefreshPolicy {
    static func interval(
        isApplicationActive: Bool,
        showsFullPlayer: Bool,
        lowPowerModeEnabled: Bool,
        thermallyConstrained: Bool
    ) -> TimeInterval {
        // Background playback needs persistence/scrobble maintenance, not UI
        // animation. Two-second ticks cut wakeups by 75% versus the old 2 Hz
        // cadence while keeping 30/180-second maintenance comfortably precise.
        guard isApplicationActive else { return 2.0 }
        // The mini player needs only coarse progress. Reserve 4 Hz for the full
        // player when the system is not asking us to conserve power/thermals.
        guard showsFullPlayer,
              !lowPowerModeEnabled,
              !thermallyConstrained else {
            return 1.0
        }
        return 0.25
    }
}

'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''    private var networkPathIsSatisfied = true
    private var runtimeIsActive = false
''',
    '''    private var networkPathIsSatisfied = true
    private var runtimeIsActive = false
    private var applicationIsActive = true
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''        guard !runtimeIsActive else { return }
        runtimeIsActive = true
        LaunchDiagnostics.mark("audio-runtime-starting")
''',
    '''        guard !runtimeIsActive else { return }
        runtimeIsActive = true
        applicationIsActive = UIApplication.shared.applicationState == .active
        LaunchDiagnostics.mark("audio-runtime-starting")
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''        let processInfo = ProcessInfo.processInfo
        let canUseSmoothRefresh =
            showPlayer
            && !processInfo.isLowPowerModeEnabled
            && processInfo.thermalState != .serious
            && processInfo.thermalState != .critical
        let refreshInterval = canUseSmoothRefresh ? 0.25 : 0.5
''',
    '''        let processInfo = ProcessInfo.processInfo
        let thermalState = processInfo.thermalState
        let refreshInterval = PlaybackTimelineRefreshPolicy.interval(
            isApplicationActive: applicationIsActive,
            showsFullPlayer: showPlayer,
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermallyConstrained: thermalState == .serious || thermalState == .critical
        )
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''            ) { @Sendable [weak self] _ in
                Task { @MainActor in self?.handleDidEnterBackground() }
            })
            tokens.append(center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { @Sendable [weak self] _ in
                Task { @MainActor in self?.preserveActivePlayback() }
            })
            tokens.append(center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard let self, self.wantsPlayback else { return }
                    self.preserveActivePlayback()
                }
            })
''',
    '''            ) { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.setApplicationActive(false)
                    self.handleDidEnterBackground()
                }
            })
            tokens.append(center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.setApplicationActive(false)
                    self.preserveActivePlayback()
                }
            })
            tokens.append(center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.setApplicationActive(true)
                    guard self.wantsPlayback else { return }
                    self.preserveActivePlayback()
                }
            })
'''
)

insert_before_once(
    "BuFi/Playback/AudioEngine.swift",
    "    private func handleDidEnterBackground() {\n",
    '''    private func setApplicationActive(_ value: Bool) {
        guard applicationIsActive != value else { return }
        applicationIsActive = value
        installPlaybackTimeObserver()
    }

'''
)


# MARK: Release optimization: slower build, stronger final binary optimization
replace_once(
    "project.yml",
    '''      # Keep release post-linking conservative on the current Swift 6.4
      # toolchain. One iOS 17+ binary covers current iOS releases without
      # maintaining a separate OS-specific artifact.
      LLVM_LTO: NO
''',
    '''      # Release favors final runtime/code-size optimization over build
      # latency. Monolithic LLVM LTO complements Swift whole-module -O and lets
      # the linker optimize across object-file boundaries.
      LLVM_LTO: YES
'''
)

replace_once(
    "Scripts/verify-swift6-language-mode.sh",
    '''        printf '%s\\n' "$settings" \\
            | grep -Eq '^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET = 17\\.0[[:space:]]*$'
    done
done
''',
    '''        printf '%s\\n' "$settings" \\
            | grep -Eq '^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET = 17\\.0[[:space:]]*$'

        if [ "$configuration" = "Debug" ]; then
            printf '%s\\n' "$settings" \\
                | grep -Eq '^[[:space:]]*OTHER_SWIFT_FLAGS = .*enable-actor-data-race-checks'
        else
            printf '%s\\n' "$settings" \\
                | grep -Eq '^[[:space:]]*SWIFT_OPTIMIZATION_LEVEL = -O[[:space:]]*$'
            printf '%s\\n' "$settings" \\
                | grep -Eq '^[[:space:]]*SWIFT_COMPILATION_MODE = wholemodule[[:space:]]*$'
            printf '%s\\n' "$settings" \\
                | grep -Eq '^[[:space:]]*LLVM_LTO = YES[[:space:]]*$'
            printf '%s\\n' "$settings" \\
                | grep -Eq '^[[:space:]]*DEAD_CODE_STRIPPING = YES[[:space:]]*$'
        fi
    done
done
'''
)


# MARK: Regression coverage for energy and explicit concurrency policies
new_test = Path("BuFiTests/CorePerformancePolicyTests.swift")
if new_test.exists():
    raise SystemExit(f"{new_test}: already exists")
new_test.write_text('''import Foundation
import XCTest
@testable import BuFi

final class CorePerformancePolicyTests: XCTestCase {
    func testTimelineRefreshPolicyPreservesSmoothFullPlayer() {
        XCTAssertEqual(
            PlaybackTimelineRefreshPolicy.interval(
                isApplicationActive: true,
                showsFullPlayer: true,
                lowPowerModeEnabled: false,
                thermallyConstrained: false
            ),
            0.25
        )
    }

    func testTimelineRefreshPolicyReducesMiniPlayerAndBackgroundWakeups() {
        XCTAssertEqual(
            PlaybackTimelineRefreshPolicy.interval(
                isApplicationActive: true,
                showsFullPlayer: false,
                lowPowerModeEnabled: false,
                thermallyConstrained: false
            ),
            1.0
        )
        XCTAssertEqual(
            PlaybackTimelineRefreshPolicy.interval(
                isApplicationActive: false,
                showsFullPlayer: true,
                lowPowerModeEnabled: false,
                thermallyConstrained: false
            ),
            2.0
        )
    }

    func testTimelineRefreshPolicyRespectsPowerAndThermalPressure() {
        XCTAssertEqual(
            PlaybackTimelineRefreshPolicy.interval(
                isApplicationActive: true,
                showsFullPlayer: true,
                lowPowerModeEnabled: true,
                thermallyConstrained: false
            ),
            1.0
        )
        XCTAssertEqual(
            PlaybackTimelineRefreshPolicy.interval(
                isApplicationActive: true,
                showsFullPlayer: true,
                lowPowerModeEnabled: false,
                thermallyConstrained: true
            ),
            1.0
        )
    }

    func testArtworkFreshnessEpochIsStableButStaggeredByURL() {
        let date = Date(timeIntervalSince1970: 10_000)
        let first = URL(string: "https://example.com/a")!
        let second = URL(string: "https://music.example/art/1")!
        let firstEpoch = ArtworkStore.artworkFreshnessEpoch(for: first, at: date)
        let secondEpoch = ArtworkStore.artworkFreshnessEpoch(for: second, at: date)

        XCTAssertNotEqual(firstEpoch, secondEpoch)
        XCTAssertEqual(
            ArtworkStore.artworkFreshnessEpoch(
                for: first,
                at: date.addingTimeInterval(12 * 60 * 60)
            ),
            firstEpoch + 1
        )
    }

    func testConcurrentRecommendationBoundaryPreservesResult() async {
        let defaults = UserDefaults(suiteName: "CorePerformancePolicyTests")!
        defaults.removePersistentDomain(forName: "CorePerformancePolicyTests")
        let weights = RecommendationWeights.current(defaults)

        let result = await RecommendationMixer.mixConcurrently(
            snapshot: .empty,
            weights: weights
        )
        let sections = await RecommendationMixer.sectionsConcurrently(
            snapshot: .empty,
            weights: weights,
            behavior: .empty
        )

        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(sections.recommended.isEmpty)
        XCTAssertTrue(sections.daylist.isEmpty)
    }
}
''')

# Core/App coordinators should now express executor hops explicitly instead of
# creating detached jobs whose lifetime is disconnected from the request.
for root in [Path("BuFi/Core"), Path("BuFi/App")]:
    for file in root.rglob("*.swift"):
        if "Task.detached" in file.read_text():
            raise SystemExit(f"Detached task remains in {file}")
