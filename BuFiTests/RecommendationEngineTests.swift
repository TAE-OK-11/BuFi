import Foundation
import XCTest
@testable import BuFi

final class RecommendationEngineTests: XCTestCase {
    func testCanonicalVersionsAreDeduplicated() {
        let original = song(
            id: "original",
            title: "Midnight Rain",
            artist: "Taylor Swift"
        )
        let remaster = song(
            id: "remaster",
            title: "Midnight Rain (Remastered 2026)",
            artist: "Taylor Swift"
        )
        let snapshot = HomeSnapshot(randomSongs: [original, remaster])

        let result = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: weights(),
            limit: 10,
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(result.count, 1)
    }

    func testExternalConsensusRanksAboveSingleSource() {
        let consensus = song(
            id: "consensus",
            title: "Consensus",
            artist: "Artist A",
            genre: "Pop"
        )
        let singleSource = song(
            id: "single",
            title: "Single",
            artist: "Artist B",
            genre: "Rock"
        )
        let snapshot = HomeSnapshot(
            starredSongs: [
                song(
                    id: "favorite",
                    title: "Favorite",
                    artist: "Favorite Artist",
                    genre: "Pop",
                    starred: "2026-07-29T00:00:00Z"
                )
            ],
            lastFMRecommendedSongs: [singleSource, consensus],
            listenBrainzRecommendedSongs: [consensus]
        )

        let result = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: weights(),
            purpose: .discovery,
            limit: 2,
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(result.first?.id, consensus.id)
    }

