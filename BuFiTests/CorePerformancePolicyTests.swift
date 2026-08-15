import Foundation
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

    func testRecommendationScoringBoundsLargeCandidateSets() {
        let songs = (0..<500).map { index in
            Song(
                id: "candidate-\(index)",
                title: "Song \(index)",
                artist: "Artist",
                album: "Album",
                artistId: "artist",
                albumId: "album",
                coverArt: nil,
                duration: 180,
                track: nil,
                suffix: "m4a",
                contentType: "audio/mp4",
                starred: nil
            )
        }

        XCTAssertEqual(
            RecommendationScoringPolicy.scoringCandidateLimit,
            360
        )
        XCTAssertEqual(
            RecommendationScoringPolicy.boundedCandidates(Array(songs.prefix(10)))
                .map(\.id),
            songs.prefix(10).map(\.id)
        )
        XCTAssertEqual(
            RecommendationScoringPolicy.boundedCandidates(songs).map(\.id),
            songs.prefix(360).map(\.id)
        )
    }

    func testFavoriteOverrideFastPathSkipsWhenNothingIsPending() {
        XCTAssertTrue(
            FavoriteOverrideApplicationPolicy.canReuseSnapshot(
                hasOverrides: false,
                hasPendingMutations: false
            )
        )
        XCTAssertFalse(
            FavoriteOverrideApplicationPolicy.canReuseSnapshot(
                hasOverrides: true,
                hasPendingMutations: false
            )
        )
        XCTAssertFalse(
            FavoriteOverrideApplicationPolicy.canReuseSnapshot(
                hasOverrides: false,
                hasPendingMutations: true
            )
        )
    }

    func testExternalRecommendationRefreshSkipsIdenticalIdentity() {
        let revision = HomeSnapshotRevision()
        let identity = ExternalRecommendationRefreshIdentity(
            sessionGeneration: 3,
            snapshotRevision: revision,
            seedSongID: "seed",
            includesLastFM: true,
            includesListenBrainz: false
        )

        XCTAssertFalse(
            ExternalRecommendationRefreshPolicy.shouldRefresh(
                previous: identity,
                next: identity
            )
        )
        XCTAssertTrue(
            ExternalRecommendationRefreshPolicy.shouldRefresh(
                previous: identity,
                next: ExternalRecommendationRefreshIdentity(
                    sessionGeneration: 3,
                    snapshotRevision: revision.advanced(),
                    seedSongID: "seed",
                    includesLastFM: true,
                    includesListenBrainz: false
                )
            )
        )
        XCTAssertTrue(
            ExternalRecommendationRefreshPolicy.shouldRefresh(
                previous: nil,
                next: identity
            )
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
