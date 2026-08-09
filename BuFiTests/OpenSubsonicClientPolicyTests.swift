import Foundation
import XCTest
@testable import BuFi

final class OpenSubsonicClientPolicyTests: XCTestCase {
    func testStructuralRequestKeyAvoidsDelimiterCollisions() {
        let singleValue = key(
            endpoint: "search3",
            items: [("a", "b&c=d")]
        )
        let multipleValues = key(
            endpoint: "search3",
            items: [("a", "b"), ("c", "d")]
        )
        let equalsInName = key(
            endpoint: "search3",
            items: [("a=b", "c")]
        )
        let equalsInValue = key(
            endpoint: "search3",
            items: [("a", "b=c")]
        )

        XCTAssertNotEqual(singleValue, multipleValues)
        XCTAssertNotEqual(equalsInName, equalsInValue)
    }

    func testStructuralRequestKeyIsOrderIndependentAndPreservesNil() {
        let forward = key(
            endpoint: "savePlayQueue",
            items: [("id", "one"), ("id", "two"), ("current", "one")]
        )
        let reverse = key(
            endpoint: "savePlayQueue",
            items: [("current", "one"), ("id", "two"), ("id", "one")]
        )
        let nilValue = OpenSubsonicRequestKey(
            endpoint: "example",
            queryItems: [URLQueryItem(name: "flag", value: nil)]
        )
        let emptyValue = OpenSubsonicRequestKey(
            endpoint: "example",
            queryItems: [URLQueryItem(name: "flag", value: "")]
        )

        XCTAssertEqual(forward, reverse)
        XCTAssertNotEqual(nilValue, emptyValue)
    }

    func testStarMutationInvalidatesOnlyStarredReads() {
        for mutation in ["star", "unstar"] {
            XCTAssertTrue(invalidates("getStarred", after: mutation))
            XCTAssertTrue(invalidates("getStarred2", after: mutation))
            XCTAssertTrue(
                invalidates(
                    "getAlbumList2",
                    items: [("type", "starred")],
                    after: mutation
                )
            )
            XCTAssertFalse(
                invalidates(
                    "getAlbumList2",
                    items: [("type", "newest")],
                    after: mutation
                )
            )
            XCTAssertFalse(invalidates("getGenres", after: mutation))
            XCTAssertFalse(invalidates("getLyricsBySongId", after: mutation))
            XCTAssertFalse(invalidates("getOpenSubsonicExtensions", after: mutation))
        }
    }

    func testQueueMutationInvalidatesOnlyPlayQueue() {
        XCTAssertTrue(invalidates("getPlayQueue", after: "savePlayQueue"))
        XCTAssertFalse(invalidates("getStarred2", after: "savePlayQueue"))
        XCTAssertFalse(invalidates("getGenres", after: "savePlayQueue"))
    }

    func testPlaybackMutationsInvalidateRecentAndNowPlayingReads() {
        for mutation in ["reportPlayback", "scrobble"] {
            XCTAssertTrue(invalidates("getNowPlaying", after: mutation))
            XCTAssertTrue(invalidates("getNowPlaying2", after: mutation))
            XCTAssertTrue(
                invalidates(
                    "getAlbumList2",
                    items: [("type", "recent"), ("size", "16")],
                    after: mutation
                )
            )
            XCTAssertTrue(
                invalidates(
                    "getAlbumList2",
                    items: [("type", "frequent")],
                    after: mutation
                )
            )
            XCTAssertTrue(
                invalidates(
                    "getAlbumList",
                    items: [("type", "highest")],
                    after: mutation
                )
            )
            XCTAssertFalse(
                invalidates(
                    "getAlbumList2",
                    items: [("type", "newest")],
                    after: mutation
                )
            )
            XCTAssertFalse(invalidates("getGenres", after: mutation))
            XCTAssertFalse(invalidates("getLyricsBySongId", after: mutation))
            XCTAssertFalse(
                invalidates("getOpenSubsonicExtensions", after: mutation)
            )
        }
    }

    func testUnknownMutationConservativelyInvalidatesCachedReads() {
        XCTAssertTrue(invalidates("getGenres", after: "futureMutation"))
    }

