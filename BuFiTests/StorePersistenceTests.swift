import Foundation
import XCTest
@testable import BuFi

final class StorePersistenceTests: XCTestCase {
    func testOfflineScopeGenerationRejectsSupersededLoad() async throws {
        let loadStarted = TestGate()
        let loadRelease = TestGate()
        let root = try makeOfflineRoot(filesByScope: [
            "account-a": ["a.audio"],
            "account-b": ["b.audio"]
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = OfflinePersistenceFake(
            valuesByScope: [
                "account-a": ["a": offlineEntry(fileName: "a.audio")],
                "account-b": ["b": offlineEntry(fileName: "b.audio")]
            ],
            blockedLoadScope: "account-a",
            loadStarted: loadStarted,
            loadRelease: loadRelease
        )
        let store = OfflineStore(database: persistence, storageRoot: root)

        let supersededActivation = Task {
            await store.activate(accountScope: "account-a")
        }
        await loadStarted.wait()
        let replacementActivated = await store.activate(accountScope: "account-b")
        await loadRelease.open()
        let supersededResult = await supersededActivation.value

        let available = await store.availableSongIDs()
        let replacementIsActive = await store.isActive(accountScope: "account-b")
        XCTAssertTrue(replacementActivated)
        XCTAssertFalse(supersededResult)
        XCTAssertTrue(replacementIsActive)
        XCTAssertEqual(available, Set(["b"]))
    }

    func testOfflineDirtyMutationDuringWriteGetsFollowUpPersistence() async throws {
        let applyStarted = TestGate()
        let applyRelease = TestGate()
        let root = try makeOfflineRoot(filesByScope: [
            "account-a": ["one.audio", "two.audio"]
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = OfflinePersistenceFake(
            valuesByScope: [
                "account-a": [
                    "one": offlineEntry(fileName: "one.audio"),
                    "two": offlineEntry(fileName: "two.audio")
                ]
            ],
            blockedApplyCall: 1,
            applyStarted: applyStarted,
            applyRelease: applyRelease
        )
        let store = OfflineStore(database: persistence, storageRoot: root)
        await store.activate(accountScope: "account-a")

        let firstURL = await store.localURL(for: "one")
        XCTAssertNotNil(firstURL)
        let flush = Task { await store.flushPendingWrites() }
        await applyStarted.wait()
        let secondURL = await store.localURL(for: "two")
        XCTAssertNotNil(secondURL)
        await applyRelease.open()
        await flush.value

        var persistedSecondMutation = false
        for _ in 0..<100 {
            let calls = await persistence.appliedSongIDs()
            if calls.contains("two") {
                persistedSecondMutation = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(persistedSecondMutation)
        let applyCallCount = await persistence.applyCallCount()
        XCTAssertGreaterThanOrEqual(applyCallCount, 2)
    }

    func testOfflineTransitionFailureKeepsPreviousScopeAndRetriesLater() async throws {
        let root = try makeOfflineRoot(filesByScope: [
            "account-a": ["a.audio"],
            "account-b": ["b.audio"]
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = OfflinePersistenceFake(valuesByScope: [
            "account-a": ["a": offlineEntry(fileName: "a.audio")],
            "account-b": ["b": offlineEntry(fileName: "b.audio")]
        ])
        let store = OfflineStore(database: persistence, storageRoot: root)
        await store.activate(accountScope: "account-a")
        let localURL = await store.localURL(for: "a")
        XCTAssertNotNil(localURL)
        await persistence.setRemainingApplyFailures(Int.max)

        let activated = await store.activate(accountScope: "account-b")

        let availableAfterFailure = await store.availableSongIDs()
        let loadedScopes = await persistence.loadedScopes()
        let previousIsActive = await store.isActive(accountScope: "account-a")
        let replacementIsActive = await store.isActive(accountScope: "account-b")
        XCTAssertFalse(activated)
        XCTAssertTrue(previousIsActive)
        XCTAssertFalse(replacementIsActive)
        XCTAssertEqual(availableAfterFailure, Set(["a"]))
        XCTAssertFalse(loadedScopes.contains("account-b"))

        await persistence.setRemainingApplyFailures(0)
        await store.flushPendingWrites()
        let persisted = await persistence.values(scope: "account-a")
        XCTAssertNotNil(persisted["a"])
    }

    func testStorageLimitConversionValidatesAndClamps() {
        XCTAssertNil(OfflineStore.storageLimitBytes(configuredGigabytes: 0))
        XCTAssertNil(OfflineStore.storageLimitBytes(configuredGigabytes: -1))
        XCTAssertNil(OfflineStore.storageLimitBytes(configuredGigabytes: .nan))
        XCTAssertNil(OfflineStore.storageLimitBytes(configuredGigabytes: .infinity))
        XCTAssertEqual(
            OfflineStore.storageLimitBytes(configuredGigabytes: 1),
            1_073_741_824
        )
        XCTAssertEqual(
            OfflineStore.storageLimitBytes(
                configuredGigabytes: .greatestFiniteMagnitude
            ),
            Int64.max
        )
        XCTAssertEqual(
            OfflineStore.storageLimitBytes(
                configuredGigabytes: .leastNonzeroMagnitude
            ),
            1
        )
        let defaultLimit: Int64 = 10_737_418_240
        XCTAssertEqual(
            OfflineStore.effectiveStorageLimitBytes(configuredGigabytes: nil),
            defaultLimit
        )
        XCTAssertEqual(
            OfflineStore.effectiveStorageLimitBytes(configuredGigabytes: .nan),
            defaultLimit
        )
        XCTAssertEqual(
            OfflineStore.effectiveStorageLimitBytes(configuredGigabytes: .infinity),
            defaultLimit
        )
        XCTAssertEqual(
            OfflineStore.effectiveStorageLimitBytes(
                configuredGigabytes: -Double.infinity
            ),
            defaultLimit
        )
        XCTAssertNil(
            OfflineStore.effectiveStorageLimitBytes(configuredGigabytes: 0)
        )
    }

    func testListeningHistoryScopeGenerationRejectsSupersededLoad() async {
        let loadStarted = TestGate()
        let loadRelease = TestGate()
        let persistence = ListeningPersistenceFake(
            valuesByScope: [
                "account-a": ["a": behavior(id: "a", playCount: 1)],
                "account-b": ["b": behavior(id: "b", playCount: 2)]
            ],
            blockedLoadScope: "account-a",
            loadStarted: loadStarted,
            loadRelease: loadRelease
        )
        let store = ListeningHistoryStore(database: persistence)

        let supersededActivation = Task {
            await store.activate(accountScope: "account-a")
        }
        await loadStarted.wait()
        let replacementActivated = await store.activate(accountScope: "account-b")
        await loadRelease.open()
        let supersededResult = await supersededActivation.value

        let snapshot = await store.recommendationSnapshot()
        let replacementIsActive = await store.isActive(accountScope: "account-b")
        XCTAssertTrue(replacementActivated)
        XCTAssertFalse(supersededResult)
        XCTAssertTrue(replacementIsActive)
        XCTAssertEqual(Set(snapshot.songs.keys), Set(["b"]))
        XCTAssertEqual(snapshot.recentSongs.map(\.id), ["b"])
    }

    func testListeningHistoryRetriesBoundedlyBeforeAcknowledgingDirtyState() async {
        let persistence = ListeningPersistenceFake(
            valuesByScope: [:],
            remainingApplyFailures: 2
        )
        let store = ListeningHistoryStore(database: persistence)
        await store.activate(accountScope: "account-a")
        await store.recordStart(
            song(id: "one"),
            accountScope: "account-a",
            origin: .manual,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        await store.flushPendingWrites()

        let calls = await persistence.applyCallCount()
        let stored = await persistence.values(scope: "account-a")
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(stored["one"]?.playCount, 1)
    }

    func testListeningHistoryKeepsNewerMutationDirtyDuringWrite() async {
        let applyStarted = TestGate()
        let applyRelease = TestGate()
        let persistence = ListeningPersistenceFake(
            valuesByScope: [:],
            blockedApplyCall: 1,
            applyStarted: applyStarted,
            applyRelease: applyRelease
        )
        let store = ListeningHistoryStore(database: persistence)
        await store.activate(accountScope: "account-a")
        let value = song(id: "one")
        await store.recordStart(
            value,
            accountScope: "account-a",
            origin: .manual
        )

        let flush = Task { await store.flushPendingWrites() }
        await applyStarted.wait()
        await store.recordStart(
            value,
            accountScope: "account-a",
            origin: .manual
        )
        await applyRelease.open()
        await flush.value

        let calls = await persistence.applyCallCount()
        let stored = await persistence.values(scope: "account-a")
        XCTAssertGreaterThanOrEqual(calls, 2)
        XCTAssertEqual(stored["one"]?.playCount, 2)
    }

    func testListeningHistoryTransitionFailureKeepsPreviousScope() async {
        let persistence = ListeningPersistenceFake(valuesByScope: [:])
        let store = ListeningHistoryStore(database: persistence)
        await store.activate(accountScope: "account-a")
        await store.recordStart(
            song(id: "one"),
            accountScope: "account-a",
            origin: .manual
        )
        await persistence.setRemainingApplyFailures(Int.max)

        let activated = await store.activate(accountScope: "account-b")

        let snapshot = await store.recommendationSnapshot()
        let loadedScopes = await persistence.loadedScopes()
        let previousIsActive = await store.isActive(accountScope: "account-a")
        let replacementIsActive = await store.isActive(accountScope: "account-b")
        XCTAssertFalse(activated)
        XCTAssertTrue(previousIsActive)
        XCTAssertFalse(replacementIsActive)
        XCTAssertEqual(Set(snapshot.songs.keys), Set(["one"]))
        XCTAssertFalse(loadedScopes.contains("account-b"))

        await persistence.setRemainingApplyFailures(0)
        await store.flushPendingWrites()
        let stored = await persistence.values(scope: "account-a")
        XCTAssertEqual(stored["one"]?.playCount, 1)
    }

    func testListeningHistoryRejectsMutationsForStaleAccountScope() async {
        let persistence = ListeningPersistenceFake(valuesByScope: [:])
        let store = ListeningHistoryStore(database: persistence)
        let value = song(id: "one")
        let activated = await store.activate(accountScope: "account-b")
        XCTAssertTrue(activated)

        await store.recordStart(
            value,
            accountScope: "account-a",
            origin: .manual
        )
        await store.recordQueueRemoval(
            value,
            accountScope: "account-a"
        )
        await store.recordFavorite(
            value,
            accountScope: "account-a",
            enabled: true
        )
        await store.recordEnd(
            value,
            accountScope: "account-a",
            playedSeconds: 30,
            duration: 30,
            reason: .completed
        )

        let snapshot = await store.recommendationSnapshot()
        XCTAssertTrue(snapshot.songs.isEmpty)
    }

    private func makeOfflineRoot(
        filesByScope: [String: [String]]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        for (scope, files) in filesByScope {
            let directory = root.appendingPathComponent(scope, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            for file in files {
                try Data([1]).write(to: directory.appendingPathComponent(file))
            }
        }
        return root
    }

    private func offlineEntry(fileName: String) -> OfflineDatabaseEntry {
        OfflineDatabaseEntry(
            fileName: fileName,
            byteCount: 1,
            lastAccessedAt: .distantPast
        )
    }

    private func song(id: String) -> Song {
        Song(
            id: id,
            title: "Song \(id)",
            artist: "Artist",
            album: "Album"
        )
    }

    private func behavior(id: String, playCount: Int) -> SongBehavior {
        var value = SongBehavior(
            song: song(id: id),
            at: Date(timeIntervalSince1970: 1_800_000_000 + Double(playCount))
        )
        value.playCount = playCount
        return value
    }
}

private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}

private actor OfflinePersistenceFake: OfflineEntryPersistence {
    private var valuesByScope: [String: [String: OfflineDatabaseEntry]]
    private let blockedLoadScope: String?
    private let loadStarted: TestGate?
    private let loadRelease: TestGate?
    private let blockedApplyCall: Int?
    private let applyStarted: TestGate?
    private let applyRelease: TestGate?
    private var remainingApplyFailures: Int
    private var applyCalls = 0
    private var loadedScopeValues: [String] = []
    private var appliedIDs: Set<String> = []

    init(
        valuesByScope: [String: [String: OfflineDatabaseEntry]],
        blockedLoadScope: String? = nil,
        loadStarted: TestGate? = nil,
        loadRelease: TestGate? = nil,
        blockedApplyCall: Int? = nil,
        applyStarted: TestGate? = nil,
        applyRelease: TestGate? = nil,
        remainingApplyFailures: Int = 0
    ) {
        self.valuesByScope = valuesByScope
        self.blockedLoadScope = blockedLoadScope
        self.loadStarted = loadStarted
        self.loadRelease = loadRelease
        self.blockedApplyCall = blockedApplyCall
        self.applyStarted = applyStarted
        self.applyRelease = applyRelease
        self.remainingApplyFailures = remainingApplyFailures
    }

    func loadOfflineEntries(
        scope: String
    ) async -> [String: OfflineDatabaseEntry] {
        loadedScopeValues.append(scope)
        if scope == blockedLoadScope {
            await loadStarted?.open()
            await loadRelease?.wait()
        }
        return valuesByScope[scope] ?? [:]
    }

    func applyOfflineEntries(
        _ values: [String: OfflineDatabaseEntry],
        deletedIDs: Set<String>,
        scope: String
    ) async -> Bool {
        applyCalls += 1
        let call = applyCalls
        if call == blockedApplyCall {
            await applyStarted?.open()
            await applyRelease?.wait()
        }
        if remainingApplyFailures > 0 {
            remainingApplyFailures -= 1
            return false
        }
        var stored = valuesByScope[scope] ?? [:]
        deletedIDs.forEach { stored[$0] = nil }
        values.forEach { stored[$0.key] = $0.value }
        valuesByScope[scope] = stored
        appliedIDs.formUnion(values.keys)
        return true
    }

    func replaceOfflineEntries(
        _ values: [String: OfflineDatabaseEntry],
        scope: String
    ) async -> Bool {
        valuesByScope[scope] = values
        return true
    }

    func clearOfflineEntries(scope: String) async {
        valuesByScope[scope] = [:]
    }

    func setRemainingApplyFailures(_ value: Int) {
        remainingApplyFailures = value
    }

    func values(scope: String) -> [String: OfflineDatabaseEntry] {
        valuesByScope[scope] ?? [:]
    }

    func appliedSongIDs() -> Set<String> {
        appliedIDs
    }

    func applyCallCount() -> Int {
        applyCalls
    }

    func loadedScopes() -> [String] {
        loadedScopeValues
    }
}

private actor ListeningPersistenceFake: ListeningHistoryPersistence {
    private var valuesByScope: [String: [String: SongBehavior]]
    private let blockedLoadScope: String?
    private let loadStarted: TestGate?
    private let loadRelease: TestGate?
    private let blockedApplyCall: Int?
    private let applyStarted: TestGate?
    private let applyRelease: TestGate?
    private var remainingApplyFailures: Int
    private var applyCalls = 0
    private var loadedScopeValues: [String] = []

    init(
        valuesByScope: [String: [String: SongBehavior]],
        blockedLoadScope: String? = nil,
        loadStarted: TestGate? = nil,
        loadRelease: TestGate? = nil,
        blockedApplyCall: Int? = nil,
        applyStarted: TestGate? = nil,
        applyRelease: TestGate? = nil,
        remainingApplyFailures: Int = 0
    ) {
        self.valuesByScope = valuesByScope
        self.blockedLoadScope = blockedLoadScope
        self.loadStarted = loadStarted
        self.loadRelease = loadRelease
        self.blockedApplyCall = blockedApplyCall
        self.applyStarted = applyStarted
        self.applyRelease = applyRelease
        self.remainingApplyFailures = remainingApplyFailures
    }

    func loadListeningHistory(
        scope: String
    ) async -> [String: SongBehavior] {
        loadedScopeValues.append(scope)
        if scope == blockedLoadScope {
            await loadStarted?.open()
            await loadRelease?.wait()
        }
        return valuesByScope[scope] ?? [:]
    }

    func applyListeningHistory(
        _ values: [String: SongBehavior],
        deletedIDs: Set<String>,
        scope: String
    ) async -> Bool {
        applyCalls += 1
        let call = applyCalls
        if call == blockedApplyCall {
            await applyStarted?.open()
            await applyRelease?.wait()
        }
        if remainingApplyFailures > 0 {
            remainingApplyFailures -= 1
            return false
        }
        var stored = valuesByScope[scope] ?? [:]
        deletedIDs.forEach { stored[$0] = nil }
        values.forEach { stored[$0.key] = $0.value }
        valuesByScope[scope] = stored
        return true
    }

    func replaceListeningHistory(
        _ values: [String: SongBehavior],
        scope: String
    ) async -> Bool {
        valuesByScope[scope] = values
        return true
    }

    func clearListeningHistory(scope: String) async {
        valuesByScope[scope] = [:]
    }

    func values(scope: String) -> [String: SongBehavior] {
        valuesByScope[scope] ?? [:]
    }

    func applyCallCount() -> Int {
        applyCalls
    }

    func setRemainingApplyFailures(_ value: Int) {
        remainingApplyFailures = value
    }

    func loadedScopes() -> [String] {
        loadedScopeValues
    }
}
