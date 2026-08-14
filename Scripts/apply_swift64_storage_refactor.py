from __future__ import annotations

import json
from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, value: str) -> None:
    Path(path).write_text(value, encoding="utf-8")


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one match, found {count}: {old[:80]!r}")
    write(path, text.replace(old, new, 1))


def replace_between(path: str, start: str, end: str, replacement: str) -> None:
    text = read(path)
    if text.count(start) != 1 or text.count(end) < 1:
        raise RuntimeError(f"{path}: unique range marker missing")
    begin = text.index(start)
    finish = text.index(end, begin)
    write(path, text[:begin] + replacement + text[finish:])


# A package that is not referenced by source code only increases resolution,
# build, and concurrency-audit surface. Refuse to remove it if it becomes used.
swiftsonic_usages: list[str] = []
for source in Path("BuFi").rglob("*.swift"):
    if "SwiftSonic" in source.read_text(encoding="utf-8"):
        swiftsonic_usages.append(str(source))
if swiftsonic_usages:
    raise RuntimeError(f"SwiftSonic is still used by source: {swiftsonic_usages}")


storage_identity = r'''import Foundation

/// Exact identity for one coalescible offline transfer.
///
/// Account scope and song identity remain separate values instead of being
/// flattened into a delimiter-bearing String. This keeps cancellation and
/// shared-transfer ownership collision-safe under Swift 6.
struct OfflineDownloadKey: Hashable, Sendable {
    let accountScope: String
    let songID: String
}

/// Exact identity for one in-flight artwork palette computation.
///
/// The generation is part of the key so work from a cleared or replaced
/// account generation cannot be joined by a newer request.
struct ArtworkPaletteRequestKey: Hashable, Sendable {
    let accountScope: String
    let cacheKey: String
    let generation: UInt64
}

/// Session-local monotonic recency for persistent offline LRU timestamps.
///
/// `Date` is retained on disk for cross-launch ordering, but wall-clock
/// rollback must never make a newly accessed file look older than a previous
/// access from the same process.
struct OfflineAccessRecency: Sendable {
    private(set) var lastIssued = Date.distantPast

    mutating func seed(lastAccess: Date?, now: Date = Date()) {
        guard let lastAccess else {
            lastIssued = .distantPast
            return
        }
        lastIssued = min(lastAccess, now)
    }

    mutating func next(now: Date = Date(), after previous: Date? = nil) -> Date {
        let boundedPrevious = min(previous ?? .distantPast, now)
        let baseline = max(lastIssued, boundedPrevious)
        let value = max(now, baseline.addingTimeInterval(0.001))
        lastIssued = value
        return value
    }
}

/// Shared freshness rule for persisted cache snapshots.
///
/// A small future tolerance handles harmless clock skew, while snapshots far
/// in the future are rejected instead of becoming effectively immortal after
/// a device clock correction.
enum CacheFreshnessPolicy {
    static func isFresh(
        savedAt: Date,
        now: Date = Date(),
        maximumAge: TimeInterval,
        futureTolerance: TimeInterval = 5 * 60
    ) -> Bool {
        guard maximumAge >= 0, futureTolerance >= 0 else { return false }
        let age = now.timeIntervalSince(savedAt)
        return age >= -futureTolerance && age <= maximumAge
    }
}
'''
write("BuFi/Core/StorageIdentity.swift", storage_identity)


