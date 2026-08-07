import Foundation
import XCTest
@testable import BuFi

final class NetworkResiliencePolicyTests: XCTestCase {
    func testRetriesOnlyTransientTransportErrors() {
        XCTAssertTrue(
            NetworkResiliencePolicy.shouldRetry(
                URLError(.networkConnectionLost)
            )
        )
        XCTAssertTrue(
            NetworkResiliencePolicy.shouldRetry(
                URLError(.timedOut)
            )
        )
        XCTAssertFalse(
            NetworkResiliencePolicy.shouldRetry(
                URLError(.notConnectedToInternet)
            )
        )
        XCTAssertFalse(
            NetworkResiliencePolicy.shouldRetry(
                URLError(.badURL)
            )
        )
        XCTAssertFalse(
            NetworkResiliencePolicy.shouldRetry(
                CancellationError()
            )
        )
    }

    func testRetriesOnlySafeTransientHTTPStatuses() {
        for status in [408, 425, 500, 502, 503, 504] {
            XCTAssertTrue(
                NetworkResiliencePolicy.shouldRetryHTTPStatus(status),
                "Expected HTTP \(status) to be retryable"
            )
        }
        for status in [200, 400, 401, 403, 404, 409, 429] {
            XCTAssertFalse(
                NetworkResiliencePolicy.shouldRetryHTTPStatus(status),
                "Expected HTTP \(status) to fail without an automatic retry"
            )
        }
    }

    func testRetryDelayBacksOff() {
        XCTAssertLessThan(
            NetworkResiliencePolicy.retryDelay(afterAttempt: 0),
            NetworkResiliencePolicy.retryDelay(afterAttempt: 1)
        )
        XCTAssertLessThan(
            NetworkResiliencePolicy.retryDelay(afterAttempt: 1),
            NetworkResiliencePolicy.retryDelay(afterAttempt: 2)
        )
    }
}
