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

    func testCacheInvalidatesWhenCandidateMetadataChangesWithoutIDChange() {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let original = song(
            id: "metadata-stable-id",
            title: "Original Title",
            artist: "Artist"
        )
        var updated = original
        updated.title = "Updated Title"
        updated.coverArt = "updated-cover"
        updated.bpm = 128

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

        XCTAssertEqual(first.first?.title, "Original Title")
        XCTAssertEqual(second.first?.title, "Updated Title")
        XCTAssertEqual(second.first?.coverArt, "updated-cover")
        XCTAssertEqual(second.first?.bpm, 128)
    }

    func testCacheFingerprintPreservesSubThousandthWeightChanges() {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let firstSong = song(
            id: "weight-12",
            title: "Weight A",
            artist: "Artist A"
        )
        let secondSong = song(
            id: "weight-95",
            title: "Weight B",
            artist: "Artist B"
        )
        let snapshot = HomeSnapshot(
            randomSongs: [secondSong, firstSong],
            serverRecommendedSongs: [firstSong, secondSong]
        )
        var serverLeaning = isolatedWeights()
        serverLeaning.serverSimilarity = 0.3124
        serverLeaning.discovery = 0.9996
        var discoveryLeaning = serverLeaning
        discoveryLeaning.discovery = 0.9998

        let first = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: serverLeaning,
            purpose: .artistMix,
            limit: 2,
            date: date
        )
        let second = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: discoveryLeaning,
            purpose: .artistMix,
            limit: 2,
            date: date
        )

        XCTAssertEqual(first.first?.id, firstSong.id)
        XCTAssertEqual(second.first?.id, secondSong.id)
    }

    func testDiscoveryRatioHasNoPurposeSpecificDeadZone() {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let known = (0..<6).map { index in
            song(
                id: "known-\(index)",
                title: "Known \(index)",
                artist: "Known Artist \(index)",
                starred: "2026-08-01T00:00:00Z"
            )
        }
        let discoveries = (0..<6).map { index in
            song(
                id: "discovery-\(index)",
                title: "Discovery \(index)",
                artist: "New Artist \(index)"
            )
        }
        let snapshot = HomeSnapshot(
            starredSongs: known,
            randomSongs: discoveries
        )
        var familiarWeights = weights()
        familiarWeights.discoveryRatio = 0
        var discoveryWeights = familiarWeights
        discoveryWeights.discoveryRatio = 1

        let familiarResult = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: familiarWeights,
            purpose: .discovery,
            limit: 4,
            date: date
        )
        let discoveryResult = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: discoveryWeights,
            purpose: .discovery,
            limit: 4,
            date: date
        )

        XCTAssertTrue(familiarResult.allSatisfy { $0.id.hasPrefix("known-") })
        XCTAssertTrue(discoveryResult.allSatisfy {
            $0.id.hasPrefix("discovery-")
        })
    }

    func testBehaviorDictionaryInsertionOrderDoesNotChangeRanking() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let candidates = (0..<20).map { index in
            song(
                id: "candidate-\(index)",
                title: "Candidate \(index)",
                artist: index.isMultiple(of: 2) ? "Artist A" : "Artist B",
                genre: index.isMultiple(of: 3) ? "Pop" : "Rock"
            )
        }
        let behaviors = candidates.enumerated().map { index, candidate in
            behavior(
                song: candidate,
                playCount: index + 1,
                lastPlayed: date.addingTimeInterval(Double(-index * 3_600))
            )
        }
        let ascending = Dictionary(uniqueKeysWithValues: behaviors.map {
            ($0.song.id, $0)
        })
        let descending = Dictionary(uniqueKeysWithValues: behaviors.reversed().map {
            ($0.song.id, $0)
        })
        let snapshot = HomeSnapshot(randomSongs: candidates)

        RecommendationMixer.invalidateCache()
        let first = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: weights(),
            behavior: RecommendationBehaviorSnapshot(
                songs: ascending,
                recentSongs: Array(candidates.prefix(5)),
                revision: 7
            ),
            limit: 12,
            date: date
        )
        RecommendationMixer.invalidateCache()
        let second = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: weights(),
            behavior: RecommendationBehaviorSnapshot(
                songs: descending,
                recentSongs: Array(candidates.prefix(5)),
                revision: 7
            ),
            limit: 12,
            date: date
        )

        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testDiscoveryPurposeUsesItsFullDayTemporalLifetime() {
        RecommendationMixer.invalidateCache()
        let songs = (0..<40).map { index in
            song(
                id: "lifetime-\(index)",
                title: "Lifetime \(index)",
                artist: "Artist \(index)"
            )
        }
        let snapshot = HomeSnapshot(randomSongs: songs)
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let secondDate = firstDate.addingTimeInterval(2 * 3_600)

        let first = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: weights(),
            purpose: .discovery,
            limit: 20,
            date: firstDate
        )
        let second = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: weights(),
            purpose: .discovery,
            limit: 20,
            date: secondDate
        )

        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testLargeStarredCatalogDoesNotDisplaceHigherPrioritySources() {
        RecommendationMixer.invalidateCache()
        let preferred = song(
            id: "server-preferred",
            title: "Preferred",
            artist: "Preferred Artist",
            genre: "Pop"
        )
        let starred = (0..<800).map { index in
            song(
                id: "starred-\(index)",
                title: "Starred \(index)",
                artist: "Starred Artist \(index)",
                starred: "2026-08-01T00:00:00Z"
            )
        }
        let result = RecommendationMixer.mix(
            snapshot: HomeSnapshot(
                starredSongs: starred,
                serverRecommendedSongs: [preferred]
            ),
            weights: weights(),
            limit: 8,
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertTrue(result.contains { $0.id == preferred.id })
        XCTAssertLessThanOrEqual(result.count, 8)
    }

    func testCancelledRecommendationDoesNotPublishPartialResults() async {
        RecommendationMixer.invalidateCache()
        let songs = (0..<10_000).map { index in
            song(
                id: "cancel-\(index)",
                title: "Cancel \(index)",
                artist: "Artist \(index % 100)",
                genre: "Genre \(index % 20)"
            )
        }
        let snapshot = HomeSnapshot(randomSongs: songs)
        let recommendationWeights = weights()
        let task = Task.detached {
            RecommendationMixer.mix(
                snapshot: snapshot,
                weights: recommendationWeights,
                limit: 30,
                date: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
        task.cancel()

        let result = await task.value

        XCTAssertTrue(result.isEmpty)
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

    func testPersonalizedMixPrefersServerMetadataOverPersistedHistory() {
        var staleHistory = song(
            id: "same-id",
            title: "Old Title",
            artist: "Artist"
        )
        staleHistory.coverArt = "old-cover"
        var serverSong = staleHistory
        serverSong.title = "Current Title"
        serverSong.coverArt = "current-cover"

        let mixes = PersonalizedMixBuilder.make(
            snapshot: HomeSnapshot(
                serverRecommendedSongs: [serverSong],
                mostPlayedSongs: [staleHistory]
            ),
            date: Date(timeIntervalSince1970: 1_800_000_000),
            songLimit: 1
        )

        XCTAssertFalse(mixes.isEmpty)
        XCTAssertTrue(mixes.allSatisfy { mix in
            mix.songs.allSatisfy {
                $0.title == "Current Title" && $0.artworkID == "current-cover"
            }
        })
    }

    func testFavoriteIdentitySurvivesStaleCandidateMetadata() {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let staleFavorite = song(
            id: "favorite-id",
            title: "Favorite",
            artist: "Old Metadata Artist"
        )
        let currentFavorite = song(
            id: "favorite-id",
            title: "Favorite",
            artist: "Current Favorite Artist",
            starred: "2026-08-01T00:00:00Z"
        )
        let competitor = song(
            id: "known-competitor",
            title: "Competitor",
            artist: "Other Artist"
        )
        var recommendationWeights = isolatedWeights()
        recommendationWeights.favorites = 1
        recommendationWeights.discoveryRatio = 0

        let result = RecommendationMixer.mix(
            snapshot: HomeSnapshot(
                starredSongs: [currentFavorite],
                serverRecommendedSongs: [staleFavorite, competitor],
                mostPlayedSongs: [competitor]
            ),
            weights: recommendationWeights,
            purpose: .taste,
            limit: 2,
            date: date
        )

        XCTAssertEqual(result.first?.id, "favorite-id")
    }

    func testLocalRecommendationConsensusOutranksSingleSourceSignal() {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let consensus = song(
            id: "consensus-local",
            title: "Consensus",
            artist: "Consensus Artist"
        )
        let single = song(
            id: "single-local",
            title: "Single",
            artist: "Single Artist"
        )
        func filler(_ id: String) -> Song {
            song(id: id, title: id, artist: "Filler \(id)")
        }
        var recommendationWeights = isolatedWeights()
        recommendationWeights.serverSimilarity = 1
        recommendationWeights.discoveryRatio = 1
        let snapshot = HomeSnapshot(
            sonicRecommendedSongs: [filler("q0"), single, consensus],
            similarArtistSongs: [filler("m0"), consensus, filler("m2")],
            genreRecommendedSongs: [filler("g0"), consensus, filler("g2")],
            serverRecommendedSongs: [filler("s0"), consensus, filler("s2")]
        )

        let result = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: recommendationWeights,
            purpose: .artistMix,
            limit: 20,
            date: date
        )
        let consensusIndex = result.firstIndex { $0.id == consensus.id }
        let singleIndex = result.firstIndex { $0.id == single.id }

        XCTAssertNotNil(consensusIndex)
        XCTAssertNotNil(singleIndex)
        if let consensusIndex, let singleIndex {
            XCTAssertLessThan(consensusIndex, singleIndex)
        }
    }

    func testPersonalizedSearchableTextIncludesSecondaryGenresAndMoods() {
        var value = song(
            id: "secondary-metadata",
            title: "Neutral Title",
            artist: "Artist"
        )
        value.genres = [SongGenre(name: "K-Pop")]
        value.moods = ["Happy"]

        let text = PersonalizedMixBuilder.searchableText(value)

        XCTAssertTrue(text.contains("k-pop"))
        XCTAssertTrue(text.contains("happy"))
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

    private func isolatedWeights() -> RecommendationWeights {
        var value = weights()
        value.history = 0
        value.favorites = 0
        value.serverSimilarity = 0
        value.discovery = 0
        value.lastFM = 0
        value.listenBrainz = 0
        value.behavior = 0
        value.completion = 0
        value.repeatListening = 0
        value.recency = 0
        value.context = 0
        value.localMetadata = 0
        value.playlistAffinity = 0
        value.albumCompletion = 0
        value.forgottenFavorites = 0
        value.artistRotation = 0
        value.timeAwareness = 0
        value.discoveryRatio = 0.35
        return value
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

    private func behavior(
        song: Song,
        playCount: Int,
        lastPlayed: Date
    ) -> SongBehavior {
        var value = SongBehavior(song: song, at: lastPlayed)
        value.playCount = playCount
        value.manualPlayCount = playCount
        value.completedCount = playCount
        value.completionSamples = playCount
        value.totalCompletion = Double(playCount) * 0.9
        return value
    }
}