storage_tests = r'''import Foundation
import XCTest
@testable import BuFi

final class StorageConcurrencyTests: XCTestCase {
    func testOfflineDownloadKeyDoesNotFlattenScopeAndSong() {
        let first = OfflineDownloadKey(accountScope: "account:a", songID: "b")
        let second = OfflineDownloadKey(accountScope: "account", songID: "a:b")
        XCTAssertNotEqual(first, second)
    }

    func testOfflineAccessRecencyRemainsMonotonicAcrossClockRollback() {
        var recency = OfflineAccessRecency()
        let initial = Date(timeIntervalSince1970: 2_000)
        recency.seed(lastAccess: initial, now: initial)
        let first = recency.next(now: initial.addingTimeInterval(10))
        let rolledBack = recency.next(now: initial.addingTimeInterval(-100))
        XCTAssertGreaterThan(rolledBack, first)
    }

    func testOfflineAccessRecencyClampsFutureSeed() {
        var recency = OfflineAccessRecency()
        let now = Date(timeIntervalSince1970: 2_000)
        recency.seed(lastAccess: now.addingTimeInterval(3_600), now: now)
        XCTAssertLessThanOrEqual(recency.lastIssued, now)
    }

    func testCacheFreshnessRejectsFarFutureSnapshot() {
        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertFalse(CacheFreshnessPolicy.isFresh(
            savedAt: now.addingTimeInterval(3_600),
            now: now,
            maximumAge: 7 * 24 * 60 * 60
        ))
    }

    func testCacheFreshnessAllowsSmallClockSkew() {
        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(CacheFreshnessPolicy.isFresh(
            savedAt: now.addingTimeInterval(60),
            now: now,
            maximumAge: 7 * 24 * 60 * 60
        ))
    }

    func testArtworkPaletteRequestKeySeparatesAccountsAndGenerations() {
        let first = ArtworkPaletteRequestKey(
            accountScope: "a",
            cacheKey: "cover",
            generation: 1
        )
        let second = ArtworkPaletteRequestKey(
            accountScope: "a",
            cacheKey: "cover",
            generation: 2
        )
        let third = ArtworkPaletteRequestKey(
            accountScope: "b",
            cacheKey: "cover",
            generation: 1
        )
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, third)
    }
}
'''
write("BuFiTests/StorageConcurrencyTests.swift", storage_tests)


# Project/toolchain: one iOS 17+ build produced by Xcode 27 / Swift 6.4.
replace_once("project.yml", '  xcodeVersion: "26.6"\n', '  xcodeVersion: "27.0"\n')
replace_once(
    "project.yml",
    "      # iOS 27 beta 4 has device-only launch failures when some Xcode 26/27\n"
    "      # Release binaries are post-linked or stripped. Keep normal Swift\n"
    "      # optimization and dead-code stripping, but avoid LTO and post-build\n"
    "      # Mach-O mutation until the iOS 27 toolchain/runtime pair is stable.\n",
    "      # Keep release post-linking conservative on the current Swift 6.4\n"
    "      # toolchain. One iOS 17+ binary covers current iOS releases without\n"
    "      # maintaining a separate OS-specific artifact.\n",
)
replace_once(
    "project.yml",
    "      # Xcode 26.3-27 beta strip -S -T can corrupt dyld chained fixups in\n"
    "      # Swift 6 binaries (FB23528109). Keep safe non-global stripping until\n"
    "      # the affected toolchains are retired.\n",
    "      # Keep unsigned CI artifacts free from aggressive post-link stripping;\n"
    "      # normal Swift optimization and dead-code stripping remain enabled.\n",
)
replace_once(
    "project.yml",
    "  SwiftSonic:\n"
    "    url: https://github.com/CassetteLab/swiftsonic.git\n"
    "    exactVersion: 0.9.0\n",
    "",
)
replace_once(
    "project.yml",
    "      - package: SwiftSonic\n"
    "        product: SwiftSonic\n",
    "",
)

resolved_path = Path("Package.resolved")
resolved = json.loads(resolved_path.read_text(encoding="utf-8"))
before = len(resolved["pins"])
resolved["pins"] = [pin for pin in resolved["pins"] if pin.get("identity") != "swiftsonic"]
if len(resolved["pins"]) != before - 1:
    raise RuntimeError("Package.resolved: expected exactly one SwiftSonic pin")
resolved_path.write_text(json.dumps(resolved, indent=2) + "\n", encoding="utf-8")


verify_script = r'''#!/bin/sh
set -eu

xcode_version="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
swift_version="$(xcrun swiftc --version | sed -n '1p')"

# SWIFT_VERSION remains the Swift 6 language-mode selector (6.0). The actual
# compiler release is verified independently. The unified CI lane intentionally
# uses Xcode 27 / Swift 6.4 while keeping the deployment target at iOS 17.
case "$xcode_version" in
    27.*) ;;
    *)
        printf 'Expected Xcode 27.x, found %s\n' "$xcode_version" >&2
        exit 1
        ;;
esac
printf '%s\n' "$swift_version" \
    | grep -Eq '(Apple )?Swift version 6\.4(\.[0-9]+)?([[:space:]]|$)'

printf 'Xcode %s / %s\n' "$xcode_version" "$swift_version"

for target in BuFi BuFiTests; do
    for configuration in Debug Release; do
        settings="$(
            xcodebuild \
                -project BuFi.xcodeproj \
                -target "$target" \
                -configuration "$configuration" \
                -showBuildSettings
        )"

        printf '%s\n' "$settings" \
            | grep -Eq '^[[:space:]]*SWIFT_VERSION = 6(\.0)?[[:space:]]*$'
        printf '%s\n' "$settings" \
            | grep -Eq '^[[:space:]]*SWIFT_STRICT_CONCURRENCY = complete[[:space:]]*$'
        printf '%s\n' "$settings" \
            | grep -Eq '^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET = 17\.0[[:space:]]*$'
    done
done
'''
write("Scripts/verify-swift6-language-mode.sh", verify_script)


