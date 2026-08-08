import Foundation
import XCTest
@testable import BuFi

final class PlaybackRecoveryPolicyTests: XCTestCase {
    func testRapidPersistentStallsIncrementTheSameRecoveryBurst() {
        let firstReload = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(
            PlaybackRecoveryPolicy.nextReloadAttempt(
                currentAttempt: 1,
                lastReloadAt: firstReload,
                now: firstReload.addingTimeInterval(5)
            ),
            2
        )
    }

    func testStablePlaybackStartsANewRecoveryBurst() {
        let firstReload = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(
            PlaybackRecoveryPolicy.nextReloadAttempt(
                currentAttempt: PlaybackRecoveryPolicy.maximumReloadAttempts,
                lastReloadAt: firstReload,
                now: firstReload.addingTimeInterval(
                    PlaybackRecoveryPolicy.stablePlaybackWindow
                )
            ),
            1
        )
    }

    func testReloadAttemptsAreBoundedWithinABurst() {
        XCTAssertTrue(PlaybackRecoveryPolicy.shouldReload(attempt: 1))
        XCTAssertTrue(
            PlaybackRecoveryPolicy.shouldReload(
                attempt: PlaybackRecoveryPolicy.maximumReloadAttempts
            )
        )
        XCTAssertFalse(
            PlaybackRecoveryPolicy.shouldReload(
                attempt: PlaybackRecoveryPolicy.maximumReloadAttempts + 1
            )
        )
    }
}