    func testCacheEpochRejectsReadCapturedBeforeMutation() {
        var epoch = OpenSubsonicCacheEpoch()
        let beforeMutation = epoch.currentValue

        XCTAssertTrue(epoch.permitsStorage(capturedValue: beforeMutation))
        epoch.advance()

        XCTAssertFalse(epoch.permitsStorage(capturedValue: beforeMutation))
        XCTAssertTrue(
            epoch.permitsStorage(capturedValue: epoch.currentValue)
        )
    }

    func testUnsupportedSearch3IsRememberedForClientSession() {
        var capability = OpenSubsonicSearchCapability()

        XCTAssertTrue(capability.shouldTrySearch3)
        XCTAssertTrue(
            OpenSubsonicSearchCapability.isAuthoritativeUnsupported(
                OpenSubsonicError.http(404)
            )
        )
        XCTAssertTrue(
            OpenSubsonicSearchCapability.isAuthoritativeUnsupported(
                OpenSubsonicError.server(
                    code: nil,
                    message: "Unknown endpoint: search3"
                )
            )
        )
        XCTAssertFalse(
            OpenSubsonicSearchCapability.isAuthoritativeUnsupported(
                OpenSubsonicError.server(
                    code: 70,
                    message: "Requested data was not found"
                )
            )
        )
        XCTAssertFalse(
            OpenSubsonicSearchCapability.isAuthoritativeUnsupported(
                OpenSubsonicError.server(
                    code: nil,
                    message: "search3 temporarily unavailable"
                )
            )
        )
        capability.recordSearch3Unsupported()
        XCTAssertFalse(capability.shouldTrySearch3)
    }

    func testUnsupportedExtensionDiscoveryIsRememberedWithSonicFallback() {
        var state = OpenSubsonicExtensionCapabilityState()
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            state.decision(for: "sonicSimilarity", now: now),
            .discover
        )
        state.recordFailure(OpenSubsonicError.http(404), now: now)