# OfflineStore: typed transfer identity, off-actor bootstrap/staging I/O, and
# monotonic persistent LRU timestamps.
replace_once(
    "BuFi/Core/OfflineStore.swift",
    "    private struct InFlightDownload: Sendable {\n"
    "        let token: UUID\n"
    "        let scopeGeneration: UInt64\n"
    "        let mediaRevision: String?\n"
    "        let task: Task<URL, Error>\n"
    "        var waiters: Set<UUID>\n"
    "    }\n",
    "    private struct InFlightDownload: Sendable {\n"
    "        let token: UUID\n"
    "        let scopeGeneration: UInt64\n"
    "        let mediaRevision: String?\n"
    "        let task: Task<URL, Error>\n"
    "        var waiters: Set<UUID>\n"
    "    }\n\n"
    "    private struct StagedDownload: Sendable {\n"
    "        let url: URL\n"
    "        let byteCount: Int64\n"
    "    }\n",
)
replace_once(
    "BuFi/Core/OfflineStore.swift",
    "    private var inFlight: [String: InFlightDownload] = [:]\n",
    "    private var inFlight: [OfflineDownloadKey: InFlightDownload] = [:]\n",
)
replace_once(
    "BuFi/Core/OfflineStore.swift",
    "    private var indexMutationEpoch: UInt64 = 0\n",
    "    private var indexMutationEpoch: UInt64 = 0\n"
    "    private var accessRecency = OfflineAccessRecency()\n",
)
replace_between(
    "BuFi/Core/OfflineStore.swift",
    "        var loadedEntries: [String: Entry] = databaseEntries.reduce(into: [:]) { result, pair in\n",
    "        let missingDatabaseIDs = Swift.Set<String>(databaseEntries.keys).subtracting(loadedEntries.keys)\n",
    "        var loadedEntries = await Self.validatedDatabaseEntries(\n"
    "            databaseEntries,\n"
    "            directory: scopedDirectory\n"
    "        )\n"
    "        guard generation == scopeGeneration, activeScope == nil else { return nil }\n",
)
replace_once(
    "BuFi/Core/OfflineStore.swift",
    "        entries = loadedEntries\n"
    "        dirtySongIDs.removeAll(keepingCapacity: true)\n",
    "        entries = loadedEntries\n"
    "        accessRecency.seed(\n"
    "            lastAccess: loadedEntries.values.map(\\.lastAccessedAt).max()\n"
    "        )\n"
    "        dirtySongIDs.removeAll(keepingCapacity: true)\n",
)
replace_once(
    "BuFi/Core/OfflineStore.swift",
    "        entries.removeAll(keepingCapacity: false)\n"
    "        indexIsDirty = false\n",
    "        entries.removeAll(keepingCapacity: false)\n"
    "        accessRecency = OfflineAccessRecency()\n"
    "        indexIsDirty = false\n",
)
replace_once(
    "BuFi/Core/OfflineStore.swift",
    "            if Date().timeIntervalSince(entry.lastAccessedAt) > 3_600 {\n"
    "                entry.lastAccessedAt = Date()\n"
    "                entryChanged = true\n"
    "            }\n",
    "            let now = Date()\n"
    "            if now.timeIntervalSince(entry.lastAccessedAt) > 3_600\n"
    "                || now < entry.lastAccessedAt {\n"
    "                entry.lastAccessedAt = accessRecency.next(\n"
    "                    now: now,\n"
    "                    after: entry.lastAccessedAt\n"
    "                )\n"
    "                entryChanged = true\n"
    "            }\n",
)
replace_once(
    "BuFi/Core/OfflineStore.swift",
    "        let taskKey = scope + \":\" + song.id\n",
    "        let taskKey = OfflineDownloadKey(\n"
    "            accountScope: scope,\n"
    "            songID: song.id\n"
    "        )\n",
)
replace_between(
    "BuFi/Core/OfflineStore.swift",
    "            let values = try temporary.resourceValues(forKeys: [.fileSizeKey])\n",
    "            guard let self else {\n",
    "            let staged = try await Self.stageDownloadedFile(\n"
    "                temporary: temporary,\n"
    "                directory: directory,\n"
    "                fileName: fileName\n"
    "            )\n"
    "            try Task.checkCancellation()\n",
)
replace_once(
    "BuFi/Core/OfflineStore.swift",
    "            guard let self else {\n"
    "                try? FileManager.default.removeItem(at: staging)\n"
    "                throw CancellationError()\n"
    "            }\n"
    "            return try await self.commitDownload(\n"
    "                staging: staging,\n"
    "                destination: destination,\n"
    "                byteCount: bytes,\n",
    "            guard let self else {\n"
    "                try? FileManager.default.removeItem(at: staged.url)\n"
    "                throw CancellationError()\n"
    "            }\n"
    "            return try await self.commitDownload(\n"
    "                staging: staged.url,\n"
    "                destination: destination,\n"
    "                byteCount: staged.byteCount,\n",
)
text = read("BuFi/Core/OfflineStore.swift")
if text.count("taskKey: String") != 3:
    raise RuntimeError("OfflineStore: expected three taskKey String signatures")