    func testLimitAndIdentityDeduplicationAreStable() {
        let repeated = (0..<12).flatMap { index -> [Song] in
            let value = song(
                id: "song-\(index)",
                title: "Track \(index)",
                artist: "Artist \(index % 4)"
            )
            return [value, value]
        }
        let snapshot = HomeSnapshot(
            randomSongs: repeated,
            serverRecommendedSongs: Array(repeated.reversed())
        )
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        let first = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: weights(),
            limit: 8,
            date: date
        )
        let second = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: weights(),
            limit: 8,
            date: date
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 8)
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
    }

    func testCacheInvalidatesWhenPreparedRecommendationSourcesChange() {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let firstSong = song(
            id: "prepared-a",
            title: "Prepared A",
            artist: "Artist A"
        )
        let secondSong = song(
            id: "prepared-b",
            title: "Prepared B",
            artist: "Artist B"
        )

        let first = RecommendationMixer.mix(
            snapshot: HomeSnapshot(recommendedSongs: [firstSong]),
            weights: weights(),
            limit: 1,
            date: date
        )
        let second = RecommendationMixer.mix(
            snapshot: HomeSnapshot(recommendedSongs: [secondSong]),
            weights: weights(),
            limit: 1,
            date: date
        )

        XCTAssertEqual(first.map(\.id), [firstSong.id])
        XCTAssertEqual(second.map(\.id), [secondSong.id])
    }

    func testDerivedRecommendationsDoNotOverrideCurrentSourceCandidates() {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let current = song(
            id: "current-source",
            title: "Current",
            artist: "Current Artist"
        )
        let stale = song(
            id: "stale-derived",
            title: "Stale",
            artist: "Stale Artist"
        )

        let result = RecommendationMixer.mix(
            snapshot: HomeSnapshot(
                randomSongs: [current],
                recommendedSongs: [stale],
                daylistSongs: [stale]
            ),
            weights: weights(),
            limit: 10,
            date: date
        )

        XCTAssertEqual(result, [current])
    }

    func testCacheInvalidatesWhenSongMetadataChangesWithoutChangingID() {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let original = song(
            id: "metadata-stable-id",
            title: "Original Title",
            artist: "Original Artist",
            genre: "Rock"
        )
        var updated = original
        updated.title = "Updated Title"
        updated.artist = "Updated Artist"
        updated.genre = "Jazz"
        updated.playCount = 42

        let first = RecommendationMixer.mix(
            snapshot: HomeSnapshot(randomSongs: [original]),
            weights: weights(),
            limit: 1,
            date: date
        )
        let second = RecommendationMixer.mix(
            snapshot: HomeSnapshot(randomSongs: [updated]),
            weights: weights(),
            limit: 1,
            date: date
        )

        XCTAssertEqual(first.first?.title, original.title)
        XCTAssertEqual(second, [updated])
    }

    func testCacheUsesExactWeightBitPatterns() {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        // These IDs have the same stable jitter bucket for this date, so the
        // ordering changes only when the history weight crosses the exact
        // server-weight threshold below.
        let historyCandidate = song(
            id: "weight-candidate-8",
            title: "History Candidate",
            artist: "History Artist"
        )
        let serverCandidate = song(
            id: "weight-candidate-176",
            title: "Server Candidate",
            artist: "Server Artist"
        )
        let historySeed = song(
            id: "weight-history-seed",
            title: "History Seed",
            artist: historyCandidate.artist
        )
        var historyBehavior = SongBehavior(song: historySeed, at: date)
        historyBehavior.playCount = 5
        historyBehavior.manualPlayCount = 5
        let behavior = RecommendationBehaviorSnapshot(
            songs: [historySeed.id: historyBehavior],
            recentSongs: [historySeed],
            revision: 41
        )
        let snapshot = HomeSnapshot(
            randomSongs: [historyCandidate],
            serverRecommendedSongs: [serverCandidate]
        )

        let lower = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: isolatedWeights(
                history: 0.7998,
                serverSimilarity: 0.5
            ),
            purpose: .artistMix,
            behavior: behavior,
            limit: 2,
            date: date
        )
        let higher = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: isolatedWeights(
                history: 0.8002,
                serverSimilarity: 0.5
            ),
            purpose: .artistMix,
            behavior: behavior,
            limit: 2,
            date: date
        )

        XCTAssertEqual(lower.first?.id, serverCandidate.id)
        XCTAssertEqual(higher.first?.id, historyCandidate.id)
    }

    func testDaylistFallbackFillsSongsRejectedByArtistCap() {
        let songs = (0..<10).map { index in
            song(
                id: "same-artist-\(index)",
                title: "Track \(index)",
                artist: "Same Artist"
            )
        }

        let result = DaylistBuilder.make(
            snapshot: HomeSnapshot(mostPlayedSongs: songs),
            date: Date(timeIntervalSince1970: 1_800_000_000),
            limit: 6
        )

        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(Set(result.map(\.id)).count, 6)
    }

    func testNegativeOnlyBehaviorDoesNotCreatePositiveAffinity() throws {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let candidates = (0..<12).map { index in
            song(
                id: "negative-profile-candidate-\(index)",
                title: "Candidate \(index)",
                artist: "Candidate Artist \(index)"
            )
        }
        let snapshot = HomeSnapshot(randomSongs: candidates)
        let scoringWeights = isolatedWeights(history: 1)
        let baseline = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: scoringWeights,
            limit: candidates.count,
            date: date
        )
        let target = try XCTUnwrap(baseline.last)
        let removedSong = song(
            id: "queue-removed-only",
            title: "Removed",
            artist: target.artist
        )
        var negativeOnly = SongBehavior(song: removedSong, at: date)
        negativeOnly.queueRemovalCount = 5
        let behavior = RecommendationBehaviorSnapshot(
            songs: [removedSong.id: negativeOnly],
            recentSongs: [removedSong],
            revision: 1
        )

        let result = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: scoringWeights,
            behavior: behavior,
            limit: candidates.count,
            date: date
        )

        XCTAssertEqual(result.map(\.id), baseline.map(\.id))
    }

    func testRecentContextRequiresAnActualPlay() throws {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let candidates = (0..<12).map { index in
            song(
                id: "context-candidate-\(index)",
                title: "Context Candidate \(index)",
                artist: "Context Artist \(index)"
            )
        }
        let snapshot = HomeSnapshot(randomSongs: candidates)
        let scoringWeights = isolatedWeights(context: 1)
        let baseline = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: scoringWeights,
            limit: candidates.count,
            date: date
        )
        let target = try XCTUnwrap(baseline.last)
        let unplayedSong = song(
            id: "unplayed-favorite",
            title: "Unplayed",
            artist: target.artist
        )
        var unplayedFavorite = SongBehavior(song: unplayedSong, at: date)
        unplayedFavorite.favoriteCount = 1
        let behavior = RecommendationBehaviorSnapshot(
            songs: [unplayedSong.id: unplayedFavorite],
            recentSongs: [unplayedSong],
            revision: 2
        )

        let result = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: scoringWeights,
            behavior: behavior,
            limit: candidates.count,
            date: date
        )

        XCTAssertEqual(result.map(\.id), baseline.map(\.id))
    }

    func testCancelledRecommendationMixDoesNotCachePartialResults() async {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let candidates = (0..<8_192).map { index in
            song(
                id: "cancel-candidate-\(index)",
                title: "Cancel Candidate \(index)",
                artist: "Cancel Artist \(index)"
            )
        }
        let snapshot = HomeSnapshot(randomSongs: candidates)
        let scoringWeights = weights()
        let task = Task.detached(priority: .userInitiated) {
            RecommendationMixer.mix(
                snapshot: snapshot,
                weights: scoringWeights,
                limit: 30,
                date: date
            )
        }

        task.cancel()
        let cancelledResult = await task.value
        XCTAssertTrue(cancelledResult.isEmpty)

        let completedResult = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: scoringWeights,
            limit: 30,
            date: date
        )
        XCTAssertEqual(completedResult.count, 30)
    }

    func testLocalRecommendationSnapshotDropsRemovedExternalOutput() async {
        RecommendationMixer.invalidateCache()
        let current = song(
            id: "current-local-source",
            title: "Current Local Source",
            artist: "Current Artist"
        )
        let staleExternal = song(
            id: "stale-external-output",
            title: "Stale External Output",
            artist: "Stale Artist"
        )
        let source = HomeSnapshot(
            randomSongs: [current],
            lastFMRecommendedSongs: [],
            listenBrainzRecommendedSongs: [],
            recommendedSongs: [staleExternal],
            daylistSongs: [staleExternal]
        )

        let rebuilt = await AppModel.localRecommendationSnapshot(
            from: source,
            weights: weights(),
            behavior: .empty
        )

        XCTAssertTrue(rebuilt.lastFMRecommendedSongs.isEmpty)
        XCTAssertTrue(rebuilt.listenBrainzRecommendedSongs.isEmpty)
        XCTAssertEqual(rebuilt.recommendedSongs, [current])
        XCTAssertEqual(rebuilt.daylistSongs, [current])
    }

    func testPersonalizedMixesProvideSixDefaultAndFourSelectedArtists() {
        let songs = (0..<12).map { index in
            song(
                id: "artist-track-\(index)",
                title: "Track \(index)",
                artist: "Artist \(index)",
                genre: index.isMultiple(of: 2) ? "Pop" : "Rock"
            )
        }
        let selected = ["Artist 8", "Artist 9", "Artist 10", "Artist 11"]
        let mixes = PersonalizedMixBuilder.make(
            snapshot: HomeSnapshot(randomSongs: songs),
            date: Date(timeIntervalSince1970: 1_800_000_000),
            selectedArtists: selected
        )
        let artistMixes = mixes.filter { $0.kind == .artist }

        XCTAssertEqual(artistMixes.count, 10)
        for artist in selected {
            XCTAssertTrue(artistMixes.contains { $0.title == "\(artist) Mix" })
        }
    }

    func testPersonalizedMixIdentityChangesOnTheNextDay() {
        let songs = (0..<12).map { index in
            song(
                id: "daily-track-\(index)",
                title: "Daily \(index)",
                artist: "Artist \(index % 6)"
            )
        }
        let snapshot = HomeSnapshot(randomSongs: songs)
        let first = PersonalizedMixBuilder.make(
            snapshot: snapshot,
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let nextDay = PersonalizedMixBuilder.make(
            snapshot: snapshot,
            date: Date(timeIntervalSince1970: 1_800_086_400)
        )

        XCTAssertNotEqual(first.map(\.id), nextDay.map(\.id))
    }

    func testPersonalizedMixCacheInvalidatesWithSnapshotContent() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let firstSong = song(
            id: "mix-a",
            title: "Mix A",
            artist: "Artist A"
        )
        let secondSong = song(
            id: "mix-b",
            title: "Mix B",
            artist: "Artist B"
        )

        let first = PersonalizedMixBuilder.make(
            snapshot: HomeSnapshot(randomSongs: [firstSong]),
            date: date,
            songLimit: 1
        )
        let second = PersonalizedMixBuilder.make(
            snapshot: HomeSnapshot(randomSongs: [secondSong]),
            date: date,
            songLimit: 1
        )

        XCTAssertTrue(first.allSatisfy { $0.songs.map(\.id) == [firstSong.id] })
        XCTAssertTrue(second.allSatisfy { $0.songs.map(\.id) == [secondSong.id] })
    }

    func testPersonalizedMixOrderedPrefixMatchesFullOrdering() {
        let seed = 1_800_123
        let limit = 24
        let base = (0..<512).map { index in
            song(
                id: "partial-order-\(index)",
                title: "Partial Order \(index)",
                artist: "Artist \(index % 37)"
            )
        }
        let songs = base + [base[3], base[17], base[3], base[241]]
        let excludedIDs: Set<String> = [
            "partial-order-4",
            "partial-order-109",
            "partial-order-311"
        ]

        let result = PersonalizedMixBuilder.orderedPrefix(
            songs,
            seed: seed,
            limit: limit,
            excluding: excludedIDs
        )
        let expected = legacyPersonalizedOrderedPrefix(
            songs,
            seed: seed,
            limit: limit,
            excluding: excludedIDs
        )

        XCTAssertEqual(result, expected)
        XCTAssertEqual(result.count, limit)
    }

    func testArtistMixPreferencesDeduplicateAndKeepFourRecentArtists() {
        var encoded = "[]"
        for artist in ["A", "B", "C", "D", "E", "B"] {
            encoded = ArtistMixPreferences.adding(artist, to: encoded)
        }

        XCTAssertEqual(
            ArtistMixPreferences.decode(encoded),
            ["B", "E", "D", "C"]
        )
    }

    private func weights() -> RecommendationWeights {
        let defaults = UserDefaults(
            suiteName: "RecommendationEngineTests.\(UUID().uuidString)"
        )!
        return RecommendationWeights.current(defaults)
    }

    private func isolatedWeights(
        history: Double = 0,
        serverSimilarity: Double = 0,
        context: Double = 0
    ) -> RecommendationWeights {
        RecommendationWeights(
            history: history,
            favorites: 0,
            serverSimilarity: serverSimilarity,
            discovery: 0,
            lastFM: 0,
            listenBrainz: 0,
            behavior: 0,
            completion: 0,
            repeatListening: 0,
            recency: 0,
            context: context,
            localMetadata: 0,
            playlistAffinity: 0,
            albumCompletion: 0,
            forgottenFavorites: 0,
            artistRotation: 0,
            timeAwareness: 0,
            discoveryRatio: 0
        )
    }

    private func legacyPersonalizedOrderedPrefix(
        _ songs: [Song],
        seed: Int,
        limit: Int,
        excluding excludedIDs: Set<String>
    ) -> [Song] {
        var seen = Set<String>()
        return Array(
            songs
                .filter { seen.insert($0.id).inserted }
                .enumerated()
                .map { index, song in
                    (
                        index: index,
                        song: song,
                        hash: personalizedStableHash(song.id, seed: seed)
                    )
                }
                .sorted { lhs, rhs in
                    lhs.hash == rhs.hash
                        ? lhs.index < rhs.index
                        : lhs.hash < rhs.hash
                }
                .lazy
                .filter { !excludedIDs.contains($0.song.id) }
                .prefix(limit)
                .map(\.song)
        )
    }

    private func personalizedStableHash(_ value: String, seed: Int) -> UInt64 {
        var hash = UInt64(bitPattern: Int64(seed)) ^ 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private func song(
        id: String,
        title: String,
        artist: String,
        genre: String? = nil,
        starred: String? = nil
    ) -> Song {
        Song(
            id: id,
            title: title,
            artist: artist,
            album: "Album",
            artistId: "artist-\(artist)",
            albumId: "album-\(artist)",
            coverArt: nil,
            duration: 180,
            track: 1,
            suffix: "m4a",
            contentType: "audio/mp4",
            starred: starred,
            genre: genre
        )
    }
}