        XCTAssertEqual(
            state.decision(
                for: "sonicSimilarity",
                now: now.addingTimeInterval(3_600)
            ),
            .resolved(true)
        )
        XCTAssertEqual(
            state.decision(for: "playbackReport", now: now),
            .resolved(false)
        )
        XCTAssertEqual(
            state.decision(for: "topSongsByArtistId", now: now),
            .resolved(false)
        )
        XCTAssertTrue(
            OpenSubsonicExtensionCapabilityState.isAuthoritativeUnsupported(
                OpenSubsonicError.server(
                    code: nil,
                    message: "Unknown API endpoint"
                )
            )
        )
        XCTAssertTrue(
            OpenSubsonicExtensionCapabilityState.isAuthoritativeUnsupported(
                OpenSubsonicError.http(405)
            )
        )
        XCTAssertFalse(
            OpenSubsonicExtensionCapabilityState.isAuthoritativeUnsupported(
                OpenSubsonicError.server(
                    code: 70,
                    message: "Requested data was not found"
                )
            )
        )
    }

    func testTransientExtensionDiscoveryFailureUsesShortRetryBackoff() {
        var state = OpenSubsonicExtensionCapabilityState()
        let now = Date(timeIntervalSince1970: 2_000)
        state.recordFailure(URLError(.timedOut), now: now)

        XCTAssertEqual(
            state.decision(for: "sonicSimilarity", now: now),
            .resolved(true)
        )
        XCTAssertEqual(
            state.decision(for: "playbackReport", now: now),
            .resolved(false)
        )
        XCTAssertEqual(
            state.decision(
                for: "sonicSimilarity",
                now: now.addingTimeInterval(
                    OpenSubsonicExtensionCapabilityState
                        .transientFailureBackoff
                )
            ),
            .discover
        )
        XCTAssertFalse(
            OpenSubsonicExtensionCapabilityState.isAuthoritativeUnsupported(
                OpenSubsonicError.http(503)
            )
        )
    }

    func testSuccessfulExtensionDiscoveryCachesAdvertisedCapabilities() {
        var state = OpenSubsonicExtensionCapabilityState()
        let now = Date(timeIntervalSince1970: 3_000)
        state.recordSuccess(["playbackReport", "topSongsByArtistId"])

        XCTAssertEqual(
            state.decision(for: "playbackReport", now: now),
            .resolved(true)
        )
        XCTAssertEqual(
            state.decision(for: "topSongsByArtistId", now: now),
            .resolved(true)
        )
        XCTAssertEqual(
            state.decision(for: "sonicSimilarity", now: now),
            .resolved(false)
        )
    }

    func testExternalIndexPreservesLibraryFirstFuzzyMatch() throws {
        let fuzzyFirst = song(
            id: "fuzzy-first",
            title: "Café Song",
            artist: "The Artist",
            album: "Album"
        )
        let exactLater = song(
            id: "exact-later",
            title: "Cafe Song",
            artist: "Artist",
            album: "Album"
        )
        let index = ExternalRecommendationSongIndex([fuzzyFirst, exactLater])
        let query = try XCTUnwrap(
            ExternalRecommendationMatchQuery(
                title: " CAFE SONG ",
                artist: "Artist",
                album: "Album",
                recordingMBID: nil
            )
        )

        XCTAssertEqual(index.match(query)?.id, fuzzyFirst.id)
        XCTAssertEqual(
            index.firstSong(
                title: "Cafe Song",
                artist: "Artist",
                album: "Album"
            )?.id,
            fuzzyFirst.id
        )
    }

    func testExternalIndexMaintainsMetadataMBIDFallbackPriority() throws {
        let titleFallback = song(
            id: "title-fallback",
            title: "Track",
            artist: "Artist",
            album: "Wrong Album"
        )
        let mbidMatch = song(
            id: "mbid-match",
            title: "Other",
            artist: "Other",
            album: "Other",
            musicBrainzID: "ABC-123"
        )
        let albumMatch = song(
            id: "album-match",
            title: "Track",
            artist: "Artist",
            album: "Wanted Album"
        )
        let index = ExternalRecommendationSongIndex([
            titleFallback,
            mbidMatch,
            albumMatch
        ])

        let primaryMetadata = try XCTUnwrap(
            ExternalRecommendationMatchQuery(
                title: "Track",
                artist: "Artist",
                album: "Wanted Album",
                recordingMBID: "abc-123"
            )
        )
        let mbidBeforeTitleFallback = try XCTUnwrap(
            ExternalRecommendationMatchQuery(
                title: "Track",
                artist: "Artist",
                album: "Missing Album",
                recordingMBID: "abc-123"
            )
        )
        let noAlbumUsesMetadataFirst = try XCTUnwrap(
            ExternalRecommendationMatchQuery(
                title: "Track",
                artist: "Artist",
                album: nil,
                recordingMBID: "abc-123"
            )
        )

        XCTAssertEqual(index.match(primaryMetadata)?.id, albumMatch.id)
        XCTAssertEqual(index.match(mbidBeforeTitleFallback)?.id, mbidMatch.id)
        XCTAssertEqual(index.match(noAlbumUsesMetadataFirst)?.id, titleFallback.id)
        XCTAssertEqual(index.firstSong(recordingMBID: "abc-123")?.id, mbidMatch.id)
        XCTAssertEqual(
            index.firstSong(title: "Track", artist: "Artist")?.id,
            titleFallback.id
        )
    }

    func testExternalIndexKeepsServerTitleContainmentFallback() throws {
        let remaster = song(
            id: "remaster",
            title: "Track (Remastered)",
            artist: "Different Artist",
            album: "Different Album"
        )
        let index = ExternalRecommendationSongIndex([remaster])
        let query = try XCTUnwrap(
            ExternalRecommendationMatchQuery(
                title: "Track",
                artist: "Artist",
                album: "Album",
                recordingMBID: nil
            )
        )

        XCTAssertNil(index.match(query))
        XCTAssertEqual(
            index.match(query, allowsTitleContainmentFallback: true)?.id,
            remaster.id
        )
    }

    func testExternalIndexMatchesLegacyLinearPriorityAcrossQueries() throws {
        let library = [
            song(
                id: "fuzzy",
                title: "Track",
                artist: "The Artist",
                album: "First Album"
            ),
            song(
                id: "exact",
                title: "Track",
                artist: "Artist",
                album: "Second Album"
            ),
            song(
                id: "mbid",
                title: "Unrelated",
                artist: "Someone",
                album: "Elsewhere",
                musicBrainzID: "recording-1"
            ),
            song(
                id: "contains-title",
                title: "Missing Track (Live)",
                artist: "Someone",
                album: "Elsewhere"
            )
        ]
        let queries = [
            try XCTUnwrap(ExternalRecommendationMatchQuery(
                title: "Track",
                artist: "Artist",
                album: "First Album",
                recordingMBID: nil
            )),
            try XCTUnwrap(ExternalRecommendationMatchQuery(
                title: "Track",
                artist: "Artist",
                album: "Missing",
                recordingMBID: "RECORDING-1"
            )),
            try XCTUnwrap(ExternalRecommendationMatchQuery(
                title: "Track",
                artist: "Artist",
                album: nil,
                recordingMBID: "RECORDING-1"
            )),
            try XCTUnwrap(ExternalRecommendationMatchQuery(
                title: "Missing Track",
                artist: "No Match",
                album: "No Match",
                recordingMBID: nil
            ))
        ]
        let index = ExternalRecommendationSongIndex(library)

        for query in queries {
            XCTAssertEqual(
                index.match(
                    query,
                    allowsTitleContainmentFallback: true
                )?.id,
                legacyExternalMatch(
                    query,
                    songs: library,
                    allowsTitleContainmentFallback: true
                )?.id
            )
        }
    }

    func testExternalMatchOrderingPreservesCandidateOrderAndDedupe() {
        let first = song(id: "first", title: "First")
        let second = song(id: "second", title: "Second")
        let third = song(id: "third", title: "Third")
        let values = [
            ExternalRecommendationResolvedSong(candidateIndex: 2, song: second),
            ExternalRecommendationResolvedSong(candidateIndex: 3, song: third),
            ExternalRecommendationResolvedSong(candidateIndex: 1, song: first),
            ExternalRecommendationResolvedSong(candidateIndex: 0, song: first)
        ]

        XCTAssertEqual(
            ExternalRecommendationMatchOrdering
                .orderedUniqueSongs(values)
                .map(\.id),
            ["first", "second", "third"]
        )
    }

    func testOrderedBoundedTaskGroupPreservesOrderAndLimit() async throws {
        let inputs = Array(0..<15)
        let probe = ConcurrencyProbe()

        let values = try await OrderedBoundedTaskGroup.map(
            inputs,
            maximumConcurrentTasks: 3
        ) { value in
            await probe.begin()
            do {
                let delay = UInt64(15 - value) * 1_000_000
                try await Task.sleep(nanoseconds: delay)
                await probe.end()
                return value
            } catch {
                await probe.end()
                throw error
            }
        }

        XCTAssertEqual(values, inputs)
        let maximum = await probe.maximumActiveCount()
        XCTAssertLessThanOrEqual(maximum, 3)
    }

    func testOrderedBoundedTaskGroupPropagatesCancellation() async throws {
        let task = Task {
            try await OrderedBoundedTaskGroup.map(
                Array(0..<6),
                maximumConcurrentTasks: 3
            ) { value in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return value
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("The bounded task group must propagate cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testMetadataLimiterBoundsConcurrentOperations() async throws {
        let limiter = MetadataRequestLimiter(limit: 3)
        let probe = ConcurrencyProbe()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<18 {
                group.addTask {
                    try await limiter.withPermit {
                        await probe.begin()
                        do {
                            try await Task.sleep(nanoseconds: 20_000_000)
                            await probe.end()
                        } catch {
                            await probe.end()
                            throw error
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        let maximum = await probe.maximumActiveCount()
        let snapshot = await limiter.snapshot()
        XCTAssertGreaterThan(maximum, 0)
        XCTAssertLessThanOrEqual(maximum, 3)
        XCTAssertEqual(snapshot.activeCount, 0)
        XCTAssertEqual(snapshot.waitingCount, 0)
    }

    func testMetadataLimiterCancellationDoesNotLeakPermit() async throws {
        let limiter = MetadataRequestLimiter(limit: 1)
        let gate = AsyncGate()
        let holder = Task {
            try await limiter.withPermit {
                await gate.wait()
            }
        }

        try await waitForLimiter(limiter, active: 1, waiting: 0)

        let cancelledWaiter = Task {
            try await limiter.withPermit { 7 }
        }
        try await waitForLimiter(limiter, active: 1, waiting: 1)
        cancelledWaiter.cancel()

        do {
            _ = try await cancelledWaiter.value
            XCTFail("A cancelled queued request must not acquire a permit")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        await gate.open()
        _ = try await holder.value
        let value = try await limiter.withPermit { 42 }
        let snapshot = await limiter.snapshot()

        XCTAssertEqual(value, 42)
        XCTAssertEqual(snapshot.activeCount, 0)
        XCTAssertEqual(snapshot.waitingCount, 0)
    }

    func testMetadataLimiterReleasesActivePermitOnCancellation() async throws {
        let limiter = MetadataRequestLimiter(limit: 1)
        let activeTask = Task {
            try await limiter.withPermit {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        try await waitForLimiter(limiter, active: 1, waiting: 0)
        activeTask.cancel()

        do {
            try await activeTask.value
            XCTFail("Cancelling an active operation must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let value = try await limiter.withPermit { 42 }
        let snapshot = await limiter.snapshot()
        XCTAssertEqual(value, 42)
        XCTAssertEqual(snapshot.activeCount, 0)
        XCTAssertEqual(snapshot.waitingCount, 0)
    }

    private func key(
        endpoint: String,
        items: [(String, String)] = []
    ) -> OpenSubsonicRequestKey {
        OpenSubsonicRequestKey(
            endpoint: endpoint,
            queryItems: items.map { URLQueryItem(name: $0.0, value: $0.1) }
        )
    }

    private func invalidates(
        _ endpoint: String,
        items: [(String, String)] = [],
        after mutation: String
    ) -> Bool {
        OpenSubsonicCacheInvalidationPolicy.shouldInvalidate(
            key(endpoint: endpoint, items: items),
            afterMutation: mutation
        )
    }

    private func waitForLimiter(
        _ limiter: MetadataRequestLimiter,
        active: Int,
        waiting: Int
    ) async throws {
        for _ in 0..<100 {
            let snapshot = await limiter.snapshot()
            if snapshot.activeCount == active,
               snapshot.waitingCount == waiting {
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for limiter state")
    }

    private func song(
        id: String,
        title: String,
        artist: String = "Artist",
        album: String = "Album",
        musicBrainzID: String? = nil
    ) -> Song {
        var value = Song(
            id: id,
            title: title,
            artist: artist,
            album: album,
            artistId: nil,
            albumId: nil,
            coverArt: nil,
            duration: 180,
            track: 1,
            suffix: "m4a",
            contentType: "audio/mp4",
            starred: nil
        )
        value.musicBrainzId = musicBrainzID
        return value
    }

    private func legacyExternalMatch(
        _ query: ExternalRecommendationMatchQuery,
        songs: [Song],
        allowsTitleContainmentFallback: Bool
    ) -> Song? {
        let primary = songs.first {
            legacyMetadataMatch(
                $0,
                title: query.title,
                artist: query.artist,
                album: query.album
            )
        }
        let mbid = query.recordingMBID.flatMap { recordingMBID in
            songs.first {
                guard let value = $0.musicBrainzId else { return false }
                return ExternalRecommendationSongIndex.mbidKey(value)
                    == recordingMBID
            }
        }
        let titleArtist = songs.first {
            legacyMetadataMatch(
                $0,
                title: query.title,
                artist: query.artist,
                album: nil
            )
        }
        let titleContains = allowsTitleContainmentFallback
            ? songs.first {
                ExternalRecommendationSongIndex.normalized($0.title)
                    .contains(query.title)
            }
            : nil
        return primary ?? mbid ?? titleArtist ?? titleContains
    }

    private func legacyMetadataMatch(
        _ song: Song,
        title: String,
        artist: String,
        album: String?
    ) -> Bool {
        let songTitle = ExternalRecommendationSongIndex.normalized(song.title)
        guard songTitle == title, !artist.isEmpty else { return false }
        let songArtist = ExternalRecommendationSongIndex.normalized(song.artist)
        guard songArtist == artist
                || songArtist.contains(artist)
                || artist.contains(songArtist) else {
            return false
        }
        guard let album, !album.isEmpty else { return true }
        return ExternalRecommendationSongIndex.normalized(song.album) == album
    }
}

private actor ConcurrencyProbe {
    private var activeCount = 0
    private var maximumCount = 0

    func begin() {
        activeCount += 1
        maximumCount = max(maximumCount, activeCount)
    }

    func end() {
        activeCount -= 1
    }

    func maximumActiveCount() -> Int {
        maximumCount
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