write(
    "BuFi/Core/OfflineStore.swift",
    text.replace("taskKey: String", "taskKey: OfflineDownloadKey"),
)
replace_once(
    "BuFi/Core/OfflineStore.swift",
    "                lastAccessedAt: Date(),\n"
    "                mediaRevision: mediaRevision\n",
    "                lastAccessedAt: accessRecency.next(),\n"
    "                mediaRevision: mediaRevision\n",
)
replace_once(
    "BuFi/Core/OfflineStore.swift",
    "        await AppDatabase.shared.clearOfflineEntries(scope: scope)\n",
    "        accessRecency.seed(\n"
    "            lastAccess: entries.values.map(\\.lastAccessedAt).max()\n"
    "        )\n"
    "        await AppDatabase.shared.clearOfflineEntries(scope: scope)\n",
)
replace_once(
    "BuFi/Core/OfflineStore.swift",
    "    private static func loadEntries(indexURL: URL, directory: URL) -> [String: Entry] {\n",
    r'''    private static func validatedDatabaseEntries(
        _ databaseEntries: [String: OfflineDatabaseEntry],
        directory: URL
    ) async -> [String: Entry] {
        let worker = Task.detached(priority: .utility) {
            databaseEntries.reduce(into: [String: Entry]()) { result, pair in
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
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func stageDownloadedFile(
        temporary: URL,
        directory: URL,
        fileName: String
    ) async throws -> StagedDownload {
        let worker = Task.detached(priority: .utility) { () throws -> StagedDownload in
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
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func loadEntries(indexURL: URL, directory: URL) -> [String: Entry] {
''',
)


