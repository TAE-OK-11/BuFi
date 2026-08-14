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