# Artwork cache: scope and generation are part of coalescing identity.
replace_once(
    "BuFi/Core/ArtworkStore.swift",
    "    private var inFlightPalettes: [String: InFlightPalette] = [:]\n",
    "    private var inFlightPalettes: [ArtworkPaletteRequestKey: InFlightPalette] = [:]\n",
)
replace_once(
    "BuFi/Core/ArtworkStore.swift",
    "                await self.cancelPaletteWaiter(\n"
    "                    cacheKey: cacheKey,\n"
    "                    generation: generation,\n",
    "                await self.cancelPaletteWaiter(\n"
    "                    scope: scope,\n"
    "                    cacheKey: cacheKey,\n"
    "                    generation: generation,\n",
)
replace_once(
    "BuFi/Core/ArtworkStore.swift",
    "        if var pending = inFlightPalettes[cacheKey],\n"
    "           pending.generation == generation {\n"
    "            pending.waiters[waiterID] = continuation\n"
    "            inFlightPalettes[cacheKey] = pending\n"
    "            return\n"
    "        }\n\n"
    "        let requestID = UUID()\n",
    "        let requestKey = ArtworkPaletteRequestKey(\n"
    "            accountScope: scope,\n"
    "            cacheKey: cacheKey,\n"
    "            generation: generation\n"
    "        )\n"
    "        if var pending = inFlightPalettes[requestKey],\n"
    "           pending.generation == generation {\n"
    "            pending.waiters[waiterID] = continuation\n"
    "            inFlightPalettes[requestKey] = pending\n"
    "            return\n"
    "        }\n\n"
    "        let requestID = UUID()\n",
)
replace_once(
    "BuFi/Core/ArtworkStore.swift",
    "            finishPaletteRequest(\n"
    "                cacheKey: cacheKey,\n"
    "                requestID: requestID,\n",
    "            finishPaletteRequest(\n"
    "                scope: scope,\n"
    "                cacheKey: cacheKey,\n"
    "                generation: generation,\n"
    "                requestID: requestID,\n",
)
replace_once(
    "BuFi/Core/ArtworkStore.swift",
    "        inFlightPalettes[cacheKey] = InFlightPalette(\n",
    "        inFlightPalettes[requestKey] = InFlightPalette(\n",
)
replace_once(
    "BuFi/Core/ArtworkStore.swift",
    "    private func cancelPaletteWaiter(\n"
    "        cacheKey: String,\n"
    "        generation: UInt64,\n"
    "        waiterID: UUID\n"
    "    ) {\n"
    "        guard var request = inFlightPalettes[cacheKey],\n"
    "              request.generation == generation,\n",
    "    private func cancelPaletteWaiter(\n"
    "        scope: String,\n"
    "        cacheKey: String,\n"
    "        generation: UInt64,\n"
    "        waiterID: UUID\n"
    "    ) {\n"
    "        let requestKey = ArtworkPaletteRequestKey(\n"
    "            accountScope: scope,\n"
    "            cacheKey: cacheKey,\n"
    "            generation: generation\n"
    "        )\n"
    "        guard var request = inFlightPalettes[requestKey],\n"
    "              request.generation == generation,\n",
)
replace_once(
    "BuFi/Core/ArtworkStore.swift",
    "            inFlightPalettes[cacheKey] = nil\n"
    "        } else {\n"
    "            inFlightPalettes[cacheKey] = request\n"
    "        }\n"
    "    }\n\n"
    "    private func finishPaletteRequest(\n"
    "        cacheKey: String,\n"
    "        requestID: UUID,\n"
    "        value: ArtworkPalette\n"
    "    ) {\n"
    "        guard let request = inFlightPalettes[cacheKey],\n"
    "              request.id == requestID else {\n"
    "            return\n"
    "        }\n"
    "        inFlightPalettes[cacheKey] = nil\n",
    "            inFlightPalettes[requestKey] = nil\n"
    "        } else {\n"
    "            inFlightPalettes[requestKey] = request\n"
    "        }\n"
    "    }\n\n"
    "    private func finishPaletteRequest(\n"
    "        scope: String,\n"
    "        cacheKey: String,\n"
    "        generation: UInt64,\n"
    "        requestID: UUID,\n"
    "        value: ArtworkPalette\n"
    "    ) {\n"
    "        let requestKey = ArtworkPaletteRequestKey(\n"
    "            accountScope: scope,\n"
    "            cacheKey: cacheKey,\n"
    "            generation: generation\n"
    "        )\n"
    "        guard let request = inFlightPalettes[requestKey],\n"
    "              request.id == requestID else {\n"
    "            return\n"
    "        }\n"
    "        inFlightPalettes[requestKey] = nil\n",
)


# Home snapshot cache: explicit Sendable payload and bounded wall-clock skew.
replace_once(
    "BuFi/Core/HomeSnapshotStore.swift",
    "    private struct CachedSnapshot: Codable {\n",
    "    private struct CachedSnapshot: Codable, Sendable {\n",
)
replace_once(
    "BuFi/Core/HomeSnapshotStore.swift",
    "                  Date().timeIntervalSince(cached.savedAt) <= maximumAge else {\n",
    "                  CacheFreshnessPolicy.isFresh(\n"
    "                    savedAt: cached.savedAt,\n"
    "                    maximumAge: maximumAge\n"
    "                  ) else {\n",
)


# Listening history: make the reentrant database suspension boundary explicit
# with an immutable Sendable batch.
replace_once(
    "BuFi/Core/ListeningHistoryStore.swift",
    "actor ListeningHistoryStore {\n"
    "    static let shared = ListeningHistoryStore()\n\n",
    "actor ListeningHistoryStore {\n"
    "    static let shared = ListeningHistoryStore()\n\n"
    "    private struct PersistenceBatch: Sendable {\n"
    "        let scope: String\n"
    "        let generation: UInt64\n"
    "        let dirty: [String: SongBehavior]\n"
    "        let deleted: Set<String>\n"
    "    }\n\n",
)
replace_once(
    "BuFi/Core/ListeningHistoryStore.swift",
    "        let dirty = Dictionary(uniqueKeysWithValues: dirtySongIDs.compactMap { id in\n"
    "            entries[id].map { (id, $0) }\n"
    "        })\n"
    "        let deleted = deletedSongIDs\n"
    "        guard await AppDatabase.shared.applyListeningHistory(\n"
    "            dirty,\n"
    "            deletedIDs: deleted,\n"
    "            scope: scope\n"
    "        ) else { return }\n",
    "        let batch = PersistenceBatch(\n"
    "            scope: scope,\n"
    "            generation: generation,\n"
    "            dirty: Dictionary(\n"
    "                uniqueKeysWithValues: dirtySongIDs.compactMap { id in\n"
    "                    entries[id].map { (id, $0) }\n"
    "                }\n"
    "            ),\n"
    "            deleted: deletedSongIDs\n"
    "        )\n"
    "        guard await AppDatabase.shared.applyListeningHistory(\n"
    "            batch.dirty,\n"
    "            deletedIDs: batch.deleted,\n"
    "            scope: batch.scope\n"
    "        ) else { return }\n",
)
replace_once(
    "BuFi/Core/ListeningHistoryStore.swift",
    "        for (id, savedValue) in dirty where entries[id] == savedValue {\n"
    "            dirtySongIDs.remove(id)\n"
    "        }\n"
    "        for id in deleted where entries[id] == nil {\n"
    "            deletedSongIDs.remove(id)\n"
    "        }\n",
    "        guard batch.generation == generation else { return }\n"
    "        for (id, savedValue) in batch.dirty where entries[id] == savedValue {\n"
    "            dirtySongIDs.remove(id)\n"
    "        }\n"
    "        for id in batch.deleted where entries[id] == nil {\n"
    "            deletedSongIDs.remove(id)\n"
    "        }\n",
)


# Remove the unused dependency's license section and update Nuke metadata.
license_path = "BuFi/Resources/ThirdPartyLicenses.txt"
license_text = read(license_path)
start = license_text.find("SwiftSonic 0.9.0\n")
end_marker = "Nuke 13.0.6\n"
end = license_text.find(end_marker)
if start < 0 or end < 0 or end <= start:
    raise RuntimeError("ThirdPartyLicenses: SwiftSonic/Nuke markers missing")
# Keep the separator immediately before Nuke.
separator = "-------------------------------------------------------------------------------\n\n"
prefix = license_text[:start]
if prefix.endswith(separator):
    prefix = prefix[: -len(separator)]
license_text = prefix + separator + license_text[end:]
license_text = license_text.replace("Nuke 13.0.6", "Nuke 13.1.0")
license_text = license_text.replace("Nuke/tree/13.0.6", "Nuke/tree/13.1.0")
license_text = license_text.replace("Nuke/blob/13.0.6/LICENSE", "Nuke/blob/13.1.0/LICENSE")
write(license_path, license_text)


# The old document exists solely for the now-removed OS-specific artifact.
ios27_doc = Path("Docs/IOS27_BETA_INSTALLATION.md")
if ios27_doc.exists():
    ios27_doc.unlink()

# Sanity checks before CI compilation.
project = read("project.yml")
if "SwiftSonic" in project or "swiftsonic" in read("Package.resolved").lower():
    raise RuntimeError("SwiftSonic removal incomplete")
if 'xcodeVersion: "27.0"' not in project:
    raise RuntimeError("Xcode 27 project version missing")
if "OfflineDownloadKey" not in read("BuFi/Core/OfflineStore.swift"):
    raise RuntimeError("Offline typed key patch missing")
if "ArtworkPaletteRequestKey" not in read("BuFi/Core/ArtworkStore.swift"):
    raise RuntimeError("Artwork typed key patch missing")
